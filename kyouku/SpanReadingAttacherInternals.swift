import Foundation
import CoreFoundation
import Mecab_Swift
import IPADic
import OSLog

internal import StringTools

extension SpanReadingAttacher {
    private static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        let start = max(0, min(length, range.location))
        let end = max(start, min(length, NSMaxRange(range)))
        return NSRange(location: start, length: end - start)
    }

    private static func hardBoundaryCharacterSet() -> CharacterSet {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
    }

    static func isHardBoundaryOnly(_ surface: String) -> Bool {
        if surface.isEmpty { return true }
        for scalar in surface.unicodeScalars {
            if hardBoundaryCharacterSet().contains(scalar) == false {
                return false
            }
        }
        return true
    }

    private static func hardBoundaryRanges(in nsText: NSString) -> [NSRange] {
        let length = nsText.length
        guard length > 0 else { return [] }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(16)

        var cursor = 0
        var pendingStart: Int? = nil
        while cursor < length {
            let r = nsText.rangeOfComposedCharacterSequence(at: cursor)
            let s = nsText.substring(with: r)
            if isHardBoundaryOnly(s) {
                if pendingStart == nil { pendingStart = r.location }
            } else if let start = pendingStart {
                let end = r.location
                if end > start {
                    ranges.append(NSRange(location: start, length: end - start))
                }
                pendingStart = nil
            }
            cursor = NSMaxRange(r)
        }

        if let start = pendingStart, start < length {
            ranges.append(NSRange(location: start, length: length - start))
        }

        return ranges
    }

    private static func nonBoundaryRuns(in nsText: NSString, hardBoundaries: [NSRange]) -> [NSRange] {
        let length = nsText.length
        guard length > 0 else { return [] }
        guard hardBoundaries.isEmpty == false else { return [NSRange(location: 0, length: length)] }

        let sorted = hardBoundaries.sorted { $0.location < $1.location }
        var runs: [NSRange] = []
        runs.reserveCapacity(sorted.count + 1)

        var cursor = 0
        for b in sorted {
            if b.location > cursor {
                runs.append(NSRange(location: cursor, length: b.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(b))
        }
        if cursor < length {
            runs.append(NSRange(location: cursor, length: length - cursor))
        }
        return runs
    }

    private static func split(_ range: NSRange, excluding boundaries: [NSRange]) -> [NSRange] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        guard boundaries.isEmpty == false else { return [range] }

        let rangeEnd = NSMaxRange(range)
        let sorted = boundaries.sorted { $0.location < $1.location }
        var pieces: [NSRange] = []
        pieces.reserveCapacity(2)

        var cursor = range.location
        for b in sorted {
            if b.location >= rangeEnd { break }
            let bEnd = NSMaxRange(b)
            if bEnd <= cursor { continue }
            if b.location > cursor {
                let piece = NSRange(location: cursor, length: b.location - cursor)
                if piece.length > 0 { pieces.append(piece) }
            }
            cursor = max(cursor, bEnd)
            if cursor >= rangeEnd { break }
        }

        if cursor < rangeEnd {
            let piece = NSRange(location: cursor, length: rangeEnd - cursor)
            if piece.length > 0 { pieces.append(piece) }
        }

        return pieces
    }

    private static func sourceSpanIndexRange(intersecting range: NSRange, spans: [TextSpan]) -> Range<Int> {
        guard spans.isEmpty == false else { return 0..<0 }
        var start: Int? = nil
        var endExclusive: Int? = nil
        for (idx, span) in spans.enumerated() {
            if NSIntersectionRange(span.range, range).length > 0 {
                if start == nil { start = idx }
                endExclusive = idx + 1
            } else if let s = start, idx > s {
                // Spans are ordered and should be contiguous; once we leave, we can stop.
                if span.range.location >= NSMaxRange(range) { break }
            }
        }
        let s = start ?? 0
        let e = endExclusive ?? min(spans.count, s + 1)
        return s..<e
    }

    private static func semanticFallbackSpans(
        in range: NSRange,
        nsText: NSString,
        spans: [TextSpan],
        annotatedSpans: [AnnotatedSpan]
    ) -> [SemanticSpan] {
        guard range.length > 0 else { return [] }
        var out: [SemanticSpan] = []
        out.reserveCapacity(4)

        for (idx, span) in spans.enumerated() {
            let intersection = NSIntersectionRange(span.range, range)
            guard intersection.length > 0 else { continue }
            guard NSMaxRange(intersection) <= nsText.length else { continue }
            let surface = nsText.substring(with: intersection)
            guard isHardBoundaryOnly(surface) == false else { continue }

            let reading = (idx < annotatedSpans.count) ? annotatedSpans[idx].readingKana : nil
            out.append(SemanticSpan(range: intersection, surface: surface, sourceSpanIndices: idx..<(idx + 1), readingKana: reading))
        }

        // If Stage-1 spans didn't cover this region cleanly (should be rare), fall back to a single span.
        if out.isEmpty {
            let surface = nsText.substring(with: range)
            if isHardBoundaryOnly(surface) == false {
                out.append(SemanticSpan(range: range, surface: surface, sourceSpanIndices: 0..<0, readingKana: nil))
            }
        }

        return out
    }

    private static func isWhitespaceOrPunctuationOnly(_ surface: String) -> Bool {
        isHardBoundaryOnly(surface)
    }

    static func tokenizer() -> Tokenizer? {
        if let t = sharedTokenizer { return t }
        sharedTokenizer = try? Tokenizer(dictionary: IPADic())
        return sharedTokenizer
    }

    private typealias RetokenizedResult = (reading: String, lemmas: [String])

    func sanitizeRubyReading(_ reading: String?) -> String? {
        guard let reading else { return nil }
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        // Ruby should be kana. Drop anything that contains kanji or contains no kana.
        guard containsKanji(trimmed) == false else { return nil }
        guard trimmed.unicodeScalars.contains(where: { Self.isKana($0) }) else { return nil }
        return trimmed
    }

    /// Contextual reading rewrites.
    ///
    /// Keep these narrow and predictable. They exist to match common phrase-level
    /// realizations without doing phrase-aware tokenization.
    static func applyContextualReadingRules(
        surface: String,
        reading: String?,
        nsText: NSString,
        range: NSRange
    ) -> String? {
        guard let reading else { return reading }
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return reading }

        let normalized = Self.toHiragana(trimmed)

        func composedCharacter(at utf16Index: Int) -> (surface: String, range: NSRange)? {
            guard utf16Index >= 0, utf16Index < nsText.length else { return nil }
            let r = nsText.rangeOfComposedCharacterSequence(at: utf16Index)
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= nsText.length else { return nil }
            return (nsText.substring(with: r), r)
        }

        func composedCharacterString(at utf16Index: Int) -> String? {
            composedCharacter(at: utf16Index)?.surface
        }

        func isNumericKanji(_ s: String) -> Bool {
            // Covers common numeric kanji used in compounds like 二人三脚 / 一人二役.
            // Keep this intentionally narrow and best-effort.
            guard s.count == 1 else { return false }
            return "一二三四五六七八九十百千".contains(s)
        }

        func isDigitLike(_ s: String) -> Bool {
            guard s.count == 1, let scalar = s.unicodeScalars.first else { return false }
            return (0x30...0x39).contains(scalar.value) || (0xFF10...0xFF19).contains(scalar.value)
        }

        func containsKanjiGlyph(_ s: String) -> Bool {
            s.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3400...0x4DBF, // CJK Ext A
                     0x4E00...0x9FFF: // CJK Unified
                    return true
                default:
                    return false
                }
            }
        }

        switch surface {
        case "一人":
            if normalized == "いちにん" || normalized == "いちじん" {
                let end = NSMaxRange(range)
                if let next = composedCharacterString(at: end), containsKanjiGlyph(next), isNumericKanji(next) {
                    return reading
                }
                return "ひとり"
            }
            return reading

        case "二人":
            if normalized == "ににん" {
                let end = NSMaxRange(range)
                if let next = composedCharacterString(at: end), containsKanjiGlyph(next), isNumericKanji(next) {
                    return reading
                }
                return "ふたり"
            }
            return reading

        case "中":
            // In counter-like compounds (中 + <number> + 人), MeCab frequently prefers the
            // on-yomi reading (ちゅう), but the common reading is なか (e.g. 中二人 → なかふたり).
            // Keep this narrowly scoped to avoid changing standalone "中" defaults.
            guard normalized == "ちゅう" else { return reading }
            let end = NSMaxRange(range)
            guard end >= 0, end < nsText.length else { return reading }

            var cursor = end
            var consumed = 0
            var sawNumber = false
            while cursor < nsText.length, consumed < 4 {
                guard let next = composedCharacter(at: cursor) else { break }
                if isNumericKanji(next.surface) || isDigitLike(next.surface) {
                    sawNumber = true
                    cursor = NSMaxRange(next.range)
                    consumed += 1
                    continue
                }
                break
            }

            guard sawNumber, cursor < nsText.length, let afterNumber = composedCharacterString(at: cursor), afterNumber == "人" else {
                return reading
            }

            return "なか"

        case "何":
            // Only rewrite the common dictionary-like "なに".
            guard normalized == "なに" else { return reading }

            // Look ahead in the original text.
            let end = NSMaxRange(range)
            guard end >= 0, end < nsText.length else { return reading }
            let lookaheadLen = min(6, nsText.length - end)
            guard lookaheadLen > 0 else { return reading }
            let remainder = nsText.substring(with: NSRange(location: end, length: lookaheadLen))

            // Common "なん" contexts: 何で / 何でも / 何だ / 何て / 何と / 何の / 何なら.
            if remainder.hasPrefix("で") ||
                remainder.hasPrefix("だ") ||
                remainder.hasPrefix("て") ||
                remainder.hasPrefix("と") ||
                remainder.hasPrefix("の") ||
                remainder.hasPrefix("なら")
            {
                return "なん"
            }

            return reading

        default:
            return reading
        }
    }

    func attachmentForSpan(_ span: TextSpan, annotations: [MeCabAnnotation], tokenizer: Tokenizer) -> SpanAttachmentResult {
        guard span.range.length > 0 else { return SpanAttachmentResult(reading: nil, lemmas: [], partOfSpeech: nil) }

        var lemmaCandidates: [String] = []
        var posCandidates: [String] = []
        let requiresReading = containsKanji(span.surface)
        var builder = requiresReading ? "" : nil
        var hasPartialTokenOverlap = false
        let spanEnd = span.range.location + span.range.length
        var coveringToken: MeCabAnnotation?
        var retokenizedCache: RetokenizedResult?
        var preferredKanaLemma: String? = nil

        for annotation in annotations {
            if annotation.range.location >= spanEnd { break }
            let intersection = NSIntersectionRange(span.range, annotation.range)
            guard intersection.length > 0 else { continue }
            Self.appendLemmaCandidate(annotation.dictionaryForm, to: &lemmaCandidates)
            Self.appendPartOfSpeechCandidate(annotation.partOfSpeech, to: &posCandidates)

            // Some nouns have a kana-only dictionary form even when the surface includes kanji
            // (e.g. 一人 -> ひとり). If present, this is often the best default ruby reading.
            if preferredKanaLemma == nil {
                let raw = annotation.dictionaryForm.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty == false {
                    let isKanaOnly = raw.unicodeScalars.allSatisfy { scalar in
                        CharacterSet.hiragana.contains(scalar) || CharacterSet.katakana.contains(scalar)
                    }
                    if isKanaOnly {
                        preferredKanaLemma = raw
                    }
                }
            }

            guard requiresReading else { continue }
            if intersection.length == annotation.range.length {
                let chunk = annotation.reading.isEmpty ? annotation.surface : annotation.reading
                builder?.append(chunk)
                // Self.debug("[SpanReadingAttacher] Matched token surface=\(annotation.surface) reading=\(chunk) for span=\(span.surface).")
            } else {
                hasPartialTokenOverlap = true
                if coveringToken == nil,
                      NSLocationInRange(span.range.location, annotation.range),
                      NSMaxRange(span.range) <= NSMaxRange(annotation.range) {
                    coveringToken = annotation
                }
            }
        }

        var readingResult: String?

        if requiresReading {
            if let built = builder, built.isEmpty == false, hasPartialTokenOverlap == false {
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

        // Reading sanitation:
        // MeCab can legitimately produce tokens with empty readings (esp. for punctuation/rare glyphs),
        // and our fallback path can yield `token.surface` as the “reading source”. When the surface is
        // kanji (e.g. 以 / 對 / 茲), this produces a kanji "reading" which then gets rendered as ruby.
        // Only keep readings that contain at least one kana scalar and contain no kanji.
        if let r = readingResult {
            let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                readingResult = nil
            } else if containsKanji(trimmed) {
                readingResult = nil
            } else if trimmed.unicodeScalars.contains(where: { Self.isKana($0) }) == false {
                readingResult = nil
            } else {
                readingResult = trimmed
            }
        }

        if lemmaCandidates.isEmpty,
           let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
            lemmaCandidates = retokenized.lemmas
        }

        // Irregular counters (人): prefer the common kun readings for ruby.
        // MeCab frequently chooses the Sino counter readings (いちにん/ににん), but for
        // standalone surfaces the default users expect is typically ひとり/ふたり.
        if requiresReading {
            switch span.surface {
            case "一人":
                if readingResult == nil || readingResult == "いちにん" {
                    readingResult = "ひとり"
                }
            case "二人":
                if readingResult == nil || readingResult == "ににん" {
                    readingResult = "ふたり"
                }
            default:
                break
            }
        }

        // Prefer kana-only dictionary form as the default ruby for noun-like kanji surfaces.
        // This avoids always surfacing counter-style readings when MeCab provides a more
        // idiomatic kana lemma (e.g. 一人: ひとり vs いちにん).
        if requiresReading,
           let kanaLemma = preferredKanaLemma,
           kanaLemma.isEmpty == false {
            let isNounLike = posCandidates.contains { $0.contains("名詞") }
            if isNounLike {
                let normalizedLemma = Self.toHiragana(kanaLemma).trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedLemma.isEmpty == false {
                    let current = readingResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if current.isEmpty == false, current != normalizedLemma {
                        readingResult = normalizedLemma
                    }
                }
            }
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

    func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func toHiragana(_ reading: String) -> String {
        let mutable = NSMutableString(string: reading) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }

    static func toKatakana(_ reading: String) -> String {
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

    static func hash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    static func signature(for spans: [TextSpan]) -> Int {
        var hasher = Hasher()
        hasher.combine(spans.count)
        for span in spans {
            hasher.combine(span.range.location)
            hasher.combine(span.range.length)
        }
        return hasher.finalize()
    }

    static func signature(forCuts cuts: [Int]) -> Int {
        guard cuts.isEmpty == false else { return 0 }
        var hasher = Hasher()
        hasher.combine(cuts.count)
        // Order-independent.
        for c in cuts.sorted() {
            hasher.combine(c)
        }
        return hasher.finalize()
    }

    static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    struct MeCabAnnotation {
        let range: NSRange
        let reading: String
        let surface: String
        let dictionaryForm: String
        let partOfSpeech: String
    }

    struct SpanAttachmentResult {
        let reading: String?
        let lemmas: [String]
        let partOfSpeech: String?
    }

    struct ReadingAttachmentCacheKey: Sendable, nonisolated Hashable {
        let textHash: Int
        let spanSignature: Int
        let treatSpanBoundariesAsAuthoritative: Bool
        let hardCutsSignature: Int

        nonisolated static func == (lhs: ReadingAttachmentCacheKey, rhs: ReadingAttachmentCacheKey) -> Bool {
            lhs.textHash == rhs.textHash &&
                lhs.spanSignature == rhs.spanSignature &&
                lhs.treatSpanBoundariesAsAuthoritative == rhs.treatSpanBoundariesAsAuthoritative &&
                lhs.hardCutsSignature == rhs.hardCutsSignature
        }

        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(textHash)
            hasher.combine(spanSignature)
            hasher.combine(treatSpanBoundariesAsAuthoritative)
            hasher.combine(hardCutsSignature)
        }
    }

    actor ReadingAttachmentCache {
        private var storage: [ReadingAttachmentCacheKey: SpanReadingAttacher.Result] = [:]
        private var order: [ReadingAttachmentCacheKey] = []
        private let maxEntries: Int

        init(maxEntries: Int) {
            self.maxEntries = maxEntries
        }

        func value(for key: ReadingAttachmentCacheKey) -> SpanReadingAttacher.Result? {
            storage[key]
        }

        func store(_ value: SpanReadingAttacher.Result, for key: ReadingAttachmentCacheKey) {
            storage[key] = value
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > maxEntries, let evicted = order.first {
                storage.removeValue(forKey: evicted)
                order.removeFirst()
            }
        }
    }
}
