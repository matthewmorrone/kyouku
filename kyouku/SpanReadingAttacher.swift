import Foundation
import CoreFoundation
import Mecab_Swift
import IPADic
import OSLog

internal import StringTools

/// Stage 2 of the furigana pipeline. Consumes `TextSpan` boundaries, runs
/// MeCab/IPADic exactly once per input text, and attaches kana readings. No
/// SQLite lookups occur here, mirroring the behavior of commit 0e7736a.
///
/// STAGE 2 CONTRACT:
/// Stage 2 always produces `SemanticSpan` as the semantic regrouping layer.
/// Downstream consumers may ignore semantic spans, but Stage 2 must always emit them.
struct SpanReadingAttacher {
    static var sharedTokenizer: Tokenizer? = {
        try? Tokenizer(dictionary: IPADic())
    }()

    private static let cache = ReadingAttachmentCache(maxEntries: 32)
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SpanReadingAttacher")
    private static let stage2DebugLoggingEnabled: Bool = {
        ProcessInfo.processInfo.environment["STAGE2_TRACE"] == "1"
    }()

    struct Result {
        let annotatedSpans: [AnnotatedSpan]
        let semanticSpans: [SemanticSpan]
    }

    /// Materialize the MeCab token stream for the full input text.
    ///
    /// This is a pure in-memory operation. Callers may reuse this output across
    /// multiple pipeline stages (e.g. Stage 1.5 + Stage 2) to avoid tokenizing
    /// the same text more than once.
    static func materializeAnnotations(text: String, tokenizer: Tokenizer) -> [MeCabAnnotation] {
        tokenizer.tokenize(text: text).compactMap { annotation -> MeCabAnnotation? in
            let nsRange = NSRange(annotation.range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
            let surface = String(text[annotation.range])
            let pos = String(describing: annotation.partOfSpeech)
            return MeCabAnnotation(range: nsRange, reading: annotation.reading, surface: surface, dictionaryForm: annotation.dictionaryForm, partOfSpeech: pos)
        }
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
        hardCuts: [Int] = [],
        precomputedAnnotations: [MeCabAnnotation]? = nil
    ) async -> Result {
        guard text.isEmpty == false, spans.isEmpty == false else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            let semantic = spans.enumerated().compactMap { idx, span -> SemanticSpan? in
                guard Self.isHardBoundaryOnly(span.surface) == false else { return nil }
                return SemanticSpan(range: span.range, surface: span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: nil)
            }
            return Result(annotatedSpans: passthrough, semanticSpans: semantic)
        }
        let overallInterval = Self.signposter.beginInterval("AttachReadings Overall", "len=\(text.count) spans=\(spans.count)")

        let key = ReadingAttachmentCacheKey(
            textHash: Self.hash(text),
            spanSignature: Self.signature(for: spans),
            treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative,
            hardCutsSignature: Self.signature(forCuts: hardCuts)
        )
        if let cached = await Self.cache.value(for: key) {
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            return cached
        }

        // TEMP DIAGNOSTICS (2026-02-02)
        // Opt-in logging only; must not affect behavior.
        let traceEnabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return env["PIPELINE_TRACE"] == "1" || env["STAGE2_TRACE"] == "1"
        }()
        func describeSpans(_ spans: [TextSpan]) -> String {
            spans
                .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
                .joined(separator: ", ")
        }
        func describeSemantic(_ spans: [SemanticSpan]) -> String {
            spans
                .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
                .joined(separator: ", ")
        }
        func log(_ message: String) {
            guard traceEnabled else { return }
            let full = "[S2.5] \(message)"
            CustomLogger.shared.info(full)
            NSLog("%@", full)
        }

        let tokStart = CFAbsoluteTimeGetCurrent()
        let tokInterval = Self.signposter.beginInterval("Tokenizer Acquire")
        let tokenizerOpt: Tokenizer? = Self.tokenizer()
        Self.signposter.endInterval("Tokenizer Acquire", tokInterval)
        let tokMs = (CFAbsoluteTimeGetCurrent() - tokStart) * 1000
        if tokenizerOpt == nil {
            CustomLogger.shared.error("Tokenizer acquisition failed after \(String(format: "%.3f", tokMs)) ms")
        }
        guard let tokenizer = tokenizerOpt else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            let semantic = passthrough.enumerated().compactMap { idx, span -> SemanticSpan? in
                guard Self.isHardBoundaryOnly(span.span.surface) == false else { return nil }
                return SemanticSpan(range: span.span.range, surface: span.span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: span.readingKana)
            }
            let result = Result(annotatedSpans: passthrough, semanticSpans: semantic)
            await Self.cache.store(result, for: key)
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            return result
        }

        let annotations: [MeCabAnnotation]
        if let provided = precomputedAnnotations {
            annotations = provided
        } else {
            let tokenizeInterval = Self.signposter.beginInterval("MeCab Tokenize", "len=\(text.count)")
            annotations = Self.materializeAnnotations(text: text, tokenizer: tokenizer)
            Self.signposter.endInterval("MeCab Tokenize", tokenizeInterval)
        }

        var annotated: [AnnotatedSpan] = []
        annotated.reserveCapacity(spans.count)

        let nsText = text as NSString

        for span in spans {
            let attachment = attachmentForSpan(span, annotations: annotations, tokenizer: tokenizer)
            let override = await ReadingOverridePolicy.shared.overrideReading(for: span.surface, mecabReading: attachment.reading)
            let candidate = override ?? attachment.reading
            let contextAdjusted = Self.applyContextualReadingRules(surface: span.surface, reading: candidate, nsText: nsText, range: span.range)
            let finalReading = sanitizeRubyReading(contextAdjusted)

            annotated.append(AnnotatedSpan(span: span, readingKana: finalReading, lemmaCandidates: attachment.lemmas, partOfSpeech: attachment.partOfSpeech))
        }

        if traceEnabled {
            let cuts = hardCuts.sorted().map(String.init).joined(separator: ",")
            log("before regrouping treatSpanBoundariesAsAuthoritative=\(treatSpanBoundariesAsAuthoritative) hardCuts=[\(cuts)]")
            log("input spans: \(describeSpans(spans))")
        }

        let semantic: [SemanticSpan] = await Task(priority: .userInitiated) { [self] in
            await self.semanticRegrouping(
                text: text,
                nsText: text as NSString,
                spans: spans,
                annotatedSpans: annotated,
                annotations: annotations,
                treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative,
                hardCuts: hardCuts
            )
        }.value

        if traceEnabled {
            log("after regrouping semanticSpans.count=\(semantic.count)")
            log("output semantic spans: \(describeSemantic(semantic))")
        }

        let result = Result(annotatedSpans: annotated, semanticSpans: semantic)
        await Self.cache.store(result, for: key)

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

        func passthroughSemanticSpans() -> [SemanticSpan] {
            return annotatedSpans.enumerated().compactMap { idx, span -> SemanticSpan? in
                guard Self.isHardBoundaryOnly(span.span.surface) == false else { return nil }
                return SemanticSpan(range: span.span.range, surface: span.span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: span.readingKana)
            }
        }

        if Task.isCancelled {
            return passthroughSemanticSpans()
        }


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
        var didLogLexiconUnavailable = false
        var didLogLexiconUnavailableChain = false

        @inline(__always)
        func fmtRange(_ r: NSRange) -> String {
            "\(r.location)-\(r.length)"
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

                    let contiguous = NSMaxRange(leftSeg.range) == rightSeg.range.location
                    if contiguous == false {
                        counters.kanjiKanaRejected_notContiguous += 1
                    } else if isHardBoundarySurface(left) || isHardBoundarySurface(right) {
                        counters.kanjiKanaRejected_hardBoundary += 1
                    } else if endsWithKanji(leftSeg) == false {
                        counters.kanjiKanaRejected_leftEndNotKanji += 1
                    } else if isHiraganaOnly(right) == false {
                        counters.kanjiKanaRejected_rightNotAllHiragana += 1
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
                                if Self.stage2DebugLoggingEnabled {
                                    CustomLogger.shared.debug("[STAGE-2.5] kanjiKana: lexicon unavailable (cached trie missing); lexicon check disabled")
                                }
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

                    let abContig = NSMaxRange(aSeg.range) == bSeg.range.location
                    let bcContig = NSMaxRange(bSeg.range) == cSeg.range.location
                    if abContig == false || bcContig == false {
                        counters.kanjiKanaChainRejected_notContiguous += 1
                    } else if isHardBoundarySurface(a) || isHardBoundarySurface(b) || isHardBoundarySurface(c) {
                        counters.kanjiKanaChainRejected_hardBoundary += 1
                    } else if containsKanji(a) == false {
                        counters.kanjiKanaChainRejected_leftNoKanji += 1
                    } else if isHiraganaOnly(b) == false || isHiraganaOnly(c) == false {
                        counters.kanjiKanaChainRejected_BorCNotAllHiragana += 1
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
                                    if Self.stage2DebugLoggingEnabled {
                                        CustomLogger.shared.debug("[STAGE-2.5] kanjiKanaChain: lexicon unavailable (cached trie missing); lexicon check disabled")
                                    }
                                }
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

        var semantic: [SemanticSpan] = []
        semantic.reserveCapacity(segments.count)
        for seg in segments {
            let surfaceText = surface(of: seg)
            let mecabReadingRaw = readingForSegment(seg)
            let mecabReading = mecabReadingRaw.map { Self.toHiragana($0) }
            let override = await ReadingOverridePolicy.shared.overrideReading(for: surfaceText, mecabReading: mecabReading)
            let candidate = override ?? mecabReading
            let contextAdjusted = Self.applyContextualReadingRules(surface: surfaceText, reading: candidate, nsText: nsText, range: seg.range)
            let finalReading = sanitizeRubyReading(contextAdjusted)

            semantic.append(
                SemanticSpan(
                    range: seg.range,
                    surface: surfaceText,
                    sourceSpanIndices: seg.sourceSpanIndices,
                    readingKana: finalReading
                )
            )
        }

        counters.spansEnd = segments.count

        if Self.stage2DebugLoggingEnabled {
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
        }
        return semantic
    }
}
