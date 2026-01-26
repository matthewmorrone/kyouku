import Foundation
import UIKit
import CoreText

enum FuriganaAttributedTextBuilder {
    static func build(
        text: String,
        textSize: Double,
        furiganaSize: Double,
        context: String = "general",
        tokenBoundaries: [Int] = [],
        readingOverrides: [ReadingOverride] = [],
        padHeadwordSpacing: Bool = false
    ) async throws -> NSAttributedString {
        guard text.isEmpty == false else {
            return NSAttributedString(string: text)
        }

        let stage2 = try await computeStage2(
            text: text,
            context: context,
            tokenBoundaries: tokenBoundaries,
            readingOverrides: readingOverrides,
            baseSpans: nil
        )
        let attributed = project(
            text: text,
            semanticSpans: stage2.semanticSpans,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: context,
            padHeadwordSpacing: padHeadwordSpacing
        )
        return attributed
    }

    struct Stage2Result {
        let annotatedSpans: [AnnotatedSpan]
        let semanticSpans: [SemanticSpan]
    }

    static func computeStage2(
        text: String,
        context: String = "general",
        tokenBoundaries: [Int] = [],
        readingOverrides: [ReadingOverride] = [],
        baseSpans: [TextSpan]? = nil
    ) async throws -> Stage2Result {
        guard text.isEmpty == false else {
            return Stage2Result(annotatedSpans: [], semanticSpans: [])
        }
        let start = CFAbsoluteTimeGetCurrent()

        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let segmented: [TextSpan]
        if let baseSpans {
            segmented = baseSpans
        } else {
            segmented = try await SegmentationService.shared.segment(text: text)
        }
        let nsText = text as NSString
        let adjustedSpans = normalizeCoverage(spans: segmented, text: nsText)

        // Optional embedding-based boundary refinement stage.
        // This never rewrites strings; it selects a best-cover over token-aligned spans
        // derived by slicing the original text.
        var spansForAttachment = adjustedSpans
        var boundariesAuthoritative = (baseSpans != nil)
        if baseSpans == nil {
            let session = EmbeddingSession()
            if session.isFeatureEnabled(.tokenBoundaryResolution) {
                let traceEnabled: Bool = {
                    ProcessInfo.processInfo.environment["EMBED_BOUNDARY_TRACE"] == "1"
                }()

                if traceEnabled {
                    let status = EmbeddingFeatureGates.shared.metadataStatus()
                    let reason = status.reason ?? "nil"
                    CustomLogger.shared.info(
                        "Embedding boundary refinement enabled. metadataOK=\(status.enabled) reason=\(reason)"
                    )
                }

                let scorer = EmbeddingBoundaryScorer()
                // Dictionary-aware eligibility consults the already-loaded in-memory JMdict trie.
                // IMPORTANT: this must not trigger SQLite bootstrap work.
                let trie: LexiconTrie?
                if let t = await SegmentationService.shared.cachedTrieIfAvailable() {
                    trie = t
                } else {
                    trie = await LexiconProvider.shared.cachedTrieIfAvailable()
                }

                // Always run refinement off the main thread; Swift 6 forbids `Thread.isMainThread`
                // checks in async contexts, and this stage is CPU-bound.
                // Control-flow invariant:
                // surface lookup → deinflection lookup → STOP if hit → only then consider refinement.
                //
                // We enforce this structurally by:
                // 1) Pre-merging verb phrases (boundary-frozen; no semantic scoring)
                // 2) Applying reduplication hard cuts (structural, not semantic)
                // 3) Pre-merging dictionary/deinflection-lockable spans (hard stop)
                // 4) Running embedding refinement ONLY if allowed and ambiguity exists.

                var workingSpans = adjustedSpans
                var combinedHardCuts = tokenBoundaries

                // (2) Verb-headed spans: boundary-frozen.
                let gated = MorphologicalIntegrityGate.apply(text: nsText, spans: workingSpans, hardCuts: combinedHardCuts, trie: trie)
                workingSpans = gated.spans

                // (3) Reduplication is structural.
                if let trie {
                    let redup = ReduplicationGate.apply(text: nsText, spans: workingSpans, hardCuts: combinedHardCuts, trie: trie)
                    if redup.addedHardCuts.isEmpty == false {
                        combinedHardCuts.append(contentsOf: redup.addedHardCuts)
                    }
                }

                // (1) Deinflection is a HARD STOP.
                var deinflectionLocks = 0
                if let trie {
                    if let deinflector = try? await MainActor.run(resultType: Deinflector.self, body: {
                        try Deinflector.loadBundled(named: "deinflect")
                    }) {
                        let merged = DeinflectionHardStopMerger.apply(text: nsText, spans: workingSpans, hardCuts: combinedHardCuts, trie: trie, deinflector: deinflector)
                        workingSpans = merged.spans
                        deinflectionLocks = merged.deinflectionLocks
                        if merged.addedHardCuts.isEmpty == false {
                            combinedHardCuts.append(contentsOf: merged.addedHardCuts)
                        }
                    }
                }

                // Boundary refinement is CONDITIONAL.
                // We skip refinement if any verb-phrase gating occurred OR any deinflection lock occurred.
                let shouldSkipDueToVerbPhrase = (gated.merges > 0)
                if shouldSkipDueToVerbPhrase && traceEnabled {
                    CustomLogger.shared.info("Boundary refinement skipped: verb-headed span(s) boundary-frozen merges=\(gated.merges)")
                }
                if deinflectionLocks > 0 && traceEnabled {
                    CustomLogger.shared.info("Boundary refinement skipped: deinflection hard-stop locks=\(deinflectionLocks)")
                }

                func hasAmbiguousDictionaryCandidates(spans: [TextSpan], hardCuts: [Int], trie: LexiconTrie) -> Bool {
                    guard spans.count >= 2 else { return false }
                    let cutSet = Set(hardCuts)

                    func isContiguous(_ a: TextSpan, _ b: TextSpan) -> Bool {
                        NSMaxRange(a.range) == b.range.location
                    }

                    func crossesHardCut(endOfTokenAt leftIndex: Int) -> Bool {
                        let cutPos = NSMaxRange(spans[leftIndex].range)
                        return cutSet.contains(cutPos)
                    }

                    func isHardStopToken(surface: String) -> Bool {
                        if surface.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) { return true }
                        if surface.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }) { return true }
                        return false
                    }

                    // Any start index with 2+ dictionary-valid multi-token options implies ambiguity.
                    let maxTokens = 4
                    for i in 0..<spans.count {
                        let tokenSurface = spans[i].surface
                        if isHardStopToken(surface: tokenSurface) { continue }

                        var validMultiTokenCount = 0
                        var union = spans[i].range
                        var j = i
                        while (j + 1) < spans.count && (j - i + 1) < maxTokens {
                            guard isContiguous(spans[j], spans[j + 1]) else { break }
                            guard crossesHardCut(endOfTokenAt: j) == false else { break }

                            let nextSurface = spans[j + 1].surface
                            if isHardStopToken(surface: nextSurface) { break }

                            j += 1
                            union = NSUnionRange(union, spans[j].range)
                            let surface = nsText.substring(with: union)
                            if trie.containsWord(surface, requireKanji: false) {
                                validMultiTokenCount += 1
                                if validMultiTokenCount >= 2 { return true }
                            }
                        }
                    }
                    return false
                }

                let shouldRunRefinement: Bool
                if let trie {
                    shouldRunRefinement = (shouldSkipDueToVerbPhrase == false) && (deinflectionLocks == 0) && hasAmbiguousDictionaryCandidates(spans: workingSpans, hardCuts: combinedHardCuts, trie: trie)
                } else {
                    shouldRunRefinement = false
                }

                if shouldRunRefinement == false, traceEnabled, shouldSkipDueToVerbPhrase == false, deinflectionLocks == 0 {
                    CustomLogger.shared.info("Boundary refinement skipped: no ambiguity or no trie")
                }

                if shouldRunRefinement {
                    let snapshot = workingSpans
                    let access = session.access
                    let textString = text
                    let hardCutsSnapshot = combinedHardCuts
                    let trieSnapshot = trie
                    spansForAttachment = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let localText = textString as NSString
                            let refined = scorer.refine(text: localText, spans: snapshot, hardCuts: hardCutsSnapshot, access: access, trie: trieSnapshot)
                            continuation.resume(returning: refined)
                        }
                    }
                } else {
                    spansForAttachment = workingSpans
                }

                boundariesAuthoritative = true
            } else {
                let traceEnabled: Bool = {
                    ProcessInfo.processInfo.environment["EMBED_BOUNDARY_TRACE"] == "1"
                }()
                if traceEnabled {
                    let status = EmbeddingFeatureGates.shared.metadataStatus()
                    let reason = status.reason ?? "nil"
                    CustomLogger.shared.info(
                        "Embedding boundary refinement disabled. metadataOK=\(status.enabled) reason=\(reason)"
                    )
                }
            }
        }

        _ = elapsedMilliseconds(since: segmentationStart)

        let attachmentStart = CFAbsoluteTimeGetCurrent()
        let stage2 = await SpanReadingAttacher().attachReadings(
            text: text,
            spans: spansForAttachment,
            treatSpanBoundariesAsAuthoritative: boundariesAuthoritative,
            hardCuts: tokenBoundaries
        )

        // Apply user overrides to Stage-2 outputs. This preserves the existing
        // precedence rule: user overrides only apply on exact range matches.
        let resolvedAnnotated = applyReadingOverrides(stage2.annotatedSpans, overrides: readingOverrides)
        let resolvedSemantic = applyReadingOverrides(stage2.semanticSpans, overrides: readingOverrides)

        _ = elapsedMilliseconds(since: attachmentStart)

        _ = elapsedMilliseconds(since: start)
        return Stage2Result(annotatedSpans: resolvedAnnotated, semanticSpans: resolvedSemantic)
    }

    static func computeAnnotatedSpans(
        text: String,
        context: String = "general",
        tokenBoundaries: [Int] = [],
        readingOverrides: [ReadingOverride] = [],
        baseSpans: [TextSpan]? = nil
    ) async throws -> [AnnotatedSpan] {
        // Reading reconciliation policy (downstream of Stage 1):
        //
        // Stage 1 provides *surface spans only*. All reading selection happens here in Stage 2.
        // Precedence is intentionally explicit and conservative:
        //  1) User override (range-based `ReadingOverride`) wins for that span.
        //  2) Deterministic dictionary reading for the surface (JMdict-derived; only when unambiguous)
        //     may override MeCab if it disagrees. If the dictionary has multiple readings for a
        //     surface, we do NOT guess here.
        //  3) MeCab/IPADic reading (attached by `SpanReadingAttacher`).
        //  4) Fallback: nil (no reading).
        //
        // IMPORTANT: This is a policy declaration only. Do not add linguistic heuristics here.
        // Any change to precedence should be made deliberately and in one place.
        let stage2 = try await computeStage2(
            text: text,
            context: context,
            tokenBoundaries: tokenBoundaries,
            readingOverrides: readingOverrides,
            baseSpans: baseSpans
        )
        return stage2.annotatedSpans
    }

    static func coverageGaps(spans: [TextSpan], text: String) -> [NSRange] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }
        let bounds = NSRange(location: 0, length: length)

        let sorted: [TextSpan] = spans
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .map { span in
                let clampedRange = NSIntersectionRange(span.range, bounds)
                let clampedSurface = clampedRange.length > 0 ? nsText.substring(with: clampedRange) : ""
                return TextSpan(range: clampedRange, surface: clampedSurface, isLexiconMatch: span.isLexiconMatch)
            }
            .filter { $0.range.length > 0 }
            .sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

        var gaps: [NSRange] = []
        gaps.reserveCapacity(8)
        var cursor = 0

        func appendGapIfNeeded(from start: Int, to end: Int) {
            guard end > start else { return }
            let gap = NSRange(location: start, length: end - start)
            guard containsNonWhitespace(in: gap, text: nsText) else { return }
            gaps.append(gap)
        }

        for span in sorted {
            let spanStart = span.range.location
            let spanEnd = NSMaxRange(span.range)
            if spanStart > cursor {
                appendGapIfNeeded(from: cursor, to: spanStart)
            }
            cursor = max(cursor, spanEnd)
            if cursor >= length { break }
        }

        if cursor < length {
            appendGapIfNeeded(from: cursor, to: length)
        }

        return gaps
    }

    static func project(
        text: String,
        annotatedSpans: [AnnotatedSpan],
        textSize: Double,
        furiganaSize: Double,
        context: String = "general",
        padHeadwordSpacing: Bool = false
    ) -> NSAttributedString {
        guard text.isEmpty == false else { return NSAttributedString(string: text) }

        let mutable = NSMutableAttributedString(string: text)
        let rubyReadingKey = NSAttributedString.Key("RubyReadingText")
        let rubySizeKey = NSAttributedString.Key("RubyReadingFontSize")
        let nsText = text as NSString
        let baseFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, textSize)))
        let rubyFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, furiganaSize)))
        var kerningTargets: [Int: HeadwordSpacingAdjustment] = [:]
        var appliedCount = 0
        let projectionStart = CFAbsoluteTimeGetCurrent()

        for (spanIndex, annotatedSpan) in annotatedSpans.enumerated() {
            guard let reading = annotatedSpan.readingKana, annotatedSpan.span.range.location != NSNotFound else { continue }
            guard annotatedSpan.span.range.length > 0 else { continue }
            guard containsKanji(in: annotatedSpan.span.surface) else { continue }
            guard isValidRubyReading(reading) else { continue }

            // Some segmentation outputs isolate the kanji and exclude the following okurigana.
            // If we only project within that kanji-only range, the projector cannot split readings
            // like "だかれ" against the surface "抱かれ" and ends up attaching the full reading
            // to a single glyph, which is prone to CoreText clamping/shift.
            //
            // Expand the projection window to include immediate trailing kana so the projector can
            // properly consume/trim the okurigana portion.
            let originalRange = annotatedSpan.span.range
            guard NSMaxRange(originalRange) <= nsText.length else { continue }

            // Never extend across token/span boundaries. If the next span begins immediately after
            // this one (e.g. particle "に"), pulling it into the projection window causes
            // overzealous trimming (e.g. custom reading "くに" -> "く").
            let nextBoundary: Int = {
                guard spanIndex + 1 < annotatedSpans.count else { return nsText.length }
                let next = annotatedSpans[spanIndex + 1].span.range
                return next.location == NSNotFound ? nsText.length : max(0, min(nsText.length, next.location))
            }()

            let projectionRange = extendRangeForwardOverKana(originalRange, in: nsText, maxEnd: nextBoundary)
            guard NSMaxRange(projectionRange) <= nsText.length else { continue }
            let spanText = nsText.substring(with: projectionRange)

            let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: projectionRange)

            for segment in segments {
                guard segment.reading.isEmpty == false else { continue }
                mutable.addAttribute(.rubyAnnotation, value: true, range: segment.range)
                mutable.addAttribute(rubyReadingKey, value: segment.reading, range: segment.range)
                mutable.addAttribute(rubySizeKey, value: furiganaSize, range: segment.range)

                appliedCount += 1

                if padHeadwordSpacing {
                    let adjustments = spacingAdjustments(
                        for: segment.range,
                        reading: segment.reading,
                        text: nsText,
                        baseFont: baseFont,
                        rubyFont: rubyFont
                    )
                    mergeHeadwordSpacingAdjustments(adjustments, into: &kerningTargets)
                }
            }
        }

        _ = elapsedMilliseconds(since: projectionStart)
        if padHeadwordSpacing {
            applyHeadwordSpacingAdjustments(Array(kerningTargets.values), to: mutable)
        }
        // CustomLogger.shared.info("[\(context)] Projected ruby for \(appliedCount) segments in (projectionDuration) ms.")
        return mutable.copy() as? NSAttributedString ?? NSAttributedString(string: text)
    }

    /// Ruby projection over Stage-2 semantic units.
    ///
    /// This consumes `SemanticSpan` so that ruby projection can treat kanji+okurigana
    /// as a single unit when MeCab proves it, without pushing that logic back into
    /// Stage 1 segmentation.
    static func project(
        text: String,
        semanticSpans: [SemanticSpan],
        textSize: Double,
        furiganaSize: Double,
        context: String = "general",
        padHeadwordSpacing: Bool = false
    ) -> NSAttributedString {
        guard text.isEmpty == false else { return NSAttributedString(string: text) }

        let mutable = NSMutableAttributedString(string: text)
        let rubyReadingKey = NSAttributedString.Key("RubyReadingText")
        let rubySizeKey = NSAttributedString.Key("RubyReadingFontSize")
        let nsText = text as NSString
        let baseFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, textSize)))
        let rubyFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, furiganaSize)))
        var kerningTargets: [Int: HeadwordSpacingAdjustment] = [:]
        var appliedCount = 0
        let projectionStart = CFAbsoluteTimeGetCurrent()

        for semantic in semanticSpans {
            guard let reading = semantic.readingKana, semantic.range.location != NSNotFound else { continue }
            guard semantic.range.length > 0 else { continue }
            guard containsKanji(in: semantic.surface) else { continue }
            guard isValidRubyReading(reading) else { continue }
            guard NSMaxRange(semantic.range) <= nsText.length else { continue }

            // The semantic span range already includes any okurigana that is proven
            // by MeCab token coverage. Do not extend across semantic boundaries here.
            let spanText = nsText.substring(with: semantic.range)
            let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: semantic.range)

            for segment in segments {
                guard segment.reading.isEmpty == false else { continue }
                mutable.addAttribute(.rubyAnnotation, value: true, range: segment.range)
                mutable.addAttribute(rubyReadingKey, value: segment.reading, range: segment.range)
                mutable.addAttribute(rubySizeKey, value: furiganaSize, range: segment.range)

                // let headword = nsText.substring(with: segment.range)
                // CustomLogger.shared.info("ruby headword='\(headword)' reading='\(segment.reading)' commonKanaRemoved='\(segment.commonKanaRemoved)'")
                appliedCount += 1

                if padHeadwordSpacing {
                    let adjustments = spacingAdjustments(
                        for: segment.range,
                        reading: segment.reading,
                        text: nsText,
                        baseFont: baseFont,
                        rubyFont: rubyFont
                    )
                    mergeHeadwordSpacingAdjustments(adjustments, into: &kerningTargets)
                }
            }
        }

        _ = elapsedMilliseconds(since: projectionStart)
        if padHeadwordSpacing {
            applyHeadwordSpacingAdjustments(Array(kerningTargets.values), to: mutable)
        }
        // CustomLogger.shared.info("[\(context)] Projected ruby for \(appliedCount) segments in (projectionDuration) ms.")
        return mutable.copy() as? NSAttributedString ?? NSAttributedString(string: text)
    }

    private static func containsKanji(in text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func isValidRubyReading(_ reading: String) -> Bool {
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        // Ruby readings should be kana. If a reading contains kanji (or contains no kana),
        // skip ruby rather than rendering duplicated kanji above the base.
        if containsKanji(in: trimmed) { return false }
        let hasKana = trimmed.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
        return hasKana
    }

    private static func extendRangeForwardOverKana(_ range: NSRange, in text: NSString, maxEnd: Int) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        let textLength = min(text.length, max(0, maxEnd))
        var end = NSMaxRange(range)
        guard end <= textLength else { return range }

        // If the span already includes trailing kana (e.g. "香り"), do NOT extend further.
        // Extending would pull in kana from the next token/particle (e.g. "で"), which can
        // prevent proper okurigana removal.
        let lastIndex = max(range.location, end - 1)
        let lastComposed = text.rangeOfComposedCharacterSequence(at: lastIndex)
        if lastComposed.location != NSNotFound, lastComposed.length > 0, NSMaxRange(lastComposed) <= textLength {
            let lastString = text.substring(with: lastComposed)
            if let lastChar = lastString.first, isKana(lastChar) {
                return range
            }
        }

        // Keep this conservative to avoid accidentally pulling in the next token.
        let maxAdditionalComposedChars = 8
        var added = 0

        while end < textLength, added < maxAdditionalComposedChars {
            let composed = text.rangeOfComposedCharacterSequence(at: end)
            guard composed.location != NSNotFound, composed.length > 0 else { break }
            guard NSMaxRange(composed) <= textLength else { break }

            let s = text.substring(with: composed)
            guard let ch = s.first else { break }
            if ch.isWhitespace || ch.isNewline { break }
            if isKana(ch) {
                end = NSMaxRange(composed)
                added += 1
            } else {
                break
            }
        }

        return NSRange(location: range.location, length: end - range.location)
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func makeRubyAnnotation(text: String, textSize _: Double, furiganaSize: Double) -> CTRubyAnnotation? {
        guard text.isEmpty == false else { return nil }
        let rubyFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, furiganaSize)))
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: rubyFont] as CFDictionary
        return CTRubyAnnotationCreateWithAttributes(
            .center,
            // Prefer expanding the base rather than allowing ruby to overhang the base.
            .none,
            .before,
            text as CFString,
            attributes
        )
    }

    private static func describe(spans: [TextSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }
}

private extension FuriganaAttributedTextBuilder {
    private struct HeadwordSpacingAdjustment {
        let range: NSRange
        let kern: CGFloat
    }

    private static let whitespaceAndNewlineSet = CharacterSet.whitespacesAndNewlines

    private static func normalizeCoverage(spans: [TextSpan], text: NSString) -> [TextSpan] {
        let length = text.length
        guard length > 0 else { return [] }
        let bounds = NSRange(location: 0, length: length)

        let sorted: [TextSpan] = spans
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .map { span in
                let clampedRange = NSIntersectionRange(span.range, bounds)
                let clampedSurface = clampedRange.length > 0 ? text.substring(with: clampedRange) : ""
                return TextSpan(range: clampedRange, surface: clampedSurface, isLexiconMatch: span.isLexiconMatch)
            }
            .filter { $0.range.length > 0 }
            .sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

        var normalized: [TextSpan] = []
        normalized.reserveCapacity(sorted.count + 8)
        var cursor = 0

        func appendGapIfNeeded(from start: Int, to end: Int) {
            guard end > start else { return }
            let gap = NSRange(location: start, length: end - start)
            guard containsNonWhitespace(in: gap, text: text) else { return }
            let surface = text.substring(with: gap)
            normalized.append(TextSpan(range: gap, surface: surface, isLexiconMatch: false))
        }

        for span in sorted {
            let spanStart = span.range.location
            let spanEnd = NSMaxRange(span.range)
            if spanStart > cursor {
                appendGapIfNeeded(from: cursor, to: spanStart)
                normalized.append(span)
                cursor = max(cursor, spanEnd)
                continue
            }
            if spanEnd <= cursor {
                continue
            }
            // Overlap: trim leading portion so coverage stays contiguous.
            let trimmedRange = NSRange(location: cursor, length: spanEnd - cursor)
            let surface = text.substring(with: trimmedRange)
            normalized.append(TextSpan(range: trimmedRange, surface: surface, isLexiconMatch: span.isLexiconMatch))
            cursor = spanEnd
        }

        if cursor < length {
            appendGapIfNeeded(from: cursor, to: length)
        }

        return normalized
    }

    private static func containsNonWhitespace(in range: NSRange, text: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let substring = text.substring(with: range)
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
            if let scalar = UnicodeScalar(unit), CharacterSet.newlines.contains(scalar) {
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
        return segments.isEmpty ? [range] : segments
    }

    private static func applyReadingOverrides(
        _ annotated: [AnnotatedSpan],
        overrides: [ReadingOverride]
    ) -> [AnnotatedSpan] {
        let mapping: [OverrideKey: String] = overrides.reduce(into: [:]) { partialResult, override in
            guard let kana = override.userKana, kana.isEmpty == false else { return }
            let key = OverrideKey(location: override.rangeStart, length: override.rangeLength)
            partialResult[key] = kana
        }
        guard mapping.isEmpty == false else { return annotated }
        return annotated.map { span in
            let key = OverrideKey(location: span.span.range.location, length: span.span.range.length)
            if let kana = mapping[key] {
                return AnnotatedSpan(span: span.span, readingKana: kana, lemmaCandidates: span.lemmaCandidates, partOfSpeech: span.partOfSpeech)
            }
            return span
        }
    }

    private static func applyReadingOverrides(
        _ semantic: [SemanticSpan],
        overrides: [ReadingOverride]
    ) -> [SemanticSpan] {
        let mapping: [OverrideKey: String] = overrides.reduce(into: [:]) { partialResult, override in
            guard let kana = override.userKana, kana.isEmpty == false else { return }
            let key = OverrideKey(location: override.rangeStart, length: override.rangeLength)
            partialResult[key] = kana
        }
        guard mapping.isEmpty == false else { return semantic }
        return semantic.map { span in
            let key = OverrideKey(location: span.range.location, length: span.range.length)
            if let kana = mapping[key] {
                return SemanticSpan(range: span.range, surface: span.surface, sourceSpanIndices: span.sourceSpanIndices, readingKana: kana)
            }
            return span
        }
    }

    private struct OverrideKey: Hashable {
        let location: Int
        let length: Int
    }

    private static func spacingAdjustments(
        for headwordRange: NSRange,
        reading: String,
        text: NSString,
        baseFont: UIFont,
        rubyFont: UIFont
    ) -> [HeadwordSpacingAdjustment] {
        guard headwordRange.location != NSNotFound, headwordRange.length > 0 else { return [] }
        guard NSMaxRange(headwordRange) <= text.length else { return [] }
        guard reading.isEmpty == false else { return [] }

        let headword = text.substring(with: headwordRange)
        let baseWidth = (headword as NSString).size(withAttributes: [.font: baseFont]).width
        let rubyWidth = (reading as NSString).size(withAttributes: [.font: rubyFont]).width
        guard baseWidth.isFinite, rubyWidth.isFinite else { return [] }

        let overhang = rubyWidth - baseWidth
        // Requirement: when headword spacing is enabled and ruby is wider than the base,
        // expand the base so widths match (even if alignment isn't perfectly centered yet).
        // Use a tiny epsilon to avoid micro-adjustments from measurement noise.
        let epsilon: CGFloat = 0.01
        guard overhang > epsilon else { return [] }

        let totalPad = overhang
        guard totalPad > 0 else { return [] }

        var adjustments: [HeadwordSpacingAdjustment] = []

        // Apply padding INSIDE the headword so it remains effective at soft-wrap line starts
        // and at visual line ends. Applying kern only "after" the last glyph can be ignored
        // by the layout engine when the run ends the line/document.
        var glyphRanges: [NSRange] = []
        glyphRanges.reserveCapacity(min(8, headwordRange.length))

        var cursor = headwordRange.location
        let upperBound = NSMaxRange(headwordRange)
        while cursor < upperBound {
            let r = text.rangeOfComposedCharacterSequence(at: cursor)
            guard r.location != NSNotFound, r.length > 0 else { break }
            guard NSMaxRange(r) <= upperBound else { break }
            let s = text.substring(with: r)
            if s.trimmingCharacters(in: whitespaceAndNewlineSet).isEmpty == false {
                glyphRanges.append(r)
            }
            cursor = NSMaxRange(r)
        }

        if glyphRanges.count >= 2 {
            // Distribute padding across inter-glyph gaps.
            // IMPORTANT: `.kern` affects spacing BETWEEN characters. Applying `.kern` to a
            // single-character range is typically ineffective, so we apply one kern value
            // across the full headword *excluding the final glyph*.
            let perGap = totalPad / CGFloat(max(1, glyphRanges.count - 1))
            if let first = glyphRanges.first, let last = glyphRanges.last {
                let kernRangeLength = max(0, last.location - first.location)
                if kernRangeLength > 0 {
                    let kernRange = NSRange(location: first.location, length: kernRangeLength)
                    adjustments.append(HeadwordSpacingAdjustment(range: kernRange, kern: perGap))
                }
            }
        } else if let only = glyphRanges.first {
            // Single glyph (common for lone kanji): TextKit kerning cannot widen a single glyph
            // without affecting adjacent characters. Leave this unadjusted in TextKit mode.
            _ = only
        }

        return adjustments
    }

    private static func mergeHeadwordSpacingAdjustments(
        _ adjustments: [HeadwordSpacingAdjustment],
        into targets: inout [Int: HeadwordSpacingAdjustment]
    ) {
        guard adjustments.isEmpty == false else { return }
        for adjustment in adjustments {
            let key = adjustment.range.location
            if let existing = targets[key] {
                if adjustment.kern > existing.kern {
                    targets[key] = adjustment
                }
            } else {
                targets[key] = adjustment
            }
        }
    }

    private static func applyHeadwordSpacingAdjustments(
        _ adjustments: [HeadwordSpacingAdjustment],
        to attributed: NSMutableAttributedString
    ) {
        guard adjustments.isEmpty == false else { return }
        let length = attributed.length
        for adjustment in adjustments {
            guard adjustment.kern > 0 else { continue }
            let range = adjustment.range
            guard range.location != NSNotFound, range.length > 0 else { continue }
            guard NSMaxRange(range) <= length else { continue }
            attributed.addAttribute(.kern, value: adjustment.kern, range: range)
        }
    }
}
