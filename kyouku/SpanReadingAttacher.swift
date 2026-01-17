import Foundation
import CoreFoundation
import QuartzCore
import Mecab_Swift
import IPADic
import OSLog

internal import StringTools

// INVESTIGATION: timing/logging helpers (2026-01-05)
// NOTE: Investigation-only instrumentation. Do not change control flow beyond adding logs.
@preconcurrency @inline(__always)
func ivlog(_ msg: String) {
    print("[INVESTIGATION] \(msg) main=\(Thread.isMainThread)")
}

@preconcurrency @inline(__always)
func ivtime<T>(_ label: String, _ f: () throws -> T) rethrows -> T {
    let t0 = CACurrentMediaTime()
    defer {
        let ms = (CACurrentMediaTime() - t0) * 1000
        ivlog("\(label) dt=\(String(format: "%.2f", ms))ms")
    }
    return try f()
}

@preconcurrency @inline(__always)
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
        let result = await attachReadings(text: text, spans: spans, treatSpanBoundariesAsAuthoritative: false, hardCuts: [])
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
        treatSpanBoundariesAsAuthoritative: Bool,
        hardCuts: [Int] = []
    ) async -> Result {
        ivlog("Stage2.attachReadings enter len=\(text.count) spans=\(spans.count) authoritative=\(treatSpanBoundariesAsAuthoritative) hardCuts=\(hardCuts.count)")
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
            treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative,
            hardCutsSignature: Self.signature(forCuts: hardCuts)
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
                        treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative,
                        hardCuts: hardCuts
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
        treatSpanBoundariesAsAuthoritative: Bool,
        hardCuts: [Int]
    ) async -> [SemanticSpan] {
        // INVESTIGATION/ROLLBACK (2026-01-05)
        // Merge-only, multi-pass boundary repair.
        // Hard rules:
        //  1) May merge spans, but must never split an existing Stage-1 span.
        //  2) Span count must be monotonically non-increasing across passes.
        //  3) No head/dependent logic, no syntactic parsing, no POS ownership.
        // Merge criteria (only):
        //  • A MeCab token whose surface range exactly covers multiple adjacent Stage-1 spans → merge them.
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

        // RANGE-SCOPED AUTHORITY (2026-01-05)
        // When the caller provides `baseSpans` (manual token edits), we must still run Stage-2.5,
        // but we must not merge across *explicit user-inserted* boundaries.
        // Important nuance:
        // - The app stores a full span snapshot when the user edits anything, which includes many
        //   boundaries that the user did not explicitly create.
        // - If we treat all base-span edges as authoritative, we prevent useful regrouping and
        //   cause regressions like “splitting 出逢ってか into 出逢って + か yields 出逢,って,か”.
        // Therefore we diff amended spans vs fresh Stage-1 segmentation and treat ONLY inserted
        // boundaries (splits) as non-crossable cuts. Stage-2.5 is merge-only, so deleted boundaries
        // (merges) cannot be reintroduced here.
        let authoritativeCuts: Set<Int> = await {
            guard treatSpanBoundariesAsAuthoritative else { return [] }

            func endBoundaries(of spans: [TextSpan]) -> Set<Int> {
                var out: Set<Int> = []
                out.reserveCapacity(min(256, spans.count))
                for s in spans {
                    let end = NSMaxRange(s.range)
                    if end > 0, end < nsText.length {
                        out.insert(end)
                    }
                }
                return out
            }

            let amendedEnds = endBoundaries(of: spans)

            // We diff against a fresh Stage-1 segmentation to detect *which* boundaries are custom.
            // If segmentation fails, fall back conservatively to treating all amended boundaries as cuts.
            do {
                let stage1 = try await SegmentationService.shared.segment(text: text)
                let stage1Ends = endBoundaries(of: stage1)

                let insertedBoundaries = amendedEnds.subtracting(stage1Ends)

                // Inserted boundaries (user splits) are always non-crossable cuts.
                // NOTE: We do NOT treat all katakana-internal boundaries as authoritative here.
                // Explicit user splits are persisted separately as `hardCuts` and enforced below.
                return insertedBoundaries
            } catch {
                CustomLogger.shared.debug("[STAGE-2.5] authoritativeCuts: fallback (segmentation failed)")
                return amendedEnds
            }
        }()

        let explicitCuts: Set<Int> = {
            guard hardCuts.isEmpty == false else { return [] }
            var out: Set<Int> = []
            out.reserveCapacity(min(64, hardCuts.count))
            for c in hardCuts {
                if c > 0, c < nsText.length { out.insert(c) }
            }
            return out
        }()

        let allAuthoritativeCuts = authoritativeCuts.union(explicitCuts)

        // Lexicon membership (JMdict trie). Optional secondary check.
        // IMPORTANT: must not trigger trie building or SQLite; only use cached trie.
        let trie: LexiconTrie? = await LexiconProvider.shared.cachedTrieIfAvailable()

        // INVESTIGATION instrumentation
        struct MergeOnlyCounters {
            var passCount: Int = 0
            var spansStart: Int = 0
            var spansEnd: Int = 0

            var mecabBlanketMerges: Int = 0

            var kanjiKanaCandidates: Int = 0
            var kanjiKanaAccepted: Int = 0
            var kanjiKanaRejected_hardBoundary: Int = 0
            var kanjiKanaRejected_notContiguous: Int = 0
            var kanjiKanaRejected_rightNotAllHiragana: Int = 0
            var kanjiKanaRejected_leftEndNotKanji: Int = 0
            var kanjiKanaRejected_noMecabCrossingToken: Int = 0
            var kanjiKanaRejected_notInLexiconSurfaceSet: Int = 0

            var kanjiKanaChainCandidates: Int = 0
            var kanjiKanaChainAccepted: Int = 0
            var kanjiKanaChainRejected_hardBoundary: Int = 0
            var kanjiKanaChainRejected_notContiguous: Int = 0
            var kanjiKanaChainRejected_leftNoKanji: Int = 0
            var kanjiKanaChainRejected_BorCNotAllHiragana: Int = 0
            var kanjiKanaChainRejected_noMecabSingleTokenCover: Int = 0
            var kanjiKanaChainRejected_notInLexiconSurfaceSet: Int = 0
        }

        var counters = MergeOnlyCounters()
        var rejectionSamplesRemaining = 20
        var chainRejectionSamplesRemaining = 20
        var didLogLexiconUnavailable = false
        var didLogLexiconUnavailableChain = false

        @inline(__always)
        func fmtRange(_ r: NSRange) -> String {
            "\(r.location)-\(r.length)"
        }

        @inline(__always)
        func logKanjiKanaReject(reason: String, A: String, ARange: NSRange, B: String, BRange: NSRange, combined: String) {
            guard rejectionSamplesRemaining > 0 else { return }
            rejectionSamplesRemaining -= 1
            CustomLogger.shared.debug("[STAGE-2.5] kanjiKana reject reason=\(reason) A=«\(A)».(\(fmtRange(ARange))) B=«\(B)».(\(fmtRange(BRange))) combined=«\(combined)»")
        }

        @inline(__always)
        func logKanjiKanaChainReject(reason: String, A: String, B: String, C: String, combined: String) {
            guard chainRejectionSamplesRemaining > 0 else { return }
            chainRejectionSamplesRemaining -= 1
            CustomLogger.shared.debug("[STAGE-2.5] kanjiKanaChain reject reason=\(reason) A=«\(A)» B=«\(B)» C=«\(C)» combined=«\(combined)»")
        }

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

        func isKatakanaLikeScalar(_ scalar: UnicodeScalar) -> Bool {
            // Fullwidth katakana block (includes '・' U+30FB and 'ー' U+30FC).
            if (0x30A0...0x30FF).contains(scalar.value) { return true }
            // Halfwidth katakana block.
            // Include dakuten/handakuten marks (FF9E/FF9F) so sequences like "ｶﾞ" are treated as katakana-like.
            if (0xFF66...0xFF9F).contains(scalar.value) { return true }
            // Halfwidth prolonged sound mark.
            if scalar.value == 0xFF70 { return true }
            return false
        }

        func isKatakanaLikeString(_ s: String) -> Bool {
            guard s.isEmpty == false else { return false }
            return s.unicodeScalars.allSatisfy(isKatakanaLikeScalar)
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

        func endsWithKanji(_ segment: Segment) -> Bool {
            let end = NSMaxRange(segment.range)
            guard segment.range.location != NSNotFound, segment.range.length > 0 else { return false }
            guard end > segment.range.location else { return false }
            let lastCharRange = nsText.rangeOfComposedCharacterSequence(at: end - 1)
            guard lastCharRange.location != NSNotFound, lastCharRange.length > 0 else { return false }
            let lastChar = nsText.substring(with: lastCharRange)
            return containsKanji(lastChar)
        }

        func merge(_ segments: inout [Segment], from start: Int, to endExclusive: Int) -> Bool {
            guard start >= 0, endExclusive <= segments.count, endExclusive - start >= 2 else { return false }

            // Do not merge across authoritative boundaries.
            if allAuthoritativeCuts.isEmpty == false {
                var j = start
                while j < endExclusive - 1 {
                    let join = NSMaxRange(segments[j].range)
                    if allAuthoritativeCuts.contains(join) {
                        return false
                    }
                    j += 1
                }
            }

            // Never cross hard boundaries: only merge if spans are strictly contiguous in UTF-16.
            var cursor = segments[start].range.location
            let end = NSMaxRange(segments[endExclusive - 1].range)
            var k = start
            while k < endExclusive {
                if segments[k].range.location != cursor { return false }
                let s = surface(of: segments[k])
                // Absolute invariant: never merge segments that contain line breaks.
                // A token/span must never include a newline or cross paragraphs.
                if s.rangeOfCharacter(from: .newlines) != nil { return false }
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
                // Never allow token coverage merges to include line breaks.
                if s.rangeOfCharacter(from: .newlines) != nil { return nil }
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

            // Next-best: assemble reading from MeCab token coverage over this exact range.
            // This prevents duplicated readings when individual Stage-1 spans each inherit a larger token's reading.
            // (e.g. 出 + 逢 both getting "であ" separately.)
            let segStart = segment.range.location
            let segEnd = NSMaxRange(segment.range)
            if segStart != NSNotFound, segEnd > segStart {
                var cursor = segStart
                var out = ""
                while cursor < segEnd {
                    // Choose a token that starts at the cursor and stays within the segment.
                    var best: MeCabAnnotation?
                    for t in annotations {
                        if t.range.location != cursor { continue }
                        let tEnd = NSMaxRange(t.range)
                        if tEnd > segEnd { continue }
                        if let currentBest = best {
                            if t.range.length > currentBest.range.length {
                                best = t
                            }
                        } else {
                            best = t
                        }
                    }

                    guard let token = best else {
                        out = ""
                        break
                    }

                    let chunkSource = token.reading.isEmpty ? token.surface : token.reading
                    out.append(chunkSource)
                    cursor = NSMaxRange(token.range)
                }

                if out.isEmpty == false {
                    let normalized = Self.toHiragana(out).trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized.isEmpty == false {
                        return normalized
                    }
                }
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

        // Newlines are absolute hard boundaries for semantic grouping.
        // If a Stage-1 span (or user-edited span) accidentally contains a line break,
        // split it here so Stage-2.5 cannot ever produce a semantic span with `\n`/`\r`.
        var segments: [Segment] = []
        segments.reserveCapacity(spans.count)
        for (idx, span) in spans.enumerated() {
            let r = span.range
            guard r.location != NSNotFound, r.length > 0 else { continue }
            guard r.location < nsText.length else { continue }
            let end = min(nsText.length, NSMaxRange(r))
            guard end > r.location else { continue }

            var cursor = r.location
            while cursor < end {
                let search = NSRange(location: cursor, length: end - cursor)
                let newlineRange = nsText.rangeOfCharacter(from: .newlines, options: [], range: search)
                if newlineRange.location == NSNotFound {
                    let piece = NSRange(location: cursor, length: end - cursor)
                    if piece.length > 0 {
                        segments.append(Segment(range: piece, sourceSpanIndices: idx..<(idx + 1)))
                    }
                    break
                }

                if newlineRange.location > cursor {
                    let piece = NSRange(location: cursor, length: newlineRange.location - cursor)
                    if piece.length > 0 {
                        segments.append(Segment(range: piece, sourceSpanIndices: idx..<(idx + 1)))
                    }
                }

                // Skip over the newline character(s).
                cursor = max(cursor, NSMaxRange(newlineRange))
            }
        }

        counters.spansStart = segments.count

        let maxPasses = 64
        var pass = 0
        while pass < maxPasses {
            pass += 1
            counters.passCount = pass
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
                            // IMPORTANT: preserve Stage-1 katakana decomposition.
                            // MeCab often emits a single token for a long katakana run; if we blindly merge,
                            // we undo Stage-1's lexicon-driven DP splitting (e.g. ロンリー|ロンリー|ハート).
                            // However, if Stage-1 produced only singleton katakana spans (no lex hits),
                            // allow MeCab to merge so we don't leave per-character katakana tokens.
                            let candidateSlice = segments[i..<endExclusive]
                            let allKatakanaLike = candidateSlice.allSatisfy { isKatakanaLikeString(surface(of: $0)) }
                            let hasAnyNonSingleton = candidateSlice.contains { $0.range.length > 1 }
                            if allKatakanaLike && hasAnyNonSingleton {
                                continue
                            }
                            if merge(&segments, from: i, to: endExclusive) {
                                didMerge = true
                                counters.mecabBlanketMerges += 1
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
                // Merge A + B iff:
                //  1) A ends with Kanji (join boundary is Kanji → Hiragana)
                //  2) B is entirely Hiragana
                //  3) Either:
                //     a) MeCab has a token that starts at A and crosses the join (e.g. "閉じ" crosses "閉|じ")
                //     b) (secondary) (A+B) exists in cached lexicon trie
                if i + 1 < segments.count {
                    let leftSeg = segments[i]
                    let rightSeg = segments[i + 1]
                    let left = surface(of: leftSeg)
                    let right = surface(of: rightSeg)
                    let combinedSurface = left + right

                    let contiguous = NSMaxRange(leftSeg.range) == rightSeg.range.location
                    if contiguous == false {
                        counters.kanjiKanaRejected_notContiguous += 1
                        logKanjiKanaReject(reason: "notContiguous", A: left, ARange: leftSeg.range, B: right, BRange: rightSeg.range, combined: combinedSurface)
                    } else if isHardBoundarySurface(left) || isHardBoundarySurface(right) {
                        counters.kanjiKanaRejected_hardBoundary += 1
                        logKanjiKanaReject(reason: "hardBoundary", A: left, ARange: leftSeg.range, B: right, BRange: rightSeg.range, combined: combinedSurface)
                    } else if endsWithKanji(leftSeg) == false {
                        counters.kanjiKanaRejected_leftEndNotKanji += 1
                        logKanjiKanaReject(reason: "leftEndNotKanji", A: left, ARange: leftSeg.range, B: right, BRange: rightSeg.range, combined: combinedSurface)
                    } else if isHiraganaOnly(right) == false {
                        counters.kanjiKanaRejected_rightNotAllHiragana += 1
                        logKanjiKanaReject(reason: "rightNotAllHiragana", A: left, ARange: leftSeg.range, B: right, BRange: rightSeg.range, combined: combinedSurface)
                    } else {
                        counters.kanjiKanaCandidates += 1
                        let combinedRange = NSRange(location: leftSeg.range.location, length: leftSeg.range.length + rightSeg.range.length)

                        // Prefer MeCab grouping signal over lexicon membership.
                        let join = NSMaxRange(leftSeg.range)
                        let combinedEnd = NSMaxRange(combinedRange)

                        // If MeCab emits a token that starts at A and extends past the join (but not beyond combined),
                        // it means MeCab is grouping across the boundary we want to repair.
                        var mecabCrossesJoin = false
                        if let startingTokens = tokensByStart[combinedRange.location] {
                            for token in startingTokens {
                                let tokenEnd = NSMaxRange(token.range)
                                if tokenEnd > join && tokenEnd <= combinedEnd {
                                    mecabCrossesJoin = true
                                    break
                                }
                            }
                        }

                        var lexiconOk = false
                        if mecabCrossesJoin == false {
                            if let trie {
                                lexiconOk = trie.containsWord(in: nsText, from: combinedRange.location, through: NSMaxRange(combinedRange), requireKanji: true)
                            } else if didLogLexiconUnavailable == false {
                                didLogLexiconUnavailable = true
                                CustomLogger.shared.debug("[STAGE-2.5] kanjiKana: lexicon unavailable (cached trie missing); lexicon check disabled")
                            }
                        }

                        if mecabCrossesJoin || lexiconOk {
                            if merge(&segments, from: i, to: i + 2) {
                                didMerge = true
                                counters.kanjiKanaAccepted += 1
                                continue
                            }
                        } else {
                            counters.kanjiKanaRejected_noMecabCrossingToken += 1
                            if lexiconOk == false {
                                counters.kanjiKanaRejected_notInLexiconSurfaceSet += 1
                            }
                            logKanjiKanaReject(reason: "noMecabCrossingToken+lexicon", A: left, ARange: leftSeg.range, B: right, BRange: rightSeg.range, combined: combinedSurface)
                        }
                    }
                }

                // Rule 2.5: Kanji+kanji compound merge (adjacent only).
                // Motivation: allow compounds like 出 + 逢 to merge when MeCab or the lexicon says they're a unit.
                // Merge A + B iff:
                //  1) A contains at least one Kanji
                //  2) B contains at least one Kanji
                //  3) A and B are contiguous and neither is a hard boundary
                //  4) Either:
                //     a) MeCab has a token starting at A that extends at least through the end of (A ∪ B)
                //     b) (secondary) (A+B) exists in cached lexicon trie
                if i + 1 < segments.count {
                    let leftSeg = segments[i]
                    let rightSeg = segments[i + 1]
                    let left = surface(of: leftSeg)
                    let right = surface(of: rightSeg)

                    let contiguous = NSMaxRange(leftSeg.range) == rightSeg.range.location
                    if contiguous,
                       isHardBoundarySurface(left) == false,
                       isHardBoundarySurface(right) == false,
                       containsKanji(left),
                       containsKanji(right) {
                        let combinedRange = NSRange(location: leftSeg.range.location, length: leftSeg.range.length + rightSeg.range.length)
                        let combinedEnd = NSMaxRange(combinedRange)

                        var mecabExtendsThroughCombined = false
                        if let startingTokens = tokensByStart[combinedRange.location] {
                            for token in startingTokens {
                                if NSMaxRange(token.range) >= combinedEnd {
                                    mecabExtendsThroughCombined = true
                                    break
                                }
                            }
                        }

                        var lexiconOk = false
                        if mecabExtendsThroughCombined == false {
                            if let trie {
                                lexiconOk = trie.containsWord(in: nsText, from: combinedRange.location, through: combinedEnd, requireKanji: true)
                            }
                        }

                        if mecabExtendsThroughCombined || lexiconOk {
                            if merge(&segments, from: i, to: i + 2) {
                                didMerge = true
                                continue
                            }
                        }
                    }
                }

                // Rule 3: Kanji-head + kana-kana chain merge (adjacent only).
                // Merge A + B + C iff ALL are true:
                //  1) A contains at least one Kanji scalar
                //  2) B is all Hiragana
                //  3) C is all Hiragana
                //  4) A, B, C are UTF-16 contiguous (no gaps)
                //  5) No hard boundary between any of A|B or B|C
                //  6) Either:
                //     a) MeCab has exactly ONE token whose range == (A ∪ B ∪ C)
                //     b) (secondary) (A+B+C) exists in cached lexicon trie
                if i + 2 < segments.count {
                    let aSeg = segments[i]
                    let bSeg = segments[i + 1]
                    let cSeg = segments[i + 2]

                    let a = surface(of: aSeg)
                    let b = surface(of: bSeg)
                    let c = surface(of: cSeg)
                    let combinedSurface = a + b + c

                    let abContig = NSMaxRange(aSeg.range) == bSeg.range.location
                    let bcContig = NSMaxRange(bSeg.range) == cSeg.range.location
                    if abContig == false || bcContig == false {
                        counters.kanjiKanaChainRejected_notContiguous += 1
                        logKanjiKanaChainReject(reason: "notContiguous", A: a, B: b, C: c, combined: combinedSurface)
                    } else if isHardBoundarySurface(a) || isHardBoundarySurface(b) || isHardBoundarySurface(c) {
                        counters.kanjiKanaChainRejected_hardBoundary += 1
                        logKanjiKanaChainReject(reason: "hardBoundary", A: a, B: b, C: c, combined: combinedSurface)
                    } else if containsKanji(a) == false {
                        counters.kanjiKanaChainRejected_leftNoKanji += 1
                        logKanjiKanaChainReject(reason: "leftNoKanji", A: a, B: b, C: c, combined: combinedSurface)
                    } else if isHiraganaOnly(b) == false || isHiraganaOnly(c) == false {
                        counters.kanjiKanaChainRejected_BorCNotAllHiragana += 1
                        logKanjiKanaChainReject(reason: "BorCNotAllHiragana", A: a, B: b, C: c, combined: combinedSurface)
                    } else {
                        counters.kanjiKanaChainCandidates += 1
                        let combinedRange = NSRange(location: aSeg.range.location, length: aSeg.range.length + bSeg.range.length + cSeg.range.length)

                        var mecabCoverOk = false
                        if let candidates = tokensByStart[combinedRange.location] {
                            let matches = candidates.filter { token in
                                token.range.location == combinedRange.location && token.range.length == combinedRange.length
                            }
                            mecabCoverOk = (matches.count == 1)
                        }

                        var lexiconOk = false
                        if mecabCoverOk == false {
                            if let trie {
                                lexiconOk = trie.containsWord(in: nsText, from: combinedRange.location, through: NSMaxRange(combinedRange), requireKanji: true)
                            } else {
                                counters.kanjiKanaChainRejected_notInLexiconSurfaceSet += 1
                                if didLogLexiconUnavailableChain == false {
                                    didLogLexiconUnavailableChain = true
                                    CustomLogger.shared.debug("[STAGE-2.5] kanjiKanaChain: lexicon unavailable (cached trie missing); lexicon check disabled")
                                }
                                logKanjiKanaChainReject(reason: "lexiconUnavailable", A: a, B: b, C: c, combined: combinedSurface)
                            }
                        }

                        if mecabCoverOk || lexiconOk {
                            if merge(&segments, from: i, to: i + 3) {
                                didMerge = true
                                counters.kanjiKanaChainAccepted += 1
                                continue
                            }
                        } else {
                            counters.kanjiKanaChainRejected_noMecabSingleTokenCover += 1
                            counters.kanjiKanaChainRejected_notInLexiconSurfaceSet += 1
                            logKanjiKanaChainReject(reason: "mecabCover+lexicon", A: a, B: b, C: c, combined: combinedSurface)
                        }
                    }
                }

                i += 1
            }

            let afterCount = segments.count
//#if DEBUG
            assert(afterCount <= beforeCount, "Stage2.5 invariant failed: span count increased \(beforeCount) -> \(afterCount)")
//#endif
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

        counters.spansEnd = segments.count
        ivlog("Stage2.5.mergeOnly end spansIn=\(spans.count) spansOut=\(semantic.count)")

        CustomLogger.shared.debug(
            "[STAGE-2.5] mergeOnly summary passes=\(counters.passCount) spans start=\(counters.spansStart) end=\(counters.spansEnd) " +
            "mecabBlanket=\(counters.mecabBlanketMerges) " +
            "kanjiKana cand=\(counters.kanjiKanaCandidates) ok=\(counters.kanjiKanaAccepted) " +
            "rej(HB=\(counters.kanjiKanaRejected_hardBoundary) contig=\(counters.kanjiKanaRejected_notContiguous) " +
            "leftEndKanji=\(counters.kanjiKanaRejected_leftEndNotKanji) rightHira=\(counters.kanjiKanaRejected_rightNotAllHiragana) " +
            "mecabCross=\(counters.kanjiKanaRejected_noMecabCrossingToken) lex=\(counters.kanjiKanaRejected_notInLexiconSurfaceSet)) " +
            "kanjiKanaChain cand=\(counters.kanjiKanaChainCandidates) ok=\(counters.kanjiKanaChainAccepted) " +
            "rej(HB=\(counters.kanjiKanaChainRejected_hardBoundary) contig=\(counters.kanjiKanaChainRejected_notContiguous) " +
            "leftKanji=\(counters.kanjiKanaChainRejected_leftNoKanji) hira=\(counters.kanjiKanaChainRejected_BorCNotAllHiragana) " +
            "mecab=\(counters.kanjiKanaChainRejected_noMecabSingleTokenCover) lex=\(counters.kanjiKanaChainRejected_notInLexiconSurfaceSet))"
        )
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

    private static func signature(forCuts cuts: [Int]) -> Int {
        guard cuts.isEmpty == false else { return 0 }
        var hasher = Hasher()
        hasher.combine(cuts.count)
        // Order-independent.
        for c in cuts.sorted() {
            hasher.combine(c)
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
    let hardCutsSignature: Int

    nonisolated static func == (lhs: ReadingAttachmentCacheKey, rhs: ReadingAttachmentCacheKey) -> Bool {
        lhs.textHash == rhs.textHash &&
        lhs.spanSignature == rhs.spanSignature &&
        lhs.treatSpanBoundariesAsAuthoritative == rhs.treatSpanBoundariesAsAuthoritative &&
        lhs.hardCutsSignature == rhs.hardCutsSignature
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(textHash)
        hasher.combine(spanSignature)
        hasher.combine(treatSpanBoundariesAsAuthoritative)
        hasher.combine(hardCutsSignature)
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

