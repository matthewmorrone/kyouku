import Foundation
import UIKit

struct FuriganaPipelineService {
    private static let tailMergeDeinflectionCache = DeinflectionCache()

    #if DEBUG
    // Debug-only: helps verify whether overlap coverage counts (>1) are ever produced.
    // Dedupes logging to avoid spamming while typing/scrolling.
    private static var lastDebugDictionaryCoverageLogFingerprint: Int?
    #endif

    private static let debugHighlightAllDictionaryEntriesDefaultsKey = "debugHighlightAllDictionaryEntries"

    private static func debugHighlightAllDictionaryEntriesEnabled() -> Bool {
    #if DEBUG
        if ProcessInfo.processInfo.environment["DEBUG_HIGHLIGHT_ALL_DICT_ENTRIES"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: debugHighlightAllDictionaryEntriesDefaultsKey)
    #else
        return false
    #endif
    }

    private static func foldKanaToHiragana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    private static func isIgnorableTokenSurfaceScalar(_ scalar: UnicodeScalar) -> Bool {
        // Regular whitespace/newlines.
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }

        // Common invisible separators that can appear in copied text.
        switch scalar.value {
        case 0x00AD: return true // soft hyphen
        case 0x034F: return true // combining grapheme joiner
        case 0x061C: return true // arabic letter mark
        case 0x180E: return true // mongolian vowel separator (deprecated but seen in the wild)
        case 0x200B: return true // zero width space
        case 0x200C: return true // zero width non-joiner
        case 0x200D: return true // zero width joiner
        case 0x2060: return true // word joiner
        case 0xFEFF: return true // zero width no-break space / BOM
        default: break
        }

        // Variation selectors (VS1..VS16) and IVS (Variation Selector Supplement).
        // These can appear in Japanese text like 朕󠄂 / 通󠄁 and render “invisible” on their own.
        if (0xFE00...0xFE0F).contains(scalar.value) { return true }
        if (0xE0100...0xE01EF).contains(scalar.value) { return true }

        return false
    }

    private static func isEffectivelyEmptyTokenSurface(_ surface: String) -> Bool {
        surface.unicodeScalars.allSatisfy { isIgnorableTokenSurfaceScalar($0) }
    }

    struct Input {
        let text: String
        let showFurigana: Bool
        let needsTokenHighlights: Bool
        let textSize: Double
        let furiganaSize: Double
        let recomputeSpans: Bool
        let existingSpans: [AnnotatedSpan]?
        let existingSemanticSpans: [SemanticSpan]
        let amendedSpans: [TextSpan]?
        let hardCuts: [Int]
        let readingOverrides: [ReadingOverride]
        let context: String
        let padHeadwordSpacing: Bool

        /// Kana-folded “known word” surfaces used for adaptive ruby suppression.
        /// When non-empty, ruby annotations are removed for semantic spans that match.
        let knownWordSurfaceKeys: Set<String>
    }

    struct Result {
        let spans: [AnnotatedSpan]?
        let semanticSpans: [SemanticSpan]
        let attributedString: NSAttributedString?
    }

    func render(_ input: Input) async -> Result {
        guard input.text.isEmpty == false else {
            return Result(spans: nil, semanticSpans: [], attributedString: nil)
        }

        var spans = input.existingSpans
        var semantic = input.existingSemanticSpans
        let hasInvalidSemantic = (spans?.isEmpty == false) && semantic.isEmpty
        if input.recomputeSpans || spans == nil || hasInvalidSemantic {
            do {
                let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
                    text: input.text,
                    context: input.context,
                    tokenBoundaries: input.hardCuts,
                    readingOverrides: input.readingOverrides,
                    baseSpans: input.amendedSpans
                )
                spans = stage2.annotatedSpans
                semantic = stage2.semanticSpans
            } catch {
                CustomLogger.shared.error("\(input.context) span computation failed: \(String(describing: error))")
                return Result(spans: nil, semanticSpans: [], attributedString: NSAttributedString(string: input.text))
            }
        }

        guard let resolvedSpans = spans else {
            CustomLogger.shared.error("\(input.context) span computation returned nil even after recompute.")
            return Result(spans: nil, semanticSpans: [], attributedString: NSAttributedString(string: input.text))
        }

        // Hard invariant: semantic spans must never contain line breaks.
        // Newlines are hard boundaries for selection + dictionary lookup.
        let resolvedSemantic = Self.splitSemanticSpansOnLineBreaks(text: input.text, spans: semantic)

        // Tail-end post pass: attempt to merge adjacent semantic spans into a single
        // lexicon-valid surface form when safe.
        //
        // This is intentionally *not* Stage 1 logic; it runs after the current
        // pipeline iteration has produced semantic spans and exists to reduce
        // over-segmentation that can remain even after Stage 2.5 regrouping.
        let mergedSemantic = await Self.mergeAdjacentSemanticSpansIfValid(
            text: input.text,
            spans: resolvedSemantic,
            hardCuts: input.hardCuts,
            context: input.context
        )

        var attributed: NSAttributedString?
        if input.showFurigana {
            let projected = FuriganaAttributedTextBuilder.project(
                text: input.text,
                semanticSpans: mergedSemantic,
                textSize: input.textSize,
                furiganaSize: input.furiganaSize,
                context: input.context,
                padHeadwordSpacing: input.padHeadwordSpacing
            )
            if input.knownWordSurfaceKeys.isEmpty {
                attributed = projected
            } else {
                attributed = stripRubyForKnownSemanticSpans(
                    attributed: projected,
                    semanticSpans: mergedSemantic,
                    stage2Spans: resolvedSpans,
                    knownSurfaceKeys: input.knownWordSurfaceKeys
                )
            }
        } else {
            attributed = nil
        }

        if Self.debugHighlightAllDictionaryEntriesEnabled() {
            if attributed == nil {
                attributed = NSAttributedString(string: input.text)
            }
            if let base = attributed {
                let cachedTrie = await SegmentationService.shared.cachedTrieIfAvailable()
                let trie: LexiconTrie?
                if let cachedTrie {
                    trie = cachedTrie
                } else {
                    trie = await SegmentationService.shared.ensureTrieLoaded()
                }
                if let trie {
                    attributed = Self.applyDebugDictionaryEntryHighlights(text: input.text, to: base, trie: trie)
                }
            }
        }

        return Result(spans: resolvedSpans, semanticSpans: mergedSemantic, attributedString: attributed)
    }

    private static func applyDebugDictionaryEntryHighlights(
        text: String,
        to base: NSAttributedString,
        trie: LexiconTrie
    ) -> NSAttributedString {
        let nsText = text as NSString
        guard nsText.length > 0 else { return base }

        let mutable = NSMutableAttributedString(attributedString: base)

        var globalMaxCoverage = 0
        var globalOverlapUnits = 0
        var firstOverlapExampleRange: NSRange?

        // Assume words never cross line boundaries: scan each line independently.
        let fullRange = NSRange(location: 0, length: nsText.length)
        nsText.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let lineStart = lineRange.location
            let lineEnd = NSMaxRange(lineRange)
            let lineLen = lineEnd - lineStart
            guard lineLen > 0 else { return }

            var coverage: [Int] = Array(repeating: 0, count: lineLen)
            coverage.reserveCapacity(lineLen)

            func bumpCoverage(localStart: Int, localEnd: Int) {
                guard localStart >= 0, localEnd <= lineLen, localEnd > localStart else { return }
                for idx in localStart..<localEnd {
                    coverage[idx] += 1
                }
            }

            // Iterate by composed character sequences to avoid starting inside surrogate pairs.
            var cursor = lineStart
            while cursor < lineEnd {
                let r = nsText.rangeOfComposedCharacterSequence(at: cursor)
                if r.length == 0 { break }
                let start = r.location

                // Skip obvious whitespace (within line).
                let ch = nsText.substring(with: r)
                if ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cursor = NSMaxRange(r)
                    continue
                }

                let ends = trie.allMatchEnds(in: nsText, from: start, requireKanji: false)
                for end in ends {
                    guard end <= lineEnd else { continue }
                    bumpCoverage(localStart: start - lineStart, localEnd: end - lineStart)
                }

                cursor = NSMaxRange(r)
            }

            if let lineMax = coverage.max() {
                globalMaxCoverage = max(globalMaxCoverage, lineMax)
            }
            for v in coverage {
                if v >= 2 { globalOverlapUnits += 1 }
            }

            if firstOverlapExampleRange == nil {
                var i = 0
                while i < coverage.count {
                    if coverage[i] >= 2 {
                        var j = i + 1
                        while j < coverage.count, coverage[j] >= 2 {
                            j += 1
                        }
                        firstOverlapExampleRange = NSRange(location: lineStart + i, length: j - i)
                        break
                    }
                    i += 1
                }
            }

            func maxCoverage(in utf16Range: NSRange) -> Int {
                let localStart = max(0, utf16Range.location - lineStart)
                let localEnd = min(lineLen, NSMaxRange(utf16Range) - lineStart)
                guard localEnd > localStart else { return 0 }
                var m = 0
                for idx in localStart..<localEnd {
                    m = max(m, coverage[idx])
                }
                return m
            }

            // Apply underline segments, grouped by composed character boundaries.
            var segCursor = lineStart
            var segStart = lineStart
            var segCount = 0
            var first = true

            while segCursor < lineEnd {
                let r = nsText.rangeOfComposedCharacterSequence(at: segCursor)
                if r.length == 0 { break }
                let c = maxCoverage(in: r)

                if first {
                    segStart = r.location
                    segCount = c
                    first = false
                } else if c != segCount {
                    if segCount > 0 {
                        let range = NSRange(location: segStart, length: segCursor - segStart)
                        if range.length > 0, NSMaxRange(range) <= mutable.length {
                            // Store coverage as an attribute and let the renderer decide
                            // how to visualize it (e.g. circled/outlined spans).
                            mutable.addAttribute(DebugDictionaryHighlighting.coverageLevelAttribute, value: segCount, range: range)
                        }
                    }
                    segStart = r.location
                    segCount = c
                }

                segCursor = NSMaxRange(r)
            }

            if first == false, segCount > 0 {
                let range = NSRange(location: segStart, length: lineEnd - segStart)
                if range.length > 0, NSMaxRange(range) <= mutable.length {
                    mutable.addAttribute(DebugDictionaryHighlighting.coverageLevelAttribute, value: segCount, range: range)
                }
            }
        }

        #if DEBUG
        // Print a short summary so we can confirm whether overlaps are being produced at all.
        // This is intentionally very low-noise and deduped.
        let fingerprint = text.hashValue ^ (globalMaxCoverage << 8) ^ globalOverlapUnits
        if lastDebugDictionaryCoverageLogFingerprint != fingerprint {
            lastDebugDictionaryCoverageLogFingerprint = fingerprint
            if globalMaxCoverage <= 1 {
                print("DebugDictionaryHighlighting: maxCoverage=1 (no overlaps detected), overlapUnits=0")
            } else {
                if let r = firstOverlapExampleRange, r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= nsText.length {
                    let raw = nsText.substring(with: r)
                    let sample = raw.count > 24 ? String(raw.prefix(24)) + "…" : raw
                    print("DebugDictionaryHighlighting: maxCoverage=\(globalMaxCoverage), overlapUnits=\(globalOverlapUnits), example=\(sample) r=\(r.location)-\(NSMaxRange(r))")
                } else {
                    print("DebugDictionaryHighlighting: maxCoverage=\(globalMaxCoverage), overlapUnits=\(globalOverlapUnits)")
                }
            }
        }
        #endif

        return mutable
    }

    private static func mergeAdjacentSemanticSpansIfValid(
        text: String,
        spans: [SemanticSpan],
        hardCuts: [Int],
        context: String
    ) async -> [SemanticSpan] {
        guard spans.count >= 2 else { return spans }

        let traceEnabled: Bool = {
    #if DEBUG
            return true
    #else
            return ProcessInfo.processInfo.environment["PIPELINE_TRACE"] == "1" || UserDefaults.standard.bool(forKey: "debugPipelineTrace")
    #endif
        }()

        // Only attempt lexicon validation if the in-memory trie is already warm.
        // This must not trigger bootstrap work or touch SQLite.
        let trie = await SegmentationService.shared.cachedTrieIfAvailable()
        guard let trie else { return spans }

        let nsText = text as NSString
        let hardCutSet = Set(hardCuts)

        func canJoinBoundary(at utf16Offset: Int) -> Bool {
            // Respect explicit user boundaries.
            if hardCutSet.contains(utf16Offset) { return false }
            return true
        }

        func mergedSourceSpanIndices(_ a: Range<Int>, _ b: Range<Int>) -> Range<Int> {
            let lower = min(a.lowerBound, b.lowerBound)
            let upper = max(a.upperBound, b.upperBound)
            return lower..<upper
        }

        func describeSemanticSpans(_ value: [SemanticSpan]) -> String {
            value.enumerated().map { idx, span in
                let start = span.range.location
                let end = NSMaxRange(span.range)
                let reading = span.readingKana ?? "-"
                return "\(idx): \(start)-\(end) «\(span.surface)» src=\(span.sourceSpanIndices.lowerBound)..<\(span.sourceSpanIndices.upperBound) r=\(reading)"
            }.joined(separator: "\n")
        }

        // Heuristic: allow merges that form common auxiliary verb chains
        // (even if the whole surface is not a standalone lexicon entry).
        // This targets tail-end over-segmentation like: 見て + いる -> 見ている.
        // Keep it conservative: no whitespace/punctuation, capped length.
        let auxiliarySuffixes: [String] = [
            "ている", "でいる", "てた", "でた", "ていた", "でいた", "てました", "でました", "てます", "でます", "ています", "でいます", "ていました", "でいました",
            "てしまう", "てしまった", "てしまいます", "てしまいました",
            "ておく", "ておいた", "ておきます", "ておきました",
            "てみる", "てみた", "てみます", "てみました",
            "てくる", "てきた", "てきます", "てきました",
            "ていく", "ていった", "ていきます", "ていきました",
            "てください"
        ]

        func isHeuristicallyMergeableSurface(_ surface: String, candidateUtf16Length: Int) -> Bool {
            if candidateUtf16Length <= 0 { return false }
            if candidateUtf16Length > 24 { return false }
            if surface.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }

            // Heuristic merges are intended for verb+auxiliary chains (e.g. 見て+いた→見ていた),
            // not for collapsing multi-word phrases that merely *end* with an auxiliary suffix
            // (e.g. 何気なく+話していた). Guard by rejecting surfaces that contain multiple
            // kanji runs separated by kana.
            func hasMultipleKanjiRunsSeparatedByKana(_ s: String) -> Bool {
                var runCount = 0
                var inKanjiRun = false
                for scalar in s.unicodeScalars {
                    let isKanji = (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                    if isKanji {
                        if inKanjiRun == false {
                            runCount += 1
                            inKanjiRun = true
                            if runCount >= 2 {
                                return true
                            }
                        }
                    } else if (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value) {
                        // Kana breaks a kanji run.
                        inKanjiRun = false
                    } else {
                        // Non-kana (ASCII/punct/etc) does not by itself reset; leave state unchanged.
                    }
                }
                return false
            }

            if hasMultipleKanjiRunsSeparatedByKana(surface) {
                return false
            }

            // Avoid merging across punctuation/symbols with the heuristic.
            if surface.rangeOfCharacter(from: CharacterSet.punctuationCharacters.union(.symbols)) != nil {
                return false
            }

            return auxiliarySuffixes.contains { surface.hasSuffix($0) }
        }

        // Memoize expensive checks within this call.
        var surfaceIsMergeableCache: [String: Bool] = [:]
        surfaceIsMergeableCache.reserveCapacity(min(512, spans.count * 8))

        // Hot-path-safe normalization variants that help resolve common colloquial contractions
        // without calling MeCab or touching SQLite.
        //
        // Goal: allow deinflection + trie checks to succeed on surfaces like:
        // - じゃなくて -> ではなくて -> (deinflect) ではない
        func tailMergeContractionNormalize(_ surface: String) -> String {
            // じゃ is the common contraction of では.
            // We keep this intentionally narrow and best-effort.
            if surface.contains("じゃ") {
                return surface.replacingOccurrences(of: "じゃ", with: "では")
            }
            return surface
        }

        func tailMergeLexiconVariants(_ surface: String) -> [String] {
            var out: [String] = []
            out.reserveCapacity(4)

            func appendUnique(_ s: String) {
                guard s.isEmpty == false else { return }
                if out.contains(s) == false {
                    out.append(s)
                }
            }

            appendUnique(surface)

            let asciiNormalized = DictionaryKeyPolicy.normalizeFullWidthASCII(surface)
            if asciiNormalized != surface {
                appendUnique(asciiNormalized)
            }

            let contractionNormalized = tailMergeContractionNormalize(surface)
            if contractionNormalized != surface {
                appendUnique(contractionNormalized)
                let contractionAscii = DictionaryKeyPolicy.normalizeFullWidthASCII(contractionNormalized)
                if contractionAscii != contractionNormalized {
                    appendUnique(contractionAscii)
                }
            }

            return out
        }

        func isMergeableSurface(_ surface: String) async -> Bool {
            if let cached = surfaceIsMergeableCache[surface] { return cached }

            // Mirror dictionary normalization and also try a tiny set of contraction normalizations.
            let surfaceVariants = tailMergeLexiconVariants(surface)

            for v in surfaceVariants {
                if trie.containsWord(v, requireKanji: false) {
                    surfaceIsMergeableCache[surface] = true
                    return true
                }
            }

            // More aggressive: allow merges when the combined surface can deinflect
            // to a lexicon-valid base form. This is what enables merges like
            // "食べ"+"ました" -> "食べました" (then lookup deinflects to "食べる").
            //
            // Keep this lightweight by using a per-session cache and bounded outputs.
            for v in surfaceVariants {
                let candidates = await tailMergeDeinflectionCache.candidates(for: v, maxDepth: 6, maxResults: 24)
                for cand in candidates {
                    for baseVariant in tailMergeLexiconVariants(cand.baseForm) {
                        if trie.containsWord(baseVariant, requireKanji: false) {
                            surfaceIsMergeableCache[surface] = true
                            return true
                        }
                    }
                }
            }

            surfaceIsMergeableCache[surface] = false
            return false
        }

        // Greedy incremental merge: for each i, attempt to merge with i+1.
        // Track the longest mergeable concatenation, but keep scanning forward
        // as long as the current concatenation is still a *lexicon prefix*.
        // Stop only once the concatenation is neither mergeable nor a prefix.
        var out: [SemanticSpan] = []
        out.reserveCapacity(spans.count)

        var mergedRuns = 0

        var i = 0
        while i < spans.count {
            let start = spans[i]
            if i == spans.count - 1 {
                out.append(start)
                break
            }

            // Disallow merging if the current span is degenerate.
            if start.range.location == NSNotFound || start.range.length <= 0 {
                out.append(start)
                i += 1
                continue
            }

            let startLoc = start.range.location
            var bestEndExclusive: Int? = nil
            var bestRange: NSRange? = nil
            var bestReading: String? = nil
            var bestSourceIndices: Range<Int>? = nil

            var currentEnd = NSMaxRange(start.range)
            var currentReading = start.readingKana
            var currentIndices = start.sourceSpanIndices

            // Cap lookahead using trie max word length.
            let maxUtf16Len = trie.maxLexiconWordLength

            var j = i + 1
            while j < spans.count {
                let next = spans[j]
                guard next.range.location != NSNotFound, next.range.length > 0 else { break }

                // Topic particle guard:
                // Do not merge a standalone 「は」 into the previous semantic span.
                // This is important for token selection + dictionary lookup, since PasteView
                // uses semantic spans as token spans when available.
                if next.surface == "は" {
                    let leftSurface = spans[j - 1].surface
                    if leftSurface != "で" && leftSurface != "て" {
                        break
                    }
                }

                // Case-particle guard for tail-merge heuristics:
                // Avoid collapsing noun/counter + で + (aux) into one semantic span (e.g. 二人でいた).
                // Allow verb te-form patterns like 読ん + で + いた / 泳い + で + いた.
                if next.surface == "で" {
                    let leftSurface = spans[j - 1].surface
                    if leftSurface.hasSuffix("ん") == false && leftSurface.hasSuffix("い") == false {
                        break
                    }
                }

                // Must be contiguous.
                if currentEnd != next.range.location { break }

                // Respect explicit boundaries at the join.
                if canJoinBoundary(at: next.range.location) == false { break }

                let candidateEnd = NSMaxRange(next.range)
                let candidateLen = candidateEnd - startLoc
                if candidateLen > maxUtf16Len { break }

                let candidateRange = NSRange(location: startLoc, length: candidateLen)
                let candidateSurface = nsText.substring(with: candidateRange)
                if isEffectivelyEmptyTokenSurface(candidateSurface) {
                    break
                }

                // Reading: only preserve if all pieces have a reading.
                if let r = currentReading, let nr = next.readingKana {
                    currentReading = r + nr
                } else {
                    currentReading = nil
                }
                currentIndices = mergedSourceSpanIndices(currentIndices, next.sourceSpanIndices)

                let lexiconOk = await isMergeableSurface(candidateSurface)
                let heuristicOk = isHeuristicallyMergeableSurface(candidateSurface, candidateUtf16Length: candidateLen)
                if lexiconOk || heuristicOk {
                    bestEndExclusive = j + 1
                    bestRange = candidateRange
                    bestReading = currentReading
                    bestSourceIndices = currentIndices
                } else {
                    // Keep extending while the concatenation remains a lexicon prefix.
                    // This enables cases where intermediate concatenations are not valid words
                    // (e.g. inflected fragments) but can still lead to a later full hit.
                    var prefixOk = trie.hasPrefix(in: nsText, from: startLoc, through: candidateEnd)
                    if prefixOk == false {
                        // Try the same lightweight variant set used for mergeability.
                        for variant in tailMergeLexiconVariants(candidateSurface) {
                            if variant == candidateSurface { continue }
                            let nsVariant = variant as NSString
                            if trie.hasPrefix(in: nsVariant, from: 0, through: nsVariant.length) {
                                prefixOk = true
                                break
                            }
                        }
                    }

                    if prefixOk == false {
                        break
                    }
                }

                currentEnd = candidateEnd
                j += 1
            }

            if let endExclusive = bestEndExclusive,
               let range = bestRange,
               let sourceIndices = bestSourceIndices,
               endExclusive > i + 1 {
                let surface = nsText.substring(with: range)
                out.append(
                    SemanticSpan(
                        range: range,
                        surface: surface,
                        sourceSpanIndices: sourceIndices,
                        readingKana: bestReading
                    )
                )
                mergedRuns += 1
                i = endExclusive
            } else {
                out.append(start)
                i += 1
            }
        }

        let mergedSpansDelta = spans.count - out.count
        if traceEnabled, mergedSpansDelta > 0 {
            let full = "[PipelineTailMerge] runs=\(mergedRuns) delta=\(mergedSpansDelta) spans \(spans.count)->\(out.count) context=\(context)"
            CustomLogger.shared.debug(full)
            NSLog("%@", full)

            // User-requested: full post-pass dump.
            // Keep it on NSLog to avoid duplicating huge output in multiple sinks.
            NSLog("%@", "[PipelineTailMergeDump after] context=\(context)\n\(describeSemanticSpans(out))")
        }

        return out
    }

    private func stripRubyForKnownSemanticSpans(
        attributed: NSAttributedString,
        semanticSpans: [SemanticSpan],
        stage2Spans: [AnnotatedSpan],
        knownSurfaceKeys: Set<String>
    ) -> NSAttributedString {
        guard knownSurfaceKeys.isEmpty == false else { return attributed }
        guard semanticSpans.isEmpty == false else { return attributed }
        guard stage2Spans.isEmpty == false else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)

        func matchesKnown(for semantic: SemanticSpan) -> Bool {
            let surfaceKey = Self.foldKanaToHiragana(semantic.surface.trimmingCharacters(in: .whitespacesAndNewlines))
            if surfaceKey.isEmpty == false, knownSurfaceKeys.contains(surfaceKey) { return true }

            // Also consider lemma candidates from underlying Stage-2 spans.
            for idx in semantic.sourceSpanIndices {
                guard idx >= 0, idx < stage2Spans.count else { continue }
                for lemma in stage2Spans[idx].lemmaCandidates {
                    let key = Self.foldKanaToHiragana(lemma.trimmingCharacters(in: .whitespacesAndNewlines))
                    if key.isEmpty == false, knownSurfaceKeys.contains(key) {
                        return true
                    }
                }
            }
            return false
        }

        for semantic in semanticSpans {
            guard semantic.range.location != NSNotFound, semantic.range.length > 0 else { continue }
            guard matchesKnown(for: semantic) else { continue }

            mutable.removeAttribute(.furiganaAnnotation, range: semantic.range)
            mutable.removeAttribute(.furiganaReadingText, range: semantic.range)
            mutable.removeAttribute(.furiganaReadingFontSize, range: semantic.range)
        }

        return mutable.copy() as? NSAttributedString ?? attributed
    }

    private static func splitSemanticSpansOnLineBreaks(text: String, spans: [SemanticSpan]) -> [SemanticSpan] {
        guard spans.isEmpty == false else { return [] }
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        var out: [SemanticSpan] = []
        out.reserveCapacity(spans.count)

        for span in spans {
            guard span.range.location != NSNotFound, span.range.length > 0 else { continue }
            guard span.range.location < length else { continue }
            let end = min(length, NSMaxRange(span.range))
            guard end > span.range.location else { continue }
            let clamped = NSRange(location: span.range.location, length: end - span.range.location)

            var cursor = clamped.location
            var pieceStart = cursor

            while cursor < end {
                let r = nsText.rangeOfComposedCharacterSequence(at: cursor)
                if r.length == 0 { break }
                let s = nsText.substring(with: r)
                let isLineBreak = (s.rangeOfCharacter(from: .newlines) != nil)
                if isLineBreak {
                    if pieceStart < r.location {
                        let piece = NSRange(location: pieceStart, length: r.location - pieceStart)
                        let surface = nsText.substring(with: piece)
                        if isEffectivelyEmptyTokenSurface(surface) == false {
                            out.append(
                                SemanticSpan(
                                    range: piece,
                                    surface: surface,
                                    sourceSpanIndices: span.sourceSpanIndices,
                                    readingKana: nil
                                )
                            )
                        }
                    }
                    pieceStart = NSMaxRange(r)
                }
                cursor = NSMaxRange(r)
            }

            if pieceStart < end {
                let piece = NSRange(location: pieceStart, length: end - pieceStart)
                let surface = nsText.substring(with: piece)
                if isEffectivelyEmptyTokenSurface(surface) == false {
                    let reading = (piece == clamped) ? span.readingKana : nil
                    out.append(
                        SemanticSpan(
                            range: piece,
                            surface: surface,
                            sourceSpanIndices: span.sourceSpanIndices,
                            readingKana: reading
                        )
                    )
                }
            }
        }

        return out
    }
}
