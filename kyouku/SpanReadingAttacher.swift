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

    private static func info(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.info("[\(file):\(line)] \(function): \(message)")
    }

    private static func debug(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.debug("[\(file):\(line)] \(function): \(message)")
    }

    func attachReadings(text: String, spans: [TextSpan]) async -> [AnnotatedSpan] {
        guard text.isEmpty == false, spans.isEmpty == false else { return spans.map { AnnotatedSpan(span: $0, readingKana: nil) } }

        let start = CFAbsoluteTimeGetCurrent()
        let overallInterval = Self.signposter.beginInterval("AttachReadings Overall", "len=\(text.count) spans=\(spans.count)")

        let key = ReadingAttachmentCacheKey(textHash: Self.hash(text), spanSignature: Self.signature(for: spans))
        if let cached = await Self.cache.value(for: key) {
            let duration = Self.elapsedMilliseconds(since: start)
            Self.debug("[SpanReadingAttacher] Cache hit for \(spans.count) spans in \(duration) ms.")
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
            Self.info("[SpanReadingAttacher] Tokenizer acquired in \(String(format: "%.3f", tokMs)) ms")
        }
        guard let tokenizer = tokenizerOpt else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            await Self.cache.store(passthrough, for: key)
//            Self.info("[SpanReadingAttacher] Failed to acquire tokenizer. Returning passthrough spans in (duration) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            return passthrough
        }

        let tokenizeStart = CFAbsoluteTimeGetCurrent()
        let tokenizeInterval = Self.signposter.beginInterval("MeCab Tokenize", "len=\(text.count)")
        let annotations = tokenizer.tokenize(text: text).compactMap { annotation -> MeCabAnnotation? in
            let nsRange = NSRange(annotation.range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
            let surface = String(text[annotation.range])
            let pos = String(describing: annotation.partOfSpeech)
            return MeCabAnnotation(range: nsRange, reading: annotation.reading, surface: surface, dictionaryForm: annotation.dictionaryForm, partOfSpeech: pos)
        }
        Self.signposter.endInterval("MeCab Tokenize", tokenizeInterval)
        let tokenizeMs = (CFAbsoluteTimeGetCurrent() - tokenizeStart) * 1000
        Self.info("[SpanReadingAttacher] MeCab tokenization produced \(annotations.count) annotations in \(String(format: "%.3f", tokenizeMs)) ms")

        var annotated: [AnnotatedSpan] = []
        annotated.reserveCapacity(spans.count)

        for span in spans {
            let attachment = attachmentForSpan(span, annotations: annotations, tokenizer: tokenizer)
            let override = await ReadingOverridePolicy.shared.overrideReading(for: span.surface, mecabReading: attachment.reading)
            let finalReading = override ?? attachment.reading
            annotated.append(AnnotatedSpan(span: span, readingKana: finalReading, lemmaCandidates: attachment.lemmas, partOfSpeech: attachment.partOfSpeech))
        }

        await Self.cache.store(annotated, for: key)
        let duration = Self.elapsedMilliseconds(since: start)
        Self.info("[SpanReadingAttacher] Attached readings for \(spans.count) spans in \(String(format: "%.3f", duration)) ms.")
        Self.signposter.endInterval("AttachReadings Overall", overallInterval)
        return annotated
    }

    private static func tokenizer() -> Tokenizer? {
        if let t = sharedTokenizer { return t }
        sharedTokenizer = try? Tokenizer(dictionary: IPADic())
        return sharedTokenizer
    }

    private typealias RetokenizedResult = (reading: String, lemmas: [String])

    private func attachmentForSpan(_ span: TextSpan, annotations: [MeCabAnnotation], tokenizer: Tokenizer) -> SpanAttachmentResult {
        guard span.range.length > 0 else { return SpanAttachmentResult(reading: nil, lemmas: [], partOfSpeech: nil) }

        var lemmaCandidates: [String] = []
        var posCandidates: [String] = []
        let requiresReading = containsKanji(span.surface)
        var builder = requiresReading ? "" : nil
        let spanEnd = span.range.location + span.range.length
        var coveringToken: MeCabAnnotation?
        var retokenizedCache: RetokenizedResult?

        for annotation in annotations {
            if annotation.range.location >= spanEnd { break }
            let intersection = NSIntersectionRange(span.range, annotation.range)
            guard intersection.length > 0 else { continue }
            Self.appendLemmaCandidate(annotation.dictionaryForm, to: &lemmaCandidates)
            Self.appendPartOfSpeechCandidate(annotation.partOfSpeech, to: &posCandidates)

            guard requiresReading else { continue }
            if intersection.length == annotation.range.length {
                let chunk = annotation.reading.isEmpty ? annotation.surface : annotation.reading
                builder?.append(chunk)
//                Self.debug("[SpanReadingAttacher] Matched token surface=\(annotation.surface) reading=\(chunk) for span=\(span.surface).")
            } else if coveringToken == nil,
                      NSLocationInRange(span.range.location, annotation.range),
                      NSMaxRange(span.range) <= NSMaxRange(annotation.range) {
                coveringToken = annotation
            }
        }

        var readingResult: String?

        if requiresReading {
            if let built = builder, built.isEmpty == false {
                // Keep the full reading (including okurigana) and let the ruby projector
                // split/trim against the surface text. Pre-trimming here can cause the
                // projector to mis-detect kana boundaries (e.g. "私たち" -> "わ").
                let normalized = Self.toHiragana(built)
                readingResult = normalized.isEmpty ? nil : normalized
            } else if let token = coveringToken {
                let tokenReadingSource: String
                if token.reading.isEmpty == false {
                    tokenReadingSource = token.reading
                } else if let retokenized = readingByRetokenizingSurface(token.surface, tokenizer: tokenizer)?.reading, retokenized.isEmpty == false {
                    tokenReadingSource = retokenized
                } else {
                    tokenReadingSource = token.surface
                }

                let tokenReadingKatakana = Self.toKatakana(tokenReadingSource)
                if containsKanji(tokenReadingKatakana) == false,
                   let stripped = Self.kanjiReadingFromToken(tokenSurface: token.surface, tokenReadingKatakana: tokenReadingKatakana) {
                    let normalizedFallback = Self.toHiragana(stripped)
                    readingResult = normalizedFallback.isEmpty ? nil : normalizedFallback
                }

                if readingResult == nil,
                   let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
                    let normalized = Self.toHiragana(retokenized.reading)
                    readingResult = normalized.isEmpty ? nil : normalized
                }
            } else if let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
                let normalized = Self.toHiragana(retokenized.reading)
                readingResult = normalized.isEmpty ? nil : normalized
            }
        }

        if lemmaCandidates.isEmpty,
           let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
            lemmaCandidates = retokenized.lemmas
        }

        let posSummary: String? = posCandidates.isEmpty ? nil : posCandidates.joined(separator: " / ")
        return SpanAttachmentResult(reading: readingResult, lemmas: lemmaCandidates, partOfSpeech: posSummary)
    }

    private func retokenizedResult(for span: TextSpan, tokenizer: Tokenizer, cache: inout RetokenizedResult?) -> RetokenizedResult? {
        if cache == nil {
            cache = readingByRetokenizingSurface(span.surface, tokenizer: tokenizer)
        }
        return cache
    }

    private func readingByRetokenizingSurface(_ surface: String, tokenizer: Tokenizer) -> RetokenizedResult? {
        guard surface.isEmpty == false else { return nil }
        let tokens = tokenizer.tokenize(text: surface)
        guard tokens.isEmpty == false else { return nil }
        var builder = ""
        var lemmas: [String] = []
        for token in tokens {
            let chunk: String
            if token.reading.isEmpty {
                chunk = String(surface[token.range])
            } else {
                chunk = token.reading
            }
            builder.append(chunk)
            Self.appendLemmaCandidate(token.dictionaryForm, to: &lemmas)
        }
        return builder.isEmpty ? nil : (builder, lemmas)
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

    private static func appendLemmaCandidate(_ candidate: String?, to list: inout [String]) {
        guard let lemma = normalizeLemma(candidate) else { return }
        if list.contains(lemma) == false {
            list.append(lemma)
        }
    }

    private static func appendPartOfSpeechCandidate(_ candidate: String, to list: inout [String]) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard trimmed != "unknown" else { return }
        if list.contains(trimmed) == false {
            list.append(trimmed)
        }
    }

    private static func normalizeLemma(_ candidate: String?) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), candidate.isEmpty == false else { return nil }
        guard candidate != "*" else { return nil }
        return toHiragana(candidate)
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
    let dictionaryForm: String
    let partOfSpeech: String
}

private struct SpanAttachmentResult {
    let reading: String?
    let lemmas: [String]
    let partOfSpeech: String?
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

