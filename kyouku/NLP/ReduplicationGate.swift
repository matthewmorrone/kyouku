import Foundation

/// ReduplicationGate
///
/// Structural rule:
/// - If adjacent contiguous tokens normalize to the same lookup key (X X)
/// - AND X exists in JMdict
/// - AND X X does NOT exist in JMdict
/// Then insert a hard cut between them and forbid treating X X as a lexical unit.
enum ReduplicationGate {
    struct Result {
        let addedHardCuts: [Int]
        let fires: Int
    }

    static func apply(text: NSString, spans: [TextSpan], hardCuts: [Int], trie: LexiconTrie) -> Result {
        guard spans.count >= 2 else { return Result(addedHardCuts: [], fires: 0) }

        let traceEnabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return env["REDUP_TRACE"] == "1" || env["EMBED_BOUNDARY_TRACE"] == "1"
        }()

        let cutSet = Set(hardCuts)
        var addedCuts: Set<Int> = []
        addedCuts.reserveCapacity(16)

        func isContiguous(_ a: TextSpan, _ b: TextSpan) -> Bool {
            NSMaxRange(a.range) == b.range.location
        }

        func crossesAnyHardCut(between a: TextSpan, and b: TextSpan) -> Bool {
            let boundary = NSMaxRange(a.range)
            return cutSet.contains(boundary) || addedCuts.contains(boundary)
        }

        var fires = 0
        for i in 0..<(spans.count - 1) {
            let a = spans[i]
            let b = spans[i + 1]
            guard isContiguous(a, b) else { continue }
            if crossesAnyHardCut(between: a, and: b) { continue }

            let aKey = DictionaryKeyPolicy.lookupKey(for: a.surface)
            let bKey = DictionaryKeyPolicy.lookupKey(for: b.surface)
            guard aKey.isEmpty == false, aKey == bKey else { continue }

            // Require dictionary presence for the single token.
            guard trie.containsWord(a.surface, requireKanji: false) else { continue }

            // Ensure the combined surface is not a dictionary unit.
            let combinedRange = NSUnionRange(a.range, b.range)
            let combinedSurface = text.substring(with: combinedRange)
            if trie.containsWord(combinedSurface, requireKanji: false) {
                continue
            }

            let boundary = NSMaxRange(a.range)
            addedCuts.insert(boundary)
            fires += 1

            if traceEnabled {
                CustomLogger.shared.info("ReduplicationGate: forcing boundary at \(boundary) for «\(a.surface)» «\(b.surface)» (combined «\(combinedSurface)» not in dict)")
            }
        }

        return Result(addedHardCuts: Array(addedCuts).sorted(), fires: fires)
    }
}
