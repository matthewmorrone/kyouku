import Foundation

/// DeinflectionHardStopMerger
///
/// Structural pre-pass used to lock spans BEFORE any embedding boundary refinement.
///
/// Mandatory behavior:
/// - If a token-aligned span has an exact JMdict surface hit OR any deinflected lemma has a JMdict hit,
///   the span is merged and then boundary-frozen via inserted hard cuts.
/// - This is deterministic and does not use embeddings.
enum DeinflectionHardStopMerger {
    struct Result {
        let spans: [TextSpan]
        /// Hard cut positions (UTF-16 indices) to prevent later stages from crossing locked boundaries.
        let addedHardCuts: [Int]
        /// Count of multi-token merges performed.
        let merges: Int
        /// Count of lemma-based locks (deinflection) performed.
        let deinflectionLocks: Int
    }

    static func apply(
        text: NSString,
        spans: [TextSpan],
        hardCuts: [Int],
        trie: LexiconTrie,
        deinflector: Deinflector,
        maxTokens: Int = 4
    ) -> Result {
        guard spans.count >= 2 else {
            return Result(spans: spans, addedHardCuts: [], merges: 0, deinflectionLocks: 0)
        }

        let traceEnabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return env["DEINFLECT_HARDSTOP_TRACE"] == "1" || env["EMBED_BOUNDARY_TRACE"] == "1"
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

        func crossesHardCut(_ union: NSRange) -> Bool {
            guard union.length > 0 else { return false }
            for c in cutSet {
                if c > union.location && c < NSMaxRange(union) {
                    return true
                }
            }
            return false
        }

        var out: [TextSpan] = []
        out.reserveCapacity(spans.count)

        var addedCuts: Set<Int> = []
        addedCuts.reserveCapacity(16)

        var merges = 0
        var deinflectionLocks = 0

        // Per-surface cache: does any deinflected lemma exist in dictionary?
        var lemmaHitCache: [String: (hit: Bool, lemma: String?)] = [:]
        lemmaHitCache.reserveCapacity(spans.count)

        func lemmaHit(for surface: String) -> (Bool, String?) {
            if let cached = lemmaHitCache[surface] { return (cached.hit, cached.lemma) }
            let cands = deinflector.deinflect(surface, maxDepth: 8, maxResults: 32)
            for c in cands {
                if c.trace.isEmpty { continue }
                if trie.containsWord(c.baseForm, requireKanji: false) {
                    lemmaHitCache[surface] = (true, c.baseForm)
                    return (true, c.baseForm)
                }
            }
            lemmaHitCache[surface] = (false, nil)
            return (false, nil)
        }

        var i = 0
        while i < spans.count {
            let firstSurface = spans[i].surface
            if isHardStopToken(surface: firstSurface) {
                out.append(spans[i])
                i += 1
                continue
            }

            // Find the longest lockable span starting at i.
            var bestEnd: Int? = nil
            var bestLemma: String? = nil
            var bestWasLemmaLock = false

            let maxEnd = min(spans.count - 1, i + maxTokens - 1)

            var union = spans[i].range
            var end = i
            while end <= maxEnd {
                if end > i {
                    // Must be contiguous and not cross hard cuts.
                    guard isContiguous(spans[end - 1], spans[end]) else { break }
                    union = NSUnionRange(union, spans[end].range)
                    if crossesHardCut(union) { break }
                    if isHardStopToken(surface: spans[end].surface) { break }
                }

                if end > i {
                    let surface = text.substring(with: union)
                    if trie.containsWord(surface, requireKanji: false) {
                        bestEnd = end
                        bestLemma = nil
                        bestWasLemmaLock = false
                    } else {
                        let (hit, lemma) = lemmaHit(for: surface)
                        if hit {
                            bestEnd = end
                            bestLemma = lemma
                            bestWasLemmaLock = true
                        }
                    }
                }

                end += 1
            }

            if let bestEnd, bestEnd > i {
                let mergedRange = NSUnionRange(spans[i].range, spans[bestEnd].range)
                let mergedSurface = text.substring(with: mergedRange)
                let isLex = trie.containsWord(mergedSurface, requireKanji: false)
                out.append(TextSpan(range: mergedRange, surface: mergedSurface, isLexiconMatch: isLex))

                merges += 1
                if bestWasLemmaLock { deinflectionLocks += 1 }

                // Freeze boundaries around the merged span.
                let startCut = mergedRange.location
                let endCut = NSMaxRange(mergedRange)
                addedCuts.insert(startCut)
                addedCuts.insert(endCut)

                if traceEnabled {
                    if bestWasLemmaLock, let lemma = bestLemma {
                        CustomLogger.shared.info("DeinflectionHardStop: lock \(mergedRange.location)-\(NSMaxRange(mergedRange)) «\(mergedSurface)» via lemma «\(lemma)»")
                    } else {
                        CustomLogger.shared.info("DeinflectionHardStop: lock \(mergedRange.location)-\(NSMaxRange(mergedRange)) «\(mergedSurface)» via surface hit")
                    }
                }

                i = bestEnd + 1
                continue
            }

            out.append(spans[i])
            i += 1
        }

        return Result(
            spans: out,
            addedHardCuts: Array(addedCuts).sorted(),
            merges: merges,
            deinflectionLocks: deinflectionLocks
        )
    }
}
