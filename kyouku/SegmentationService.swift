import Foundation
import OSLog

/// Stage 1 of the furigana pipeline. Produces bounded, lexicon-driven spans by
/// walking the shared JMdict trie. No readings or semantic metadata escape this
/// layer, and SQLite is never touched after the trie finishes bootstrapping.
actor SegmentationService {
    static let shared = SegmentationService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SegmentationService")
    private var cache: [SegmentationCacheKey: [TextSpan]] = [:]
    private var lruKeys: [SegmentationCacheKey] = []
    private let maxEntries = 32

    func segment(text: String) async throws -> [TextSpan] {
        guard text.isEmpty == false else { return [] }

        let key = SegmentationCacheKey(textHash: Self.hash(text), length: text.utf16.count)
        if let cached = cache[key] {
            return cached
        }

        let trie = try await LexiconProvider.shared.trie()
        let nsText = text as NSString
        let dictionaryRanges = trie.spans(in: nsText)
        let ranges = mergedRanges(dictionaryRanges: dictionaryRanges, text: nsText)
        let spans = ranges.map { range in
            TextSpan(range: range, surface: nsText.substring(with: range))
        }

        store(spans, for: key)
        logger.debug("Segmented text length \(text.count) into \(spans.count) spans.")
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

    private func mergedRanges(dictionaryRanges: [NSRange], text: NSString) -> [NSRange] {
        guard text.length > 0 else { return dictionaryRanges }

        var merged: [NSRange] = []
        merged.reserveCapacity(dictionaryRanges.count)

        var cursor = 0
        var dictionaryIndex = 0
        let length = text.length

        while cursor < length {
            if dictionaryIndex < dictionaryRanges.count {
                let nextRange = dictionaryRanges[dictionaryIndex]
                if nextRange.location == cursor {
                    merged.append(nextRange)
                    cursor = nextRange.location + nextRange.length
                    dictionaryIndex += 1
                    continue
                } else if nextRange.location < cursor {
                    dictionaryIndex += 1
                    continue
                }
            }

            if isKanji(text.character(at: cursor)) {
                let fallback = NSRange(location: cursor, length: 1)
                merged.append(fallback)
            }
            cursor += 1
        }

        return merged
    }

    private func isKanji(_ unit: unichar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(unit))
    }
}

private struct SegmentationCacheKey: Hashable {
    let textHash: Int
    let length: Int
}
