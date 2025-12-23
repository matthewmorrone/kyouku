import Foundation
import OSLog

/// Stage 1 of the furigana pipeline. Produces bounded, lexicon-driven spans by
/// walking the shared JMdict trie. No readings or semantic metadata escape this
/// layer, and SQLite is never touched after the trie finishes bootstrapping.
actor SegmentationService {
    static let shared = SegmentationService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SegmentationService")
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
            logger.debug("[Segmentation] Cache hit for len=\(text.count) -> \(cached.count) spans.")
            signposter.endInterval("Segment", segInterval)
            return cached
        } else {
            logger.debug("[Segmentation] Cache miss for len=\(text.count). Proceeding to segment.")
        }

        let trieInterval = signposter.beginInterval("TrieLoad")
        let trieLoadStart = CFAbsoluteTimeGetCurrent()
        let trie = try await getTrie()
        let trieLoadMs = (CFAbsoluteTimeGetCurrent() - trieLoadStart) * 1000
        let trieSource = (trieInitTask == nil && trieCache != nil) ? "cached" : (trieInitTask != nil ? "building" : "unknown")
        logger.debug("SegmentationService: trie load completed (source=\(trieSource)) in \(String(format: "%.3f", trieLoadMs)) ms.")
        signposter.endInterval("TrieLoad", trieInterval)

        let nsText = text as NSString

        let rangesInterval = signposter.beginInterval("SegmentRanges")
        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let ranges = segmentRanges(using: trie, text: nsText)
        let segmentationMs = (CFAbsoluteTimeGetCurrent() - segmentationStart) * 1000
        logger.debug("SegmentationService: segmentRanges took \(String(format: "%.3f", segmentationMs)) ms.")
        signposter.endInterval("SegmentRanges", rangesInterval)

        let mapInterval = signposter.beginInterval("MapRangesToSpans")
        let mapStart = CFAbsoluteTimeGetCurrent()
        let spans = ranges.map { range in
            TextSpan(range: range, surface: nsText.substring(with: range))
        }
        let mapMs = (CFAbsoluteTimeGetCurrent() - mapStart) * 1000
        logger.debug("SegmentationService: mapping ranges->spans took \(String(format: "%.3f", mapMs)) ms.")
        signposter.endInterval("MapRangesToSpans", mapInterval)

        store(spans, for: key)
        let overallDurationMsDouble = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
        let overallDurationMs = Int(overallDurationMsDouble.rounded())
        logger.debug("Segmented text length \(text.count) into \(spans.count) spans in \(String(format: "%.3f", overallDurationMsDouble)) ms (trie: \(String(format: "%.3f", trieLoadMs)) ms, segment: \(String(format: "%.3f", segmentationMs)) ms, map: \(String(format: "%.3f", mapMs)) ms).")
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
            logger.debug("getTrie(): returning cached trie in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
            return t
        }
        if let task = trieInitTask {
            logger.debug("getTrie(): awaiting existing build task…")
            return try await task.value
        }
        logger.debug("getTrie(): creating new build task…")
        let task = Task { try await LexiconProvider.shared.trie() }
        trieInitTask = task
        let t = try await task.value
        trieCache = t
        trieInitTask = nil
        logger.debug("getTrie(): build task completed in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
        return t
    }

    private func segmentRanges(using trie: LexiconTrie, text: NSString) -> [NSRange] {
        let length = text.length
        guard length > 0 else { return [] }

        logger.debug("segmentRanges: starting scan length=\(length)")

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

        trie.beginProfiling()
        let profilingStart = CFAbsoluteTimeGetCurrent()
        let loopInterval = signposter.beginInterval("SegmentRangesLoop", "len=\(length)")

        var cursor = 0
        while cursor < length {
            trieLookups += 1
            let lookupStart = CFAbsoluteTimeGetCurrent()
            if let end = trie.longestMatchEnd(in: text, from: cursor) {
                trieLookupTime += CFAbsoluteTimeGetCurrent() - lookupStart
                let len = end - cursor
                sumMatchLen += len
                if len > maxMatchLen { maxMatchLen = len }
                let range = NSRange(location: cursor, length: len)
                ranges.append(range)
                matchesFound += 1
                cursor = end
                continue
            }
            trieLookupTime += CFAbsoluteTimeGetCurrent() - lookupStart

            let unit = text.character(at: cursor)
            if isKanji(unit) {
                kanjiCount += 1
                singletonKanji += 1
                ranges.append(NSRange(location: cursor, length: 1))
            } else {
                nonKanjiCount += 1
            }
            cursor += 1
        }

        logger.debug("segmentRanges: finished scan with \(ranges.count) ranges. Performing metrics…")

        let totalDuration = CFAbsoluteTimeGetCurrent() - profilingStart
        let totalMs = totalDuration * 1000
        let lookupMs = trieLookupTime * 1000
        let avgMatchLen = matchesFound > 0 ? Double(sumMatchLen) / Double(matchesFound) : 0
        logger.debug("segmentRanges: scanned length \(length) -> \(ranges.count) ranges in \(String(format: "%.3f", totalMs)) ms (lookups: \(trieLookups), matches: \(matchesFound), singletons: \(singletonKanji), avgMatchLen: \(String(format: "%.2f", avgMatchLen)), maxMatchLen: \(maxMatchLen), kanji: \(kanjiCount), nonKanji: \(nonKanjiCount), lookupTime: \(String(format: "%.3f", lookupMs)) ms).")
        trie.endProfiling(totalDuration: totalDuration)
        signposter.endInterval("SegmentRangesLoop", loopInterval)

        return ranges
    }

    private func isKanji(_ unit: unichar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(unit))
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

