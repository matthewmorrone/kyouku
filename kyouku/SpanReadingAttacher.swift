import Foundation
import CoreFoundation
import QuartzCore
import Mecab_Swift
import IPADic
import OSLog

internal import StringTools

// INVESTIGATION: timing/logging helpers (2026-01-05)
// NOTE: Investigation-only instrumentation. Do not change control flow beyond adding logs.
@preconcurrency @MainActor @inline(__always)
func ivlog(_ msg: String) {
    print("[INVESTIGATION] \(msg) main=\(Thread.isMainThread)")
}

@preconcurrency @MainActor @inline(__always)
func ivtime<T>(_ label: String, _ f: () throws -> T) rethrows -> T {
    let t0 = CACurrentMediaTime()
    defer {
        let ms = (CACurrentMediaTime() - t0) * 1000
        ivlog("\(label) dt=\(String(format: "%.2f", ms))ms")
    }
    return try f()
}

@preconcurrency @MainActor @inline(__always)
func ivtimeAsync<T>(_ label: String, _ f: () async throws -> T) async rethrows -> T {
    let t0 = CACurrentMediaTime()
    defer {
        let ms = (CACurrentMediaTime() - t0) * 1000
        ivlog("\(label) dt=\(String(format: "%.2f", ms))ms")
    }
    return try await f()
}

/// Stage 2 of the furigana pipeline. Consumes `TextSpan` boundaries, runs
/// MeCab/IPADic exactly once per input text, and attaches kana readings. No
/// SQLite lookups occur here, mirroring the behavior of commit 0e7736a.
///
/// STAGE 2 CONTRACT:
/// Stage 2 always produces `SemanticSpan` as the semantic regrouping layer.
/// Downstream consumers may ignore semantic spans, but Stage 2 must always emit them.
struct SpanReadingAttacher {
    private static var sharedTokenizer: Tokenizer? = {
        try? Tokenizer(dictionary: IPADic())
    }()

    private static let cache = ReadingAttachmentCache(maxEntries: 32)
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SpanReadingAttacher")

    struct Result {
        let annotatedSpans: [AnnotatedSpan]
        let semanticSpans: [SemanticSpan]
    }

    func attachReadings(text: String, spans: [TextSpan]) async -> [AnnotatedSpan] {
        let result = await attachReadings(text: text, spans: spans, treatSpanBoundariesAsAuthoritative: false)
        return result.annotatedSpans
    }

    /// Stage 2 (MeCab attachment) plus Stage 2.5 (semantic regrouping) in one pass.
    ///
    /// This intentionally lives downstream of Stage 1 because Stage 1 is frozen
    /// and lexicon-only. Semantic regrouping is driven by MeCab token coverage and
    /// is used for ruby projection only; it never mutates the original spans.
    ///
    /// INVESTIGATION NOTES (2026-01-04)
    /// - Execution path: FuriganaPipelineService.render → FuriganaAttributedTextBuilder.computeStage2 → Stage-1 segmentation
    ///   → SpanReadingAttacher.attachReadings (Stage-2) → semanticRegrouping (Stage-2.5) → FuriganaAttributedTextBuilder.project.
    /// - New work vs prior "stable" (commit 17a31955…): Stage-2.5 semantic regrouping now runs for every Stage-2 pass.
    /// - Performance-sensitive additions:
    ///   - Materializing and printing semantic spans via `SemanticSpan.describe(spans:)` can be O(n) in span count and alloc-heavy.
    ///   - Stage-2.5 contains nested scans that can degrade worse than O(n) depending on token/run structure (see below).
    /// - No explicit numeric "scoring" found here; instead there are head/dependent heuristics (POS + boundary rules) that function
    ///   like a classifier to decide grouping.
    func attachReadings(
        text: String,
        spans: [TextSpan],
        treatSpanBoundariesAsAuthoritative: Bool
    ) async -> Result {
        ivlog("Stage2.attachReadings enter len=\(text.count) spans=\(spans.count) authoritative=\(treatSpanBoundariesAsAuthoritative)")
        guard text.isEmpty == false, spans.isEmpty == false else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            let semantic = spans.enumerated().map { idx, span in
                SemanticSpan(range: span.range, surface: span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: nil)
            }
            CustomLogger.shared.print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
            CustomLogger.shared.print(SemanticSpan.describe(spans: semantic))
            return Result(annotatedSpans: passthrough, semanticSpans: semantic)
        }

        let start = CFAbsoluteTimeGetCurrent()
        let overallInterval = Self.signposter.beginInterval("AttachReadings Overall", "len=\(text.count) spans=\(spans.count)")

        let key = ReadingAttachmentCacheKey(
            textHash: Self.hash(text),
            spanSignature: Self.signature(for: spans),
            treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative
        )
        if let cached = await Self.cache.value(for: key) {
            let duration = Self.elapsedMilliseconds(since: start)
            CustomLogger.shared.debug("[SpanReadingAttacher] Cache hit for \(spans.count) spans in \(duration) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            CustomLogger.shared.print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
            CustomLogger.shared.print(SemanticSpan.describe(spans: cached.semanticSpans))
            return cached
        }

        let tokStart = CFAbsoluteTimeGetCurrent()
        let tokInterval = Self.signposter.beginInterval("Tokenizer Acquire")
        let tokenizerOpt: Tokenizer? = ivtime("Stage2.tokenizerAcquire") {
            Self.tokenizer()
        }
        Self.signposter.endInterval("Tokenizer Acquire", tokInterval)
        let tokMs = (CFAbsoluteTimeGetCurrent() - tokStart) * 1000
        if tokenizerOpt == nil {
            // CustomLogger.shared.error("[SpanReadingAttacher] Tokenizer acquisition failed in \(String(format: \"%.3f\", tokMs)) ms")
        } else {
            CustomLogger.shared.info("[SpanReadingAttacher] Tokenizer acquired in \(String(format: "%.3f", tokMs)) ms")
        }
        guard let tokenizer = tokenizerOpt else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            let semantic = passthrough.enumerated().map { idx, span in
                SemanticSpan(range: span.span.range, surface: span.span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: span.readingKana)
            }
            let result = Result(annotatedSpans: passthrough, semanticSpans: semantic)
            await Self.cache.store(result, for: key)
            CustomLogger.shared.info("[SpanReadingAttacher] Failed to acquire tokenizer. Returning passthrough spans in (duration) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            CustomLogger.shared.print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
            CustomLogger.shared.print(SemanticSpan.describe(spans: result.semanticSpans))
            return result
        }

        let tokenizeStart = CFAbsoluteTimeGetCurrent()
        let tokenizeInterval = Self.signposter.beginInterval("MeCab Tokenize", "len=\(text.count)")
        let annotations: [MeCabAnnotation] = ivtime("Stage2.mecabTokenize") {
            tokenizer.tokenize(text: text).compactMap { annotation -> MeCabAnnotation? in
                let nsRange = NSRange(annotation.range, in: text)
                guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
                let surface = String(text[annotation.range])
                let pos = String(describing: annotation.partOfSpeech)
                return MeCabAnnotation(range: nsRange, reading: annotation.reading, surface: surface, dictionaryForm: annotation.dictionaryForm, partOfSpeech: pos)
            }
        }
        Self.signposter.endInterval("MeCab Tokenize", tokenizeInterval)
        let tokenizeMs = (CFAbsoluteTimeGetCurrent() - tokenizeStart) * 1000
        CustomLogger.shared.info("[SpanReadingAttacher] MeCab tokenization produced \(annotations.count) annotations in \(String(format: "%.3f", tokenizeMs)) ms")

        var annotated: [AnnotatedSpan] = []
        annotated.reserveCapacity(spans.count)

        for span in spans {
            let attachment = attachmentForSpan(span, annotations: annotations, tokenizer: tokenizer)
            let override = await ReadingOverridePolicy.shared.overrideReading(for: span.surface, mecabReading: attachment.reading)
            let finalReading = override ?? attachment.reading
            annotated.append(AnnotatedSpan(span: span, readingKana: finalReading, lemmaCandidates: attachment.lemmas, partOfSpeech: attachment.partOfSpeech))
        }

        let semantic: [SemanticSpan] = await ivtimeAsync("Stage2.5.detachedWait") {
            await Task.detached(priority: .userInitiated) { [self] in
                await ivlog("Stage2.5.detached start")
                let out = await ivtimeAsync("Stage2.5.semanticRegrouping") {
                    await self.semanticRegrouping(
                        text: text,
                        nsText: text as NSString,
                        spans: spans,
                        annotatedSpans: annotated,
                        annotations: annotations,
                        treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative
                    )
                }
                await ivlog("Stage2.5.detached end out=\(out.count)")
                return out
            }.value
        }

        CustomLogger.shared.print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
        CustomLogger.shared.print(SemanticSpan.describe(spans: semantic))
        CustomLogger.shared.debug("Stage2: stage1Count=\(spans.count) stage2Count=\(semantic.count)")

        let result = Result(annotatedSpans: annotated, semanticSpans: semantic)
        await Self.cache.store(result, for: key)

        _ = Self.elapsedMilliseconds(since: start)
        // CustomLogger.shared.info("[SpanReadingAttacher] Attached readings for \(spans.count) spans in \(String(format: \"%.3f\", duration)) ms.")
        Self.signposter.endInterval("AttachReadings Overall", overallInterval)
        return result
    }

    private func semanticRegrouping(
        text: String,
        nsText: NSString,
        spans: [TextSpan],
        annotatedSpans: [AnnotatedSpan],
        annotations: [MeCabAnnotation],
        treatSpanBoundariesAsAuthoritative: Bool
    ) async -> [SemanticSpan] {
        // INVESTIGATION/ROLLBACK (2026-01-05)
        // Merge-only, multi-pass boundary repair.
        // Hard rules:
        //  1) May merge spans, but must never split an existing Stage-1 span.
        //  2) Span count must be monotonically non-increasing across passes.
        //  3) No head/dependent logic, no syntactic parsing, no POS ownership.
        // Merge criteria (only):
        //  • A MeCab token whose surface range exactly covers multiple adjacent Stage-1 spans → merge them.
        //  • Explicit small whitelist merges (e.g. verb stem + auxiliaries like てる, ていく, てくる).
        // Safety:
        //  • Never cross hard boundaries (punctuation / whitespace). We enforce contiguity and reject hard-boundary spans.

        func passthroughSemanticSpans(reason: String?) -> [SemanticSpan] {
            if let reason {
                CustomLogger.shared.debug("[STAGE-2] bailout: \(reason)")
            }
            return annotatedSpans.enumerated().map { idx, span in
                SemanticSpan(range: span.span.range, surface: span.span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: span.readingKana)
            }
        }

        ivlog("Stage2.5.mergeOnly start spans=\(spans.count)")

        // User-amended spans are authoritative: do not regroup across their boundaries.
        guard treatSpanBoundariesAsAuthoritative == false else {
            let semantic = passthroughSemanticSpans(reason: "authoritative boundaries")

#if DEBUG
            assert(semantic.count == spans.count, "Stage2 invariant failed: authoritative semantic passthrough count mismatch")
            var expectedCursor = 0
            for (idx, s) in semantic.enumerated() {
                assert(s.sourceSpanIndices.lowerBound == idx && s.sourceSpanIndices.upperBound == (idx + 1), "Stage2 invariant failed: authoritative semantic indices mismatch at \(idx)")
                assert(s.range.location == expectedCursor, "Stage2 invariant failed: authoritative semantic ranges have gap/overlap at \(s.range.location), expected \(expectedCursor)")
                expectedCursor = NSMaxRange(s.range)
            }
            assert(expectedCursor == nsText.length, "Stage2 invariant failed: authoritative semantic ranges do not cover full text")
#endif

            CustomLogger.shared.debug("[STAGE-2] end spansIn=\(spans.count) spansOut=\(semantic.count)")
            return semantic
        }

        // Lexicon membership (JMdict trie). Used only for merge validation; never mutates Stage-1.
        let trie: LexiconTrie? = try? await LexiconProvider.shared.trie()

        struct Segment {
            var range: NSRange
            var sourceSpanIndices: Range<Int>
        }

        func surface(of segment: Segment) -> String {
            guard segment.range.location != NSNotFound, segment.range.length > 0 else { return "" }
            guard NSMaxRange(segment.range) <= nsText.length else { return "" }
            return nsText.substring(with: segment.range)
        }

        func isKanaOnly(_ s: String) -> Bool {
            guard s.isEmpty == false else { return false }
            for scalar in s.unicodeScalars {
                if CharacterSet.hiragana.contains(scalar) == false && CharacterSet.katakana.contains(scalar) == false {
                    return false
                }
            }
            return true
        }

        func isHiraganaOnly(_ s: String) -> Bool {
            guard s.isEmpty == false else { return false }
            for scalar in s.unicodeScalars {
                if CharacterSet.hiragana.contains(scalar) == false {
                    return false
                }
            }
            return true
        }

        func isHardBoundarySurface(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return true }
            // Treat punctuation/symbol-only spans as hard boundaries.
            var allBoundary = true
            for scalar in trimmed.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    continue
                }
                if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                    continue
                }
                allBoundary = false
                break
            }
            return allBoundary
        }

        func merge(_ segments: inout [Segment], from start: Int, to endExclusive: Int) -> Bool {
            guard start >= 0, endExclusive <= segments.count, endExclusive - start >= 2 else { return false }

            // Never cross hard boundaries: only merge if spans are strictly contiguous in UTF-16.
            var cursor = segments[start].range.location
            let end = NSMaxRange(segments[endExclusive - 1].range)
            var k = start
            while k < endExclusive {
                if segments[k].range.location != cursor { return false }
                let s = surface(of: segments[k])
                if isHardBoundarySurface(s) { return false }
                cursor = NSMaxRange(segments[k].range)
                k += 1
            }
            guard cursor == end else { return false }

            let union = NSUnionRange(segments[start].range, segments[endExclusive - 1].range)
            let lower = segments[start].sourceSpanIndices.lowerBound
            let upper = segments[(endExclusive - 1)].sourceSpanIndices.upperBound
            segments[start] = Segment(range: union, sourceSpanIndices: lower..<upper)
            segments.removeSubrange((start + 1)..<endExclusive)
            return true
        }

        func tokenEndExclusiveCoveringSegments(tokenRange: NSRange, segments: [Segment], startIndex: Int) -> Int? {
            guard tokenRange.location != NSNotFound, tokenRange.length > 0 else { return nil }
            guard startIndex >= 0, startIndex < segments.count else { return nil }
            guard segments[startIndex].range.location == tokenRange.location else { return nil }
            let tokenEnd = NSMaxRange(tokenRange)

            var cursor = tokenRange.location
            var j = startIndex
            while j < segments.count, cursor < tokenEnd {
                let r = segments[j].range
                guard r.location == cursor else { return nil }
                let s = surface(of: segments[j])
                if isHardBoundarySurface(s) { return nil }
                cursor = NSMaxRange(r)
                if cursor > tokenEnd { return nil }
                j += 1
            }
            guard cursor == tokenEnd else { return nil }
            guard j - startIndex >= 2 else { return nil }
            return j
        }

        func readingForSegment(_ segment: Segment) -> String? {
            // Prefer an exact MeCab token reading for this range when available.
            if let token = annotations.first(where: { $0.range.location == segment.range.location && $0.range.length == segment.range.length }) {
                let r = token.reading.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.isEmpty == false { return r }
            }

            // Fallback: concatenate underlying span readings, including kana-only surfaces.
            var out = ""
            for idx in segment.sourceSpanIndices {
                guard annotatedSpans.indices.contains(idx) else { continue }
                let a = annotatedSpans[idx]
                if let r = a.readingKana, r.isEmpty == false {
                    out.append(r)
                } else if isKanaOnly(a.span.surface) {
                    out.append(a.span.surface)
                }
            }
            return out.isEmpty ? nil : out
        }

        // Pre-index tokens by start to keep the per-pass scan O(n) in spans.
        var tokensByStart: [Int: [MeCabAnnotation]] = [:]
        tokensByStart.reserveCapacity(min(64, annotations.count))
        for token in annotations {
            guard token.range.location != NSNotFound, token.range.length > 0 else { continue }
            tokensByStart[token.range.location, default: []].append(token)
        }
        for (k, list) in tokensByStart {
            tokensByStart[k] = list.sorted { lhs, rhs in
                if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
                return lhs.surface.count > rhs.surface.count
            }
        }

        let whitelistMerges: Set<String> = ["てる", "ていく", "てくる"]

        var segments: [Segment] = spans.enumerated().map { idx, span in
            Segment(range: span.range, sourceSpanIndices: idx..<(idx + 1))
        }

        let maxPasses = 64
        var pass = 0
        while pass < maxPasses {
            pass += 1
            let beforeCount = segments.count
            ivlog("Stage2.5.mergeOnly pass=\(pass) spans=\(beforeCount)")

            var didMerge = false
            var i = 0
            while i < segments.count {
                // Rule 1: token coverage merge (exact range cover).
                if let candidates = tokensByStart[segments[i].range.location], candidates.isEmpty == false {
                    var mergedThisIndex = false
                    for token in candidates {
                        if let endExclusive = tokenEndExclusiveCoveringSegments(tokenRange: token.range, segments: segments, startIndex: i) {
                            if merge(&segments, from: i, to: endExclusive) {
                                didMerge = true
                                mergedThisIndex = true
                                break
                            }
                        }
                    }
                    if mergedThisIndex {
                        continue
                    }
                }

                // Rule 2: Kanji-head + kana-tail continuation merge (adjacent only).
                // Merge S[i], S[i+1] iff:
                //  1) left contains at least one Kanji
                //  2) right is entirely Hiragana
                //  3) (a) combined surface exists in lexicon trie, OR
                //     (b) MeCab produced a single lemma/token whose range exactly covers the combined range.
                if i + 1 < segments.count {
                    let leftSeg = segments[i]
                    let rightSeg = segments[i + 1]
                    let contiguous = NSMaxRange(leftSeg.range) == rightSeg.range.location
                    if contiguous {
                        let left = surface(of: leftSeg)
                        let right = surface(of: rightSeg)
                        if isHardBoundarySurface(left) == false,
                           isHardBoundarySurface(right) == false,
                           containsKanji(left),
                           isHiraganaOnly(right) {
                            let combinedRange = NSRange(location: leftSeg.range.location, length: leftSeg.range.length + rightSeg.range.length)
                            let combinedSurface = left + right

                            var ok = false
                            if let trie {
                                ok = trie.containsWord(in: nsText, from: combinedRange.location, through: NSMaxRange(combinedRange), requireKanji: true)
                            }
                            if ok == false {
                                if let candidates = tokensByStart[combinedRange.location] {
                                    ok = candidates.contains(where: { token in
                                        token.range.location == combinedRange.location &&
                                            token.range.length == combinedRange.length &&
                                            token.dictionaryForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                    })
                                }
                            }

                            if ok {
                                CustomLogger.shared.debug("[STAGE-2.5] merge kanjiKana '\(left)' + '\(right)' -> '\(combinedSurface)'")
                                if merge(&segments, from: i, to: i + 2) {
                                    didMerge = true
                                    continue
                                }
                            }
                        }
                    }
                }

                // Rule 3: explicit whitelist merges (adjacent only).
                if i + 1 < segments.count {
                    let left = surface(of: segments[i])
                    let right = surface(of: segments[i + 1])
                    let contiguous = NSMaxRange(segments[i].range) == segments[i + 1].range.location
                    if contiguous && isHardBoundarySurface(left) == false && isHardBoundarySurface(right) == false {
                        if whitelistMerges.contains(right) {
                            if merge(&segments, from: i, to: i + 2) {
                                didMerge = true
                                continue
                            }
                        }
                    }
                }

                i += 1
            }

            let afterCount = segments.count
#if DEBUG
            assert(afterCount <= beforeCount, "Stage2.5 invariant failed: span count increased \(beforeCount) -> \(afterCount)")
#endif
            if didMerge == false {
                break
            }
        }

        let semantic: [SemanticSpan] = segments.map { seg in
            SemanticSpan(
                range: seg.range,
                surface: surface(of: seg),
                sourceSpanIndices: seg.sourceSpanIndices,
                readingKana: readingForSegment(seg)
            )
        }

        ivlog("Stage2.5.mergeOnly end spansIn=\(spans.count) spansOut=\(semantic.count)")
        return semantic
    }

    private static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        let start = max(0, min(length, range.location))
        let end = max(start, min(length, NSMaxRange(range)))
        return NSRange(location: start, length: end - start)
    }

    private static func hardBoundaryCharacterSet() -> CharacterSet {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
    }

    private static func isHardBoundaryOnly(_ surface: String) -> Bool {
        if surface.isEmpty { return true }
        for scalar in surface.unicodeScalars {
            if hardBoundaryCharacterSet().contains(scalar) == false {
                return false
            }
        }
        return true
    }

    private static func hardBoundaryRanges(in nsText: NSString) -> [NSRange] {
        let length = nsText.length
        guard length > 0 else { return [] }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(16)

        var cursor = 0
        var pendingStart: Int? = nil
        while cursor < length {
            let r = nsText.rangeOfComposedCharacterSequence(at: cursor)
            let s = nsText.substring(with: r)
            if isHardBoundaryOnly(s) {
                if pendingStart == nil { pendingStart = r.location }
            } else if let start = pendingStart {
                let end = r.location
                if end > start {
                    ranges.append(NSRange(location: start, length: end - start))
                }
                pendingStart = nil
            }
            cursor = NSMaxRange(r)
        }

        if let start = pendingStart, start < length {
            ranges.append(NSRange(location: start, length: length - start))
        }

        return ranges
    }

    private static func nonBoundaryRuns(in nsText: NSString, hardBoundaries: [NSRange]) -> [NSRange] {
        let length = nsText.length
        guard length > 0 else { return [] }
        guard hardBoundaries.isEmpty == false else { return [NSRange(location: 0, length: length)] }

        let sorted = hardBoundaries.sorted { $0.location < $1.location }
        var runs: [NSRange] = []
        runs.reserveCapacity(sorted.count + 1)

        var cursor = 0
        for b in sorted {
            if b.location > cursor {
                runs.append(NSRange(location: cursor, length: b.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(b))
        }
        if cursor < length {
            runs.append(NSRange(location: cursor, length: length - cursor))
        }
        return runs
    }

    private static func split(_ range: NSRange, excluding boundaries: [NSRange]) -> [NSRange] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        guard boundaries.isEmpty == false else { return [range] }

        let rangeEnd = NSMaxRange(range)
        let sorted = boundaries.sorted { $0.location < $1.location }
        var pieces: [NSRange] = []
        pieces.reserveCapacity(2)

        var cursor = range.location
        for b in sorted {
            if b.location >= rangeEnd { break }
            let bEnd = NSMaxRange(b)
            if bEnd <= cursor { continue }
            if b.location > cursor {
                let piece = NSRange(location: cursor, length: b.location - cursor)
                if piece.length > 0 { pieces.append(piece) }
            }
            cursor = max(cursor, bEnd)
            if cursor >= rangeEnd { break }
        }

        if cursor < rangeEnd {
            let piece = NSRange(location: cursor, length: rangeEnd - cursor)
            if piece.length > 0 { pieces.append(piece) }
        }

        return pieces
    }

    private static func sourceSpanIndexRange(intersecting range: NSRange, spans: [TextSpan]) -> Range<Int> {
        guard spans.isEmpty == false else { return 0..<0 }
        var start: Int? = nil
        var endExclusive: Int? = nil
        for (idx, span) in spans.enumerated() {
            if NSIntersectionRange(span.range, range).length > 0 {
                if start == nil { start = idx }
                endExclusive = idx + 1
            } else if let s = start, idx > s {
                // Spans are ordered and should be contiguous; once we leave, we can stop.
                if span.range.location >= NSMaxRange(range) { break }
            }
        }
        let s = start ?? 0
        let e = endExclusive ?? min(spans.count, s + 1)
        return s..<e
    }

    private static func semanticFallbackSpans(
        in range: NSRange,
        nsText: NSString,
        spans: [TextSpan],
        annotatedSpans: [AnnotatedSpan]
    ) -> [SemanticSpan] {
        guard range.length > 0 else { return [] }
        var out: [SemanticSpan] = []
        out.reserveCapacity(4)

        for (idx, span) in spans.enumerated() {
            let intersection = NSIntersectionRange(span.range, range)
            guard intersection.length > 0 else { continue }
            guard NSMaxRange(intersection) <= nsText.length else { continue }
            let surface = nsText.substring(with: intersection)
            guard isHardBoundaryOnly(surface) == false else { continue }

            let reading = (idx < annotatedSpans.count) ? annotatedSpans[idx].readingKana : nil
            out.append(SemanticSpan(range: intersection, surface: surface, sourceSpanIndices: idx..<(idx + 1), readingKana: reading))
        }

        // If Stage-1 spans didn't cover this region cleanly (should be rare), fall back to a single span.
        if out.isEmpty {
            let surface = nsText.substring(with: range)
            if isHardBoundaryOnly(surface) == false {
                out.append(SemanticSpan(range: range, surface: surface, sourceSpanIndices: 0..<0, readingKana: nil))
            }
        }

        return out
    }

    private static func isWhitespaceOrPunctuationOnly(_ surface: String) -> Bool {
        isHardBoundaryOnly(surface)
    }

    private static func tokenizer() -> Tokenizer? {
        if let t = sharedTokenizer { return t }
        sharedTokenizer = try? Tokenizer(dictionary: IPADic())
        return sharedTokenizer
    }

    private typealias RetokenizedResult = (reading: String, lemmas: [String])

    private func attachmentForSpan(_ span: TextSpan, annotations: [MeCabAnnotation], tokenizer: Tokenizer) -> SpanAttachmentResult {
        guard span.range.length > 0 else { return SpanAttachmentResult(reading: nil, lemmas: [], partOfSpeech: nil) }

        var lemmaCandidates: [String] = []
        var posCandidates: [String] = []
        let requiresReading = containsKanji(span.surface)
        var builder = requiresReading ? "" : nil
        let spanEnd = span.range.location + span.range.length
        var coveringToken: MeCabAnnotation?
        var retokenizedCache: RetokenizedResult?

        for annotation in annotations {
            if annotation.range.location >= spanEnd { break }
            let intersection = NSIntersectionRange(span.range, annotation.range)
            guard intersection.length > 0 else { continue }
            Self.appendLemmaCandidate(annotation.dictionaryForm, to: &lemmaCandidates)
            Self.appendPartOfSpeechCandidate(annotation.partOfSpeech, to: &posCandidates)

            guard requiresReading else { continue }
            if intersection.length == annotation.range.length {
                let chunk = annotation.reading.isEmpty ? annotation.surface : annotation.reading
                builder?.append(chunk)
                // Self.debug("[SpanReadingAttacher] Matched token surface=\(annotation.surface) reading=\(chunk) for span=\(span.surface).")
            } else if coveringToken == nil,
                      NSLocationInRange(span.range.location, annotation.range),
                      NSMaxRange(span.range) <= NSMaxRange(annotation.range) {
                coveringToken = annotation
            }
        }

        var readingResult: String?

        if requiresReading {
            if let built = builder, built.isEmpty == false {
                // Keep the full reading (including okurigana) and let the ruby projector
                // split/trim against the surface text. Pre-trimming here can cause the
                // projector to mis-detect kana boundaries (e.g. "私たち" -> "わ").
                let normalized = Self.toHiragana(built)
                readingResult = normalized.isEmpty ? nil : normalized
            } else if let token = coveringToken {
                let tokenReadingSource: String
                if token.reading.isEmpty == false {
                    tokenReadingSource = token.reading
                } else if let retokenized = readingByRetokenizingSurface(token.surface, tokenizer: tokenizer)?.reading, retokenized.isEmpty == false {
                    tokenReadingSource = retokenized
                } else {
                    tokenReadingSource = token.surface
                }

                let tokenReadingKatakana = Self.toKatakana(tokenReadingSource)
                if containsKanji(tokenReadingKatakana) == false,
                   let stripped = Self.kanjiReadingFromToken(tokenSurface: token.surface, tokenReadingKatakana: tokenReadingKatakana) {
                    let normalizedFallback = Self.toHiragana(stripped)
                    readingResult = normalizedFallback.isEmpty ? nil : normalizedFallback
                }

                if readingResult == nil,
                   let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
                    let normalized = Self.toHiragana(retokenized.reading)
                    readingResult = normalized.isEmpty ? nil : normalized
                }
            } else if let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
                let normalized = Self.toHiragana(retokenized.reading)
                readingResult = normalized.isEmpty ? nil : normalized
            }
        }

        if lemmaCandidates.isEmpty,
           let retokenized = retokenizedResult(for: span, tokenizer: tokenizer, cache: &retokenizedCache) {
            lemmaCandidates = retokenized.lemmas
        }

        let posSummary: String? = posCandidates.isEmpty ? nil : posCandidates.joined(separator: " / ")
        return SpanAttachmentResult(reading: readingResult, lemmas: lemmaCandidates, partOfSpeech: posSummary)
    }

    private func retokenizedResult(for span: TextSpan, tokenizer: Tokenizer, cache: inout RetokenizedResult?) -> RetokenizedResult? {
        if cache == nil {
            cache = readingByRetokenizingSurface(span.surface, tokenizer: tokenizer)
        }
        return cache
    }

    private func readingByRetokenizingSurface(_ surface: String, tokenizer: Tokenizer) -> RetokenizedResult? {
        guard surface.isEmpty == false else { return nil }
        let tokens = tokenizer.tokenize(text: surface)
        guard tokens.isEmpty == false else { return nil }
        var builder = ""
        var lemmas: [String] = []
        for token in tokens {
            let chunk: String
            if token.reading.isEmpty {
                chunk = String(surface[token.range])
            } else {
                chunk = token.reading
            }
            builder.append(chunk)
            Self.appendLemmaCandidate(token.dictionaryForm, to: &lemmas)
        }
        return builder.isEmpty ? nil : (builder, lemmas)
    }

    static func kanjiReadingFromToken(tokenSurface: String, tokenReadingKatakana: String) -> String? {
        guard tokenReadingKatakana.isEmpty == false else { return nil }
        let okuriganaSuffix = kanaSuffix(in: tokenSurface)

        guard okuriganaSuffix.isEmpty == false else {
            return tokenReadingKatakana
        }

        let okuriganaKatakana = toKatakana(okuriganaSuffix)
        guard okuriganaKatakana.isEmpty == false else { return nil }
        guard tokenReadingKatakana.hasSuffix(okuriganaKatakana) else { return nil }

        let kanaCount = okuriganaKatakana.count
        guard kanaCount <= tokenReadingKatakana.count else { return nil }
        let endIndex = tokenReadingKatakana.index(tokenReadingKatakana.endIndex, offsetBy: -kanaCount)
        let kanjiReadingKatakana = String(tokenReadingKatakana[..<endIndex])
        return kanjiReadingKatakana.isEmpty ? nil : kanjiReadingKatakana
    }

    private static func kanaSuffix(in surface: String) -> String {
        guard surface.isEmpty == false else { return "" }
        var scalars: [UnicodeScalar] = []
        for scalar in surface.unicodeScalars.reversed() {
            if isKana(scalar) {
                scalars.append(scalar)
            } else {
                break
            }
        }
        guard scalars.isEmpty == false else { return "" }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    private static func trailingKanaRun(in surface: String) -> String? {
        guard surface.isEmpty == false else { return nil }
        var scalars: [UnicodeScalar] = []
        for scalar in surface.unicodeScalars.reversed() {
            if isKana(scalar) {
                scalars.append(scalar)
            } else {
                break
            }
        }
        guard scalars.isEmpty == false else { return nil }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    private func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func toHiragana(_ reading: String) -> String {
        let mutable = NSMutableString(string: reading) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }

    private static func toKatakana(_ reading: String) -> String {
        let mutable = NSMutableString(string: reading) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, false)
        return mutable as String
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
    }

    private static func appendLemmaCandidate(_ candidate: String?, to list: inout [String]) {
        guard let lemma = normalizeLemma(candidate) else { return }
        if list.contains(lemma) == false {
            list.append(lemma)
        }
    }

    private static func appendPartOfSpeechCandidate(_ candidate: String, to list: inout [String]) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard trimmed != "unknown" else { return }
        if list.contains(trimmed) == false {
            list.append(trimmed)
        }
    }

    private static func normalizeLemma(_ candidate: String?) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), candidate.isEmpty == false else { return nil }
        guard candidate != "*" else { return nil }
        return toHiragana(candidate)
    }

    private static func hash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    private static func signature(for spans: [TextSpan]) -> Int {
        var hasher = Hasher()
        hasher.combine(spans.count)
        for span in spans {
            hasher.combine(span.range.location)
            hasher.combine(span.range.length)
        }
        return hasher.finalize()
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}

extension SemanticSpan {
    static func describe(spans: [SemanticSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }
}

private struct MeCabAnnotation {
    let range: NSRange
    let reading: String
    let surface: String
    let dictionaryForm: String
    let partOfSpeech: String
}

private struct SpanAttachmentResult {
    let reading: String?
    let lemmas: [String]
    let partOfSpeech: String?
}

private struct ReadingAttachmentCacheKey: Sendable, nonisolated Hashable {
    let textHash: Int
    let spanSignature: Int
    let treatSpanBoundariesAsAuthoritative: Bool

    nonisolated static func == (lhs: ReadingAttachmentCacheKey, rhs: ReadingAttachmentCacheKey) -> Bool {
        lhs.textHash == rhs.textHash && lhs.spanSignature == rhs.spanSignature && lhs.treatSpanBoundariesAsAuthoritative == rhs.treatSpanBoundariesAsAuthoritative
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(textHash)
        hasher.combine(spanSignature)
        hasher.combine(treatSpanBoundariesAsAuthoritative)
    }
}

private actor ReadingAttachmentCache {
    private var storage: [ReadingAttachmentCacheKey: SpanReadingAttacher.Result] = [:]
    private var order: [ReadingAttachmentCacheKey] = []
    private let maxEntries: Int

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func value(for key: ReadingAttachmentCacheKey) -> SpanReadingAttacher.Result? {
        storage[key]
    }

    func store(_ value: SpanReadingAttacher.Result, for key: ReadingAttachmentCacheKey) {
        storage[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > maxEntries, let evicted = order.first {
            storage.removeValue(forKey: evicted)
            order.removeFirst()
        }
    }
}

