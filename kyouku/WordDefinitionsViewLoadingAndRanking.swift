import SwiftUI
import NaturalLanguage

extension WordDefinitionsView {
    // MARK: POS-aware ranking
    enum CoarseTokenPOS {
        case noun
        case verb
        case adjective
        case adverb
        case particle
        case auxiliary
        case other
    }

    func coarseTokenPOS() -> CoarseTokenPOS? {
        let raw = (tokenPartOfSpeech ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return nil }

        // Mecab_Swift POS strings are typically like "名詞,一般,*,*".
        let head = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
        switch head {
        case "名詞": return .noun
        case "動詞": return .verb
        case "形容詞": return .adjective
        case "副詞": return .adverb
        case "助詞": return .particle
        case "助動詞": return .auxiliary
        default: return .other
        }
    }

    func senseMatchesTokenPOS(_ sense: DictionaryEntrySense) -> Bool {
        guard let coarse = coarseTokenPOS() else { return false }
        guard sense.partsOfSpeech.isEmpty == false else { return false }

        func anyPrefix(_ prefixes: [String]) -> Bool {
            sense.partsOfSpeech.contains { tag in
                let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return prefixes.contains(where: { t.hasPrefix($0) })
            }
        }

        switch coarse {
        case .noun:
            return anyPrefix(["n", "pn"])
        case .verb:
            return anyPrefix(["v", "vs"])
        case .adjective:
            return anyPrefix(["adj"])
        case .adverb:
            return anyPrefix(["adv"])
        case .particle:
            return anyPrefix(["prt"])
        case .auxiliary:
            return anyPrefix(["aux"])
        case .other:
            return false
        }
    }

    func orderedSensesForDisplay(_ detail: DictionaryEntryDetail) -> [DictionaryEntrySense] {
        guard detail.senses.isEmpty == false else { return [] }
        // If we don't have token POS, preserve JMdict order.
        guard coarseTokenPOS() != nil else {
            return detail.senses.sorted(by: { $0.orderIndex < $1.orderIndex })
        }

        return detail.senses.sorted { lhs, rhs in
            let lhsTier = senseMatchesTokenPOS(lhs) ? 0 : 1
            let rhsTier = senseMatchesTokenPOS(rhs) ? 0 : 1
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.id < rhs.id
        }
    }

    func primaryHeadword(for detail: DictionaryEntryDetail) -> String {
        if let kanji = detail.kanjiForms.first?.text, kanji.isEmpty == false {
            return kanji
        }
        if let kana = detail.kanaForms.first?.text, kana.isEmpty == false {
            return kana
        }
        return titleText
    }

    func orderedUniqueForms(from forms: [DictionaryEntryForm]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for form in forms {
            let trimmed = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    func formattedTagsLine(from tags: [String]) -> String? {
        guard tags.isEmpty == false else { return nil }
        return tags.joined(separator: " · ")
    }

    func formattedSenseNotes(for sense: DictionaryEntrySense) -> String? {
        let raw = sense.miscellaneous + sense.fields + sense.dialects
        guard raw.isEmpty == false else { return nil }

        var seen: Set<String> = []
        var expanded: [String] = []
        for tag in raw {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else { continue }
            let value = expandSenseTag(normalized)
            let key = value.lowercased()
            if seen.insert(key).inserted {
                expanded.append(value)
            }
        }

        guard expanded.isEmpty == false else { return nil }
        return expanded.joined(separator: ", ")
    }

    func expandSenseTag(_ tag: String) -> String {
        let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "uk": return "usually kana"
        case "arch": return "archaic"
        case "fem": return "feminine"
        case "obs": return "obsolete"
        case "col": return "colloquial"
        case "hon": return "honorific"
        case "hum": return "humble"
        case "pol": return "polite"
        case "sl": return "slang"
        case "vulg": return "vulgar"
        default: return tag
        }
    }

    // MARK: Data Loading
    @MainActor
    func load() async {
        let requestID = UUID()
        activeLoadRequestID = requestID

        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        var primaryTerms: [String] = []
        for t in [primary, secondary].compactMap({ $0 }) {
            guard t.isEmpty == false else { continue }
            if primaryTerms.contains(t) == false { primaryTerms.append(t) }
        }

        guard primaryTerms.isEmpty == false else {
            entries = []
            entryDetails = []
            exampleSentences = []
            exampleSentenceReadingGuides = [:]
            return
        }

        isLoading = true
        errorMessage = nil
        entryDetails = []
        hasPitchAccentsTable = nil
        pitchAccentsForTerm = []
        isLoadingPitchAccents = true
        exampleSentences = []
        exampleSentenceReadingGuides = [:]
        showAllExampleSentences = false
        isLoadingExampleSentences = true

        resolvedLemmaForLookup = nil
        resolvedDeinflectionTrace = []

        var merged: [DictionaryEntry] = []
        var seen: Set<String> = []
        var selectedLemmaUsedForLookup: String? = nil

        func selectedLemmaCandidate() -> String? {
            // Important: `lemmaCandidates` can include component/subtoken lemmas.
            // Only consider a lemma as a fallback when the surface/kana have no results.
            let raw = lemmaCandidates
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.isEmpty == false })
            guard let raw else { return nil }
            // For non-inflecting categories (particles/adverbs/nouns), lemma fallback
            // tends to add noise and can look unrelated.
            switch coarseTokenPOS() {
            case .verb?, .adjective?, .auxiliary?:
                return raw
            default:
                return nil
            }
        }

        do {
            for term in primaryTerms {
                try Task.checkCancellation()
                let keys = DictionaryKeyPolicy.keys(forDisplayKey: term)
                guard keys.lookupKey.isEmpty == false else { continue }
                let rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 100)
                for row in rows {
                    if seen.insert(row.id).inserted {
                        merged.append(row)
                    }
                }
            }

            // Only fall back to lemma if the surface/kana did not yield anything.
            if merged.isEmpty, let lemma = selectedLemmaCandidate() {
                if primaryTerms.contains(lemma) == false {
                    try Task.checkCancellation()
                    let keys = DictionaryKeyPolicy.keys(forDisplayKey: lemma)
                    if keys.lookupKey.isEmpty == false {
                        let rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 100)
                        for row in rows {
                            if seen.insert(row.id).inserted {
                                merged.append(row)
                            }
                        }
                        if rows.isEmpty == false {
                            selectedLemmaUsedForLookup = lemma
                        }
                    }
                }
            }

            // If we're still empty, attempt deinflection-based lemma lookup.
            // This is especially important for Words/History items saved as inflected surfaces.
            if merged.isEmpty {
                if let deinflector = try? Deinflector.loadBundled(named: "deinflect") {
                    // Prefer the explicit surface term; then try kana (if supplied).
                    for term in primaryTerms {
                        try Task.checkCancellation()
                        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { continue }

                        let candidates = deinflector.deinflect(trimmed, maxDepth: 8, maxResults: 64)
                        for cand in candidates {
                            if cand.trace.isEmpty { continue }
                            let keys = DictionaryKeyPolicy.keys(forDisplayKey: cand.baseForm)
                            guard keys.lookupKey.isEmpty == false else { continue }

                            let rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 100)
                            if rows.isEmpty == false {
                                for row in rows {
                                    if seen.insert(row.id).inserted {
                                        merged.append(row)
                                    }
                                }
                                resolvedLemmaForLookup = cand.baseForm
                                resolvedDeinflectionTrace = cand.trace
                                selectedLemmaUsedForLookup = cand.baseForm
                                break
                            }
                        }

                        if merged.isEmpty == false {
                            break
                        }
                    }
                }
            }

            guard activeLoadRequestID == requestID else { return }
            try Task.checkCancellation()

            // Display requirement: common entries should appear before non-common ones.
            // Preserve the existing relative order within each group.
            let mergedCommonFirst = merged.filter { $0.isCommon } + merged.filter { $0.isCommon == false }
            entries = mergedCommonFirst
            let details = await loadEntryDetails(for: mergedCommonFirst)

            guard activeLoadRequestID == requestID else { return }
            try Task.checkCancellation()

            let baseOrderedDetails: [DictionaryEntryDetail] = {
                // Keep any existing ordering, but optionally push POS-matching senses higher.
                if coarseTokenPOS() != nil {
                    return details.sorted { lhs, rhs in
                        let lhsTier = lhs.senses.contains(where: senseMatchesTokenPOS) ? 0 : 1
                        let rhsTier = rhs.senses.contains(where: senseMatchesTokenPOS) ? 0 : 1
                        if lhsTier != rhsTier { return lhsTier < rhsTier }
                        return lhs.entryID < rhs.entryID
                    }
                }
                return details
            }()
            // Final display requirement: common entries should all appear before non-common ones.
            entryDetails = baseOrderedDetails.filter { $0.isCommon } + baseOrderedDetails.filter { $0.isCommon == false }

            // If we did not resolve a lemma explicitly, treat the displayed term as the lemma.
            // (Used for morphology/pitch logic to avoid mixing surface/lemma in verb pages.)
            if resolvedLemmaForLookup == nil {
                let t = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty == false {
                    resolvedLemmaForLookup = t
                }
            }

            // Pitch accents are an optional table. Load these after details so the page can render.
            let supportsPitchAccents = await DictionarySQLiteStore.shared.supportsPitchAccents()
            hasPitchAccentsTable = supportsPitchAccents

            if supportsPitchAccents {
                // Precompute lookup keys on the main actor to avoid Swift 6 isolation violations.
                let pitchPairs: [(surface: String, reading: String)] = {
                    let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedKana = (kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    var pairs: [(String, String)] = []
                    func add(_ s: String, _ r: String) {
                        let s2 = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        let r2 = r.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard s2.isEmpty == false, r2.isEmpty == false else { return }
                        pairs.append((s2, r2))
                    }

                    // Surface-form candidates first (best effort for inflected forms like ～て).
                    if trimmedSurface.isEmpty == false, trimmedKana.isEmpty == false {
                        add(trimmedSurface, trimmedKana)
                    }
                    if trimmedSurface.isEmpty == false {
                        add(trimmedSurface, trimmedSurface)
                    }
                    if trimmedKana.isEmpty == false {
                        add(trimmedKana, trimmedKana)
                    }

                    // Always prefer lemma entry spellings/readings from JMdict details.
                    for detail in entryDetails {
                        let headword = primaryHeadword(for: detail)
                        let reading = (detail.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if headword.isEmpty == false, reading.isEmpty == false {
                            add(headword, reading)
                        }
                        if reading.isEmpty == false {
                            add(reading, reading)
                        }
                    }

                    // De-dupe while preserving order.
                    var seen = Set<String>()
                    var out: [(surface: String, reading: String)] = []
                    for (s, r) in pairs {
                        let key = "\(s)|\(r)"
                        if seen.insert(key).inserted {
                            out.append((s, r))
                        }
                    }
                    return out
                }()

                let pitchRows: [PitchAccent] = await Task.detached(priority: .userInitiated) {
                    var seen = Set<String>()
                    var out: [PitchAccent] = []
                    out.reserveCapacity(8)

                    for pair in pitchPairs {
                        let rows = (try? await DictionarySQLiteStore.shared.fetchPitchAccents(surface: pair.surface, reading: pair.reading)) ?? []
                        for row in rows {
                            let key = "\(row.surface)|\(row.reading)|\(row.accent)|\(row.morae)|\(row.kind ?? "")|\(row.readingMarked ?? "")"
                            if seen.insert(key).inserted {
                                out.append(row)
                            }
                        }
                    }

                    out.sort {
                        if $0.accent != $1.accent { return $0.accent < $1.accent }
                        if $0.morae != $1.morae { return $0.morae < $1.morae }
                        return ($0.kind ?? "") < ($1.kind ?? "")
                    }
                    return out
                }.value

                guard activeLoadRequestID == requestID else { return }
                pitchAccentsForTerm = pitchRows
            } else {
                pitchAccentsForTerm = []
            }
            isLoadingPitchAccents = false

            // If we weren't invoked with component parts from Paste, infer a reasonable component
            // breakdown for compounds.
            await inferTokenPartsIfNeeded()

            guard activeLoadRequestID == requestID else { return }
            try Task.checkCancellation()

            // Example sentences are substring-matched. Prefer surface/lemma terms before kana so
            // the initial terms don't get dominated by broad kana matches.
            let sentencePrimaryTerms: [String] = {
                var ordered: [String] = []
                func add(_ value: String?) {
                    guard let value else { return }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { return }
                    if ordered.contains(trimmed) == false { ordered.append(trimmed) }
                }
                add(primary)
                add(selectedLemmaUsedForLookup)
                add(secondary)
                return ordered
            }()

            let sentenceTerms = sentenceLookupTerms(primaryTerms: sentencePrimaryTerms, entryDetails: details)
            do {
                let sentences = try await DictionarySQLiteStore.shared.fetchExampleSentences(containing: sentenceTerms, limit: 8)
                exampleSentences = sentences.sorted { lhs, rhs in
                    let ls = exampleSentenceComplexityScore(lhs)
                    let rs = exampleSentenceComplexityScore(rhs)
                    if ls != rs { return ls < rs }
                    // Stable-ish tie-breakers.
                    if lhs.jpText.count != rhs.jpText.count { return lhs.jpText.count < rhs.jpText.count }
                    return lhs.id < rhs.id
                }
            } catch {
                exampleSentences = []
            }
            isLoadingExampleSentences = false

            isLoading = false
            debugSQL = await DictionarySQLiteStore.shared.debugLastQueryDescription()
        } catch is CancellationError {
            // No-op: a new lookup superseded this one.
            return
        } catch {
            guard activeLoadRequestID == requestID else { return }
            entries = []
            entryDetails = []
            hasPitchAccentsTable = nil
            pitchAccentsForTerm = []
            isLoadingPitchAccents = false
            exampleSentences = []
            exampleSentenceReadingGuides = [:]
            isLoadingExampleSentences = false
            isLoading = false
            errorMessage = String(describing: error)
        }
    }
}
