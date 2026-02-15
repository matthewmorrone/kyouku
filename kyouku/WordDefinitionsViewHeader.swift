import SwiftUI
import NaturalLanguage

extension WordDefinitionsView {
    var loadTaskKey: String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = (kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lemmas = lemmaCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "|")
        return "\(primary)|\(secondary)|\(lemmas)"
    }

    // MARK: Header
    var titleText: String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if primary.isEmpty == false { return primary }
        return kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var primaryLemmaText: String? {
        lemmaCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }

    var resolvedLemmaText: String? {
        let a = (resolvedLemmaForLookup ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty == false { return a }
        return primaryLemmaText
    }

    var resolvedSurfaceText: String {
        titleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var headerDisplayReading: String? {
        let preferred = (kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if preferred.isEmpty == false { return preferred }

        let detailReading = (entryDetails.first?.kanaForms.first?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if detailReading.isEmpty == false { return detailReading }

        return nil
    }

    struct HeaderMetadataPill: Identifiable, Hashable {
        enum Tone: Hashable {
            case accent
            case subtle
        }

        let id: String
        let text: String
        let tone: Tone
    }

    var headerMetadataPills: [HeaderMetadataPill] {
        var pills: [HeaderMetadataPill] = []

        if let frequencyMetadataLabel {
            let tone: HeaderMetadataPill.Tone = (frequencyMetadataLabel == "Common") ? .accent : .subtle
            pills.append(HeaderMetadataPill(id: "freq:\(frequencyMetadataLabel)", text: frequencyMetadataLabel, tone: tone))
        }

        if hasUsuallyKanaUsageTag {
            pills.append(HeaderMetadataPill(id: "usage:uk", text: "Usually kana", tone: .subtle))
        }

        let altCount = alternativeFormCount
        if altCount > 0 {
            let label = (altCount == 1) ? "1 alt form" : "\(altCount) alt forms"
            pills.append(HeaderMetadataPill(id: "alt:\(altCount)", text: label, tone: .subtle))
        }

        return pills
    }

    @ViewBuilder
    func headerMetadataPillView(_ pill: HeaderMetadataPill) -> some View {
        let foreground: Color = (pill.tone == .accent) ? Color.accentColor : Color.secondary
        let background: Color = (pill.tone == .accent)
            ? Color.accentColor.opacity(0.14)
            : Color.secondary.opacity(0.14)

        Text(pill.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    var frequencyMetadataLabel: String? {
        if let detail = entryDetails.first {
            return detail.isCommon ? "Common" : "Uncommon"
        }
        if let entry = entries.first {
            return entry.isCommon ? "Common" : "Uncommon"
        }
        return nil
    }

    var hasUsuallyKanaUsageTag: Bool {
        for detail in entryDetails {
            for sense in detail.senses {
                if sense.miscellaneous.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "uk" }) {
                    return true
                }
            }
        }
        return false
    }

    var alternativeFormCount: Int {
        guard let detail = entryDetails.first else { return 0 }

        let primaryHeadwordText = primaryHeadword(for: detail).trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryReadingText = (detail.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let kanjiAlternatives = orderedUniqueForms(from: detail.kanjiForms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0 != primaryHeadwordText }

        let kanaAlternatives = orderedUniqueForms(from: detail.kanaForms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0 != primaryReadingText }

        return Set(kanjiAlternatives + kanaAlternatives).count
    }

    var isVerbLemma: Bool {
        // Verbs only: gate morphology + lemma-pitch behaviors.
        verbConjugationVerbClass != nil
    }

    struct VerbMorphologyAnalysis: Hashable {
        let surface: String
        let lemmaSurface: String
        let lemmaDisplay: String
        let verbClass: VerbConjugator.VerbClass
        let formDisplay: String
        let functionDisplay: String
        let pitchNote: String
        let isUncertain: Bool
    }

    var verbMorphologyAnalysis: VerbMorphologyAnalysis? {
        guard isVerbLemma else { return nil }

        let surface = resolvedSurfaceText
        guard surface.isEmpty == false else { return nil }

        let lemmaSurface = (resolvedLemmaText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard lemmaSurface.isEmpty == false else { return nil }

        // Only show for inflected forms.
        guard lemmaSurface != surface else { return nil }

        guard let verbClass = verbConjugationVerbClass else { return nil }

        // Prefer the primary lemma's (kanji,kana) display from the fetched entry details.
        let lemmaHeadword: String = {
            guard let first = entryDetails.first else { return lemmaSurface }
            let h = primaryHeadword(for: first).trimmingCharacters(in: .whitespacesAndNewlines)
            return h.isEmpty ? lemmaSurface : h
        }()
        let lemmaReading: String = (entryDetails.first?.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let lemmaDisplay: String = {
            let h = lemmaHeadword
            let r = lemmaReading
            if h.isEmpty { return lemmaSurface }
            if r.isEmpty { return h }
            if containsKanji(h) {
                return "\(h)（\(r)）"
            }
            // Kana-only lemma.
            return h
        }()

        let allConjs = VerbConjugator.conjugations(for: lemmaSurface, verbClass: verbClass, set: .all)
        let matchingLabels: [String] = {
            var seen = Set<String>()
            var out: [String] = []
            for label in allConjs.filter({ $0.surface == surface }).map({ $0.label }) {
                let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.isEmpty == false else { continue }
                if seen.insert(t).inserted { out.append(t) }
            }
            return out
        }()

        let (formDisplay, functionDisplay, uncertain): (String, String, Bool) = {
            if matchingLabels.isEmpty == false {
                // If multiple labels map to the same surface (e.g. 来られる: potential/passive), do not guess.
                let baseLabel = matchingLabels.count == 1 ? matchingLabels[0] : matchingLabels.joined(separator: " / ")
                let structural = structuralBreakdown(for: matchingLabels, verbClass: verbClass, surface: surface)
                let funcText = functionSummary(for: matchingLabels)
                let display = structural.isEmpty ? baseLabel : "\(baseLabel)（\(structural)）"
                return (display, funcText, matchingLabels.count > 1)
            }

            // Fallback: use the deinflection trace if we have it, but mark uncertain.
            if resolvedDeinflectionTrace.isEmpty == false {
                let traceLabel = describeVerbishDeinflectionTrace(resolvedDeinflectionTrace)
                let display = traceLabel.isEmpty ? "(uncertain)" : "\(traceLabel)（uncertain）"
                return (display, "(uncertain)", true)
            }

            return ("(uncertain)", "(uncertain)", true)
        }()

        let pitchNote = "Pitch accent is shown for the lemma. The surface form may inherit it or be modified by attached auxiliaries; this view does not compute surface pitch from morae."

        return VerbMorphologyAnalysis(
            surface: surface,
            lemmaSurface: lemmaSurface,
            lemmaDisplay: lemmaDisplay,
            verbClass: verbClass,
            formDisplay: formDisplay,
            functionDisplay: functionDisplay,
            pitchNote: pitchNote,
            isUncertain: uncertain
        )
    }

    @MainActor
    func updateHeaderLemmaAndFormLines() async {
        let surfaceText = resolvedSurfaceText
        guard surfaceText.isEmpty == false else {
            headerLemmaLine = nil
            headerFormLine = nil
            return
        }

        guard let lemmaTextRaw = resolvedLemmaText else {
            headerLemmaLine = nil
            headerFormLine = nil
            return
        }

        let lemmaText = lemmaTextRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lemmaText.isEmpty == false, lemmaText != surfaceText else {
            headerLemmaLine = nil
            headerFormLine = nil
            return
        }

        let lemmaReading = (entryDetails.first?.kanaForms.first?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lemmaReading.isEmpty == false, lemmaReading != lemmaText {
            headerLemmaLine = "Lemma: \(lemmaText)/\(lemmaReading)"
        } else {
            headerLemmaLine = "Lemma: \(lemmaText)"
        }

        func friendlyDeinflectionReason(_ reason: String) -> String {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            switch key {
            case "-te": return "て-form"
            case "-ta", "past": return "past"
            case "negative": return "negative"
            case "polite": return "polite"
            case "potential": return "potential"
            case "passive": return "passive"
            case "causative": return "causative"
            case "volitional": return "volitional"
            case "imperative": return "imperative"
            case "conditional": return "conditional"
            default:
                return trimmed.isEmpty ? reason : trimmed
            }
        }

        func describeTrace(_ trace: [Deinflector.AppliedRule]) -> String? {
            guard trace.isEmpty == false else { return nil }
            var ordered: [String] = []
            var seen = Set<String>()
            for step in trace {
                let label = friendlyDeinflectionReason(step.reason)
                if label.isEmpty { continue }
                if seen.insert(label).inserted {
                    ordered.append(label)
                }
            }
            guard ordered.isEmpty == false else { return nil }
            if ordered.count == 1 { return ordered[0] }
            return ordered.joined(separator: " → ")
        }

        if resolvedDeinflectionTrace.isEmpty == false {
            if let form = describeTrace(resolvedDeinflectionTrace) {
                headerFormLine = "Form: \(form) of \(lemmaText)"
                return
            }
        } else if let deinflector = try? Deinflector.loadBundled(named: "deinflect") {
            let candidates = deinflector.deinflect(surfaceText, maxDepth: 8, maxResults: 64)
            if let match = candidates.first(where: { $0.surface == lemmaText }) {
                if let form = describeTrace(match.trace) {
                    headerFormLine = "Form: \(form) of \(lemmaText)"
                    return
                }
            }
        }

        headerFormLine = "Form: inflected of \(lemmaText)"
    }
}
