import Foundation

/// Japanese deinflection (deconjugation) using Yomichan-compatible rules.
///
/// Rule source format: https://github.com/FooSoft/yomichan/blob/master/ext/data/deinflect.json
///
/// Notes:
/// - This is a deterministic breadth-first rewrite system over suffix rules.
/// - This does not perform normalization beyond what callers choose to apply.
///   Callers should normalize dictionary lookup keys via `DictionaryKeyPolicy`.
struct Deinflector: Sendable {
    struct Rule: Codable, Hashable, Sendable {
        let kanaIn: String
        let kanaOut: String
        let rulesIn: [String]
        let rulesOut: [String]
    }

    struct AppliedRule: Hashable, Sendable {
        let reason: String
        let rule: Rule
    }

    struct Candidate: Hashable, Sendable {
        let surface: String
        let rules: Set<String>
        let trace: [AppliedRule]

        var baseForm: String { surface }
    }

    enum LoadError: Error {
        case decodeFailed
    }

    private let reasonsInStableOrder: [String]
    private let rulesByReason: [String: [Rule]]
    private let initialRuleUniverse: Set<String>

    init(rulesByReason: [String: [Rule]]) {
        self.rulesByReason = rulesByReason
        self.reasonsInStableOrder = rulesByReason.keys.sorted()

        var universe: Set<String> = []
        for (_, rules) in rulesByReason {
            for r in rules {
                for x in r.rulesIn { universe.insert(x) }
                for x in r.rulesOut { universe.insert(x) }
            }
        }
        self.initialRuleUniverse = universe
    }

    static func loadBundled(named baseName: String = "deinflect") throws -> Deinflector {
        let bundle = Bundle.main
        let url = bundle.url(forResource: baseName, withExtension: "json")
            ?? bundle.url(forResource: "deinflect.min", withExtension: "json")

        if let url {
            let data = try Data(contentsOf: url)
            do {
                let decoded = try JSONDecoder().decode([String: [Rule]].self, from: data)
                return Deinflector(rulesByReason: decoded)
            } catch {
                throw LoadError.decodeFailed
            }
        }

        // Fallback: embedded minimal subset (verbatim Yomichan-compatible rules for common cases).
        guard let data = embeddedMinimalRulesJSON.data(using: .utf8) else {
            throw LoadError.decodeFailed
        }
        do {
            let decoded = try JSONDecoder().decode([String: [Rule]].self, from: data)
            return Deinflector(rulesByReason: decoded)
        } catch {
            throw LoadError.decodeFailed
        }
    }

    // Keep this minimal: it is intended as a safety net when the full Yomichan
    // rules file isn't bundled. Drop a full `deinflect.json` into the app bundle
    // to expand coverage.
        private static let embeddedMinimalRulesJSON: String = #"""
{
    "-ba": [
        {"kanaIn": "れば", "kanaOut": "る", "rulesIn": [], "rulesOut": ["v1", "v5", "vk", "vs", "vz"]}
    ],
    "-tai": [
        {"kanaIn": "たい", "kanaOut": "る", "rulesIn": ["adj-i"], "rulesOut": ["v1"]}
    ],
    "-te": [
        {"kanaIn": "て", "kanaOut": "る", "rulesIn": ["iru"], "rulesOut": ["v1"]},
        {"kanaIn": "んで", "kanaOut": "む", "rulesIn": ["iru"], "rulesOut": ["v5"]},
        {"kanaIn": "して", "kanaOut": "する", "rulesIn": ["iru"], "rulesOut": ["vs"]}
    ],
    "negative": [
        {"kanaIn": "ない", "kanaOut": "る", "rulesIn": ["adj-i"], "rulesOut": ["v1"]}
    ],
    "progressive or perfect": [
        {"kanaIn": "ている", "kanaOut": "て", "rulesIn": ["v1"], "rulesOut": ["iru"]}
    ]
}
"""#

    /// Deterministically produce ranked deinflection candidates for `surface`.
    ///
    /// Ranking:
    /// - Fewer steps first (BFS depth)
    /// - Stable tie-break via sorted reason keys and original rule order
    func deinflect(
        _ surface: String,
        maxDepth: Int = 8,
        maxResults: Int = 64
    ) -> [Candidate] {
        let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        // BFS queue
        struct State: Hashable {
            let surface: String
            let rules: Set<String>
            let trace: [AppliedRule]
        }

        // Start permissive: allow any rule chain to begin.
        // (This matches how Yomichan's engine treats unknown word classes.)
        let start = State(surface: trimmed, rules: initialRuleUniverse, trace: [])

        var out: [Candidate] = []
        out.reserveCapacity(min(16, maxResults))

        var queue: [State] = [start]
        var queueIndex = 0

        // Avoid loops: track best (shallowest) visit per (surface,rules).
        var visited: Set<State> = []
        visited.insert(start)

        // Also avoid emitting the same surface many times. Keep earliest (best-ranked) trace.
        var emittedSurfaces: Set<String> = []

        func emit(_ state: State) {
            if emittedSurfaces.insert(state.surface).inserted {
                out.append(Candidate(surface: state.surface, rules: state.rules, trace: state.trace))
            }
        }

        // Always include the original surface first.
        emit(start)

        while queueIndex < queue.count {
            let state = queue[queueIndex]
            queueIndex += 1

            if state.trace.count >= maxDepth {
                continue
            }

            // Early exit if we already have enough unique outputs.
            if out.count >= maxResults {
                break
            }

            for reason in reasonsInStableOrder {
                guard let rules = rulesByReason[reason] else { continue }
                for rule in rules {
                    guard state.surface.hasSuffix(rule.kanaIn) else { continue }

                    if rule.rulesIn.isEmpty == false {
                        // Require that all rule-in tags are permitted by the current state.
                        var ok = true
                        for req in rule.rulesIn {
                            if state.rules.contains(req) == false {
                                ok = false
                                break
                            }
                        }
                        if ok == false { continue }
                    }

                    let prefix = String(state.surface.dropLast(rule.kanaIn.count))
                    let nextSurface = prefix + rule.kanaOut
                    if nextSurface.isEmpty { continue }

                    let nextRules = Set(rule.rulesOut)
                    let nextTrace = state.trace + [AppliedRule(reason: reason, rule: rule)]

                    let next = State(surface: nextSurface, rules: nextRules, trace: nextTrace)
                    if visited.insert(next).inserted {
                        queue.append(next)
                        emit(next)
                        if out.count >= maxResults {
                            break
                        }
                    }
                }
                if out.count >= maxResults {
                    break
                }
            }
        }

        // Deterministic: BFS already yields shortest traces first, but the queue can
        // contain states discovered in different reason buckets at the same depth.
        // Sorting by (trace length, surface, trace reasons) makes this stable.
        out.sort { a, b in
            if a.trace.count != b.trace.count { return a.trace.count < b.trace.count }
            if a.surface != b.surface { return a.surface < b.surface }
            // Tie-break by trace reasons (string compare).
            let ar = a.trace.map { $0.reason }.joined(separator: ">")
            let br = b.trace.map { $0.reason }.joined(separator: ">")
            return ar < br
        }

        return out
    }
}
