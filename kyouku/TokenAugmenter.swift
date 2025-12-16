#if false
import Foundation

/// A lightweight augmenter that merges MeCab annotations with user-provided Trie words.
/// Strategy:
/// - Build a list of word ranges from the Trie (if present).
/// - Emit tokens for Trie words with surface from the original text and reading = concatenation of readings from overlapping annotations.
/// - For gaps that aren't covered by Trie words, fall back to MeCab annotations.
struct TokenAugmenter {
    struct Segment: Hashable {
        let range: Range<String.Index>
        let surface: String
        let reading: String
    }

    /// Build merged segments from annotations and an optional Trie.
    static func mergedSegments(text: String,
                               annotations: [Annotation],
                               trie: Trie?) -> [Segment] {
        guard let trie = trie else {
            // No augmentation: map 1:1 from annotations
            return annotations.map { ann in
                let surface = String(text[ann.range])
                return Segment(range: ann.range, surface: surface, reading: ann.reading)
            }
        }

        // 1) Collect Trie word ranges (only isWord tokens)
        let trieTokens = trie.tokenize(text, emitSeparators: false, treatWhitespaceAsSeparator: true)
        let wordRanges = trieTokens.filter { $0.isWord }.map { $0.range }
        if wordRanges.isEmpty {
            return annotations.map { ann in
                let surface = String(text[ann.range])
                return Segment(range: ann.range, surface: surface, reading: ann.reading)
            }
        }

        // Sort by position
        let sortedRanges = wordRanges.sorted(by: { $0.lowerBound < $1.lowerBound })
        // Helper to concatenate readings of annotations overlapping a given range
        func reading(for range: Range<String.Index>) -> String {
            var out = ""
            for ann in annotations {
                if ann.range.overlaps(range) {
                    out += ann.reading
                }
            }
            return out
        }

        // 2) Walk through the text, emitting gap annotations and trie words
        var segments: [Segment] = []
        var cursor = text.startIndex

        func emitGap(until end: String.Index) {
            guard cursor < end else { return }
            for ann in annotations {
                if ann.range.lowerBound >= cursor && ann.range.upperBound <= end {
                    let surface = String(text[ann.range])
                    segments.append(Segment(range: ann.range, surface: surface, reading: ann.reading))
                }
            }
            cursor = end
        }

        for wr in sortedRanges {
            // Emit gap before the word range
            emitGap(until: wr.lowerBound)
            // Emit the trie word segment
            let surface = String(text[wr])
            let rd = reading(for: wr)
            segments.append(Segment(range: wr, surface: surface, reading: rd.isEmpty ? surface : rd))
            cursor = wr.upperBound
        }
        // Emit trailing gap
        emitGap(until: text.endIndex)

        // As a safeguard, if segments ended up empty, fall back
        if segments.isEmpty {
            return annotations.map { ann in
                let surface = String(text[ann.range])
                return Segment(range: ann.range, surface: surface, reading: ann.reading)
            }
        }
        // Sort segments by position and deduplicate contiguous duplicates
        segments.sort(by: { $0.range.lowerBound < $1.range.lowerBound })
        var unique: [Segment] = []
        for seg in segments {
            if let last = unique.last, last.range == seg.range { continue }
            unique.append(seg)
        }
        return unique
    }
}
/// This augmenter relied on MeCab annotations and is deprecated in favor of DictionarySegmenter.
#endif
