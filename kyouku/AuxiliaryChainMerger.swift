import Foundation

/// Stage 1.25: AuxiliaryChainMerger
///
/// Merge-only structural pass that coalesces over-segmented auxiliary chains
/// (e.g. なり + たく + て, 光っ + て + る, 抱かれ + ながら) using MeCab/IPADic
/// POS metadata only.
///
/// Constraints:
/// - Pure in-memory (no trie / no SQLite).
/// - Merge-only: never splits, never reorders, preserves exact UTF-16 coverage.
/// - Respects `hardCuts` (user/token-locked boundaries) and never merges across them.
/// - Avoids surface-word lists; decisions come from MeCab POS feature strings.
struct AuxiliaryChainMerger {
    typealias MeCabAnnotation = SpanReadingAttacher.MeCabAnnotation

    struct Result {
        let spans: [TextSpan]
        let merges: Int
    }

    private struct MorphToken {
        let range: NSRange
        let surface: String
        let partOfSpeech: String

        private var fields: [String] {
            partOfSpeech
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        var coarsePOS: String {
            fields.first ?? partOfSpeech
        }

        var isVerb: Bool { coarsePOS == "動詞" }
        var isAdjective: Bool { coarsePOS == "形容詞" }
        var isAuxiliary: Bool { coarsePOS == "助動詞" }
        var isParticle: Bool { coarsePOS == "助詞" }

        var isNominalizer: Bool {
            coarsePOS == "名詞" && fields.contains("接尾")
        }

        /// Case particle boundary (格助詞) must not be crossed.
        var isCaseParticle: Bool {
            isParticle && fields.contains("格助詞")
        }

        /// Connective particle (接続助詞) is allowed inside auxiliary chains (e.g. て, ながら).
        var isConnectiveParticle: Bool {
            isParticle && fields.contains("接続助詞")
        }

        /// Boundary-sensitive particles should remain separable from the preceding token.
        /// Example: 気づいて + は should not be merged into 気づいては.
        var isBoundarySensitiveParticle: Bool {
            isParticle && (fields.contains("係助詞") || fields.contains("格助詞"))
        }

        /// True when IPADic marks this as bound / non-independent.
        var isNonIndependent: Bool {
            partOfSpeech.contains("非自立") || partOfSpeech.contains("接尾")
        }

        /// Aux-like follower tokens based on metadata (not surface lists).
        /// Includes:
        /// - auxiliaries (助動詞)
        /// - connective particles (接続助詞)
        /// - non-independent verbs/adjectives acting as grammatical followers (e.g. る/いる in てる/ている)
        var isAuxChainFollower: Bool {
            if isAuxiliary { return true }
            if isConnectiveParticle { return true }
            if (isVerb || isAdjective) && isNonIndependent { return true }
            return false
        }

        var isHardStopSurface: Bool {
            surface.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) ||
                surface.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) })
        }
    }

    static func apply(text: NSString, spans: [TextSpan], hardCuts: [Int], mecab: [MeCabAnnotation]) -> Result {
        guard spans.count >= 2 else { return Result(spans: spans, merges: 0) }

        // Opt-in diagnostics (must not affect behavior).
        let traceEnabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return env["STAGE125_TRACE"] == "1" || env["PIPELINE_TRACE"] == "1"
        }()

        func log(_ message: String) {
            guard traceEnabled else { return }
            let full = "[S1.25] \(message)"
            CustomLogger.shared.info(full)
            NSLog("%@", full)
        }

        let cutSet = Set(hardCuts)

        func isContiguous(_ a: NSRange, _ b: NSRange) -> Bool {
            NSMaxRange(a) == b.location
        }

        // Build a non-overlapping MeCab token stream.
        // Tokenizers can emit multiple candidate annotations that overlap; Stage 1.25 must
        // reason about a single, consistent token stream.
        var candidatesByStart: [Int: [MeCabAnnotation]] = [:]
        candidatesByStart.reserveCapacity(min(64, mecab.count))
        for a in mecab {
            guard a.range.location != NSNotFound, a.range.length > 0 else { continue }
            candidatesByStart[a.range.location, default: []].append(a)
        }
        for (k, list) in candidatesByStart {
            candidatesByStart[k] = list.sorted { lhs, rhs in
                if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
                return lhs.surface.count > rhs.surface.count
            }
        }

        let starts = candidatesByStart.keys.sorted()
        var tokens: [MorphToken] = []
        tokens.reserveCapacity(starts.count)
        var cursor = 0
        for start in starts {
            guard start >= cursor else { continue }
            guard let best = candidatesByStart[start]?.first else { continue }
            let tok = MorphToken(range: best.range, surface: best.surface, partOfSpeech: best.partOfSpeech)
            tokens.append(tok)
            cursor = NSMaxRange(best.range)
        }

        var boundaryPairs: [Int: (left: MorphToken, right: MorphToken)] = [:]
        boundaryPairs.reserveCapacity(tokens.count)

        // Range map for Condition B (authoritative single-token coverage).
        // Keyed by token start, valued by token end. If multiple tokens share a start, treat as ambiguous.
        var tokenEndByStart: [Int: Int] = [:]
        tokenEndByStart.reserveCapacity(tokens.count)

        // Token lookup for debug logs.
        var tokenByStart: [Int: MorphToken] = [:]
        tokenByStart.reserveCapacity(tokens.count)

        if tokens.count >= 2 {
            for idx in 1..<tokens.count {
                let left = tokens[idx - 1]
                let right = tokens[idx]
                guard isContiguous(left.range, right.range) else { continue }
                let boundary = right.range.location
                boundaryPairs[boundary] = (left: left, right: right)
            }
        }

        for tok in tokens {
            let start = tok.range.location
            let end = NSMaxRange(tok.range)
            tokenEndByStart[start] = end
            tokenByStart[start] = tok
        }

        // Helper: do not merge across a hard cut.
        func boundaryAllowed(_ boundary: Int) -> Bool {
            cutSet.contains(boundary) == false
        }

        // MERGE AUTHORITY B (NEW, REQUIRED):
        // If a single MeCab token range fully covers multiple adjacent spans, merge those spans.
        // This mostly overrides particle concerns: we trust MeCab's token coverage, but still respect hardCuts.
        // Exception: do not merge into boundary-sensitive particles (係助詞/格助詞) like は/を.
        func mergeByAuthoritativeMecabCoverage(_ spans: [TextSpan]) -> (spans: [TextSpan], merges: Int) {
            guard spans.count >= 2 else { return (spans, 0) }

            var out: [TextSpan] = []
            out.reserveCapacity(spans.count)

            var merges = 0
            var i = 0
            while i < spans.count {
                let start = spans[i].range.location
                guard let tokenEnd = tokenEndByStart[start] else {
                    out.append(spans[i])
                    i += 1
                    continue
                }

                func isBoundarySensitiveParticleSpanStart(_ start: Int) -> Bool {
                    guard let candidates = candidatesByStart[start], candidates.isEmpty == false else { return false }
                    // Consider any candidate starting here. If MeCab can interpret it as a binding particle,
                    // do not allow authoritative merges to swallow it.
                    return candidates.contains { a in
                        let tok = MorphToken(range: a.range, surface: a.surface, partOfSpeech: a.partOfSpeech)
                        return tok.isBoundarySensitiveParticle
                    }
                }

                func mergedRangeEndsWithBoundarySensitiveParticle(_ range: NSRange) -> Bool {
                    // If MeCab yields a boundary-sensitive particle token whose end aligns with the end
                    // of the proposed merged range, keep it separable (e.g. ...ては, ...では).
                    let end = NSMaxRange(range)
                    for a in mecab {
                        guard a.range.location != NSNotFound, a.range.length > 0 else { continue }
                        guard NSMaxRange(a.range) == end else { continue }
                        let tok = MorphToken(range: a.range, surface: a.surface, partOfSpeech: a.partOfSpeech)
                        if tok.isBoundarySensitiveParticle {
                            return true
                        }
                    }
                    return false
                }

                // Grow a contiguous union forward and see if it matches exactly this token range.
                var unionEnd = NSMaxRange(spans[i].range)
                var j = i
                var bestJ: Int? = nil

                while j < spans.count {
                    if unionEnd == tokenEnd, j > i {
                        bestJ = j
                    }
                    if unionEnd >= tokenEnd { break }
                    guard (j + 1) < spans.count else { break }

                    let boundary = NSMaxRange(spans[j].range)
                    guard boundaryAllowed(boundary) else { break }
                    guard isContiguous(spans[j].range, spans[j + 1].range) else { break }

                    // Do not merge into boundary-sensitive particles (係助詞/格助詞).
                    // This preserves spans like "気づいて" + "は".
                    let nextStart = spans[j + 1].range.location
                    if isBoundarySensitiveParticleSpanStart(nextStart) { break }

                    j += 1
                    unionEnd = NSMaxRange(spans[j].range)
                }

                if let bestJ {
                    let mergedRange = NSRange(location: start, length: tokenEnd - start)
                    if mergedRangeEndsWithBoundarySensitiveParticle(mergedRange) {
                        out.append(spans[i])
                        i += 1
                        continue
                    }
                    let surface = text.substring(with: mergedRange)
                    out.append(TextSpan(range: mergedRange, surface: surface, isLexiconMatch: false))
                    merges += 1
                    if let tok = tokenByStart[start] {
                        log("merge mecabCover POS=[\(tok.coarsePOS)] spans=\(i)-\(bestJ) range=\(mergedRange.location)-\(NSMaxRange(mergedRange))")
                    } else {
                        log("merge mecabCover POS=[?] spans=\(i)-\(bestJ) range=\(mergedRange.location)-\(NSMaxRange(mergedRange))")
                    }
                    i = bestJ + 1
                } else {
                    out.append(spans[i])
                    i += 1
                }
            }

            return (out, merges)
        }

        // MERGE AUTHORITY A (EXISTING BEHAVIOR, EXPANDED):
        // Merge auxiliary chains using MeCab POS metadata (verb/adjective heads plus bound followers).
        // This does not override particle concerns; it remains conservative and respects hardCuts.
        func mergeByAuxiliaryChains(_ spans: [TextSpan]) -> (spans: [TextSpan], merges: Int) {
            guard spans.count >= 2 else { return (spans, 0) }

            var out: [TextSpan] = []
            out.reserveCapacity(spans.count)

            var merges = 0
            var i = 0
            while i < spans.count {
                var mergedRange = spans[i].range
                var endIndex = i

                // Inflectional-merge invariant:
                // We only merge adjacent spans when their boundary aligns to a MeCab token boundary
                // and the POS metadata indicates a valid inflectional continuation (e.g. 動詞→助動詞,
                // 形容詞→接続助詞). This remains strictly range+POS based (no surface/dictionary rules)
                // and always respects `hardCuts`.
                var posSequence: [String] = []

                while (endIndex + 1) < spans.count {
                    let next = spans[endIndex + 1]
                    guard isContiguous(mergedRange, next.range) else { break }

                    let boundary = NSMaxRange(mergedRange)
                    guard boundaryAllowed(boundary) else { break }

                    guard let pair = boundaryPairs[boundary] else { break }
                    let leftTok = pair.left
                    let rightTok = pair.right

                    if leftTok.isHardStopSurface || rightTok.isHardStopSurface { break }

                    // Hard blocks (metadata-only):
                    // - do not cross case particles (格助詞)
                    // - do not cross nominalizer → particle edges (名詞,接尾 then 助詞)
                    if leftTok.isCaseParticle || rightTok.isCaseParticle { break }
                    if leftTok.isNominalizer && rightTok.isParticle { break }

                    func allowsInflectionalContinuation(left: MorphToken, right: MorphToken) -> Bool {
                        // Primary allowance: head → follower.
                        if (left.isVerb || left.isAdjective) && right.isAuxChainFollower { return true }
                        // Allow auxiliary stacking and connective→aux transitions.
                        if left.isAuxiliary && right.isAuxChainFollower { return true }
                        if left.isConnectiveParticle && (right.isAuxiliary || ((right.isVerb || right.isAdjective) && right.isNonIndependent)) { return true }
                        // Allow follower→follower inside a conjugation chain (e.g. っ + て + る).
                        if left.isAuxChainFollower && right.isAuxChainFollower { return true }
                        return false
                    }

                    guard allowsInflectionalContinuation(left: leftTok, right: rightTok) else { break }

                    if posSequence.isEmpty {
                        posSequence.append(leftTok.coarsePOS)
                    }
                    posSequence.append(rightTok.coarsePOS)

                    mergedRange = NSUnionRange(mergedRange, next.range)
                    endIndex += 1
                }

                if endIndex > i {
                    merges += 1
                    let surface = text.substring(with: mergedRange)
                    out.append(TextSpan(range: mergedRange, surface: surface, isLexiconMatch: false))
                    if posSequence.isEmpty == false {
                        let pos = posSequence.joined(separator: "+")
                        log("merge auxChain POS=[\(pos)] spans=\(i)-\(endIndex) range=\(mergedRange.location)-\(NSMaxRange(mergedRange))")
                    } else {
                        log("merge auxChain POS=[?] spans=\(i)-\(endIndex) range=\(mergedRange.location)-\(NSMaxRange(mergedRange))")
                    }
                    i = endIndex + 1
                } else {
                    out.append(spans[i])
                    i += 1
                }
            }

            return (out, merges)
        }

        // Apply merge authorities in order:
        // 1) Authoritative MeCab coverage merges (B)
        // 2) Auxiliary-chain merges (A)
        let b = mergeByAuthoritativeMecabCoverage(spans)
        let a = mergeByAuxiliaryChains(b.spans)
        return Result(spans: a.spans, merges: b.merges + a.merges)
    }
}
