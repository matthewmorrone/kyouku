import SwiftUI
import UIKit
import Foundation

extension PasteView {
    func updateSentenceHeatmapSelection(for selectedRange: NSRange?) {
        guard let base = furiganaAttributedTextBase else {
            // Rendering not ready yet; just record state.
            sentenceHeatmapSelectedIndex = nil
            return
        }

        guard let selectedRange, sentenceRanges.isEmpty == false else {
            sentenceHeatmapSelectedIndex = nil
            furiganaAttributedText = base
            return
        }

        let idx = sentenceRanges.firstIndex(where: { NSLocationInRange(selectedRange.location, $0) })
        if idx == sentenceHeatmapSelectedIndex {
            return
        }

        sentenceHeatmapSelectedIndex = idx
        if idx == nil {
            furiganaAttributedText = base
        } else {
            furiganaAttributedText = applySentenceHeatmap(to: base)
        }
    }

    func startSentenceHeatmapPrecomputeIfPossible(text: String, spans: [AnnotatedSpan]?) {
        guard Self.sentenceHeatmapEnabledFlag else {
            sentenceHeatmapTask?.cancel()
            sentenceVectors = []
            sentenceRanges = []
            clearSentenceHeatmap()
            return
        }

        let nsText = text as NSString
        let ranges = SentenceRangeResolver.sentenceRanges(in: nsText)
        sentenceRanges = ranges

        // Do not infer heatmap selection from the current selection range; that makes
        // dictionary taps paint background blocks across other tokens.
        if sentenceHeatmapSelectedIndex == nil, let base = furiganaAttributedTextBase {
            furiganaAttributedText = base
        }

        guard let spans, spans.isEmpty == false, ranges.isEmpty == false else {
            sentenceVectors = []
            return
        }

        sentenceHeatmapTask?.cancel()
        let capturedRanges = ranges
        let capturedSpans = spans
        sentenceHeatmapTask = Task(priority: .utility) {
            // Resolve EmbeddingAccess safely.
            let access = await MainActor.run(resultType: EmbeddingAccess.self, body: { EmbeddingAccess.shared })

            // Bucket spans by sentence.
            var tokenBuckets: [[EmbeddingToken]] = Array(repeating: [], count: capturedRanges.count)
            tokenBuckets.reserveCapacity(capturedRanges.count)

            var sentenceIndex = 0
            for s in capturedSpans {
                let r = s.span.range
                guard r.location != NSNotFound, r.length > 0 else { continue }

                // Fast path: spans are typically in ascending order.
                if sentenceIndex < capturedRanges.count {
                    while sentenceIndex < capturedRanges.count,
                          NSMaxRange(capturedRanges[sentenceIndex]) <= r.location {
                        sentenceIndex += 1
                    }
                }

                let resolvedSentenceIndex: Int?
                if sentenceIndex < capturedRanges.count,
                   NSLocationInRange(r.location, capturedRanges[sentenceIndex]) {
                    resolvedSentenceIndex = sentenceIndex
                } else {
                    // Fallback (should be rare): handle out-of-order spans.
                    resolvedSentenceIndex = capturedRanges.firstIndex(where: { NSLocationInRange(r.location, $0) })
                }

                guard let sentenceIndex = resolvedSentenceIndex else { continue }
                let lemma = s.lemmaCandidates.first
                let token = EmbeddingToken(surface: s.span.surface, lemma: lemma, reading: s.readingKana)
                tokenBuckets[sentenceIndex].append(token)
            }

            // Collect all unique candidate keys for batch fetch.
            var unique: [String] = []
            unique.reserveCapacity(capturedSpans.count * 2)
            var seen: Set<String> = []
            seen.reserveCapacity(capturedSpans.count * 2)

            let perSentenceCandidates: [[[String]]] = tokenBuckets.map { bucket in
                bucket.map { EmbeddingFallbackPolicy.candidates(for: $0) }
            }

            for sentence in perSentenceCandidates {
                for tokenCandidates in sentence {
                    for c in tokenCandidates {
                        if c.isEmpty { continue }
                        if seen.insert(c).inserted {
                            unique.append(c)
                        }
                    }
                }
            }

            let fetched = access.vectors(for: unique)

            func normalize(_ v: [Float]) -> [Float] {
                var sum: Float = 0
                for x in v { sum += x * x }
                let norm = sum.squareRoot()
                guard norm > 0 else { return v }
                return v.map { $0 / norm }
            }

            var vectors: [[Float]?] = Array(repeating: nil, count: capturedRanges.count)

            for (i, sentence) in perSentenceCandidates.enumerated() {
                var acc: [Float]? = nil
                var count: Float = 0
                for tokenCandidates in sentence {
                    var chosen: [Float]? = nil
                    for c in tokenCandidates {
                        if let v = fetched[c] {
                            chosen = v
                            break
                        }
                    }
                    guard let vec = chosen else { continue }

                    if acc == nil {
                        acc = Array(repeating: 0, count: vec.count)
                    }
                    guard var a = acc else { continue }
                    for j in 0..<vec.count {
                        a[j] += vec[j]
                    }
                    acc = a
                    count += 1
                }

                if let acc, count > 0 {
                    let mean = acc.map { $0 / count }
                    vectors[i] = normalize(mean)
                }
            }

            await MainActor.run {
                guard Task.isCancelled == false else { return }
                sentenceVectors = vectors
                // Re-apply heatmap with fresh vectors if a selection is active.
                if let base = furiganaAttributedTextBase {
                    furiganaAttributedText = applySentenceHeatmap(to: base)
                }
            }
        }
    }

    func applySentenceHeatmap(to base: NSAttributedString?) -> NSAttributedString? {
        guard let base else { return nil }
        guard Self.sentenceHeatmapEnabledFlag else { return base }
        // Heatmap is a semantic exploration visual; don't show it during dictionary popup.
        guard tokenSelection == nil else { return base }
        guard let selectedIndex = sentenceHeatmapSelectedIndex else { return base }
        guard sentenceRanges.isEmpty == false, sentenceVectors.count == sentenceRanges.count else { return base }
        guard sentenceVectors.indices.contains(selectedIndex), let selectedVec = sentenceVectors[selectedIndex] else { return base }

        // Compute similarities (dot product) and map to background colors.
        var sims: [Float] = Array(repeating: 0, count: sentenceRanges.count)
        for i in 0..<sentenceRanges.count {
            guard let v = sentenceVectors[i] else {
                sims[i] = 0
                continue
            }
            sims[i] = EmbeddingMath.cosineSimilarity(a: selectedVec, b: v)
        }

        let mutable = NSMutableAttributedString(attributedString: base)
        // Remove any existing heatmap backgrounds (only within sentence ranges).
        for r in sentenceRanges {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= mutable.length else { continue }
            mutable.removeAttribute(.backgroundColor, range: r)
        }

        func clamp01(_ x: Float) -> CGFloat {
            CGFloat(max(0, min(1, x)))
        }

        func heatColor(sim: Float, isSelected: Bool) -> UIColor {
            // Convert [-1,1] -> [0,1], but we mostly expect [0,1].
            let t = clamp01((sim + 1) * 0.5)
            // Low similarity = light gray; high similarity = warm.
            let baseGray = UIColor.systemGray5
            let warm = UIColor.systemOrange

            let alpha: CGFloat = isSelected ? 0.28 : (0.04 + 0.18 * t)
            return blend(base: baseGray, top: warm, t: t).withAlphaComponent(alpha)
        }

        for i in 0..<sentenceRanges.count {
            let r = sentenceRanges[i]
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= mutable.length else { continue }
            let color = heatColor(sim: sims[i], isSelected: i == selectedIndex)
            mutable.addAttribute(.backgroundColor, value: color, range: r)
        }

        return mutable
    }

    func clearSentenceHeatmap() {
        sentenceHeatmapSelectedIndex = nil
        if let base = furiganaAttributedTextBase {
            furiganaAttributedText = base
        }
    }

    struct LiveSemanticFeedback: Equatable {
        let previousSimilarity: Float?
        let paragraphSimilarity: Float?
        let displaySentenceIndex: Int
    }

    func scheduleLiveSemanticFeedbackIfNeeded() {
        guard isEditing else { return }
        guard incrementalLookupEnabled == false else {
            liveSemanticFeedback = nil
            return
        }

        liveSemanticFeedbackTask?.cancel()

        let capturedText = inputText
        let capturedCaretRange = editorSelectedRange
        let capturedSentenceRanges = sentenceRanges
        let capturedSentenceVectors = sentenceVectors

        liveSemanticFeedbackTask = Task(priority: .utility) {
            // Debounce: don't run on every keystroke.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard Task.isCancelled == false else { return }

            let nsText = capturedText as NSString
            guard nsText.length > 0 else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard let caret = capturedCaretRange else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            let caretLoc = max(0, min(caret.location, max(0, nsText.length - 1)))

            let ranges: [NSRange] = capturedSentenceRanges.isEmpty
                ? SentenceRangeResolver.sentenceRanges(in: nsText)
                : capturedSentenceRanges

            guard ranges.isEmpty == false else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard let sentenceIndex = ranges.firstIndex(where: { NSLocationInRange(caretLoc, $0) }) else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard capturedSentenceVectors.count == ranges.count else {
                // Embeddings not ready for this text yet.
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard let current = capturedSentenceVectors[sentenceIndex] else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            let prevSim: Float? = {
                guard sentenceIndex > 0 else { return nil }
                guard let prev = capturedSentenceVectors[sentenceIndex - 1] else { return nil }
                return EmbeddingMath.cosineSimilarity(a: current, b: prev)
            }()

            let paragraph = paragraphRange(containingUTF16: caretLoc, in: nsText)
            let paraIndices = ranges.indices.filter { NSIntersectionRange(ranges[$0], paragraph).length > 0 }

            let paraSim: Float? = {
                // Exclude current sentence when possible.
                let withoutCurrent = paraIndices.filter { $0 != sentenceIndex }
                let source = withoutCurrent.isEmpty ? paraIndices : withoutCurrent
                guard source.count > 0 else { return nil }

                var acc: [Float]? = nil
                var count: Float = 0
                for idx in source {
                    guard let v = capturedSentenceVectors[idx] else { continue }
                    if acc == nil { acc = Array(repeating: 0, count: v.count) }
                    guard var a = acc else { continue }
                    for j in 0..<v.count { a[j] += v[j] }
                    acc = a
                    count += 1
                }
                guard let acc, count > 0 else { return nil }
                let mean = acc.map { $0 / count }
                var sum: Float = 0
                for x in mean { sum += x * x }
                let norm = sum.squareRoot()
                guard norm > 0 else { return nil }
                let centroid = mean.map { $0 / norm }
                return EmbeddingMath.cosineSimilarity(a: current, b: centroid)
            }()

            if prevSim == nil && paraSim == nil {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            let feedback = LiveSemanticFeedback(
                previousSimilarity: prevSim,
                paragraphSimilarity: paraSim,
                displaySentenceIndex: sentenceIndex
            )

            await MainActor.run {
                guard isEditing else { return }
                liveSemanticFeedback = feedback
            }
        }
    }

    private func blend(base: UIColor, top: UIColor, t: CGFloat) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let u = max(0, min(1, t))
        return UIColor(
            red: br + (tr - br) * u,
            green: bg + (tg - bg) * u,
            blue: bb + (tb - bb) * u,
            alpha: 1
        )
    }

    private func paragraphRange(containingUTF16 loc: Int, in text: NSString) -> NSRange {
        let n = text.length
        guard n > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = max(0, min(loc, n - 1))

        func isLineBreak(_ ch: unichar) -> Bool {
            ch == 0x000A || ch == 0x000D
        }

        // Paragraph boundaries are blank lines (two consecutive line breaks).
        var start = 0
        var i = clamped
        while i > 0 {
            let c0 = text.character(at: i)
            let c1 = text.character(at: i - 1)
            if isLineBreak(c0) && isLineBreak(c1) {
                start = i + 1
                break
            }
            i -= 1
        }

        var end = n
        i = clamped
        while i < n - 1 {
            let c0 = text.character(at: i)
            let c1 = text.character(at: i + 1)
            if isLineBreak(c0) && isLineBreak(c1) {
                end = i
                break
            }
            i += 1
        }

        if end < start { return NSRange(location: 0, length: n) }
        return NSRange(location: start, length: end - start)
    }
}
