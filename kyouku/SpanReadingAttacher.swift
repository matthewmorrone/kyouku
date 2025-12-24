import Foundation
import CoreFoundation
import Mecab_Swift
import IPADic
import OSLog

/// Stage 2 of the furigana pipeline. Consumes `TextSpan` boundaries, runs
/// MeCab/IPADic exactly once per input text, and attaches kana readings. No
/// SQLite lookups occur here, mirroring the behavior of commit 0e7736a.
struct SpanReadingAttacher {
    private static var sharedTokenizer: Tokenizer? = {
        try? Tokenizer(dictionary: IPADic())
    }()

    private static let cache = ReadingAttachmentCache(maxEntries: 32)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SpanReadingAttacher")
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SpanReadingAttacher")

    func attachReadings(text: String, spans: [TextSpan]) async -> [AnnotatedSpan] {
        guard text.isEmpty == false, spans.isEmpty == false else { return spans.map { AnnotatedSpan(span: $0, readingKana: nil) } }

        let start = CFAbsoluteTimeGetCurrent()
        let overallInterval = Self.signposter.beginInterval("AttachReadings Overall", "len=\(text.count) spans=\(spans.count)")

        let key = ReadingAttachmentCacheKey(textHash: Self.hash(text), spanSignature: Self.signature(for: spans))
        if let cached = await Self.cache.value(for: key) {
            let duration = Self.elapsedMilliseconds(since: start)
            Self.logger.debug("[SpanReadingAttacher] Cache hit for \(spans.count, privacy: .public) spans in \(duration, privacy: .public) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            return cached
        }

        let tokStart = CFAbsoluteTimeGetCurrent()
        let tokInterval = Self.signposter.beginInterval("Tokenizer Acquire")
        let tokenizerOpt = Self.tokenizer()
        Self.signposter.endInterval("Tokenizer Acquire", tokInterval)
        let tokMs = (CFAbsoluteTimeGetCurrent() - tokStart) * 1000
        if tokenizerOpt == nil {
            Self.logger.error("[SpanReadingAttacher] Tokenizer acquisition failed in \(String(format: "%.3f", tokMs)) ms")
        } else {
            Self.logger.info("[SpanReadingAttacher] Tokenizer acquired in \(String(format: "%.3f", tokMs)) ms")
        }
        guard let tokenizer = tokenizerOpt else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            await Self.cache.store(passthrough, for: key)
//            let duration = Self.elapsedMilliseconds(since: start)
//            Self.logger.error("[SpanReadingAttacher] Failed to acquire tokenizer. Returning passthrough spans in \(duration, privacy: .public) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            return passthrough
        }

        let tokenizeStart = CFAbsoluteTimeGetCurrent()
        let tokenizeInterval = Self.signposter.beginInterval("MeCab Tokenize", "len=\(text.count)")
        let annotations = tokenizer.tokenize(text: text).compactMap { annotation -> MeCabAnnotation? in
            let nsRange = NSRange(annotation.range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
            let surface = String(text[annotation.range])
            return MeCabAnnotation(range: nsRange, reading: annotation.reading, surface: surface)
        }
        Self.signposter.endInterval("MeCab Tokenize", tokenizeInterval)
        let tokenizeMs = (CFAbsoluteTimeGetCurrent() - tokenizeStart) * 1000
        Self.logger.info("[SpanReadingAttacher] MeCab tokenization produced \(annotations.count) annotations in \(String(format: "%.3f", tokenizeMs)) ms")

        var annotated: [AnnotatedSpan] = []
        annotated.reserveCapacity(spans.count)

        for span in spans {
            let reading = readingForSpan(span, annotations: annotations, tokenizer: tokenizer)
            annotated.append(AnnotatedSpan(span: span, readingKana: reading))
        }

        await Self.cache.store(annotated, for: key)
        let duration = Self.elapsedMilliseconds(since: start)
        Self.logger.info("[SpanReadingAttacher] Attached readings for \(spans.count, privacy: .public) spans in \(duration, privacy: .public) ms.")
        Self.signposter.endInterval("AttachReadings Overall", overallInterval)
        return annotated
    }

    private static func tokenizer() -> Tokenizer? {
        if let t = sharedTokenizer { return t }
        sharedTokenizer = try? Tokenizer(dictionary: IPADic())
        return sharedTokenizer
    }

    private func readingForSpan(_ span: TextSpan, annotations: [MeCabAnnotation], tokenizer: Tokenizer) -> String? {
        guard span.range.length > 0, containsKanji(span.surface) else { return nil }
        var builder = ""
        let spanEnd = span.range.location + span.range.length
        var coveringToken: MeCabAnnotation?

        for annotation in annotations {
            if annotation.range.location >= spanEnd { break }
            if NSLocationInRange(annotation.range.location, span.range) == false {
                continue
            }
            let intersection = NSIntersectionRange(span.range, annotation.range)
            if intersection.length == annotation.range.length {
                let chunk = annotation.reading.isEmpty ? annotation.surface : annotation.reading
                builder.append(chunk)
//                Self.logger.debug("[SpanReadingAttacher] Matched token surface=\(annotation.surface, privacy: .public) reading=\(chunk, privacy: .public) for span=\(span.surface, privacy: .public).")
            } else if coveringToken == nil, NSLocationInRange(span.range.location, annotation.range), NSMaxRange(span.range) <= NSMaxRange(annotation.range) {
                coveringToken = annotation
            }
        }

        if builder.isEmpty == false {
            let trimmed = Self.trimDictionaryOkurigana(surface: span.surface, reading: builder)
            let normalized = Self.toHiragana(trimmed)
            return normalized.isEmpty ? nil : normalized
        }

        if let token = coveringToken {
            let tokenReadingKatakana = Self.toKatakana(token.reading.isEmpty ? token.surface : token.reading)
            guard let stripped = Self.kanjiReadingFromToken(tokenSurface: token.surface, tokenReadingKatakana: tokenReadingKatakana) else { return nil }
            let normalizedFallback = Self.toHiragana(stripped)
//            Self.logger.debug("[SpanReadingAttacher] Fallback token surface=\(token.surface, privacy: .public) strippedReading=\(normalizedFallback, privacy: .public) for span=\(span.surface, privacy: .public).")
            return normalizedFallback.isEmpty ? nil : normalizedFallback
        }

        guard let retokenized = readingByRetokenizingSurface(span.surface, tokenizer: tokenizer) else { return nil }
        let trimmedRetokenized = Self.trimDictionaryOkurigana(surface: span.surface, reading: retokenized)
        let normalizedRetokenized = Self.toHiragana(trimmedRetokenized)
        return normalizedRetokenized.isEmpty ? nil : normalizedRetokenized
    }

    private func readingByRetokenizingSurface(_ surface: String, tokenizer: Tokenizer) -> String? {
        guard surface.isEmpty == false else { return nil }
        let tokens = tokenizer.tokenize(text: surface)
        guard tokens.isEmpty == false else { return nil }
        var builder = ""
        for token in tokens {
            let chunk: String
            if token.reading.isEmpty {
                chunk = String(surface[token.range])
            } else {
                chunk = token.reading
            }
            builder.append(chunk)
        }
        return builder.isEmpty ? nil : builder
    }

    static func kanjiReadingFromToken(tokenSurface: String, tokenReadingKatakana: String) -> String? {
        guard tokenReadingKatakana.isEmpty == false else { return nil }
        let okuriganaSuffix = kanaSuffix(in: tokenSurface)

        guard okuriganaSuffix.isEmpty == false else {
            return tokenReadingKatakana
        }

        let okuriganaKatakana = toKatakana(okuriganaSuffix)
        guard okuriganaKatakana.isEmpty == false else { return nil }
        guard tokenReadingKatakana.hasSuffix(okuriganaKatakana) else { return nil }

        let kanaCount = okuriganaKatakana.count
        guard kanaCount <= tokenReadingKatakana.count else { return nil }
        let endIndex = tokenReadingKatakana.index(tokenReadingKatakana.endIndex, offsetBy: -kanaCount)
        let kanjiReadingKatakana = String(tokenReadingKatakana[..<endIndex])
        return kanjiReadingKatakana.isEmpty ? nil : kanjiReadingKatakana
    }

    private static func kanaSuffix(in surface: String) -> String {
        guard surface.isEmpty == false else { return "" }
        var scalars: [UnicodeScalar] = []
        for scalar in surface.unicodeScalars.reversed() {
            if isKana(scalar) {
                scalars.append(scalar)
            } else {
                break
            }
        }
        guard scalars.isEmpty == false else { return "" }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// JMdict dictionary readings keep okurigana, but ruby should align to kanji only.
    private static func trimDictionaryOkurigana(surface: String, reading: String) -> String {
        guard reading.isEmpty == false else { return reading }
        guard let suffix = trailingKanaRun(in: surface), suffix.isEmpty == false else { return reading }
        guard reading.hasSuffix(suffix) else { return reading }
        let endIndex = reading.index(reading.endIndex, offsetBy: -suffix.count)
        return String(reading[..<endIndex])
    }

    private static func trailingKanaRun(in surface: String) -> String? {
        guard surface.isEmpty == false else { return nil }
        var scalars: [UnicodeScalar] = []
        for scalar in surface.unicodeScalars.reversed() {
            if isKana(scalar) {
                scalars.append(scalar)
            } else {
                break
            }
        }
        guard scalars.isEmpty == false else { return nil }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    private func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func toHiragana(_ reading: String) -> String {
        let mutable = NSMutableString(string: reading) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }

    private static func toKatakana(_ reading: String) -> String {
        let mutable = NSMutableString(string: reading) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, false)
        return mutable as String
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
    }

    private static func hash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    private static func signature(for spans: [TextSpan]) -> Int {
        var hasher = Hasher()
        hasher.combine(spans.count)
        for span in spans {
            hasher.combine(span.range.location)
            hasher.combine(span.range.length)
        }
        return hasher.finalize()
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}

private struct MeCabAnnotation {
    let range: NSRange
    let reading: String
    let surface: String
}

private struct ReadingAttachmentCacheKey: Sendable, nonisolated Hashable {
    let textHash: Int
    let spanSignature: Int

    nonisolated static func == (lhs: ReadingAttachmentCacheKey, rhs: ReadingAttachmentCacheKey) -> Bool {
        lhs.textHash == rhs.textHash && lhs.spanSignature == rhs.spanSignature
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(textHash)
        hasher.combine(spanSignature)
    }
}

private actor ReadingAttachmentCache {
    private var storage: [ReadingAttachmentCacheKey: [AnnotatedSpan]] = [:]
    private var order: [ReadingAttachmentCacheKey] = []
    private let maxEntries: Int

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func value(for key: ReadingAttachmentCacheKey) -> [AnnotatedSpan]? {
        storage[key]
    }

    func store(_ value: [AnnotatedSpan], for key: ReadingAttachmentCacheKey) {
        storage[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > maxEntries, let evicted = order.first {
            storage.removeValue(forKey: evicted)
            order.removeFirst()
        }
    }
}

