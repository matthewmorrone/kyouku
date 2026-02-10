import SwiftUI

extension WordDefinitionsView {
    // MARK: Morphology helpers (verbs only)
    func describeVerbishDeinflectionTrace(_ trace: [Deinflector.AppliedRule]) -> String {
        guard trace.isEmpty == false else { return "" }
        var ordered: [String] = []
        var seen = Set<String>()

        func add(_ label: String) {
            let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty == false else { return }
            if seen.insert(t).inserted { ordered.append(t) }
        }

        for step in trace {
            switch step.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "-te": add("て-form")
            case "-ta", "past": add("past")
            case "negative": add("negative")
            case "polite": add("polite")
            case "potential": add("potential")
            case "passive": add("passive")
            case "causative": add("causative")
            case "volitional": add("volitional")
            case "imperative": add("imperative")
            case "conditional": add("conditional")
            default:
                break
            }
        }
        return ordered.joined(separator: " → ")
    }

    func structuralBreakdown(
        for labels: [String],
        verbClass: VerbConjugator.VerbClass,
        surface: String
    ) -> String {
        // Do not guess if multiple labels conflict.
        if labels.count != 1 {
            return ""
        }

        let label = labels[0]
        let endsWithTeDe = surface.hasSuffix("で") ? "で" : (surface.hasSuffix("て") ? "て" : nil)
        let endsWithTaDa = surface.hasSuffix("だ") ? "だ" : (surface.hasSuffix("た") ? "た" : nil)

        switch label {
        case "て-form":
            if let td = endsWithTeDe { return "連用形 + \(td)" }
            return "連用形 + て"
        case "Past (た)":
            if let td = endsWithTaDa { return "連用形 + \(td)" }
            return "連用形 + た"
        case "Negative (ない)":
            return "未然形 + ない"
        case "Polite (ます)":
            return "連用形 + ます"
        case "Progressive (ている)":
            return "て-form + いる"
        case "Potential":
            switch verbClass {
            case .godan:
                return "可能形（え段 + る）"
            case .ichidan:
                return "未然形 + られる"
            case .suru:
                return "できる"
            case .kuru:
                return "こられる"
            }
        case "Passive":
            switch verbClass {
            case .godan:
                return "未然形 + れる"
            case .ichidan:
                return "未然形 + られる"
            case .suru:
                return "される"
            case .kuru:
                // Passive for 来る is not typically used; avoid guessing.
                return ""
            }
        case "Causative":
            switch verbClass {
            case .godan:
                return "未然形 + せる"
            case .ichidan:
                return "未然形 + させる"
            case .suru:
                return "させる"
            case .kuru:
                return "こさせる"
            }
        case "Volitional":
            switch verbClass {
            case .godan:
                return "意向形（お段 + う）"
            case .ichidan:
                return "意向形（よう）"
            case .suru:
                return "しよう"
            case .kuru:
                return "こよう"
            }
        case "Imperative", "Imperative (alt)":
            return "命令形"
        case "Conditional (ば)":
            return "仮定形 + ば"
        case "Conditional (たら)":
            return "過去形 + ら"
        case "Prohibitive":
            return "終止形 + な"
        case "Desire (たい)":
            return "連用形 + たい"
        default:
            return ""
        }
    }

    func functionSummary(for labels: [String]) -> String {
        // If multiple labels match, we can only state that the function is ambiguous.
        guard labels.count == 1 else {
            return "(uncertain: multiple analyses match this surface)"
        }

        switch labels[0] {
        case "て-form": return "Clause chaining / auxiliary attachment"
        case "Past (た)": return "Past / perfective"
        case "Negative (ない)": return "Negation"
        case "Polite (ます)": return "Politeness"
        case "Progressive (ている)": return "Progressive / resulting state"
        case "Potential": return "Ability / possibility"
        case "Passive": return "Passive"
        case "Causative": return "Causation"
        case "Volitional": return "Volition / invitation"
        case "Imperative", "Imperative (alt)": return "Command"
        case "Conditional (ば)": return "Conditional"
        case "Conditional (たら)": return "Conditional / temporal sequence"
        case "Prohibitive": return "Prohibition"
        case "Desire (たい)": return "Desire"
        default:
            return "(uncertain)"
        }
    }

    func verbClassDisplayName(_ cls: VerbConjugator.VerbClass) -> String {
        switch cls {
        case .godan:
            return "Godan"
        case .ichidan:
            return "Ichidan"
        case .suru:
            return "Irregular (する)"
        case .kuru:
            return "Irregular (来る)"
        }
    }

    func refreshContextInsights() {
        let sentence = contextSentence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sentence, sentence.isEmpty == false {
            detectedGrammar = GrammarPatternDetector.detect(in: sentence)
        } else {
            detectedGrammar = []
        }

        let headword = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = (lemmaCandidates.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) ?? headword
        similarWords = JapaneseSimilarityService.neighbors(for: seed, maxCount: 12)
            .filter { $0 != seed }
    }

    func sentenceLookupTerms(primaryTerms: [String], entryDetails: [DictionaryEntryDetail]) -> [String] {
        let shouldSuppressComponentTerms = tokenParts.count > 1
        let partTerms: Set<String> = {
            guard shouldSuppressComponentTerms else { return [] }
            var s: Set<String> = []
            for part in tokenParts {
                let surface = part.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if surface.isEmpty == false { s.insert(surface) }
                if let kana = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false { s.insert(kana) }
            }
            return s
        }()

        var out: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            // Avoid pulling in examples for component terms of a compound (e.g. 思考 + 回路).
            if shouldSuppressComponentTerms, partTerms.contains(trimmed) { return }
            if out.contains(trimmed) == false { out.append(trimmed) }
        }

        for term in primaryTerms {
            add(term)
        }

        if let first = entryDetails.first {
            add(primaryHeadword(for: first))
            if let reading = first.kanaForms.first?.text {
                add(reading)
            }
        }

        return out
    }
}
