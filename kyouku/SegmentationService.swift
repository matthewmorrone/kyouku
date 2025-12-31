import Foundation
import OSLog

/// Stage 1 of the furigana pipeline. Produces bounded, lexicon-driven spans by
/// walking the shared JMdict trie. No readings or semantic metadata escape this
/// layer, and SQLite is never touched after the trie finishes bootstrapping.
actor SegmentationService {
    static let shared = SegmentationService()

    static func describe(spans: [TextSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SegmentationService")

    private func info(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) async {
        if await loggingEnabled() == false { return }
        logger.info("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }

    private func debug(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) async {
        if await loggingEnabled() == false { return }
        logger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }

    private func loggingEnabled() async -> Bool {
        await MainActor.run { DiagnosticsLogging.isEnabled(.furigana) }
    }

    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SegmentationService")
    private var cache: [SegmentationCacheKey: [TextSpan]] = [:]
    private var lruKeys: [SegmentationCacheKey] = []
    private let maxEntries = 32

    private var trieCache: LexiconTrie?
    private var trieInitTask: Task<LexiconTrie, Error>?

    func segment(text: String) async throws -> [TextSpan] {
        guard text.isEmpty == false else { return [] }
        let overallStart = CFAbsoluteTimeGetCurrent()
        let segInterval = signposter.beginInterval("Segment", id: .exclusive, "len=\(text.count)")
        let key = SegmentationCacheKey(textHash: Self.hash(text), length: text.utf16.count)
        if let cached = cache[key] {
            await debug("[Segmentation] Cache hit for len=\(text.count) -> \(cached.count) spans.")
            signposter.endInterval("Segment", segInterval)
            return cached
        } else {
            await debug("[Segmentation] Cache miss for len=\(text.count). Proceeding to segment.")
        }

        let trieInterval = signposter.beginInterval("TrieLoad")
        let trieLoadStart = CFAbsoluteTimeGetCurrent()
        let trie = try await getTrie()
        let trieLoadMs = (CFAbsoluteTimeGetCurrent() - trieLoadStart) * 1000
        let trieSource = (trieInitTask == nil && trieCache != nil) ? "cached" : (trieInitTask != nil ? "building" : "unknown")
        await debug("SegmentationService: trie load completed (source=\(trieSource)) in \(String(format: "%.3f", trieLoadMs)) ms.")
        signposter.endInterval("TrieLoad", trieInterval)

        let nsText = text as NSString

        let rangesInterval = signposter.beginInterval("SegmentRanges")
        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let ranges = await segmentRanges(using: trie, text: nsText)
        let segmentationMs = (CFAbsoluteTimeGetCurrent() - segmentationStart) * 1000
        await debug("SegmentationService: segmentRanges took \(String(format: "%.3f", segmentationMs)) ms.")
        signposter.endInterval("SegmentRanges", rangesInterval)

        let mapInterval = signposter.beginInterval("MapRangesToSpans")
        let mapStart = CFAbsoluteTimeGetCurrent()
        let spans = ranges.flatMap { segmented -> [TextSpan] in
            guard let trimmedRange = Self.trimmedRange(from: segmented.range, in: nsText) else { return [] }
            let newlineSeparated = Self.splitRangeByNewlines(trimmedRange, in: nsText)
            return newlineSeparated.compactMap { segment -> TextSpan? in
                guard let clamped = Self.trimmedRange(from: segment, in: nsText) else { return nil }
                let surface = nsText.substring(with: clamped)
                return TextSpan(range: clamped, surface: surface, isLexiconMatch: segmented.isLexiconMatch)
            }
        }
        let mapMs = (CFAbsoluteTimeGetCurrent() - mapStart) * 1000
        await debug("SegmentationService: mapping ranges->spans took \(String(format: "%.3f", mapMs)) ms.")
        signposter.endInterval("MapRangesToSpans", mapInterval)

        store(spans, for: key)
        let overallDurationMsDouble = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
        await debug("Segmented text length \(text.count) into \(spans.count) spans in \(String(format: "%.3f", overallDurationMsDouble)) ms (trie: \(String(format: "%.3f", trieLoadMs)) ms, segment: \(String(format: "%.3f", segmentationMs)) ms, map: \(String(format: "%.3f", mapMs)) ms).")
        signposter.endInterval("Segment", segInterval)
        return spans
    }

    private func store(_ spans: [TextSpan], for key: SegmentationCacheKey) {
        cache[key] = spans
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
        if lruKeys.count > maxEntries, let evicted = lruKeys.first {
            cache[evicted] = nil
            lruKeys.removeFirst()
        }
    }

    private static func hash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    private func flushPendingNonKanji(start: inout Int?, kind: inout ScriptKind?, cursor: Int, text: NSString, trie: LexiconTrie, into ranges: inout [SegmentedRange]) async -> Bool {
        guard let pending = start, pending < cursor else { return false }
        let pendingRange = NSRange(location: pending, length: cursor - pending)
        if let scriptKind = kind, await ScriptKind.equals(scriptKind, .katakana) {
            ranges.append(contentsOf: await Self.splitKatakana(range: pendingRange, text: text, trie: trie))
        } else {
            ranges.append(SegmentedRange(range: pendingRange, isLexiconMatch: false))
        }
        start = nil
        kind = nil
        return true
    }

    private static func splitKatakana(range: NSRange, text: NSString, trie: LexiconTrie) async -> [SegmentedRange] {
        var results: [SegmentedRange] = []
        let swiftText: String = text as String
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end {
            let current = cursor
            let matchEnd: Int? = await MainActor.run { [current, swiftText] in
                let ns = swiftText as NSString
                return trie.longestMatchEnd(in: ns, from: current, requireKanji: false)
            }
            if let matchEnd, matchEnd <= end, matchEnd > cursor {
                results.append(SegmentedRange(range: NSRange(location: cursor, length: matchEnd - cursor), isLexiconMatch: true))
                cursor = matchEnd
                continue
            }
            results.append(SegmentedRange(range: NSRange(location: cursor, length: 1), isLexiconMatch: false))
            cursor += 1
        }
        return results
    }

    private static func trimmedRange(from range: NSRange, in text: NSString) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var start = range.location
        var end = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines
        while start < end {
            guard let scalar = UnicodeScalar(text.character(at: start)) else { break }
            if whitespace.contains(scalar) {
                start += 1
            } else {
                break
            }
        }
        while end > start {
            guard let scalar = UnicodeScalar(text.character(at: end - 1)) else { break }
            if whitespace.contains(scalar) {
                end -= 1
            } else {
                break
            }
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func splitRangeByNewlines(_ range: NSRange, in text: NSString) -> [NSRange] {
        guard range.length > 0 else { return [] }
        var segments: [NSRange] = []
        var segmentStart = range.location
        let upperBound = NSMaxRange(range)
        var index = range.location
        while index < upperBound {
            let unit = text.character(at: index)
            if let scalar = UnicodeScalar(unit), newlineCharacters.contains(scalar) {
                if index > segmentStart {
                    segments.append(NSRange(location: segmentStart, length: index - segmentStart))
                }
                segmentStart = index + 1
            }
            index += 1
        }
        if segmentStart < upperBound {
            segments.append(NSRange(location: segmentStart, length: upperBound - segmentStart))
        }
        return segments
    }

    private func getTrie() async throws -> LexiconTrie {
        let start = CFAbsoluteTimeGetCurrent()
        if let t = trieCache {
            await debug("getTrie(): returning cached trie in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
            return t
        }
        if let task = trieInitTask {
            await debug("getTrie(): awaiting existing build task…")
            return try await task.value
        }
        await debug("getTrie(): creating new build task…")
        let task = Task { try await LexiconProvider.shared.trie() }
        trieInitTask = task
        let t = try await task.value
        trieCache = t
        trieInitTask = nil
        await debug("getTrie(): build task completed in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
        return t
    }

    private func segmentRanges(using trie: LexiconTrie, text: NSString) async -> [SegmentedRange] {
        let length = text.length
        guard length > 0 else { return [] }

        await debug("segmentRanges: starting scan length=\(length)")

        var ranges: [SegmentedRange] = []
        ranges.reserveCapacity(max(1, length / 2))

        var kanjiCount = 0
        var nonKanjiCount = 0
        var trieLookups = 0
        var matchesFound = 0
        var singletonKanji = 0
        var sumMatchLen = 0
        var maxMatchLen = 0
        var trieLookupTime: Double = 0

        await MainActor.run {
            trie.beginProfiling()
        }
        // Make a Sendable copy to avoid capturing NSString in a @Sendable closure
        let swiftText: String = text as String
        let profilingStart = CFAbsoluteTimeGetCurrent()
        let loopInterval = signposter.beginInterval("SegmentRangesLoop", "len=\(length)")

        var cursor = 0
        var pendingNonKanjiStart: Int? = nil
        var pendingNonKanjiKind: ScriptKind? = nil
        while cursor < length {
            trieLookups += 1
            let lookupStart = CFAbsoluteTimeGetCurrent()
            let current = cursor
            let matchEnd: Int? = await MainActor.run { [current, swiftText] in
                let ns = swiftText as NSString
                return trie.longestMatchEnd(in: ns, from: current)
            }
            if let end = matchEnd {
                trieLookupTime += CFAbsoluteTimeGetCurrent() - lookupStart
                if await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges) {
                    // start cleared inside helper
                }
                let extendedEnd = await extendMatchEnd(
                    trie: trie,
                    swiftText: swiftText,
                    text: text,
                    startIndex: current,
                    initialEnd: end,
                    totalLength: length
                )
                let len = extendedEnd - cursor
                sumMatchLen += len
                if len > maxMatchLen { maxMatchLen = len }
                let range = NSRange(location: cursor, length: len)
                ranges.append(SegmentedRange(range: range, isLexiconMatch: true))
                matchesFound += 1
                cursor = extendedEnd
                continue
            }
            trieLookupTime += CFAbsoluteTimeGetCurrent() - lookupStart

            let unit = text.character(at: cursor)
            guard let scalar = UnicodeScalar(unit) else {
                cursor += 1
                continue
            }

            if Self.isKanji(unit) {
                _ = await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges)
                kanjiCount += 1
                singletonKanji += 1
                ranges.append(SegmentedRange(range: NSRange(location: cursor, length: 1), isLexiconMatch: false))
            } else {
                nonKanjiCount += 1
                if Self.isWhitespaceOrNewline(scalar) || Self.isPunctuation(scalar) {
                    _ = await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges)
                    ranges.append(SegmentedRange(range: NSRange(location: cursor, length: 1), isLexiconMatch: false))
                    cursor += 1
                    continue
                }

                if Self.isStandaloneParticle(at: cursor, scalar: scalar, text: text, totalLength: length) {
                    _ = await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges)
                    ranges.append(SegmentedRange(range: NSRange(location: cursor, length: 1), isLexiconMatch: false))
                    cursor += 1
                    continue
                }

                let kind = Self.scriptKind(for: scalar)
                if let currentKind = pendingNonKanjiKind, await ScriptKind.equals(currentKind, kind) == false {
                    _ = await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges)
                }
                if pendingNonKanjiStart == nil {
                    pendingNonKanjiStart = cursor
                    pendingNonKanjiKind = kind
                }
                cursor += 1
                continue
            }
            cursor += 1
        }

        _ = await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: length, text: text, trie: trie, into: &ranges)

        await debug("segmentRanges: finished scan with \(ranges.count) ranges. Performing metrics…")

        let totalDuration = CFAbsoluteTimeGetCurrent() - profilingStart
        let totalMs = totalDuration * 1000
        let lookupMs = trieLookupTime * 1000
        let avgMatchLen = matchesFound > 0 ? Double(sumMatchLen) / Double(matchesFound) : 0
        await debug("segmentRanges: scanned length \(length) -> \(ranges.count) ranges in \(String(format: "%.3f", totalMs)) ms (lookups: \(trieLookups), matches: \(matchesFound), singletons: \(singletonKanji), avgMatchLen: \(String(format: "%.2f", avgMatchLen)), maxMatchLen: \(maxMatchLen), kanji: \(kanjiCount), nonKanji: \(nonKanjiCount), lookupTime: \(String(format: "%.3f", lookupMs)) ms).")
        await MainActor.run {
            trie.endProfiling(totalDuration: totalDuration)
        }
        signposter.endInterval("SegmentRangesLoop", loopInterval)

        return ranges
    }

    private func extendMatchEnd(
        trie: LexiconTrie,
        swiftText: String,
        text: NSString,
        startIndex: Int,
        initialEnd: Int,
        totalLength: Int
    ) async -> Int {
        var end = initialEnd
        var consumedKana = 0
        while end < totalLength {
            let unit = text.character(at: end)
            guard let scalar = UnicodeScalar(unit) else { break }
            if Self.isWhitespaceOrNewline(scalar) || Self.isPunctuation(scalar) { break }
            if Self.particleScalars.contains(scalar) { break }
            if Self.isExtensionStopSequence(in: swiftText, start: end) { break }
            if Self.isHiragana(unit) {
                if consumedKana > 0 && Self.okuriganaStopSet.contains(scalar) {
                    break
                }
                // Do not swallow the next dictionary word
                let currentEnd = end
                let nextMatchEnd: Int? = await MainActor.run { [swiftText, currentEnd] in
                    let ns = swiftText as NSString
                    return trie.longestMatchEnd(in: ns, from: currentEnd)
                }
                if nextMatchEnd != nil { break }

                let candidateEnd = end + 1
                let capturedStart = startIndex
                let capturedCandidateEnd = candidateEnd
                let hasLexiconPrefix: Bool = await MainActor.run { [swiftText, capturedStart, capturedCandidateEnd] in
                    let ns = swiftText as NSString
                    return trie.hasPrefix(in: ns, from: capturedStart, through: capturedCandidateEnd)
                }
                if hasLexiconPrefix {
                    consumedKana += 1
                    end = candidateEnd
                    continue
                }

                if let fallbackLength = Self.okuriganaFallbackLength(in: swiftText, start: end) {
                    consumedKana += fallbackLength
                    end += fallbackLength
                    continue
                }

                break
            }
            break
        }
        return end
    }

    private static func isKanji(_ unit: unichar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(unit))
    }

    private static func isHiragana(_ unit: unichar) -> Bool {
        (0x3040...0x309F).contains(Int(unit))
    }

    private static func isKatakana(_ unit: unichar) -> Bool {
        if (0x30A0...0x30FF).contains(Int(unit)) { return true }
        if unit == 0x30FC || unit == 0xFF70 { return true } // prolonged sound marks
        return false
    }

    private static func isWhitespaceOrNewline(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isPunctuation(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.punctuationCharacters.contains(scalar) { return true }
        return punctuationExtras.contains(scalar)
    }

    private static func scriptKind(for scalar: UnicodeScalar) -> ScriptKind {
        if (0x3040...0x309F).contains(Int(scalar.value)) { return .hiragana }
        if (0x30A0...0x30FF).contains(Int(scalar.value)) || scalar.value == 0x30FC || scalar.value == 0xFF70 {
            return .katakana
        }
        if (0x0030...0x0039).contains(Int(scalar.value)) { return .numeric }
        if (0x0041...0x005A).contains(Int(scalar.value)) || (0x0061...0x007A).contains(Int(scalar.value)) {
            return .latin
        }
        return .other
    }

    private static func isStandaloneParticle(at index: Int, scalar: UnicodeScalar, text: NSString, totalLength: Int) -> Bool {
        guard particleScalars.contains(scalar) else { return false }
        // Require previous or next boundary markers to reduce false positives
        let prevChar = (index - 1) >= 0 ? text.character(at: index - 1) : 0
        let nextChar = (index + 1) < totalLength ? text.character(at: index + 1) : 0
        if prevChar == 0, nextChar != 0, isHiragana(nextChar) {
            // avoid splitting words that begin with kana such as "もの" or "のに"
            return false
        }
        if scalar == "な" {
            if prevChar == 0 { return false }
            if isHiragana(prevChar) { return false }
        }
        let prevIsBoundary = prevChar == 0 || isBoundaryChar(prevChar)
        let nextIsBoundary = nextChar == 0 || isBoundaryChar(nextChar)
        if prevIsBoundary || nextIsBoundary { return true }
        if prevChar != 0 && isKanji(prevChar) { return true }
        if nextChar != 0 && isKanji(nextChar) { return true }
        if let prevScalar = UnicodeScalar(prevChar), (0x3040...0x309F).contains(Int(prevScalar.value)) == false {
            return true
        }
        if let nextScalar = UnicodeScalar(nextChar), (0x3040...0x309F).contains(Int(nextScalar.value)) == false {
            return true
        }
        return false
    }

    private static func isBoundaryChar(_ unit: unichar) -> Bool {
        if unit == 0 { return true }
        if isHiragana(unit) == false && isKatakana(unit) == false && (0x4E00...0x9FFF).contains(Int(unit)) == false {
            return true
        }
        if let scalar = UnicodeScalar(unit) {
            return isWhitespaceOrNewline(scalar) || isPunctuation(scalar)
        }
        return false
    }

    private static let particleScalars: Set<UnicodeScalar> = {
        let particles = "はがをにでへものねよもな"
        return Set(particles.unicodeScalars)
    }()

    private static func isExtensionStopSequence(in text: String, start: Int) -> Bool {
        guard start < text.utf16.count else { return false }
        for sequence in extensionStopSequences {
            if stringHasPrefix(text, prefix: sequence, fromUTF16Offset: start) {
                return true
            }
        }
        return false
    }

    private static func okuriganaFallbackLength(in text: String, start: Int) -> Int? {
        guard start < text.utf16.count else { return nil }
        for sequence in okuriganaFallbackSequences {
            if stringHasPrefix(text, prefix: sequence, fromUTF16Offset: start) {
                return sequence.utf16.count
            }
        }
        return nil
    }

    private static let extensionStopSequences: [String] = [
        "なら",
        "ならば",
        "ので",
        "のに",
        "のは",
        "のを",
        "のでしょう",
        "のです"
    ]

    private static let okuriganaFallbackSequences: [String] = {
        let sequences = [
            "させられた",
            "させられる",
            "させられ",
            "させない",
            "させた",
            "させて",
            "させる",
            "られない",
            "られた",
            "られて",
            "られる",
            "かれない",
            "かれた",
            "かれて",
            "かれる",
            "かれ",
            "されない",
            "された",
            "されて",
            "される",
            "いたい",
            "たかった",
            "たくて",
            "たく",
            "たい",
            "った",
            "って",
            "て",
            "た",
            "れなかった",
            "れない",
            "れた",
            "れて",
            "れる",
            "なくて",
            "なく",
            "なかった",
            "ない"
        ]
        return sequences.sorted { $0.utf16.count > $1.utf16.count }
    }()

    private static let okuriganaStopSet: Set<UnicodeScalar> = {
        let markers = "はがをにでへともやかものねよぞわな"
        return Set(markers.unicodeScalars)
    }()

    private static let punctuationExtras: Set<UnicodeScalar> = {
        let chars = "、。！？：；（）［］｛｝「」『』・…―〜。・"
        return Set(chars.unicodeScalars)
    }()

    private static let newlineCharacters = CharacterSet.newlines

    private static func stringHasPrefix(_ text: String, prefix: String, fromUTF16Offset offset: Int) -> Bool {
        guard offset >= 0 else { return false }
        let utf16Count = text.utf16.count
        guard offset <= utf16Count else { return false }
        let startIndex = String.Index(utf16Offset: offset, in: text)
        let limit = text.endIndex
        guard let endIndex = text.index(startIndex, offsetBy: prefix.count, limitedBy: limit) else { return false }
        return text[startIndex..<endIndex] == prefix
    }
}

private enum ScriptKind {
    case hiragana
    case katakana
    case latin
    case numeric
    case other
}

private struct SegmentedRange: Sendable {
    let range: NSRange
    let isLexiconMatch: Bool
}

private extension ScriptKind {
    static func equals(_ lhs: ScriptKind, _ rhs: ScriptKind) -> Bool {
        switch (lhs, rhs) {
        case (.hiragana, .hiragana),
             (.katakana, .katakana),
             (.latin, .latin),
             (.numeric, .numeric),
             (.other, .other):
            return true
        default:
            return false
        }
    }
}

private struct SegmentationCacheKey: Sendable, nonisolated Hashable {
    let textHash: Int
    let length: Int

    nonisolated static func == (lhs: SegmentationCacheKey, rhs: SegmentationCacheKey) -> Bool {
        lhs.textHash == rhs.textHash && lhs.length == rhs.length
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(textHash)
        hasher.combine(length)
    }
}

