import Foundation

/// Stage 1.5: MeCab token-boundary normalization.
///
/// This stage runs *after* Stage 1 segmentation and *before* Stage 2 reading attachment.
///
/// Invariant: Stage 1.5 must never split inside a single MeCab token. Splits are allowed only
/// at boundaries *between adjacent MeCab tokens*.
enum MeCabTokenBoundaryNormalizer {
    typealias MeCabAnnotation = SpanReadingAttacher.MeCabAnnotation

    private static let smallTsuHiragana: unichar = 0x3063 // っ
    private static let smallTsuKatakana: unichar = 0x30C3 // ッ

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

        // Stage 1.5 should preserve non-covering inputs as-is. The normal pipeline
        // feeds full-coverage spans here, but tests and edge callers may provide a
        // prefix/slice; in that case we must not synthesize trailing gap spans.
        func spansCoverEntireText(_ spans: [TextSpan]) -> Bool {
            var cursor = 0
            for span in spans {
                guard span.range.length > 0 else { return false }
                guard span.range.location == cursor else { return false }
                cursor = NSMaxRange(span.range)
            }
            return cursor == text.length
        }
        guard spansCoverEntireText(spans) else {
            return Result(spans: spans, forcedCuts: [])
        }

        func isKatakanaLikeScalar(_ scalar: UnicodeScalar) -> Bool {
            // Fullwidth katakana block.
            if (0x30A0...0x30FF).contains(scalar.value) { return true }
            // Halfwidth katakana block.
            if (0xFF66...0xFF9F).contains(scalar.value) { return true }
            return false
        }

        func isKatakanaLikeString(_ s: String) -> Bool {
            guard s.isEmpty == false else { return false }
            return s.unicodeScalars.allSatisfy(isKatakanaLikeScalar)
        }

        func isBoundaryScalar(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }

        func endsWithSokuon(_ r: NSRange) -> Bool {
            let end = NSMaxRange(r)
            guard end > r.location, end <= text.length else { return false }
            let unit = text.character(at: end - 1)
            return unit == smallTsuHiragana || unit == smallTsuKatakana
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

        // Map each chosen MeCab token to the contiguous range of Stage-1 spans it covers.
        // This lets Stage 1.5 selectively avoid collapsing katakana boundaries in cases
        // that are known to be harmful (while leaving non-katakana behavior unchanged).
        var tokenSpanRanges: [Range<Int>] = []
        tokenSpanRanges.reserveCapacity(tokens.count)
        var spanCursor = 0
        for token in tokens {
            let tokenStart = token.range.location
            let tokenEnd = NSMaxRange(token.range)
            while spanCursor < spans.count, NSMaxRange(spans[spanCursor].range) <= tokenStart {
                spanCursor += 1
            }
            let startIdx = spanCursor
            var endIdx = startIdx
            while endIdx < spans.count, spans[endIdx].range.location < tokenEnd {
                endIdx += 1
            }
            tokenSpanRanges.append(startIdx..<endIdx)
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

            // Counter compound exception:
            // Preserve a boundary after 「中」 when the next characters are <digit>「人」.
            // This enables spans like 中 + 二人 even if MeCab tokenizes 中二 as a single token.
            func isMiddleNakaCounterBoundary(_ b: Int) -> Bool {
                // Need room for: ...「中」|<digit>「人」...
                guard b - 1 >= 0, b + 1 < text.length else { return false }

                let leftCharRange = text.rangeOfComposedCharacterSequence(at: b - 1)
                guard leftCharRange.length > 0 else { return false }
                let left = text.substring(with: leftCharRange)
                guard left == "中" else { return false }

                let digitRange = text.rangeOfComposedCharacterSequence(at: b)
                guard digitRange.length > 0 else { return false }
                let digit = text.substring(with: digitRange)
                let isDigit = (
                    digit == "一" || digit == "二" || digit == "三" || digit == "四" || digit == "五" ||
                    digit == "六" || digit == "七" || digit == "八" || digit == "九" || digit == "十" ||
                    digit == "0" || digit == "1" || digit == "2" || digit == "3" || digit == "4" ||
                    digit == "5" || digit == "6" || digit == "7" || digit == "8" || digit == "9" ||
                    digit == "０" || digit == "１" || digit == "２" || digit == "３" || digit == "４" ||
                    digit == "５" || digit == "６" || digit == "７" || digit == "８" || digit == "９"
                )
                guard isDigit else { return false }

                let personIndex = NSMaxRange(digitRange)
                guard personIndex < text.length else { return false }
                let personRange = text.rangeOfComposedCharacterSequence(at: personIndex)
                guard personRange.length > 0 else { return false }
                let person = text.substring(with: personRange)
                return person == "人"
            }

            if isMiddleNakaCounterBoundary(b) {
                return b
            }
            guard let t = tokenCoveringLocation(b) else { return b }
            let start = t.range.location
            let end = NSMaxRange(t.range)
            guard start < b, b < end else { return b }

            // Katakana-merge regression guard:
            // If the chosen MeCab token is a long katakana run, snapping boundaries inside it
            // can collapse multiple Stage-1 katakana spans into one (and later stages cannot
            // reliably undo that). For katakana-only tokens, preserve existing Stage-1 cuts
            // when they look like a lexicon-driven decomposition.
            if let tokenIdx = mecabTokenIndex(at: b), tokenIdx < tokenSpanRanges.count {
                let tokenRange = tokenSpanRanges[tokenIdx]
                if tokenRange.count >= 2, isKatakanaLikeString(t.surface) {
                    let tokenUtf16Len = end - start
                    let maxKatakanaMergedUtf16Len = 24

                    var hasRepeatedIdenticalSurface = false
                    var hasAnyAttestedSubspan = false
                    var mergedSurfaceAttested = false

                    if tokenRange.isEmpty == false {
                        for idx in tokenRange {
                            if idx >= 0, idx < spans.count {
                                if spans[idx].isLexiconMatch { hasAnyAttestedSubspan = true }
                                if spans[idx].isLexiconMatch, spans[idx].range.location == start, NSMaxRange(spans[idx].range) == end {
                                    mergedSurfaceAttested = true
                                }
                            }
                        }

                        // Detect repeated identical katakana surfaces within the covered run.
                        var prevSurface: String?
                        for idx in tokenRange {
                            guard idx >= 0, idx < spans.count else { continue }
                            let s = spans[idx].surface
                            if let prevSurface, prevSurface == s, isKatakanaLikeString(s) {
                                hasRepeatedIdenticalSurface = true
                                break
                            }
                            prevSurface = s
                        }
                    }

                    let mergedTooLong = tokenUtf16Len > maxKatakanaMergedUtf16Len
                    let mergedUnattestedWhileSubspansAttested = hasAnyAttestedSubspan && mergedSurfaceAttested == false

                    if hasRepeatedIdenticalSurface || mergedTooLong || mergedUnattestedWhileSubspansAttested {
                        return b
                    }
                }
            }

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

        func isSokuonUnit(_ unit: unichar) -> Bool {
            unit == smallTsuHiragana || unit == smallTsuKatakana
        }

        // Hard linguistic constraint (matches Stage 1):
        // Never allow a token boundary immediately after small っ/ッ unless it's end-of-text
        // or followed by a boundary character (whitespace/punctuation).
        //
        // Important: we must enforce this on the full cut set, not just MeCab token boundaries,
        // because upstream stages (e.g. embedding refinement) can introduce cuts that would
        // otherwise leak through and create spans like “ぼっ” + “ちよ”.
        let cutsFilteredForSokuon: [Int] = {
            guard cuts.count >= 3 else { return cuts }
            var out: [Int] = []
            out.reserveCapacity(cuts.count)
            for b in cuts {
                if b <= 0 || b >= text.length {
                    out.append(b)
                    continue
                }
                let prevUnit = text.character(at: b - 1)
                guard isSokuonUnit(prevUnit) else {
                    out.append(b)
                    continue
                }
                let nextUnit = text.character(at: b)
                if let nextScalar = UnicodeScalar(nextUnit), isBoundaryScalar(nextScalar) {
                    out.append(b)
                    continue
                }
                // Drop the cut to bind sokuon to the right.
            }
            // Ensure strict monotonic coverage and start/end are present.
            var dedup = Array(Set(out)).map(clampIndex).sorted()
            if dedup.first != 0 { dedup.insert(0, at: 0) }
            if dedup.last != text.length { dedup.append(text.length) }
            return dedup
        }()

        // Precompute all legal MeCab boundaries once.
        //
        // Hard linguistic constraint:
        // Do not introduce a split immediately after small っ/ッ when the next character
        // is not a boundary (whitespace/punctuation). This prevents Stage 1.5 from
        // emitting spans like “ぼっ” + “ちよ” for “ぼっちよ”.
        let tokenBoundariesSorted: [Int] = {
            // Boundaries to exclude entirely (both as an end-of-token and start-of-next-token).
            // This prevents creating spans that terminate on small っ/ッ.
            var illegalCuts: Set<Int> = []
            illegalCuts.reserveCapacity(16)
            for t in tokens {
                let end = NSMaxRange(t.range)
                guard end >= 0, end < text.length else { continue }
                guard endsWithSokuon(t.range) else { continue }
                let nextUnit = text.character(at: end)
                guard let nextScalar = UnicodeScalar(nextUnit) else { continue }
                if isBoundaryScalar(nextScalar) == false {
                    illegalCuts.insert(end)
                }
            }

            var b: Set<Int> = []
            b.reserveCapacity(tokens.count * 2)
            for t in tokens {
                let start = t.range.location
                let end = NSMaxRange(t.range)
                if start >= 0, start <= text.length, illegalCuts.contains(start) == false {
                    b.insert(start)
                }
                if end >= 0, end <= text.length, illegalCuts.contains(end) == false {
                    b.insert(end)
                }
            }
            // Always ensure start/end-of-text are available as cuts.
            b.insert(0)
            b.insert(text.length)
            return b.sorted()
        }()

        for i in 0..<(cutsFilteredForSokuon.count - 1) {
            let start = cutsFilteredForSokuon[i]
            let end = cutsFilteredForSokuon[i + 1]
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
