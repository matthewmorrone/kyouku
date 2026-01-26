import Foundation

/// Embedding-based boundary scoring between tokenization and final token output.
///
/// This layer does NOT rewrite text. It only decides whether to keep or remove
/// existing boundaries by selecting among local candidates.
final class EmbeddingBoundaryScorer: @unchecked Sendable {
    struct Configuration {
        /// Number of tokens to consider on each side (2–5 total window implied).
        var windowRadius: Int = 2
        /// If merge vs keep scores are within epsilon, preserve the original boundary.
        var tieEpsilon: Float = 0.03

        // Scoring weights (embedding-derived signals only).
        var surpriseWeight: Float = 1.0
        var cohesionWeight: Float = 0.7
        var centroidWeight: Float = 0.6

        // Similarity floor for surprise penalty; lower similarity increases penalty.
        var lowSimilarityFloor: Float = 0.15

        init() {}
    }

    private let config: Configuration

    init(config: Configuration = Configuration()) {
        self.config = config
    }

    /// Refines Stage-1 spans by selecting a best-cover over token-aligned candidate spans.
    ///
    /// Key rule: candidate surfaces MUST be derived by slicing `text` using token ranges.
    /// Do NOT construct candidate strings by concatenation or rewriting.
    ///
    /// Dictionary-aware eligibility (REQUIRED):
    /// - A candidate span is eligible if it exists as a JMdict surface-form entry OR
    ///   it exists in the embeddings table.
    /// - IMPORTANT: embedding existence is NOT a gate. Missing embeddings must NOT
    ///   disqualify a dictionary-valid span.
    ///
    /// Structural hard stops (REQUIRED):
    /// - Never generate or score spans that cross punctuation, whitespace/newlines,
    ///   sentence boundaries, or user hard cuts (`hardCuts`).
    func refine(text: NSString, spans: [TextSpan], hardCuts: [Int], access: EmbeddingAccess, trie: LexiconTrie?) -> [TextSpan] {
        guard spans.count >= 2 else {
            return spans.map { s in
                TextSpan(range: s.range, surface: text.substring(with: s.range), isLexiconMatch: s.isLexiconMatch)
            }
        }

        let traceEnabled: Bool = {
            ProcessInfo.processInfo.environment["EMBED_BOUNDARY_TRACE"] == "1"
        }()

        let cutSet = Set(hardCuts)

        func isHardStopToken(surface: String) -> Bool {
            if surface.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
                return true
            }
            if surface.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }) {
                return true
            }
            return false
        }

        func isContiguous(_ a: TextSpan, _ b: TextSpan) -> Bool {
            NSMaxRange(a.range) == b.range.location
        }

        func crossesHardCut(endOfTokenAt leftIndex: Int) -> Bool {
            let cutPos = NSMaxRange(spans[leftIndex].range)
            return cutSet.contains(cutPos)
        }

        // Dictionary existence check via the already-loaded in-memory trie.
        // IMPORTANT: this is used for ELIGIBILITY only; embedding existence is NOT a gate.

        struct Candidate {
            let start: Int
            let end: Int
            let range: NSRange
            let surface: String
            let inDictionary: Bool
            var inEmbeddings: Bool

            var length: Int { end - start + 1 }
            var eligible: Bool { inDictionary || inEmbeddings }
        }

        let maxTokens = 4
        var candidatesByStart: [[Candidate]] = Array(repeating: [], count: spans.count)
        var allSurfaces: [String] = []
        allSurfaces.reserveCapacity(spans.count * 2)
        var seenSurface: Set<String> = []
        seenSurface.reserveCapacity(spans.count * 2)

        var blockedNonContiguous = 0
        var blockedHardCut = 0
        var blockedHardStop = 0
        var prunedIneligible = 0
        var cohesionPairsScored: Int = 0

        // Candidate generation: for each i, generate [i..i], [i..i+1], [i..i+2], [i..i+3]
        // without crossing hard stops or user cuts. Surfaces are sliced from `text`.
        for i in 0..<spans.count {
            let tokenSurface = text.substring(with: spans[i].range)
            let tokenInDict = trie?.containsWord(tokenSurface, requireKanji: false) ?? false
            let single = Candidate(start: i, end: i, range: spans[i].range, surface: tokenSurface, inDictionary: tokenInDict, inEmbeddings: false)
            candidatesByStart[i].append(single)
            if seenSurface.insert(tokenSurface).inserted { allSurfaces.append(tokenSurface) }

            // Do not attempt multi-token spans starting at a hard-stop token.
            if isHardStopToken(surface: tokenSurface) { continue }

            var currentRange = spans[i].range
            var j = i
            while (j + 1) < spans.count && (j - i + 1) < maxTokens {
                guard isContiguous(spans[j], spans[j + 1]) else {
                    blockedNonContiguous += 1
                    break
                }
                guard crossesHardCut(endOfTokenAt: j) == false else {
                    blockedHardCut += 1
                    break
                }

                let nextSurface = text.substring(with: spans[j + 1].range)
                if isHardStopToken(surface: nextSurface) {
                    blockedHardStop += 1
                    break
                }

                j += 1
                currentRange = NSUnionRange(currentRange, spans[j].range)
                let surface = text.substring(with: currentRange)
                let inDict = trie?.containsWord(surface, requireKanji: false) ?? false
                let cand = Candidate(start: i, end: j, range: currentRange, surface: surface, inDictionary: inDict, inEmbeddings: false)
                candidatesByStart[i].append(cand)
                if seenSurface.insert(surface).inserted { allSurfaces.append(surface) }
            }
        }

        // Batch check embeddings existence for all candidate surfaces.
        let vectors = access.vectors(for: allSurfaces)
        let hasEmbedding: (String) -> Bool = { vectors[$0] != nil }

        // Apply embedding eligibility and prune multi-token candidates that are not eligible.
        for i in 0..<candidatesByStart.count {
            var filtered: [Candidate] = []
            filtered.reserveCapacity(candidatesByStart[i].count)
            for var c in candidatesByStart[i] {
                c.inEmbeddings = hasEmbedding(c.surface)

                if c.length == 1 {
                    filtered.append(c)
                    continue
                }

                // Multi-token spans are only considered if eligible.
                // IMPORTANT: embedding existence is NOT required if the dictionary contains the span.
                // If the trie is unavailable, do NOT prune: we must not reject a dictionary span
                // just because we cannot consult the dictionary.
                if trie == nil {
                    filtered.append(c)
                } else if c.eligible {
                    filtered.append(c)
                } else {
                    prunedIneligible += 1
                }
            }
            candidatesByStart[i] = filtered
        }

        // Token vectors for cohesion ranking.
        let uniqueTokenSurfaces = Array(Set(spans.map { text.substring(with: $0.range) }))
        let tokenVectors = access.vectors(for: uniqueTokenSurfaces)
        func tokenVec(_ surface: String) -> [Float]? { tokenVectors[surface] }

        func cohesionScore(for c: Candidate) -> Float {
            guard c.length > 1 else { return 0 }
            var sum: Float = 0
            var count: Float = 0
            var k = c.start
            while k < c.end {
                let aSurf = text.substring(with: spans[k].range)
                let bSurf = text.substring(with: spans[k + 1].range)
                if let a = tokenVec(aSurf), let b = tokenVec(bSurf) {
                    sum += EmbeddingMath.cosineSimilarity(a: a, b: b)
                    count += 1
                    cohesionPairsScored += 1
                }
                k += 1
            }
            return (count > 0) ? (sum / count) : 0
        }

        func candidateCost(_ c: Candidate) -> Float {
            // Lower is better.
            var cost: Float = 0

            // Prefer lexically valid spans.
            if c.inDictionary {
                cost -= 10
            } else if c.inEmbeddings {
                cost -= 2
            }

            if c.length > 1 {
                // Merge penalty ensures "close" cases keep the original segmentation.
                cost += 0.25 * Float(c.length - 1)
                // Semantic scoring is ranking only (never gating).
                cost -= config.cohesionWeight * cohesionScore(for: c)
            }
            return cost
        }

        // DP best-cover selection.
        let n = spans.count
        var dp: [Float] = Array(repeating: Float.greatestFiniteMagnitude, count: n + 1)
        var choiceLen: [Int] = Array(repeating: 1, count: n)
        dp[n] = 0

        for i in stride(from: n - 1, through: 0, by: -1) {
            var bestScore = Float.greatestFiniteMagnitude
            var bestLen = 1

            for c in candidatesByStart[i] {
                let next = i + c.length
                guard next <= n else { continue }
                let score = candidateCost(c) + dp[next]
                if score < bestScore {
                    bestScore = score
                    bestLen = c.length
                } else if abs(score - bestScore) <= config.tieEpsilon {
                    // Preserve original tokenization when scores are close.
                    if bestLen != 1 && c.length == 1 {
                        bestLen = 1
                    } else if c.length < bestLen {
                        bestLen = c.length
                    }
                }
            }

            dp[i] = bestScore
            choiceLen[i] = bestLen
        }

        // Reconstruct output spans.
        var out: [TextSpan] = []
        out.reserveCapacity(spans.count)
        var idx = 0
        var mergedSpans = 0
        let start = CFAbsoluteTimeGetCurrent()

        while idx < n {
            let len = max(1, choiceLen[idx])
            let end = min(n - 1, idx + len - 1)
            let r = NSUnionRange(spans[idx].range, spans[end].range)
            let surface = text.substring(with: r)
            let inDict = trie?.containsWord(surface, requireKanji: false) ?? false
            let isLex = (len == 1) ? spans[idx].isLexiconMatch : inDict
            out.append(TextSpan(range: r, surface: surface, isLexiconMatch: isLex))
            if len > 1 { mergedSpans += 1 }
            idx += len
        }

        if traceEnabled {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let msText = String(format: "%.2f", ms)
            CustomLogger.shared.info(
                "EmbeddingBoundaryScorer(DP): in=\(spans.count) out=\(out.count) mergedSpans=\(mergedSpans) uniqueSurfaces=\(allSurfaces.count) trie=\(trie == nil ? "nil" : "ok") blocked(nonContig=\(blockedNonContiguous) hardCut=\(blockedHardCut) hardStop=\(blockedHardStop)) prunedIneligible=\(prunedIneligible) cohesionPairs=\(cohesionPairsScored) ms=\(msText)"
            )
        }

        return out
    }

    // MARK: - Scoring

    /// Scores the local neighborhood for the original boundary A | B.
    private func scoreLocal(
        keepLeft a: TextSpan,
        keepRight b: TextSpan,
        spans: [TextSpan],
        boundaryIndex i: Int,
        vec: (String) -> [Float]?
    ) -> Float? {
        guard let va = vec(a.surface), let vb = vec(b.surface) else {
            return nil
        }

        // (A) Boundary surprise penalty: low similarity at A|B is penalized.
        let simAB = EmbeddingMath.cosineSimilarity(a: va, b: vb)
        let surprisePenalty = max(0, config.lowSimilarityFloor - simAB)

        // (C) Centroid stability: compare centroid of a small window before and after the boundary.
        let centroidSim = centroidSimilarityAroundBoundary(leftIndex: i, rightIndex: i + 1, spans: spans, vec: vec)

        // Keep candidate has no cohesion term (no merge).
        let score =
            (-config.surpriseWeight * surprisePenalty) +
            (config.centroidWeight * centroidSim)

        return score
    }

    /// Scores the local neighborhood when merging AB.
    private func scoreLocalMerged(
        merged ab: TextSpan,
        leftPart a: TextSpan,
        rightPart b: TextSpan,
        spans: [TextSpan],
        boundaryIndex i: Int,
        vec: (String) -> [Float]?
    ) -> Float? {
        let vab: [Float]
        if let direct = vec(ab.surface) {
            vab = direct
        } else if let va = vec(a.surface), let vb = vec(b.surface) {
            // Many concatenated surfaces will not exist in the embedding vocabulary.
            // Fall back to a derived merged vector computed from the parts (embedding-derived only).
            vab = derivedMergedVector(va: va, vb: vb)
        } else {
            return nil
        }

        // Build the local token list for scoring: replace A,B with AB.
        // This remains local and bounded.
        let leftStart = max(0, i - config.windowRadius)
        let rightEnd = min(spans.count, (i + 2) + config.windowRadius)

        var local: [TextSpan] = []
        local.reserveCapacity(rightEnd - leftStart)

        var j = leftStart
        while j < rightEnd {
            if j == i {
                local.append(ab)
                j += 2
                continue
            }
            local.append(spans[j])
            j += 1
        }

        // (A) Surprise penalty: sum penalties for adjacent boundaries inside the local window.
        var surprisePenaltySum: Float = 0
        if local.count >= 2 {
            for k in 0..<(local.count - 1) {
                let l = local[k]
                let r = local[k + 1]
                guard let vl = vec(l.surface), let vr = vec(r.surface) else { continue }
                let sim = EmbeddingMath.cosineSimilarity(a: vl, b: vr)
                surprisePenaltySum += max(0, config.lowSimilarityFloor - sim)
            }
        }

        // (B) Token cohesion: merged token should align with its constituents.
        var cohesion: Float = 0
        if let va = vec(a.surface), let vb = vec(b.surface) {
            let simA = EmbeddingMath.cosineSimilarity(a: vab, b: va)
            let simB = EmbeddingMath.cosineSimilarity(a: vab, b: vb)
            let simParts = EmbeddingMath.cosineSimilarity(a: va, b: vb)
            // Prefer merges where AB is closer to both parts than the parts are to each other.
            cohesion = (0.5 * (simA + simB)) - simParts
        }

        // (C) Centroid stability: similarity between centroid of left-half and right-half of the local window.
        let centroidSim = centroidSimilarityForLocalWindow(local: local, splitAt: localFirstIndex(of: ab, in: local), vec: vec)

        let score =
            (-config.surpriseWeight * surprisePenaltySum) +
            (config.cohesionWeight * cohesion) +
            (config.centroidWeight * centroidSim)

        return score
    }

    private func localFirstIndex(of span: TextSpan, in local: [TextSpan]) -> Int {
        for (idx, s) in local.enumerated() {
            if s.range.location == span.range.location && s.range.length == span.range.length && s.surface == span.surface {
                return idx
            }
        }
        return max(0, local.count / 2)
    }

    /// Computes centroid similarity around an original boundary (leftIndex | rightIndex).
    ///
    /// Centroids are computed from available vectors only. If one side has no vectors, returns 0.
    private func centroidSimilarityAroundBoundary(
        leftIndex: Int,
        rightIndex: Int,
        spans: [TextSpan],
        vec: (String) -> [Float]?
    ) -> Float {
        let leftStart = max(0, leftIndex - config.windowRadius + 1)
        let leftEnd = leftIndex + 1
        let rightStart = rightIndex
        let rightEnd = min(spans.count, rightIndex + config.windowRadius)

        let left = Array(spans[leftStart..<leftEnd])
        let right = Array(spans[rightStart..<rightEnd])
        return centroidCosine(left: left, right: right, vec: vec)
    }

    /// Computes centroid similarity for a local window split around `splitAt`.
    private func centroidSimilarityForLocalWindow(
        local: [TextSpan],
        splitAt: Int,
        vec: (String) -> [Float]?
    ) -> Float {
        guard local.isEmpty == false else { return 0 }
        let leftEnd = max(0, min(local.count, splitAt + 1))
        let rightStart = min(local.count, leftEnd)
        let left = Array(local[0..<leftEnd])
        let right = Array(local[rightStart..<local.count])
        return centroidCosine(left: left, right: right, vec: vec)
    }

    /// Computes cosine similarity between normalized centroids of two token lists.
    ///
    /// Uses canonical cosineSimilarity() only after normalizing the centroid buffers.
    private func centroidCosine(
        left: [TextSpan],
        right: [TextSpan],
        vec: (String) -> [Float]?
    ) -> Float {
        let dim = 300
        var leftBuf = Array<Float>(repeating: 0, count: dim)
        var rightBuf = Array<Float>(repeating: 0, count: dim)

        var leftCount: Float = 0
        for s in left {
            guard let v = vec(s.surface) else { continue }
            assert(v.count == dim)
            for i in 0..<dim { leftBuf[i] += v[i] }
            leftCount += 1
        }

        var rightCount: Float = 0
        for s in right {
            guard let v = vec(s.surface) else { continue }
            assert(v.count == dim)
            for i in 0..<dim { rightBuf[i] += v[i] }
            rightCount += 1
        }

        guard leftCount > 0, rightCount > 0 else {
            return 0
        }

        // Normalize centroid buffers (safe: these are derived scratch vectors).
        normalizeInPlace(&leftBuf)
        normalizeInPlace(&rightBuf)

        return EmbeddingMath.cosineSimilarity(a: leftBuf, b: rightBuf)
    }

    private func normalizeInPlace(_ v: inout [Float]) {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return }
        let inv = 1 / norm
        for i in 0..<v.count { v[i] *= inv }
    }

    private func derivedMergedVector(va: [Float], vb: [Float]) -> [Float] {
        let dim = 300
        assert(va.count == dim)
        assert(vb.count == dim)

        var out = Array<Float>(repeating: 0, count: dim)
        for i in 0..<dim {
            out[i] = 0.5 * (va[i] + vb[i])
        }
        normalizeInPlace(&out)
        return out
    }
}
