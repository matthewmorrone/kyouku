import Foundation

/// Stage 1.5: boundary normalization.
///
/// This stage runs *after* Stage 1 segmentation and *before* Stage 2 reading attachment.
///
/// Invariant: Stage 1.5 must never split inside a single MeCab token. Splits are allowed only
/// at boundaries *between adjacent MeCab tokens*.
enum Stage1_5PosBoundaryNormalizer {
    typealias MeCabAnnotation = SpanReadingAttacher.MeCabAnnotation

    struct Result {
        /// Split (but never merged) spans to pass into Stage 2.
        let spans: [TextSpan]
        /// UTF-16 boundary indices (end positions) that must be treated as hard cuts downstream.
        ///
        /// This is *not* persistence/user state; it is an ephemeral enforcement mechanism so
        /// Stage 2.5 merge-only regrouping cannot merge across POS-enforced boundaries.
        let forcedCuts: Set<Int>
    }

    /// Apply Stage 1.5 to the given spans.
    ///
    /// - Parameters:
    ///   - text: The original full text (UTF-16 indexed).
    ///   - spans: Stage-1 (or post-refinement) spans covering the text.
    ///   - mecab: MeCab annotations for the full text.
    static func apply(text: NSString, spans: [TextSpan], mecab: [MeCabAnnotation]) -> Result {
        guard spans.isEmpty == false else {
            return Result(spans: [], forcedCuts: [])
        }

        // TEMP DIAGNOSTICS (2026-02-02)
        // Opt-in logging only; must not affect behavior.
        let traceEnabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return env["STAGE15_TRACE"] == "1" || env["PIPELINE_TRACE"] == "1"
        }()

        func fmt(_ r: NSRange) -> String {
            guard r.location != NSNotFound else { return "NSNotFound" }
            return "\(r.location)-\(NSMaxRange(r))"
        }

        func log(_ message: String) {
            guard traceEnabled else { return }
            let full = "[S1.5] \(message)"
            CustomLogger.shared.info(full)
            NSLog("%@", full)
        }

        // Build a non-overlapping MeCab token stream first.
        // Some tokenizers can provide multiple candidate annotations sharing boundaries; we must
        // treat the chosen token stream as atomic and never cut at offsets strictly inside it.
        var candidatesByStart: [Int: [MeCabAnnotation]] = [:]
        candidatesByStart.reserveCapacity(min(64, mecab.count))
        for a in mecab {
            guard a.range.location != NSNotFound, a.range.length > 0 else { continue }
            candidatesByStart[a.range.location, default: []].append(a)
        }
        for (k, list) in candidatesByStart {
            candidatesByStart[k] = list.sorted { lhs, rhs in
                if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
                return lhs.surface.count > rhs.surface.count
            }
        }

        let starts = candidatesByStart.keys.sorted()
        var tokens: [MeCabAnnotation] = []
        tokens.reserveCapacity(starts.count)
        var cursor = 0
        for start in starts {
            guard start >= cursor else { continue }
            guard let best = candidatesByStart[start]?.first else { continue }
            tokens.append(best)
            cursor = NSMaxRange(best.range)
        }

        let allowedBoundaries: Set<Int> = {
            var boundaries: Set<Int> = []
            boundaries.reserveCapacity(tokens.count * 2)
            for t in tokens {
                boundaries.insert(t.range.location)
                boundaries.insert(NSMaxRange(t.range))
            }
            return boundaries
        }()

        func tokenCoveringLocation(_ location: Int) -> MeCabAnnotation? {
            // Finds the (non-overlapping) chosen token where:
            // token.start <= location < token.end
            guard tokens.isEmpty == false else { return nil }

            var lo = 0
            var hi = tokens.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let t = tokens[mid]
                let start = t.range.location
                let end = NSMaxRange(t.range)
                if location < start {
                    hi = mid - 1
                } else if location >= end {
                    lo = mid + 1
                } else {
                    return t
                }
            }
            return nil
        }

        func mecabTokenIndex(at location: Int) -> Int? {
            guard tokens.isEmpty == false else { return nil }

            var lo = 0
            var hi = tokens.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let t = tokens[mid]
                let start = t.range.location
                let end = NSMaxRange(t.range)
                if location < start {
                    hi = mid - 1
                } else if location >= end {
                    lo = mid + 1
                } else {
                    return mid
                }
            }
            return nil
        }

        func isInteriorToAnyChosenToken(_ offset: Int) -> Bool {
            // If an offset falls strictly inside a chosen token range, it is not a legal split.
            if let t = tokenCoveringLocation(offset) {
                return t.range.location < offset && offset < NSMaxRange(t.range)
            }
            return false
        }

        // Stage 1.5 is a split-only normalization pass.
        //
        // Correctness hardening:
        // Stage 1 segmentation can emit spans whose boundaries fall strictly inside a chosen
        // MeCab token (i.e. the boundary is not a MeCab token boundary). Later stages that
        // rely on MeCab boundary metadata then fail to merge/split correctly.
        //
        // Strategy:
        // 1) Snap every Stage-1 span boundary to a valid MeCab token boundary when it is interior.
        //    (Deterministic majority-side assignment; tie breaks toward token start.)
        // 2) Split any resulting ranges only at MeCab token boundaries.
        var out: [TextSpan] = []
        out.reserveCapacity(spans.count)

        // `forcedCuts` record the boundary indices introduced or adjusted by snapping.
        // These are ephemeral (not persisted).
        var forcedCuts: Set<Int> = []
        forcedCuts.reserveCapacity(min(128, spans.count))

        func clampIndex(_ idx: Int) -> Int {
            max(0, min(text.length, idx))
        }

        func snapToTokenBoundaryIfInterior(_ boundary: Int) -> Int {
            let b = clampIndex(boundary)
            guard b > 0, b < text.length else { return b }
            guard let t = tokenCoveringLocation(b) else { return b }
            let start = t.range.location
            let end = NSMaxRange(t.range)
            guard start < b, b < end else { return b }

            let leftLen = b - start
            let rightLen = end - b
            if leftLen < rightLen { return start }
            if rightLen < leftLen { return end }
            return start
        }

        guard tokens.isEmpty == false else {
            return Result(spans: spans, forcedCuts: [])
        }

        let originalCuts: Set<Int> = {
            var s: Set<Int> = []
            s.reserveCapacity(spans.count + 2)
            s.insert(0)
            s.insert(text.length)
            for span in spans {
                let end = clampIndex(NSMaxRange(span.range))
                s.insert(end)
            }
            return s
        }()

        var snappedCuts: [Int] = []
        snappedCuts.reserveCapacity(spans.count + 2)
        snappedCuts.append(0)
        for span in spans {
            let rawEnd = clampIndex(NSMaxRange(span.range))
            let snapped = snapToTokenBoundaryIfInterior(rawEnd)
            snappedCuts.append(snapped)
        }
        snappedCuts.append(text.length)

        // Sort + dedupe, and ensure strict monotonic coverage.
        let cuts = Array(Set(snappedCuts))
            .map(clampIndex)
            .sorted()

        // Precompute all legal MeCab boundaries once.
        let tokenBoundariesSorted: [Int] = {
            var b: Set<Int> = []
            b.reserveCapacity(tokens.count * 2)
            for t in tokens {
                b.insert(t.range.location)
                b.insert(NSMaxRange(t.range))
            }
            return b.sorted()
        }()

        for i in 0..<(cuts.count - 1) {
            let start = cuts[i]
            let end = cuts[i + 1]
            guard end > start else { continue }

            // If we cannot guarantee token-boundary alignment (e.g. missing MeCab coverage), keep range as-is.
            if allowedBoundaries.contains(start) == false || allowedBoundaries.contains(end) == false {
                let r = NSRange(location: start, length: end - start)
                out.append(TextSpan(range: r, surface: text.substring(with: r), isLexiconMatch: false))
                continue
            }

            // Split at any internal MeCab boundaries.
            let internalCuts = tokenBoundariesSorted.filter { $0 > start && $0 < end }
            if internalCuts.isEmpty {
                let r = NSRange(location: start, length: end - start)
                out.append(TextSpan(range: r, surface: text.substring(with: r), isLexiconMatch: false))
                continue
            }

            var cursor = start
            for cut in internalCuts {
                guard cut > cursor else { continue }
                let r = NSRange(location: cursor, length: cut - cursor)
                guard r.length > 0 else { continue }
                out.append(TextSpan(range: r, surface: text.substring(with: r), isLexiconMatch: false))
                cursor = cut
            }
            if cursor < end {
                let r = NSRange(location: cursor, length: end - cursor)
                if r.length > 0 {
                    out.append(TextSpan(range: r, surface: text.substring(with: r), isLexiconMatch: false))
                }
            }
        }

        // forcedCuts = output boundaries not present in the original Stage-1 cuts.
        for span in out {
            let end = clampIndex(NSMaxRange(span.range))
            if end > 0, end < text.length, originalCuts.contains(end) == false {
                forcedCuts.insert(end)
            }
        }

        if traceEnabled {
            let cutList = Array(forcedCuts).sorted().map(String.init).joined(separator: ",")
            log("return forcedCuts count=\(forcedCuts.count) [\(cutList)]")
        }

        return Result(spans: out, forcedCuts: forcedCuts)
    }
}
