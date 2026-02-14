import Foundation
import UIKit
import CoreText

enum FuriganaAttributedTextBuilder {
    private static let stageDumpLock = NSLock()
    private static var lastStageDumpKey: String = ""

    private actor DeinflectorCache {
        static let shared = DeinflectorCache()
        private var cached: Deinflector?

        func get() throws -> Deinflector {
            if let cached { return cached }
            let loaded = try Deinflector.loadBundled(named: "deinflect")
            cached = loaded
            return loaded
        }
    }

    private static func stageDumpKey(
        text: String,
        context: String,
        tokenBoundaries: [Int],
        readingOverridesCount: Int,
        baseSpans: [TextSpan]?
    ) -> String {
        // Keep it cheap: we need stable de-duping, not cryptographic uniqueness.
        let cutsSig = tokenBoundaries.prefix(64).map(String.init).joined(separator: ",")
        let baseSig: String = {
            guard let baseSpans else { return "nil" }
            let r = baseSpans.prefix(64).map { "\($0.range.location):\($0.range.length)" }.joined(separator: ",")
            return "n=\(baseSpans.count)|\(r)"
        }()
        return "ctx=\(context)|h=\(SpanReadingAttacher.hash(text))|cuts=\(cutsSig)|ovr=\(readingOverridesCount)|base=\(baseSig)"
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

        // TEMP DIAGNOSTICS (2026-02-02)
        // Goal: concise dumps at each stage, without requiring toggles.
        // Guardrail: dedupe by input so we don't spam logs on rerenders.
        let pipelineTraceEnabled = true

        let shouldDumpStages: Bool = {
            guard pipelineTraceEnabled else { return false }

    #if DEBUG
            let key = stageDumpKey(
            text: text,
            context: context,
            tokenBoundaries: tokenBoundaries,
            readingOverridesCount: readingOverrides.count,
            baseSpans: baseSpans
            )
            stageDumpLock.lock()
            defer { stageDumpLock.unlock() }
            if key == lastStageDumpKey { return false }
            lastStageDumpKey = key
            return true
    #else
            return true
    #endif
        }()
        func log(_ prefix: String, _ message: String) {
            guard shouldDumpStages else { return }
            CustomLogger.shared.pipeline(context: context, stage: prefix, message)
        }
        func stageLine(_ name: String, _ value: String) -> String {
            let columnWidth = 26
            if name.count >= columnWidth {
                return "\(name) -> \(value)"
            }
            return "\(name)\(String(repeating: " ", count: columnWidth - name.count)) -> \(value)"
        }
        func cutDescription(_ cuts: [Int]) -> String {
            guard cuts.isEmpty == false else { return "(no user hard cuts)" }
            return "[\(cuts.sorted().map(String.init).joined(separator: ","))]"
        }

        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let segmented: [TextSpan]
        if let baseSpans {
            segmented = baseSpans
        } else {
            segmented = try await SegmentationService.shared.segment(text: text)
        }
        let nsText = text as NSString
        var adjustedSpans = normalizeCoverage(spans: segmented, text: nsText)

        // Materialize MeCab annotations once per pipeline run and reuse them across
        // Stage 1.25 (merge-only), Stage 1.5 (split-only), and Stage 2 reading attachment.
        let tokenizer = SpanReadingAttacher.tokenizer()
        let mecabAnnotations: [SpanReadingAttacher.MeCabAnnotation] = {
            guard let tokenizer else { return [] }
            return SpanReadingAttacher.materializeAnnotations(text: text, tokenizer: tokenizer)
        }()

        // Hard cuts that Stage 1.25 must respect.
        // Start with user/token boundaries; refinement stages may add more structural hard cuts.
        var stage125HardCuts = tokenBoundaries

        if shouldDumpStages {
            log("S20", stageLine("BoundaryPolicy", cutDescription(tokenBoundaries)))
            log("S20", stageLine("BoundaryAuthority", baseSpans == nil ? "pipeline segmentation" : "user-authored spans"))
        }

        var structuralNotes: [String] = []

        // Optional embedding-based boundary refinement stage.
        // This never rewrites strings; it selects a best-cover over token-aligned spans
        // derived by slicing the original text.
        var spansForAttachment = adjustedSpans
        var boundariesAuthoritative = (baseSpans != nil)
        if baseSpans != nil {
            structuralNotes.append("baseSpans")
        }
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
                if gated.merges > 0 {
                    structuralNotes.append("MIG merges=\(gated.merges)")
                }

                // (3) Reduplication is structural.
                if let trie {
                    let redup = ReduplicationGate.apply(text: nsText, spans: workingSpans, hardCuts: combinedHardCuts, trie: trie)
                    if redup.addedHardCuts.isEmpty == false {
                        combinedHardCuts.append(contentsOf: redup.addedHardCuts)
                        structuralNotes.append("Redup cuts=\(redup.addedHardCuts.count)")
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
                        if deinflectionLocks > 0 {
                            structuralNotes.append("Deinflect locks=\(deinflectionLocks)")
                        }
                    }
                }

                // Preserve any structural hard cuts computed in this refinement path
                // so Stage 1.25 does not merge across them.
                stage125HardCuts = combinedHardCuts

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

                    structuralNotes.append("EBS refined")
                } else {
                    spansForAttachment = workingSpans
                    structuralNotes.append("EBS skipped")
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

                structuralNotes.append("embedding disabled")
            }
        }

        _ = elapsedMilliseconds(since: segmentationStart)

        let attachmentStart = CFAbsoluteTimeGetCurrent()

        // Stage 1.5: MeCab token-boundary enforcement (split-only).
        //
        // Important constraints:
        // - Must be pure in-memory (no SQLite, no trie lookups).
        // - May split spans, must never merge.
        // - Downstream Stage 2.5 must not merge across these enforced boundaries.
        //   We pass them as ephemeral `hardCuts` (not persisted) so existing merge
        //   logic remains unchanged.
        //
        // IMPORTANT: When `baseSpans` is provided, spans are user-authored. Do not
        // auto-split them here; otherwise manual merges can appear to “not work”
        // because Stage 1.5 immediately reintroduces boundaries.
        if baseSpans == nil {
            let stage15 = MeCabTokenBoundaryNormalizer.apply(
                text: nsText,
                spans: spansForAttachment,
                mecab: mecabAnnotations
            )

            // Stage 1.5 snaps spans to MeCab token boundaries. This must run before merge logic
            // (Stage 1.25) so later stages can safely reason about span ranges vs MeCab ranges.
            spansForAttachment = stage15.spans
            if stage15.forcedCuts.isEmpty == false {
                structuralNotes.append("S1.5 cuts=\(stage15.forcedCuts.count)")
            }
        }

        // NOTE:
        // Stage 1.5 `forcedCuts` represent snap-splits introduced to align spans to MeCab token
        // boundaries. They are not treated as hard cuts for downstream merge logic; Stage 1.25
        // is responsible for syntactic merging after snapping.
        let combinedHardCuts = tokenBoundaries

        if shouldDumpStages {
            log("S30", stageLine("BaseSegmentation", describe(spans: spansForAttachment)))
        }

        // Stage 1.25: syntactic merge stage (merge-only).
        // Hard blocks:
        // - never cross user/token hardCuts
        // - never run when spans are externally provided (user-authored segmentation)
        if baseSpans == nil {
            let stage125 = AuxiliaryChainMerger.apply(
                text: nsText,
                spans: spansForAttachment,
                hardCuts: stage125HardCuts,
                mecab: mecabAnnotations
            )
            spansForAttachment = stage125.spans
            if stage125.merges > 0 {
                structuralNotes.append("S1.25 merges=\(stage125.merges)")
            }
        }

        // Stage 1.75: Deinflection hard-stop merge (merge-only).
        // This ensures dictionary/deinflection-lockable multi-token spans get coalesced even when
        // embedding refinement is disabled.
        if baseSpans == nil {
            let trie: LexiconTrie?
            if let t = await SegmentationService.shared.cachedTrieIfAvailable() {
                trie = t
            } else {
                trie = await LexiconProvider.shared.cachedTrieIfAvailable()
            }

            // Stage 1.6: Lexicon suffix split (split-only).
            // Peels off certain trailing one-character particles (e.g. よ) when it reveals a
            // lexicon word, so Stage 1.75 can later merge dictionary-valid spans.
            if let trie {
                spansForAttachment = LexiconSuffixSplitter.apply(text: nsText, spans: spansForAttachment, trie: trie)
                structuralNotes.append("S1.6 split")
            }

            if let trie, let deinflector = try? await DeinflectorCache.shared.get() {
                let merged = DeinflectionHardStopMerger.apply(
                    text: nsText,
                    spans: spansForAttachment,
                    hardCuts: stage125HardCuts,
                    trie: trie,
                    deinflector: deinflector
                )
                spansForAttachment = merged.spans
                if merged.deinflectionLocks > 0 {
                    structuralNotes.append("S1.75 locks=\(merged.deinflectionLocks)")
                }
            }
        }

        if shouldDumpStages {
            log("S40", stageLine("StructuralComposition", describe(spans: spansForAttachment)))
            if structuralNotes.isEmpty == false {
                log("S40", stageLine("StructuralOps", structuralNotes.joined(separator: ", ")))
            }
        }

        let stage2 = await SpanReadingAttacher().attachReadings(
            text: text,
            spans: spansForAttachment,
            treatSpanBoundariesAsAuthoritative: boundariesAuthoritative,
            hardCuts: combinedHardCuts,
            precomputedAnnotations: mecabAnnotations.isEmpty ? nil : mecabAnnotations
        )

        // Apply user overrides to Stage-2 outputs. This preserves the existing
        // precedence rule: user overrides only apply on exact range matches.
        let resolvedAnnotated = applyReadingOverrides(stage2.annotatedSpans, overrides: readingOverrides)
        let resolvedSemantic = applyReadingOverrides(stage2.semanticSpans, overrides: readingOverrides)

        log("S45", stageLine("ReadingAttachment", describe(annotatedSpans: resolvedAnnotated)))
        log("S50", stageLine("SemanticGrouping", describe(semanticSpans: resolvedSemantic)))

        _ = elapsedMilliseconds(since: attachmentStart)

        _ = elapsedMilliseconds(since: start)
        return Stage2Result(annotatedSpans: resolvedAnnotated, semanticSpans: resolvedSemantic)
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
        context _: String = "general",
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
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2A6DF,
                 0x2A700...0x2B73F,
                 0x2B740...0x2B81F,
                 0x2B820...0x2CEAF,
                 0x2CEB0...0x2EBEF,
                 0x30000...0x3134F,
                 0x3005,
                 0x3006,
                 0x30F6:
                return true
            default:
                return false
            }
        }
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

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func describe(spans: [TextSpan]) -> String {
        splitDescription(from: spans.map(\.surface))
    }

    private static func describe(annotatedSpans: [AnnotatedSpan]) -> String {
        splitDescription(from: annotatedSpans.map { $0.span.surface })
    }

    private static func describe(semanticSpans: [SemanticSpan]) -> String {
        splitDescription(from: semanticSpans.map(\.surface))
    }

    private static func splitDescription(from surfaces: [String], maxChars: Int = 360) -> String {
        guard surfaces.isEmpty == false else { return "∅" }
        let joined = surfaces
            .map {
                $0
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\t", with: "\\t")
            }
            .joined(separator: " | ")
        if joined.count <= maxChars { return joined }
        let idx = joined.index(joined.startIndex, offsetBy: maxChars)
        return String(joined[..<idx]) + " ..."
    }
}

private extension FuriganaAttributedTextBuilder {
    private struct HeadwordSpacingAdjustment {
        let range: NSRange
        let kern: CGFloat
        let expansion: CGFloat

        init(range: NSRange, kern: CGFloat = 0, expansion: CGFloat = 0) {
            self.range = range
            self.kern = kern
            self.expansion = expansion
        }
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
            // Bias-free distribution:
            // - Keep spacing *inside* the headword (avoid trailing padding that creates a visible
            //   gap to the next character and looks right-shifted).
            // - Cap per-gap kern so 2-glyph headwords don't get one giant internal gap.
            // - Use `.expansion` on the run to absorb remaining width without introducing gaps.
            let internalGapCount = max(1, glyphRanges.count - 1)
            let perGapRaw = totalPad / CGFloat(internalGapCount)
            let maxPerGap = max(0.0, baseFont.pointSize * 0.22)
            let perGap = min(perGapRaw, maxPerGap)

            if let first = glyphRanges.first, let last = glyphRanges.last {
                let kernRangeLength = max(0, last.location - first.location)
                if kernRangeLength > 0, perGap > 0.001 {
                    let kernRange = NSRange(location: first.location, length: kernRangeLength)
                    adjustments.append(HeadwordSpacingAdjustment(range: kernRange, kern: perGap))
                }
            }

            let appliedByKern = perGap * CGFloat(internalGapCount)
            let remaining = max(0.0, totalPad - appliedByKern)
            if remaining > epsilon, baseWidth > 0.01 {
                // Approximate: treat expansion as a fractional increase over the run width.
                // Clamp to avoid visibly stretched glyphs.
                let expansion = min(0.20, remaining / baseWidth)
                if expansion > 0.0005 {
                    adjustments.append(HeadwordSpacingAdjustment(range: headwordRange, expansion: expansion))
                }
            }
        } else if let only = glyphRanges.first {
            // Single glyph: use expansion instead of trailing padding.
            if baseWidth > 0.01 {
                let expansion = min(0.20, totalPad / baseWidth)
                if expansion > 0.0005 {
                    adjustments.append(HeadwordSpacingAdjustment(range: only, expansion: expansion))
                }
            }
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
                let merged = HeadwordSpacingAdjustment(
                    range: existing.range,
                    kern: max(existing.kern, adjustment.kern),
                    expansion: max(existing.expansion, adjustment.expansion)
                )
                targets[key] = merged
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
            let range = adjustment.range
            guard range.location != NSNotFound, range.length > 0 else { continue }
            guard NSMaxRange(range) <= length else { continue }
            if adjustment.kern > 0.0005 {
                attributed.addAttribute(.kern, value: adjustment.kern, range: range)
            }
            if adjustment.expansion > 0.0005 {
                attributed.addAttribute(.expansion, value: adjustment.expansion, range: range)
            }
        }
    }
}
