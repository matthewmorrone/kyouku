import Foundation
import OSLog

/// Stage 1 of the furigana pipeline. Produces bounded, lexicon-driven spans by
/// walking the shared JMdict trie. No readings or semantic metadata escape this
/// layer, and SQLite is never touched after the trie finishes bootstrapping.
actor SegmentationService {
    static let shared = SegmentationService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SegmentationService")

    private func info(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.info("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }

    private func debug(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
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
            debug("[Segmentation] Cache hit for len=\(text.count) -> \(cached.count) spans.")
            signposter.endInterval("Segment", segInterval)
            return cached
        } else {
            debug("[Segmentation] Cache miss for len=\(text.count). Proceeding to segment.")
        }

        let trieInterval = signposter.beginInterval("TrieLoad")
        let trieLoadStart = CFAbsoluteTimeGetCurrent()
        let trie = try await getTrie()
        let trieLoadMs = (CFAbsoluteTimeGetCurrent() - trieLoadStart) * 1000
        let trieSource = (trieInitTask == nil && trieCache != nil) ? "cached" : (trieInitTask != nil ? "building" : "unknown")
        debug("SegmentationService: trie load completed (source=\(trieSource)) in \(String(format: "%.3f", trieLoadMs)) ms.")
        signposter.endInterval("TrieLoad", trieInterval)

        let nsText = text as NSString

        let rangesInterval = signposter.beginInterval("SegmentRanges")
        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let ranges = await segmentRanges(using: trie, text: nsText)
        let segmentationMs = (CFAbsoluteTimeGetCurrent() - segmentationStart) * 1000
        debug("SegmentationService: segmentRanges took \(String(format: "%.3f", segmentationMs)) ms.")
        signposter.endInterval("SegmentRanges", rangesInterval)

        let mapInterval = signposter.beginInterval("MapRangesToSpans")
        let mapStart = CFAbsoluteTimeGetCurrent()
        let spans = ranges.map { range in
            TextSpan(range: range, surface: nsText.substring(with: range))
        }
        let mapMs = (CFAbsoluteTimeGetCurrent() - mapStart) * 1000
        debug("SegmentationService: mapping ranges->spans took \(String(format: "%.3f", mapMs)) ms.")
        signposter.endInterval("MapRangesToSpans", mapInterval)

        store(spans, for: key)
        let overallDurationMsDouble = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
        debug("Segmented text length \(text.count) into \(spans.count) spans in \(String(format: "%.3f", overallDurationMsDouble)) ms (trie: \(String(format: "%.3f", trieLoadMs)) ms, segment: \(String(format: "%.3f", segmentationMs)) ms, map: \(String(format: "%.3f", mapMs)) ms).")
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

    private func getTrie() async throws -> LexiconTrie {
        let start = CFAbsoluteTimeGetCurrent()
        if let t = trieCache {
            debug("getTrie(): returning cached trie in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
            return t
        }
        if let task = trieInitTask {
            debug("getTrie(): awaiting existing build task…")
            return try await task.value
        }
        debug("getTrie(): creating new build task…")
        let task = Task { try await LexiconProvider.shared.trie() }
        trieInitTask = task
        let t = try await task.value
        trieCache = t
        trieInitTask = nil
        debug("getTrie(): build task completed in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
        return t
    }

    private func segmentRanges(using trie: LexiconTrie, text: NSString) async -> [NSRange] {
        let length = text.length
        guard length > 0 else { return [] }

        debug("segmentRanges: starting scan length=\(length)")

        var ranges: [NSRange] = []
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
                if let pending = pendingNonKanjiStart, pending < cursor {
                    let pendingRange = NSRange(location: pending, length: cursor - pending)
                    ranges.append(pendingRange)
                    pendingNonKanjiStart = nil
                    pendingNonKanjiKind = nil
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
                ranges.append(range)
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
                if let pending = pendingNonKanjiStart, pending < cursor {
                    let pendingRange = NSRange(location: pending, length: cursor - pending)
                    ranges.append(pendingRange)
                    pendingNonKanjiStart = nil
                    pendingNonKanjiKind = nil
                }
                kanjiCount += 1
                singletonKanji += 1
                ranges.append(NSRange(location: cursor, length: 1))
            } else {
                nonKanjiCount += 1
                if Self.isWhitespaceOrNewline(scalar) || Self.isPunctuation(scalar) {
                    if let pending = pendingNonKanjiStart, pending < cursor {
                        let pendingRange = NSRange(location: pending, length: cursor - pending)
                        ranges.append(pendingRange)
                        pendingNonKanjiStart = nil
                        pendingNonKanjiKind = nil
                    }
                    ranges.append(NSRange(location: cursor, length: 1))
                    cursor += 1
                    continue
                }

                if Self.isStandaloneParticle(at: cursor, scalar: scalar, text: text, totalLength: length) {
                    if let pending = pendingNonKanjiStart, pending < cursor {
                        let pendingRange = NSRange(location: pending, length: cursor - pending)
                        ranges.append(pendingRange)
                        pendingNonKanjiStart = nil
                        pendingNonKanjiKind = nil
                    }
                    ranges.append(NSRange(location: cursor, length: 1))
                    cursor += 1
                    continue
                }

                let kind = Self.scriptKind(for: scalar)
                if let currentKind = pendingNonKanjiKind, currentKind != kind, let pending = pendingNonKanjiStart, pending < cursor {
                    let pendingRange = NSRange(location: pending, length: cursor - pending)
                    ranges.append(pendingRange)
                    pendingNonKanjiStart = nil
                    pendingNonKanjiKind = nil
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

        if let pending = pendingNonKanjiStart, pending < length {
            let pendingRange = NSRange(location: pending, length: length - pending)
            ranges.append(pendingRange)
            pendingNonKanjiStart = nil
            pendingNonKanjiKind = nil
        }

        debug("segmentRanges: finished scan with \(ranges.count) ranges. Performing metrics…")

        let totalDuration = CFAbsoluteTimeGetCurrent() - profilingStart
        let totalMs = totalDuration * 1000
        let lookupMs = trieLookupTime * 1000
        let avgMatchLen = matchesFound > 0 ? Double(sumMatchLen) / Double(matchesFound) : 0
        debug("segmentRanges: scanned length \(length) -> \(ranges.count) ranges in \(String(format: "%.3f", totalMs)) ms (lookups: \(trieLookups), matches: \(matchesFound), singletons: \(singletonKanji), avgMatchLen: \(String(format: "%.2f", avgMatchLen)), maxMatchLen: \(maxMatchLen), kanji: \(kanjiCount), nonKanji: \(nonKanjiCount), lookupTime: \(String(format: "%.3f", lookupMs)) ms).")
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
                let nextMatchEnd: Int? = await MainActor.run {
                    let ns = swiftText as NSString
                    return trie.longestMatchEnd(in: ns, from: end)
                }
                if nextMatchEnd != nil { break }

                let candidateEnd = end + 1
                let hasLexiconPrefix: Bool = await MainActor.run {
                    let ns = swiftText as NSString
                    return trie.hasPrefix(in: ns, from: startIndex, through: candidateEnd)
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
        if let prevScalar = UnicodeScalar(prevChar), scriptKind(for: prevScalar) != .hiragana {
            return true
        }
        if let nextScalar = UnicodeScalar(nextChar), scriptKind(for: nextScalar) != .hiragana {
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
            if text.hasPrefix(sequence, fromUTF16Offset: start) {
                return true
            }
        }
        return false
    }

    private static func okuriganaFallbackLength(in text: String, start: Int) -> Int? {
        guard start < text.utf16.count else { return nil }
        for sequence in okuriganaFallbackSequences {
            if text.hasPrefix(sequence, fromUTF16Offset: start) {
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
}

private enum ScriptKind {
    case hiragana
    case katakana
    case latin
    case numeric
    case other
}

private extension String {
    func hasPrefix(_ prefix: String, fromUTF16Offset offset: Int) -> Bool {
        guard offset >= 0 else { return false }
        // Ensure the UTF-16 offset is within the string bounds
        let utf16Count = self.utf16.count
        guard offset <= utf16Count else { return false }

        // Create a String.Index from the UTF-16 offset (non-optional in modern Swift)
        let startIndex = String.Index(utf16Offset: offset, in: self)
        let limit = self.endIndex
        // Advance by the prefix's character count, limited by the end index
        guard let endIndex = self.index(startIndex, offsetBy: prefix.count, limitedBy: limit) else { return false }
        return self[startIndex..<endIndex] == prefix
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

