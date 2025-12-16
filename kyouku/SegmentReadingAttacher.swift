import Foundation
import Mecab_Swift

enum SegmentReadingAttacher {
    /// Returns a reading for the given surface using the provided tokenizer.
    /// If tokenizer is nil or returns no annotations, returns an empty string.
    static func reading(for surface: String, tokenizer: Tokenizer?) -> String {
        guard let tokenizer else { return "" }
        let anns = tokenizer.tokenize(text: surface)
        if anns.isEmpty { return "" }
        // Concatenate readings of the internal MeCab tokens; boundaries are ignored.
        return anns.map { $0.reading }.joined()
    }

    /// Attaches readings to segments; does not modify segment ranges.
    static func attachReadings(text: String, segments: [Segment], tokenizer: Tokenizer?) -> [(segment: Segment, reading: String)] {
        return segments.map { seg in
            let r = reading(for: seg.surface, tokenizer: tokenizer)
            return (segment: seg, reading: r)
        }
    }

    /// Computes readings for already-finalized dictionary segments using MeCab,
    /// without influencing boundaries.
    static func attachReadingsToDictionarySegments(segments: [Segment], tokenizer: Tokenizer?) -> [(segment: Segment, reading: String)] {
        guard let tokenizer else {
            return segments.map { ($0, "") }
        }
        return segments.map { segment in
            let annotations = tokenizer.tokenize(text: segment.surface)
            if annotations.isEmpty {
                return (segment, "")
            }
            // Join the readings of MeCab tokens inside the segment without changing boundaries
            let reading = annotations.map { $0.reading }.joined()
            return (segment, reading)
        }
    }
}
