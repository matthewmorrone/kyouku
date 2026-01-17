import Foundation
import OSLog

/// Stage 1 of the furigana pipeline. Produces bounded, lexicon-driven spans by
/// walking the shared JMdict trie. No readings or semantic metadata escape this
/// layer, and SQLite is never touched after the trie finishes bootstrapping.
actor SegmentationService {
    static let shared = SegmentationService()

    // ─────────────────────────────────────────────────────────────────────────────
    // STAGE 1 SEGMENTATION CONTRACT (GUARDRAIL)
    //
    // This file implements *Stage 1* of the furigana/token pipeline.
    //
    // ALLOWED responsibilities (only):
    //  - Lexicon-driven surface segmentation via the JMdict trie.
    //  - Character-class grouping (kanji / hiragana / katakana / latin / numeric).
    //  - Longest-match surface lookup.
    //
    // FORBIDDEN responsibilities (bugs if added here):
    //  - Any attempt to model grammar, conjugation, okurigana attachment, or suffixes.
    //  - Any hard-coded substring rules or growing lists of “helpful” phrases.
    //  - Any references to MeCab/POS/readings/ruby projection behavior.
    //  - Any attempts to “fix” perceived linguistic errors upstream.
    //
    // If you are tempted to improve linguistic quality in this file: stop.
    // Stage 1 must remain stable, boring, and lexicon-only.
    // ─────────────────────────────────────────────────────────────────────────────

    nonisolated static func describe(spans: [TextSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }

    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SegmentationService")
    private var cache: [SegmentationCacheKey: [TextSpan]] = [:]
    private var lruKeys: [SegmentationCacheKey] = []
    private let maxEntries = 32

    private var trieCache: LexiconTrie?
    private var trieInitTask: Task<LexiconTrie, Error>?

    func segment(text: String) async throws -> [TextSpan] {
        guard text.isEmpty == false else { return [] }
        await CustomLogger.shared.debug("[Segmentation] enter len=\(text.count)")
        let overallStart = CFAbsoluteTimeGetCurrent()
        let segInterval = signposter.beginInterval("Segment", id: .exclusive, "len=\(text.count)")
        let key = SegmentationCacheKey(textHash: Self.hash(text), length: text.utf16.count)
        if let cached = cache[key] {
            await CustomLogger.shared.debug("[Segmentation] Cache hit for len=\(text.count) -> \(cached.count) spans.")
            signposter.endInterval("Segment", segInterval)
            return cached
        } else {
            await CustomLogger.shared.debug("[Segmentation] Cache miss for len=\(text.count). Proceeding to segment.")
        }

        let trieInterval = signposter.beginInterval("TrieLoad")
        let trieLoadStart = CFAbsoluteTimeGetCurrent()
        let trie = try await getTrie()
        let trieLoadMs = (CFAbsoluteTimeGetCurrent() - trieLoadStart) * 1000
        let trieSource = (trieInitTask == nil && trieCache != nil) ? "cached" : (trieInitTask != nil ? "building" : "unknown")
        await CustomLogger.shared.debug("SegmentationService: trie load completed (source=\(trieSource)) in \(String(format: "%.3f", trieLoadMs)) ms.")
        signposter.endInterval("TrieLoad", trieInterval)

        let nsText = text as NSString

        let rangesInterval = signposter.beginInterval("SegmentRanges")
        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let ranges = await segmentRanges(using: trie, text: nsText)
        let segmentationMs = (CFAbsoluteTimeGetCurrent() - segmentationStart) * 1000
        await CustomLogger.shared.debug("SegmentationService: segmentRanges took \(String(format: "%.3f", segmentationMs)) ms.")
        signposter.endInterval("SegmentRanges", rangesInterval)

        let mapInterval = signposter.beginInterval("MapRangesToSpans")
        let mapStart = CFAbsoluteTimeGetCurrent()
        let spans: [TextSpan] = ranges.flatMap { segmented -> [TextSpan] in
            guard let trimmedRange = Self.trimmedRange(from: segmented.range, in: nsText) else { return [] }
            let newlineSeparated = Self.splitRangeByNewlines(trimmedRange, in: nsText)
            return newlineSeparated.compactMap { segment -> TextSpan? in
                guard let clamped = Self.trimmedRange(from: segment, in: nsText) else { return nil }
                let surface = nsText.substring(with: clamped)
                return TextSpan(range: clamped, surface: surface, isLexiconMatch: segmented.isLexiconMatch)
            }
        }
        let mapMs = (CFAbsoluteTimeGetCurrent() - mapStart) * 1000
        await CustomLogger.shared.debug("SegmentationService: mapping ranges->spans took \(String(format: "%.3f", mapMs)) ms.")
        signposter.endInterval("MapRangesToSpans", mapInterval)

        await CustomLogger.shared.print("[STAGE-1 SEGMENTS @ SEGMENTATION]")
        await CustomLogger.shared.print(Self.describe(spans: spans))

        store(spans, for: key)
        let overallDurationMsDouble = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
        await CustomLogger.shared.debug("[Segmentation] exit spans=\(spans.count) dt=\(String(format: "%.2f", overallDurationMsDouble))ms")
        await CustomLogger.shared.debug("Segmented text length \(text.count) into \(spans.count) spans in \(String(format: "%.3f", overallDurationMsDouble)) ms (trie: \(String(format: "%.3f", trieLoadMs)) ms, segment: \(String(format: "%.3f", segmentationMs)) ms, map: \(String(format: "%.3f", mapMs)) ms).")
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
        if let scriptKind = kind, scriptKind == .katakana {
            ranges.append(contentsOf: await splitKatakana(range: pendingRange, text: text, trie: trie))
        } else {
            ranges.append(SegmentedRange(range: pendingRange, isLexiconMatch: false))
        }
        start = nil
        kind = nil
        return true
    }

    private func splitKatakana(range: NSRange, text: NSString, trie: LexiconTrie) async -> [SegmentedRange] {
        var results: [SegmentedRange] = []
        let runStart = range.location
        let runEnd = NSMaxRange(range)
        let runLength = runEnd - runStart
        guard runLength > 0 else { return [] }

        // LexiconTrie is main-actor isolated. Compute all match ends on the main actor,
        // then run DP reconstruction off the main actor.
        let swiftText: String = text as String
        let (matchEndsByOffset, _): ([[Int]], Bool) = await MainActor.run { [swiftText, runStart, runEnd, runLength] in

            let ns = swiftText as NSString
            var matchEndsByOffset: [[Int]] = Array(repeating: [], count: runLength)
            var _anyMatches = false

            for offset in 0..<runLength {
                let abs = runStart + offset
                let ends = trie.allMatchEnds(in: ns, from: abs, requireKanji: false)
                if ends.isEmpty { continue }
                let filtered = ends.filter { $0 <= runEnd }
                if filtered.isEmpty { continue }
                matchEndsByOffset[offset] = filtered
                _anyMatches = true
            }

            // Defensive fallback: if the “all ends” traversal yields nothing across the entire run,
            // try the simpler longest-match traversal.
            if _anyMatches == false {
                for offset in 0..<runLength {
                    let abs = runStart + offset
                    if let end = trie.longestMatchEnd(in: ns, from: abs, requireKanji: false), end <= runEnd, end > abs {
                        matchEndsByOffset[offset] = [end]
                        _anyMatches = true
                    }
                }
            }

            return (matchEndsByOffset, _anyMatches)
        }

        struct State {
            var nonLexChars: Int
            var segments: Int
            var nextOffset: Int
            var isLex: Bool
        }

        let inf = Int.max / 8
        var dp: [State] = Array(
            repeating: State(nonLexChars: inf, segments: inf, nextOffset: -1, isLex: false),
            count: runLength + 1
        )
        dp[runLength] = State(nonLexChars: 0, segments: 0, nextOffset: runLength, isLex: false)

        func better(_ a: State, than b: State) -> Bool {
            if a.nonLexChars != b.nonLexChars { return a.nonLexChars < b.nonLexChars }
            // Among equally-covered paths, prefer fewer segments (longer words).
            if a.segments != b.segments { return a.segments < b.segments }
            // Stable tie-break: prefer advancing further.
            return a.nextOffset > b.nextOffset
        }

        // DP from end → start: minimize non-lex chars, then minimize number of segments.
        if runLength > 0 {
            for i in stride(from: runLength - 1, through: 0, by: -1) {
                var best = State(nonLexChars: inf, segments: inf, nextOffset: i + 1, isLex: false)

                // Option A: take a lexicon word starting here.
                for endAbs in matchEndsByOffset[i] {
                    let j = endAbs - runStart
                    guard j > i, j <= runLength else { continue }
                    let tail = dp[j]
                    if tail.nonLexChars >= inf { continue }
                    let cand = State(nonLexChars: tail.nonLexChars, segments: tail.segments + 1, nextOffset: j, isLex: true)
                    if better(cand, than: best) { best = cand }
                }

                // Option B: fallback singleton.
                let tail = dp[i + 1]
                if tail.nonLexChars < inf {
                    let cand = State(nonLexChars: tail.nonLexChars + 1, segments: tail.segments + 1, nextOffset: i + 1, isLex: false)
                    if better(cand, than: best) { best = cand }
                }

                dp[i] = best
            }
        }

        // Reconstruct.
        var offset = 0
        while offset < runLength {
            let s = dp[offset]
            let absStart = runStart + offset
            let absEnd = runStart + s.nextOffset
            let len = max(1, absEnd - absStart)
            results.append(SegmentedRange(range: NSRange(location: absStart, length: len), isLexiconMatch: s.isLex))
            offset = s.nextOffset
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
            await CustomLogger.shared.debug("getTrie(): returning cached trie in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
            return t
        }
        if let task = trieInitTask {
            await CustomLogger.shared.debug("getTrie(): awaiting existing build task…")
            return try await task.value
        }
        await CustomLogger.shared.debug("getTrie(): creating new build task…")
        let task = Task { try await LexiconProvider.shared.trie() }
        trieInitTask = task
        let t = try await task.value
        trieCache = t
        trieInitTask = nil
        await CustomLogger.shared.debug("getTrie(): build task completed in \(((CFAbsoluteTimeGetCurrent()-start)*1000)) ms")
        return t
    }

    private func segmentRanges(using trie: LexiconTrie, text: NSString) async -> [SegmentedRange] {
        let length = text.length
        guard length > 0 else { return [] }

        await CustomLogger.shared.debug("segmentRanges: starting scan length=\(length)")

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
            let currentUnit = text.character(at: cursor)

            // Katakana runs are intentionally decomposed (lexicon DP) instead of using
            // greedy longest-match at each cursor. This preserves tokenization like
            // "ロンリーロンリーハート" → "ロンリー","ロンリー","ハート" even when the
            // full concatenation exists in the lexicon.
            if Self.isKatakana(currentUnit) {
                nonKanjiCount += 1
                let kind: ScriptKind = .katakana
                if let currentKind = pendingNonKanjiKind, currentKind != kind {
                    _ = await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges)
                }
                if pendingNonKanjiStart == nil {
                    pendingNonKanjiStart = cursor
                    pendingNonKanjiKind = kind
                }
                cursor += 1
                continue
            }

            trieLookups += 1
            let lookupStart = CFAbsoluteTimeGetCurrent()
            let current = cursor
            let requireKanjiMatch = (Self.isHiragana(currentUnit) == false && Self.isKatakana(currentUnit) == false)
            let matchEnd: Int? = await MainActor.run { [current, swiftText, requireKanjiMatch] in
                let ns = swiftText as NSString
                return trie.longestMatchEnd(in: ns, from: current, requireKanji: requireKanjiMatch)
            }
            trieLookupTime += CFAbsoluteTimeGetCurrent() - lookupStart
            if let end = matchEnd {
                if await flushPendingNonKanji(start: &pendingNonKanjiStart, kind: &pendingNonKanjiKind, cursor: cursor, text: text, trie: trie, into: &ranges) {
                    // start cleared inside helper
                }
                let len = end - cursor
                sumMatchLen += len
                if len > maxMatchLen { maxMatchLen = len }
                ranges.append(SegmentedRange(range: NSRange(location: cursor, length: len), isLexiconMatch: true))
                matchesFound += 1
                cursor = end
                continue
            }

            let unit = currentUnit
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

                let kind = Self.scriptKind(for: scalar)
                if let currentKind = pendingNonKanjiKind, currentKind != kind {
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

        await CustomLogger.shared.debug("segmentRanges: finished scan with \(ranges.count) ranges. Performing metrics…")

        let totalDuration = CFAbsoluteTimeGetCurrent() - profilingStart
        let totalMs = totalDuration * 1000
        let lookupMs = trieLookupTime * 1000
        let avgMatchLen = matchesFound > 0 ? Double(sumMatchLen) / Double(matchesFound) : 0
        await CustomLogger.shared.debug("segmentRanges: scanned length \(length) -> \(ranges.count) ranges in \(String(format: "%.3f", totalMs)) ms (lookups: \(trieLookups), matches: \(matchesFound), singletons: \(singletonKanji), avgMatchLen: \(String(format: "%.2f", avgMatchLen)), maxMatchLen: \(maxMatchLen), kanji: \(kanjiCount), nonKanji: \(nonKanjiCount), lookupTime: \(String(format: "%.3f", lookupMs)) ms).")
        await MainActor.run {
            trie.endProfiling(totalDuration: totalDuration)
        }
        signposter.endInterval("SegmentRangesLoop", loopInterval)

#if DEBUG
        await assertStage1Guardrails(ranges: ranges, text: text, swiftText: swiftText, trie: trie)
#endif

        return ranges
    }

#if DEBUG
    /// DEBUG-only invariant check.
    ///
    /// Goal: make it obvious during development if Stage 1 starts depending on
    /// hard-coded substring heuristics, okurigana/conjugation logic, or grammar modeling.
    ///
    /// These invariants intentionally constrain Stage 1 to:
    ///  - trie longest-match spans (when `isLexiconMatch == true`)
    ///  - otherwise, maximal same-script runs (or singletons for kanji/whitespace/punctuation)
    private func assertStage1Guardrails(
        ranges: [SegmentedRange],
        text: NSString,
        swiftText: String,
        trie: LexiconTrie
    ) async {
        guard ranges.isEmpty == false else { return }

        let nsSwift = swiftText as NSString
        func snippet(_ r: NSRange) -> String {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= nsSwift.length else { return "<out-of-bounds>" }
            let s = nsSwift.substring(with: r)
            if s.count <= 40 { return s.debugDescription }
            let head = String(s.prefix(40))
            return (head + "…").debugDescription
        }
        func charSnippet(at index: Int) -> String {
            guard index >= 0, index < nsSwift.length else { return "<oob>" }
            return snippet(NSRange(location: index, length: 1))
        }

        // A) Coverage: ranges must be contiguous and cover the full string.
        var expectedCursor = 0
        for range in ranges {
            assert(range.range.location == expectedCursor, "Stage1 invariant failed: gap/overlap at \(range.range.location), expected \(expectedCursor)")
            expectedCursor = NSMaxRange(range.range)
        }
        assert(expectedCursor == text.length, "Stage1 invariant failed: ranges do not cover full length")

        // B) Lexicon matches must be EXACT trie-longest matches from their start.
        for range in ranges where range.isLexiconMatch {
            let start = range.range.location
            guard start >= 0, start < text.length else { continue }
            let firstUnit = text.character(at: start)
            // Katakana runs intentionally allow non-longest lexicon matches due to
            // DP-based decomposition (e.g. splitting concatenations into multiple words).
            if Self.isKatakana(firstUnit) {
                continue
            }
            let requireKanjiMatch = (Self.isHiragana(firstUnit) == false && Self.isKatakana(firstUnit) == false)
            let computedEnd: Int? = await MainActor.run { [start, swiftText, requireKanjiMatch] in
                let ns = swiftText as NSString
                return trie.longestMatchEnd(in: ns, from: start, requireKanji: requireKanjiMatch)
            }
            assert(computedEnd == NSMaxRange(range.range), "Stage1 invariant failed: lexicon span is not trie-longest-match (start=\(start) computedEnd=\(String(describing: computedEnd)) actualEnd=\(NSMaxRange(range.range)))")
        }

        // C) Non-lexicon ranges must be “boring” script grouping:
        //    - kanji, whitespace, punctuation => singletons
        //    - otherwise => maximal same-script runs
        for (i, seg) in ranges.enumerated() where seg.isLexiconMatch == false {
            let r = seg.range
            guard r.length > 0 else { continue }
            let start = r.location
            let end = NSMaxRange(r)
            guard start >= 0, end <= text.length else { continue }

            // A non-lexicon run may legally border a lexicon match of the same script kind.
            // We cannot extend across that boundary without overlapping a lexicon range.
            let prevIsLexicon = (i > 0) ? ranges[i - 1].isLexiconMatch : false
            let nextIsLexicon = (i + 1 < ranges.count) ? ranges[i + 1].isLexiconMatch : false

            let firstUnit = text.character(at: start)
            guard let firstScalar = UnicodeScalar(firstUnit) else { continue }

            if Self.isKanji(firstUnit) || Self.isWhitespaceOrNewline(firstScalar) || Self.isPunctuation(firstScalar) {
                assert(r.length == 1, "Stage1 invariant failed: boundary singleton expanded (\(start), len=\(r.length))")
                continue
            }

            // Same-script run
            let kind = Self.scriptKind(for: firstScalar)
            if r.length > 1 {
                for j in start..<end {
                    let unit = text.character(at: j)
                    guard let scalar = UnicodeScalar(unit) else { continue }
                    assert(Self.isKanji(unit) == false, "Stage1 invariant failed: non-lexicon run contains kanji (\(start)..\(end))")
                    assert(Self.isWhitespaceOrNewline(scalar) == false && Self.isPunctuation(scalar) == false, "Stage1 invariant failed: non-lexicon run contains boundary chars (\(start)..\(end))")
                    assert(Self.scriptKind(for: scalar) == kind, "Stage1 invariant failed: non-lexicon run crosses script kinds (\(start)..\(end))")
                }
            }

            // Maximality: should not be extendable by an adjacent char of same kind.
            if start > 0 {
                let prevUnit = text.character(at: start - 1)
                if let prevScalar = UnicodeScalar(prevUnit), Self.isKanji(prevUnit) == false, Self.isWhitespaceOrNewline(prevScalar) == false, Self.isPunctuation(prevScalar) == false {
                    if prevIsLexicon == false, Self.scriptKind(for: prevScalar) == kind {
                        await CustomLogger.shared.error(
                            "Stage1 invariant failed: non-lexicon run is not maximal on the left " +
                            "range=[\(start)..<\(end)] kind=\(kind) surface=\(snippet(r)) prevChar=\(charSnippet(at: start - 1))"
                        )
                    }
                    assert(prevIsLexicon || Self.scriptKind(for: prevScalar) != kind, "Stage1 invariant failed: non-lexicon run is not maximal on the left")
                }
            }
            if end < text.length {
                let nextUnit = text.character(at: end)
                if let nextScalar = UnicodeScalar(nextUnit), Self.isKanji(nextUnit) == false, Self.isWhitespaceOrNewline(nextScalar) == false, Self.isPunctuation(nextScalar) == false {
                    if nextIsLexicon == false, Self.scriptKind(for: nextScalar) == kind {
                        await CustomLogger.shared.error(
                            "Stage1 invariant failed: non-lexicon run is not maximal on the right " +
                            "range=[\(start)..<\(end)] kind=\(kind) surface=\(snippet(r)) nextChar=\(charSnippet(at: end))"
                        )
                    }
                    assert(nextIsLexicon || Self.scriptKind(for: nextScalar) != kind, "Stage1 invariant failed: non-lexicon run is not maximal on the right")
                }
            }

            // D) Non-lexicon runs may never be silently “upgraded” into mixed-script spans.
            // (That would indicate okurigana/grammar attachment heuristics.)
            // This is implicitly enforced by the checks above.

            _ = i // silence unused warning if assertions compiled out
        }
    }
#endif

    private static func isKanji(_ unit: unichar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(unit))
    }

    private static func isHiragana(_ unit: unichar) -> Bool {
        (0x3040...0x309F).contains(Int(unit))
    }

    private static func isKatakana(_ unit: unichar) -> Bool {
        if (0x30A0...0x30FF).contains(Int(unit)) { return true }
        // Halfwidth katakana block.
        // Include dakuten/handakuten marks (FF9E/FF9F) so sequences like "ｶﾞ" stay in the run.
        if (0xFF66...0xFF9F).contains(Int(unit)) { return true }
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
        if (0x30A0...0x30FF).contains(Int(scalar.value)) || (0xFF66...0xFF9F).contains(Int(scalar.value)) || scalar.value == 0x30FC || scalar.value == 0xFF70 {
            return .katakana
        }
        if (0x0030...0x0039).contains(Int(scalar.value)) { return .numeric }
        if (0x0041...0x005A).contains(Int(scalar.value)) || (0x0061...0x007A).contains(Int(scalar.value)) {
            return .latin
        }
        return .other
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

    private static let punctuationExtras: Set<UnicodeScalar> = {
        let chars = "、。！？：；（）［］｛｝「」『』・…―〜。・"
        return Set(chars.unicodeScalars)
    }()

    private static let newlineCharacters = CharacterSet.newlines

}

nonisolated enum ScriptKind: Equatable {
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

