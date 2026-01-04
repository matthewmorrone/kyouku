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
    private static var sharedTokenizer: Tokenizer? = {
        try? Tokenizer(dictionary: IPADic())
    }()

    private static let cache = ReadingAttachmentCache(maxEntries: 32)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SpanReadingAttacher")
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "SpanReadingAttacher")

    private static func info(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.info("[\(file):\(line)] \(function): \(message)")
    }

    private static func debug(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.debug("[\(file):\(line)] \(function): \(message)")
    }

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
    func attachReadings(
        text: String,
        spans: [TextSpan],
        treatSpanBoundariesAsAuthoritative: Bool
    ) async -> Result {
        guard text.isEmpty == false, spans.isEmpty == false else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            let semantic = spans.enumerated().map { idx, span in
                SemanticSpan(range: span.range, surface: span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: nil)
            }
            print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
            print(SemanticSpan.describe(spans: semantic))
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
            Self.debug("[SpanReadingAttacher] Cache hit for \(spans.count) spans in \(duration) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
            print(SemanticSpan.describe(spans: cached.semanticSpans))
            return cached
        }

        let tokStart = CFAbsoluteTimeGetCurrent()
        let tokInterval = Self.signposter.beginInterval("Tokenizer Acquire")
        let tokenizerOpt = Self.tokenizer()
        Self.signposter.endInterval("Tokenizer Acquire", tokInterval)
        let tokMs = (CFAbsoluteTimeGetCurrent() - tokStart) * 1000
        if tokenizerOpt == nil {
            Self.logger.error("[SpanReadingAttacher] Tokenizer acquisition failed in \(String(format: "%.3f", tokMs)) ms")
        } else {
            Self.info("[SpanReadingAttacher] Tokenizer acquired in \(String(format: "%.3f", tokMs)) ms")
        }
        guard let tokenizer = tokenizerOpt else {
            let passthrough = spans.map { AnnotatedSpan(span: $0, readingKana: nil) }
            let semantic = passthrough.enumerated().map { idx, span in
                SemanticSpan(range: span.span.range, surface: span.span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: span.readingKana)
            }
            let result = Result(annotatedSpans: passthrough, semanticSpans: semantic)
            await Self.cache.store(result, for: key)
//            Self.info("[SpanReadingAttacher] Failed to acquire tokenizer. Returning passthrough spans in (duration) ms.")
            Self.signposter.endInterval("AttachReadings Overall", overallInterval)
            print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
            print(SemanticSpan.describe(spans: result.semanticSpans))
            return result
        }

        let tokenizeStart = CFAbsoluteTimeGetCurrent()
        let tokenizeInterval = Self.signposter.beginInterval("MeCab Tokenize", "len=\(text.count)")
        let annotations = tokenizer.tokenize(text: text).compactMap { annotation -> MeCabAnnotation? in
            let nsRange = NSRange(annotation.range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
            let surface = String(text[annotation.range])
            let pos = String(describing: annotation.partOfSpeech)
            return MeCabAnnotation(range: nsRange, reading: annotation.reading, surface: surface, dictionaryForm: annotation.dictionaryForm, partOfSpeech: pos)
        }
        Self.signposter.endInterval("MeCab Tokenize", tokenizeInterval)
        let tokenizeMs = (CFAbsoluteTimeGetCurrent() - tokenizeStart) * 1000
        Self.info("[SpanReadingAttacher] MeCab tokenization produced \(annotations.count) annotations in \(String(format: "%.3f", tokenizeMs)) ms")

        var annotated: [AnnotatedSpan] = []
        annotated.reserveCapacity(spans.count)

        for span in spans {
            let attachment = attachmentForSpan(span, annotations: annotations, tokenizer: tokenizer)
            let override = await ReadingOverridePolicy.shared.overrideReading(for: span.surface, mecabReading: attachment.reading)
            let finalReading = override ?? attachment.reading
            annotated.append(AnnotatedSpan(span: span, readingKana: finalReading, lemmaCandidates: attachment.lemmas, partOfSpeech: attachment.partOfSpeech))
        }

        let semantic: [SemanticSpan] = await Task.detached(priority: .userInitiated) { [self] in
            await self.semanticRegrouping(
                text: text,
                nsText: text as NSString,
                spans: spans,
                annotatedSpans: annotated,
                annotations: annotations,
                treatSpanBoundariesAsAuthoritative: treatSpanBoundariesAsAuthoritative
            )
        }.value

        print("[STAGE-2 SEGMENTS @ SEMANTIC REGROUPING]")
        print(SemanticSpan.describe(spans: semantic))
        print("Stage2: stage1Count=\(spans.count) stage2Count=\(semantic.count)")

        let result = Result(annotatedSpans: annotated, semanticSpans: semantic)
        await Self.cache.store(result, for: key)

        let duration = Self.elapsedMilliseconds(since: start)
        Self.info("[SpanReadingAttacher] Attached readings for \(spans.count) spans in \(String(format: "%.3f", duration)) ms.")
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
        let disableSemanticRegroupingPassthrough = false

        let maxIterations = 10_000
        let progressEvery = 200

        func passthroughSemanticSpans(reason: String?) -> [SemanticSpan] {
            if let reason {
                print("[STAGE-2] bailout: \(reason)")
            }
            return annotatedSpans.enumerated().map { idx, span in
                SemanticSpan(range: span.span.range, surface: span.span.surface, sourceSpanIndices: idx..<(idx + 1), readingKana: span.readingKana)
            }
        }

        @inline(__always)
        func step(
            _ counter: inout Int,
            loop: String,
            cursor: Int? = nil,
            tokenRange: NSRange? = nil,
            tokenSurface: String? = nil,
            boundaryRange: NSRange? = nil,
            producedRange: NSRange? = nil,
            producedSurface: String? = nil,
            outputCount: Int? = nil
        ) -> Bool {
            counter += 1
            if counter % progressEvery == 0 {
                let c = cursor.map(String.init) ?? "n/a"
                let out = outputCount.map(String.init) ?? "n/a"
                print("[STAGE-2] progress loop=\(loop) iter=\(counter) cursor=\(c) out=\(out)")
            }
            if counter >= maxIterations {
                let c = cursor.map(String.init) ?? "n/a"
                let tr: String = {
                    guard let tokenRange, tokenRange.location != NSNotFound else { return "n/a" }
                    return "\(tokenRange.location)-\(NSMaxRange(tokenRange))"
                }()
                let ts = tokenSurface ?? "n/a"
                let br: String = {
                    guard let boundaryRange, boundaryRange.location != NSNotFound else { return "n/a" }
                    return "\(boundaryRange.location)-\(NSMaxRange(boundaryRange))"
                }()
                let pr: String = {
                    guard let producedRange, producedRange.location != NSNotFound else { return "n/a" }
                    return "\(producedRange.location)-\(NSMaxRange(producedRange))"
                }()
                let ps = producedSurface ?? "n/a"
                let out = outputCount.map(String.init) ?? "n/a"
                print("[STAGE-2] iteration-cap hit loop=\(loop) iter=\(counter) cursor=\(c) tokenRange=\(tr) token=\(ts) boundary=\(br) produced=\(pr) producedSurface=\(ps) out=\(out)")
                return false
            }
            return true
        }

        print("[STAGE-2] start (main=\(Thread.isMainThread)) spans=\(spans.count)")
        if Thread.isMainThread {
            print("[STAGE-2] WARNING entered on main thread")
        }

        if disableSemanticRegroupingPassthrough {
            let semantic = passthroughSemanticSpans(reason: "disableSemanticRegroupingPassthrough")
            print("[STAGE-2] end (main=\(Thread.isMainThread)) spansIn=\(spans.count) spansOut=\(semantic.count)")
            return semantic
        }

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

            print("[STAGE-2] end (main=\(Thread.isMainThread)) spansIn=\(spans.count) spansOut=\(semantic.count)")
            return semantic
        }

        // Stage-2 semantic regrouping: deterministic, Stage-1-driven.
        // HEAD-FIRST CONTRACT:
        // - Single left-to-right pass.
        // - Spans start on HEAD tokens (or hard particle boundary tokens).
        // - Dependents only attach to an already-started head span on their left.
        // - Particles の/が/を/に/は are hard boundaries (standalone spans).
        // - Compound verb heads absorb preceding verb heads (e.g. 出 + 逢 + って => 出逢って).

        struct Segment {
            var range: NSRange
            var sourceSpanIndices: Range<Int>
        }

        func surface(of segment: Segment) -> String {
            guard segment.range.location != NSNotFound, segment.range.length > 0 else { return "" }
            guard NSMaxRange(segment.range) <= nsText.length else { return "" }
            return nsText.substring(with: segment.range)
        }

        func merge(_ segments: inout [Segment], from start: Int, to endExclusive: Int) -> Bool {
            guard start >= 0, endExclusive <= segments.count, endExclusive - start >= 2 else { return false }

            // Never cross hard boundaries: only merge if spans are strictly contiguous in UTF-16.
            var cursor = NSMaxRange(segments[start].range)
            for k in (start + 1)..<endExclusive {
                if segments[k].range.location != cursor {
                    return false
                }
                cursor = NSMaxRange(segments[k].range)
            }

            let union = NSUnionRange(segments[start].range, segments[endExclusive - 1].range)
            let lower = segments[start].sourceSpanIndices.lowerBound
            let upper = segments[(endExclusive - 1)].sourceSpanIndices.upperBound
            segments[start] = Segment(range: union, sourceSpanIndices: lower..<upper)
            segments.removeSubrange((start + 1)..<endExclusive)
            return true
        }

        func splitLastComposedCharacterOff(_ segment: Segment) -> (prefix: Segment, last: Segment)? {
            let r = segment.range
            guard r.location != NSNotFound, r.length >= 2 else { return nil }
            guard NSMaxRange(r) <= nsText.length else { return nil }
            let lastIndex = max(0, NSMaxRange(r) - 1)
            let lastCharRange = nsText.rangeOfComposedCharacterSequence(at: lastIndex)
            guard NSMaxRange(lastCharRange) == NSMaxRange(r) else { return nil }
            let prefixLen = lastCharRange.location - r.location
            guard prefixLen > 0 else { return nil }
            let prefixRange = NSRange(location: r.location, length: prefixLen)
            let lastRange = lastCharRange
            return (
                prefix: Segment(range: prefixRange, sourceSpanIndices: segment.sourceSpanIndices),
                last: Segment(range: lastRange, sourceSpanIndices: segment.sourceSpanIndices)
            )
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

        func isSingleKanji(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return false }
            let ns = trimmed as NSString
            guard ns.length == 1 else { return false }
            return containsKanji(trimmed)
        }

        func endsWithKana(_ s: String) -> Bool {
            guard s.isEmpty == false else { return false }
            guard let last = s.unicodeScalars.last else { return false }
            return CharacterSet.hiragana.contains(last) || CharacterSet.katakana.contains(last)
        }

        func endsWithSmallTsu(_ s: String) -> Bool {
            s.hasSuffix("っ") || s.hasSuffix("ッ")
        }

        func startsWithSmallTsu(_ s: String) -> Bool {
            s.hasPrefix("っ") || s.hasPrefix("ッ")
        }

        func isHardParticleBoundary(_ ann: MeCabAnnotation) -> Bool {
            // Hard boundary particles must always be their own semantic span.
            // Use MeCab POS as primary signal; surface as guard.
            if ann.surface == "の" || ann.surface == "が" || ann.surface == "を" || ann.surface == "に" || ann.surface == "は" {
                return true
            }
            return false
        }

        func isVerbHead(_ ann: MeCabAnnotation) -> Bool {
            // Treat "動詞" tokens as heads, but exclude auxiliary verbs.
            if ann.partOfSpeech.contains("助動詞") { return false }
            return ann.partOfSpeech.contains("動詞")
        }

        func isHeadEligible(_ ann: MeCabAnnotation) -> Bool {
            // Heads must start spans. Keep this intentionally conservative.
            if isHardParticleBoundary(ann) { return false }
            if ann.partOfSpeech.contains("記号") { return false }
            if ann.partOfSpeech.contains("助詞") { return false }
            if ann.partOfSpeech.contains("助動詞") { return false }
            if ann.partOfSpeech.contains("接尾") { return false }

            if ann.partOfSpeech.contains("名詞") { return true }
            if ann.partOfSpeech.contains("動詞") { return true }
            if ann.partOfSpeech.contains("形容詞") { return true }
            if ann.partOfSpeech.contains("形容動詞") { return true }

            // Adverbs are only head-eligible when the surface is > 1 char.
            if ann.partOfSpeech.contains("副詞") {
                return (ann.surface as NSString).length > 1
            }
            return false
        }

        func isDependentOnly(_ ann: MeCabAnnotation) -> Bool {
            // Never heads.
            if ann.partOfSpeech.contains("記号") { return true }
            if ann.partOfSpeech.contains("助詞") { return true }
            if ann.partOfSpeech.contains("助動詞") { return true }
            if ann.partOfSpeech.contains("接尾") { return true }
            // Defensive: if token surface is boundary-only, treat as dependent-only.
            if Self.isHardBoundaryOnly(ann.surface) { return true }
            return false
        }

        func appendFallbackSegments(in range: NSRange) {
            let fallback = Self.semanticFallbackSpans(in: range, nsText: nsText, spans: spans, annotatedSpans: annotatedSpans)
            for s in fallback {
                guard s.range.location != NSNotFound, s.range.length > 0 else { continue }
                segments.append(Segment(range: s.range, sourceSpanIndices: s.sourceSpanIndices))
            }
        }

        // Single-pass head-first scan over non-boundary runs.
        var segments: [Segment] = []
        segments.reserveCapacity(max(spans.count, annotations.count))

        let hardBoundaries = Self.hardBoundaryRanges(in: nsText)
        let runs = Self.nonBoundaryRuns(in: nsText, hardBoundaries: hardBoundaries)

        let sortedTokens: [MeCabAnnotation] = annotations
            .map { ann in
                let r = Self.clamp(ann.range, toLength: nsText.length)
                return MeCabAnnotation(range: r, reading: ann.reading, surface: ann.surface, dictionaryForm: ann.dictionaryForm, partOfSpeech: ann.partOfSpeech)
            }
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .sorted { $0.range.location < $1.range.location }

        var iter = 0
        for run in runs {
            guard run.location != NSNotFound, run.length > 0 else { continue }
            guard NSMaxRange(run) <= nsText.length else { continue }

            // Tokens fully contained in this run.
            let runStart = run.location
            let runEnd = NSMaxRange(run)
            let tokensInRun = sortedTokens.filter { t in
                t.range.location >= runStart && NSMaxRange(t.range) <= runEnd
            }

            // If MeCab didn't cover this run, fall back to Stage-1-derived spans for coverage.
            if tokensInRun.isEmpty {
                appendFallbackSegments(in: run)
                continue
            }

            var currentStart: Int? = nil
            var currentEnd: Int = 0
            var currentIsVerbChain = false

            func flushCurrentIfAny() {
                guard let start = currentStart else { return }
                let r = NSRange(location: start, length: max(0, currentEnd - start))
                if r.length == 0 {
                    print("[STAGE-2] zero-length span skipped loop=head-first range=\(r.location)-\(NSMaxRange(r))")
                } else {
                    let src = Self.sourceSpanIndexRange(intersecting: r, spans: spans)
                    segments.append(Segment(range: r, sourceSpanIndices: src))
                }
                currentStart = nil
                currentEnd = 0
                currentIsVerbChain = false
            }

            var cursor = runStart
            for token in tokensInRun {
                if step(&iter, loop: "head-first", cursor: cursor, tokenRange: token.range, tokenSurface: token.surface, boundaryRange: nil, producedRange: nil, producedSurface: nil, outputCount: segments.count) == false {
                    // Do not bail to Stage-1 here; just stop regrouping and fall back for the remaining uncovered run.
                    print("[STAGE-2] head-first iteration cap reached; covering remainder with fallback")
                    flushCurrentIfAny()
                    if cursor < runEnd {
                        appendFallbackSegments(in: NSRange(location: cursor, length: runEnd - cursor))
                    }
                    cursor = runEnd
                    break
                }

                let tr = token.range
                if tr.location < runStart || NSMaxRange(tr) > runEnd {
                    // Should not happen due to filtering, but be defensive.
                    continue
                }

                // Fill any uncovered gap (should be rare in a non-boundary run).
                if tr.location > cursor {
                    flushCurrentIfAny()
                    let gap = NSRange(location: cursor, length: tr.location - cursor)
                    appendFallbackSegments(in: gap)
                    cursor = tr.location
                }

                // Skip any token that is boundary-only (should not occur in a run).
                if Self.isHardBoundaryOnly(token.surface) {
                    cursor = max(cursor, NSMaxRange(tr))
                    continue
                }

                if isHardParticleBoundary(token) {
                    // Hard particles are standalone.
                    flushCurrentIfAny()
                    if tr.length == 0 {
                        print("[STAGE-2] zero-length hard particle skipped range=\(tr.location)-\(NSMaxRange(tr))")
                    } else {
                        let src = Self.sourceSpanIndexRange(intersecting: tr, spans: spans)
                        segments.append(Segment(range: tr, sourceSpanIndices: src))
                    }
                    cursor = max(cursor, NSMaxRange(tr))
                    continue
                }

                let headEligible = isHeadEligible(token)
                let dependentOnly = isDependentOnly(token)

                // 1) If there is no current head and the token is head-eligible, start a head immediately.
                if currentStart == nil, headEligible {
                    currentStart = tr.location
                    currentEnd = NSMaxRange(tr)
                    currentIsVerbChain = isVerbHead(token)
                    cursor = max(cursor, NSMaxRange(tr))
                    continue
                }

                if headEligible {
                    // Start a new head span (or extend compound verb chain).
                    if currentStart == nil {
                        currentStart = tr.location
                        currentEnd = NSMaxRange(tr)
                        currentIsVerbChain = isVerbHead(token)
                    } else if currentIsVerbChain && isVerbHead(token) && tr.location == currentEnd {
                        // Compound verb: absorb verb heads into existing verb chain.
                        currentEnd = NSMaxRange(tr)
                    } else {
                        flushCurrentIfAny()
                        currentStart = tr.location
                        currentEnd = NSMaxRange(tr)
                        currentIsVerbChain = isVerbHead(token)
                    }
                } else {
                    // 2) Only attempt dependent attachment after a head exists.
                    if let _ = currentStart, tr.location == currentEnd {
                        currentEnd = NSMaxRange(tr)
                    } else if headEligible == false {
                        // 3) Only emit standalone fallback when the token is not head-eligible.
                        // Avoid noisy logs for head-eligible tokens by construction.
                        if dependentOnly {
                            flushCurrentIfAny()
                            if tr.length == 0 {
                                print("[STAGE-2] zero-length dependent skipped range=\(tr.location)-\(NSMaxRange(tr)) token=\(token.surface) pos=\(token.partOfSpeech)")
                            } else {
                                let src = Self.sourceSpanIndexRange(intersecting: tr, spans: spans)
                                segments.append(Segment(range: tr, sourceSpanIndices: src))
                            }
                        } else {
                            // Non-head but also not classified dependent-only; preserve coverage without extra noise.
                            flushCurrentIfAny()
                            if tr.length > 0 {
                                let src = Self.sourceSpanIndexRange(intersecting: tr, spans: spans)
                                segments.append(Segment(range: tr, sourceSpanIndices: src))
                            }
                        }
                    }
                }

                cursor = max(cursor, NSMaxRange(tr))
            }

            flushCurrentIfAny()

            if cursor < runEnd {
                appendFallbackSegments(in: NSRange(location: cursor, length: runEnd - cursor))
            }
        }

        // Materialize SemanticSpan array with readings chosen via existing override policy.
        var semantic: [SemanticSpan] = []
        semantic.reserveCapacity(segments.count)
        for seg in segments {
            let s = surface(of: seg)
            guard s.isEmpty == false else { continue }

            let requiresReading = containsKanji(s)
            var mecabReading: String?
            if requiresReading {
                var builder = ""
                let end = NSMaxRange(seg.range)
                for ann in annotations {
                    if ann.range.location >= end { break }
                    let intersection = NSIntersectionRange(seg.range, ann.range)
                    guard intersection.length > 0 else { continue }
                    // Only accept fully-covered tokens; avoid inventing readings for partial overlaps.
                    guard intersection.length == ann.range.length else {
                        builder = ""
                        break
                    }
                    let chunk = ann.reading.isEmpty ? ann.surface : ann.reading
                    builder.append(chunk)
                }
                let normalized = Self.toHiragana(builder)
                mecabReading = normalized.isEmpty ? nil : normalized
            }

            let dictOverride = await ReadingOverridePolicy.shared.overrideReading(for: s, mecabReading: mecabReading)
            let finalReading = dictOverride ?? mecabReading
            if seg.range.length == 0 {
                print("[STAGE-2] zero-length semantic span skipped range=\(seg.range.location)-\(NSMaxRange(seg.range)) surface=\(s)")
            } else {
                semantic.append(SemanticSpan(range: seg.range, surface: s, sourceSpanIndices: seg.sourceSpanIndices, readingKana: finalReading))
            }
        }

#if DEBUG
        // Semantic spans must be strictly increasing and must not include hard boundaries.
        var prevEnd = 0
        for s in semantic {
            assert(s.range.location >= prevEnd, "Stage2 invariant failed: semantic spans overlap/out-of-order")
            assert(s.range.length > 0, "Stage2 invariant failed: empty semantic span")
            assert(NSMaxRange(s.range) <= nsText.length, "Stage2 invariant failed: semantic span out of bounds")
            let surface = nsText.substring(with: s.range)
            assert(Self.isHardBoundaryOnly(surface) == false, "Stage2 invariant failed: semantic span includes only hard boundary text")
            prevEnd = NSMaxRange(s.range)
        }

        // Gaps between semantic spans may only contain hard-boundary characters.
        if semantic.isEmpty == false {
            var cursor = 0
            for s in semantic {
                if s.range.location > cursor {
                    let gap = NSRange(location: cursor, length: s.range.location - cursor)
                    let gapText = nsText.substring(with: gap)
                    assert(Self.isHardBoundaryOnly(gapText), "Stage2 invariant failed: uncovered non-boundary gap")
                }
                cursor = max(cursor, NSMaxRange(s.range))
            }
            if cursor < nsText.length {
                let gap = NSRange(location: cursor, length: nsText.length - cursor)
                let gapText = nsText.substring(with: gap)
                assert(Self.isHardBoundaryOnly(gapText), "Stage2 invariant failed: uncovered non-boundary tail gap")
            }
        }
#endif

        print("[STAGE-2] end (main=\(Thread.isMainThread)) spansIn=\(spans.count) spansOut=\(semantic.count)")
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
//                Self.debug("[SpanReadingAttacher] Matched token surface=\(annotation.surface) reading=\(chunk) for span=\(span.surface).")
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

