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
        // Stage 1 segmentation can emit spans whose ranges *straddle* MeCab token boundaries
        // (i.e. a span overlaps parts of two MeCab tokens). That makes later logic that relies on
        // MeCab ranges unreliable and can produce invalid surfaces.
        //
        // Therefore, Stage 1.5 snaps spans to MeCab token boundaries by splitting any span at
        // boundaries between adjacent MeCab tokens.
        var out: [TextSpan] = []
        out.reserveCapacity(spans.count)

        // `forcedCuts` record the boundary indices we introduced by snapping.
        // These are ephemeral (not persisted).
        var forcedCuts: Set<Int> = []
        forcedCuts.reserveCapacity(min(128, spans.count))

        var tokenIndex = 0


        func clamp(_ r: NSRange) -> NSRange {
            let length = text.length
            guard length > 0 else { return NSRange(location: NSNotFound, length: 0) }
            let start = max(0, min(length, r.location))
            let end = max(start, min(length, NSMaxRange(r)))
            return NSRange(location: start, length: end - start)
        }

        for span in spans {
            let spanRange = clamp(span.range)
            guard spanRange.location != NSNotFound, spanRange.length > 0 else {
                continue
            }

            let spanStart = spanRange.location
            let spanEnd = NSMaxRange(spanRange)

            // If this span is fully contained in a single chosen MeCab token, never split it.
            // This is the non-negotiable token-atomic invariant.
            if let t = tokenCoveringLocation(spanStart), NSMaxRange(t.range) >= spanEnd {
                out.append(TextSpan(range: spanRange, surface: text.substring(with: spanRange), isLexiconMatch: span.isLexiconMatch))
                if traceEnabled {
                    log("decision: keep (span fully contained in token \(fmt(t.range)) «\(t.surface)»)")
                }
                continue
            }

            if traceEnabled {
                log("input span range=\(fmt(spanRange)) surface=«\(text.substring(with: spanRange))»")
            }

            // Advance global token index so tokens[tokenIndex] ends after the span start.
            while tokenIndex < tokens.count {
                let tEnd = NSMaxRange(tokens[tokenIndex].range)
                if tEnd <= spanStart {
                    tokenIndex += 1
                    continue
                }
                break
            }

            // Collect overlapping tokens.
            var overlapping: [MeCabAnnotation] = []
            var j = tokenIndex
            while j < tokens.count {
                let t = tokens[j]
                if t.range.location >= spanEnd { break }
                if NSIntersectionRange(t.range, spanRange).length > 0 {
                    overlapping.append(t)
                }
                j += 1
            }

            if traceEnabled {
                if overlapping.isEmpty {
                    log("overlapping MeCab tokens: <none>")
                } else {
                    let tokenLines = overlapping.map { tok in
                        "- \(fmt(tok.range)) «\(tok.surface)» POS=\(tok.partOfSpeech)"
                    }.joined(separator: " | ")
                    log("overlapping MeCab tokens: \(tokenLines)")
                }
            }

            // If MeCab provides no usable overlap (should be rare), keep the original span.
            if overlapping.isEmpty {
                out.append(TextSpan(range: spanRange, surface: text.substring(with: spanRange), isLexiconMatch: span.isLexiconMatch))
                if traceEnabled {
                    log("decision: keep (no MeCab overlap)")
                }
                continue
            }

            // If this span is fully covered by exactly one MeCab token, never split it.
            if overlapping.count == 1 {
                let t = overlapping[0].range
                if t.location <= spanStart, NSMaxRange(t) >= spanEnd {
                    out.append(TextSpan(range: spanRange, surface: text.substring(with: spanRange), isLexiconMatch: span.isLexiconMatch))
                    continue
                }
            }

            // Only split at boundaries BETWEEN adjacent MeCab tokens; never split inside a token.
            var cuts: [Int] = []
            cuts.reserveCapacity(4)
            if overlapping.count >= 2 {
                for localIndex in 0..<(overlapping.count - 1) {
                    let left = overlapping[localIndex]
                    let right = overlapping[localIndex + 1]
                    let boundary = NSMaxRange(left.range)
                    guard boundary == right.range.location else { continue }
                    if boundary > spanStart, boundary < spanEnd {
                        cuts.append(boundary)
                    }
                }
            }

            // Emit sub-spans for this Stage-1 span.
            // No merges: we only slice the original span at the chosen cut points.
            if cuts.isEmpty {
                out.append(TextSpan(range: spanRange, surface: text.substring(with: spanRange), isLexiconMatch: span.isLexiconMatch))
                if traceEnabled {
                    log("decision: keep (already aligned; no enforced cuts)")
                }
                continue
            }

            // Defensive dedupe in case the input spans overlap weirdly.
            let uniqueCuts = Array(Set(cuts)).sorted().filter { cut in
                // Forced cuts inside a MeCab token are forbidden: they create illegal
                // over-segmentation (e.g. splitting auxiliaries into individual characters).
                if let t = tokenCoveringLocation(cut), t.range.location < cut, cut < NSMaxRange(t.range) {
                    if traceEnabled {
                        log("skip cut=\(cut) (interior) token=\(fmt(t.range)) «\(t.surface)»")
                    }
                    return false
                }

                // Only allow forced cuts at exact token boundaries.
                guard allowedBoundaries.contains(cut) else { return false }
                return true
            }

            if uniqueCuts.isEmpty {
                out.append(TextSpan(range: spanRange, surface: text.substring(with: spanRange), isLexiconMatch: span.isLexiconMatch))
                if traceEnabled {
                    log("decision: keep (all candidate cuts were interior to tokens)")
                }
                continue
            }

            if traceEnabled {
                let uniq = uniqueCuts.map(String.init).joined(separator: ",")
                log("decision: split at [\(uniq)]")
            }

            var cursor = spanStart
            for cut in uniqueCuts {
                if cut <= cursor { continue }
                let r = NSRange(location: cursor, length: cut - cursor)
                guard r.length > 0 else { continue }
                let surface = text.substring(with: r)
                // These boundaries are not trie-derived, so do not claim lexicon-match.
                out.append(TextSpan(range: r, surface: surface, isLexiconMatch: false))
                // Record the boundary index introduced by snapping.
                var didInsertForcedCut = false
                if cut > 0, cut < text.length,
                   let left = mecabTokenIndex(at: cut - 1),
                   let right = mecabTokenIndex(at: cut),
                   left == right {
                } else {
                    forcedCuts.insert(cut)
                    didInsertForcedCut = true
                }
                if traceEnabled, didInsertForcedCut {
                    log("emit subspan range=\(fmt(r)) surface=«\(surface)» ; forcedCut=\(cut)")
                }
                cursor = cut
            }

            if cursor < spanEnd {
                let r = NSRange(location: cursor, length: spanEnd - cursor)
                if r.length > 0 {
                    let surface = text.substring(with: r)
                    out.append(TextSpan(range: r, surface: surface, isLexiconMatch: false))
                    if traceEnabled {
                        log("emit tail subspan range=\(fmt(r)) surface=«\(surface)»")
                    }
                }
            }
        }

        if traceEnabled {
            let cutList = Array(forcedCuts).sorted().map(String.init).joined(separator: ",")
            log("return forcedCuts count=\(forcedCuts.count) [\(cutList)]")
        }

        return Result(spans: out, forcedCuts: forcedCuts)
    }
}
