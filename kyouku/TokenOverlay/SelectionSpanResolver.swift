import Foundation

/// Produces token-aligned lookup candidates that contain a selected character range.
///
/// Contract:
/// - No character-by-character growth.
/// - Candidates are contiguous spans of whole tokens.
/// - Candidates contain `selectedRange`.
/// - Ordered by increasing span size (smallest first).
/// - Candidate strings are derived by substringing the original text (no rewriting).
///
/// Performance:
/// - Enumeration is limited to a fixed local token window around the selection
///   to keep worst-case complexity linear in overall token count.
enum SelectionSpanResolver {
    struct Configuration {
        /// Maximum tokens to expand outward from the minimal covering span.
        /// This is a hard cap to keep candidate enumeration bounded.
        var maxExpansionTokens: Int = 6

        init() {}
    }

    static func candidates(
        selectedRange: NSRange,
        tokenSpans: [TextSpan],
        text: NSString,
        config: Configuration = Configuration()
    ) -> [SelectionSpanCandidate] {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else { return [] }
        guard tokenSpans.isEmpty == false else { return [] }

        let textLength = text.length
        guard textLength > 0 else { return [] }
        guard selectedRange.location >= 0, NSMaxRange(selectedRange) <= textLength else { return [] }

        // Assume tokenSpans are sorted and largely contiguous, but do not require full coverage.
        // Find minimal token index window [minIdx, maxIdx] that covers the selected range.
        let start = selectedRange.location
        let endExclusive = NSMaxRange(selectedRange)

        var minIdx: Int? = nil
        var maxIdx: Int? = nil

        for (idx, span) in tokenSpans.enumerated() {
            let r = span.range
            guard r.location != NSNotFound, r.length > 0 else { continue }
            let rEnd = NSMaxRange(r)

            // Overlaps selection at all?
            let overlaps = r.location < endExclusive && rEnd > start
            guard overlaps else {
                if minIdx != nil, r.location >= endExclusive {
                    break
                }
                continue
            }

            if minIdx == nil { minIdx = idx }
            maxIdx = idx

            // If this span covers the selection end, we can stop once we know maxIdx.
            if rEnd >= endExclusive {
                break
            }
        }

        guard let baseStart = minIdx, let baseEnd = maxIdx else { return [] }

        // Expansion bounds (bounded window for linear performance).
        let leftLimit = max(0, baseStart - config.maxExpansionTokens)
        let rightLimit = min(tokenSpans.count - 1, baseEnd + config.maxExpansionTokens)

        // Enumerate all token-aligned spans that contain [baseStart...baseEnd] within the bounded window.
        // Order by increasing UTF-16 length (smallest span wins).
        var out: [SelectionSpanCandidate] = []

        for startIdx in stride(from: baseStart, through: leftLimit, by: -1) {
            // Enforce contiguity across the entire candidate span.
            // If there is any gap between token ranges, do not form a lookup candidate
            // that includes the in-between characters.
            var union = tokenSpans[startIdx].range

            if startIdx < baseEnd {
                var contiguousToBaseEnd = true
                var k = startIdx
                while k < baseEnd {
                    if NSMaxRange(tokenSpans[k].range) != tokenSpans[k + 1].range.location {
                        contiguousToBaseEnd = false
                        break
                    }
                    k += 1
                }
                if contiguousToBaseEnd == false {
                    continue
                }

                // Expand union across startIdx...baseEnd now that we know it is contiguous.
                for kk in (startIdx + 1)...baseEnd {
                    union = NSUnionRange(union, tokenSpans[kk].range)
                }
            }

            for endIdx in baseEnd...rightLimit {
                if endIdx > baseEnd {
                    // Require contiguity as we expand to the right.
                    if NSMaxRange(tokenSpans[endIdx - 1].range) != tokenSpans[endIdx].range.location {
                        break
                    }
                    union = NSUnionRange(union, tokenSpans[endIdx].range)
                }

                // Must contain the full selected range.
                guard union.location <= start, NSMaxRange(union) >= endExclusive else { continue }
                guard union.location != NSNotFound, union.length > 0 else { continue }
                guard NSMaxRange(union) <= textLength else { continue }

                let displayKey = text.substring(with: union)
                let lookupKey = DictionaryKeyPolicy.lookupKey(for: displayKey)
                if lookupKey.isEmpty { continue }

                out.append(SelectionSpanCandidate(range: union, displayKey: displayKey, lookupKey: lookupKey))
            }
        }

        out.sort {
            if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.displayKey < $1.displayKey
        }

        // Deduplicate by range (same range can be reached via different start iteration order).
        var deduped: [SelectionSpanCandidate] = []
        deduped.reserveCapacity(out.count)
        var seen: Set<NSRange> = []
        for c in out {
            if seen.insert(c.range).inserted {
                deduped.append(c)
            }
        }

        return deduped
    }
}
