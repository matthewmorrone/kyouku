import SwiftUI
import NaturalLanguage

extension WordDefinitionsView {
    // MARK: Full Entries
    func entryDetailView(_ detail: DictionaryEntryDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            entryDetailSection("Entry") {
                entryDetailHeader(detail)
            }

            if let formsBlock = entryFormsBlock(detail) {
                entryDetailSection("Forms") {
                    formsBlock
                }
            }

            if let pitchBlock = entryPitchAccentBlock(detail) {
                entryDetailSection("Pitch Accent") {
                    pitchBlock
                }
            }

            let senses = orderedSensesForDisplay(detail)
            if senses.isEmpty == false {
                entryDetailSection("Senses") {
                    let showSenseNumbers = senses.count > 1
                    ForEach(Array(senses.enumerated()), id: \.element.id) { index, sense in
                        senseView(sense, index: index + 1, showIndex: showSenseNumbers)
                        if index < senses.count - 1 {
                            Divider()
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    @ViewBuilder
    func entryDetailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    func entryDetailHeader(_ detail: DictionaryEntryDetail) -> some View {
        let headword = primaryHeadword(for: detail)
        let primaryReading = detail.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let posLine = entryPrimaryPartOfSpeechLine(detail)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headword)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if detail.isCommon {
                    Text("Common")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }

            if let primaryReading, primaryReading.isEmpty == false {
                Text(primaryReading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let posLine {
                Text(posLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if detail.isCommon == false {
                Text("Uncommon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func entryFormsBlock(_ detail: DictionaryEntryDetail) -> AnyView? {
        let headword = primaryHeadword(for: detail)
        let primaryReading = detail.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookedUpSurface = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraKanjiForms = orderedUniqueForms(from: detail.kanjiForms).filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return false }
            return trimmed != headword && trimmed != lookedUpSurface
        }
        let extraKanaForms = orderedUniqueForms(from: detail.kanaForms).filter { $0 != (primaryReading ?? "") }

        guard extraKanjiForms.isEmpty == false || extraKanaForms.isEmpty == false else { return nil }

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                if extraKanjiForms.isEmpty == false {
                    Text(extraKanjiForms.joined(separator: "、"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if extraKanaForms.isEmpty == false {
                    Text(extraKanaForms.joined(separator: "、"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }

    func entryPrimaryPartOfSpeechLine(_ detail: DictionaryEntryDetail) -> String? {
        var seen: Set<String> = []
        var labels: [String] = []

        for sense in detail.senses {
            for tag in sense.partsOfSpeech {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { continue }
                let expanded = expandPartOfSpeechTag(trimmed)
                let key = expanded.lowercased()
                if seen.insert(key).inserted {
                    labels.append(expanded)
                }
                if labels.count >= 4 { break }
            }
            if labels.count >= 4 { break }
        }

        guard labels.isEmpty == false else { return nil }
        return "\(labels.joined(separator: " · "))"
    }

    @ViewBuilder
    var pitchAccentGlobalContent: some View {
        if hasPitchAccentsTable == false {
            Text("Pitch accent data isn’t available in the bundled dictionary (missing pitch_accents table).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if isLoadingPitchAccents {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading pitch accents…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if pitchAccentsForTerm.isEmpty {
            Text("No pitch accents found for this term.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let morph = verbMorphologyAnalysis
            let lemmaHeadword = (entryDetails.first.map { primaryHeadword(for: $0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lemmaReading = (entryDetails.first?.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if let morph, lemmaHeadword.isEmpty == false {
                Text("Shown for lemma: \(morph.lemmaDisplay). Surface-form pitch may differ; it isn’t computed here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let headwordForDisplay = (morph == nil ? titleText : (lemmaHeadword.isEmpty ? titleText : lemmaHeadword))
            let readingForDisplay = (morph == nil
                ? (kana ?? entryDetails.first?.kanaForms.first?.text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                : (lemmaReading.isEmpty ? ((kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) : lemmaReading)
            )
            PitchAccentSection(
                headword: headwordForDisplay,
                reading: readingForDisplay,
                accents: pitchAccentsForTerm,
                showsTitle: false,
                visualScale: 3
            )
        }
    }

    @ViewBuilder
    var pitchAccentStatusOnlyContent: some View {
        if hasPitchAccentsTable == false {
            Text("Pitch accent data isn’t available in the bundled dictionary (missing pitch_accents table).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if isLoadingPitchAccents {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading pitch accents…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            Text("No pitch accents found for this term.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    func pitchAccentsByReading() -> [String: [PitchAccent]] {
        var out: [String: [PitchAccent]] = [:]
        out.reserveCapacity(4)

        func normalize(_ value: String?) -> String {
            (value ?? "")
                .replacingOccurrences(of: "◦", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for row in pitchAccentsForTerm {
            let reading = normalize(row.reading.isEmpty ? row.readingMarked : row.reading)
            guard reading.isEmpty == false else { continue }
            out[reading, default: []].append(row)
        }

        // Keep the per-reading display stable.
        for key in out.keys {
            out[key]?.sort {
                if $0.accent != $1.accent { return $0.accent < $1.accent }
                if $0.morae != $1.morae { return $0.morae < $1.morae }
                return ($0.kind ?? "") < ($1.kind ?? "")
            }
        }

        return out
    }

    func entryPitchAccentBlock(_ detail: DictionaryEntryDetail) -> AnyView? {
        guard hasPitchAccentsTable == true else { return nil }
        guard isLoadingPitchAccents == false else { return nil }
        guard pitchAccentsForTerm.isEmpty == false else { return nil }

        let readings = orderedUniqueForms(from: detail.kanaForms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard readings.isEmpty == false else { return nil }
        let grouped = pitchAccentsByReading()

        let blocks: [(reading: String, accents: [PitchAccent])] = readings.compactMap { reading in
            guard let accents = grouped[reading], accents.isEmpty == false else { return nil }
            return (reading, accents)
        }
        guard blocks.isEmpty == false else { return nil }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, item in
                    PitchAccentSection(
                        headword: "",
                        reading: item.reading,
                        accents: item.accents,
                        showsTitle: false,
                        visualScale: 1.6
                    )
                }
            }
        )
    }

    func senseView(_ sense: DictionaryEntrySense, index: Int, showIndex: Bool) -> some View {
        let glossLine = joinedGlossLine(for: sense)
        let noteLine = formattedSenseNotes(for: sense)

        return VStack(alignment: .leading, spacing: 6) {
            if let glossLine {
                if showIndex {
                    Text(numberedGlossText(index: index, gloss: glossLine, notes: noteLine))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(plainGlossText(gloss: glossLine, notes: noteLine))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if showIndex {
                    Text("\(index).")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }

            if let posLine = formattedTagsLine(from: sense.partsOfSpeech) {
                Text(posLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Notes are appended inline to the numbered gloss in parentheses.
        }
    }

    func plainGlossText(gloss: String, notes: String?) -> AttributedString {
        var body = AttributedString(gloss)
        body.font = .body
        body.foregroundColor = .primary

        var result = body
        if let notes, notes.isEmpty == false {
            var suffix = AttributedString(" (\(notes))")
            suffix.font = .body
            suffix.foregroundColor = .primary
            result += suffix
        }
        return result
    }

    func numberedGlossText(index: Int, gloss: String, notes: String?) -> AttributedString {
        // Keep number/tag/gloss visually identical so wrapping reads naturally.
        var prefix = AttributedString("\(index). ")
        prefix.font = .body
        prefix.foregroundColor = .primary

        var body = AttributedString(gloss)
        body.font = .body
        body.foregroundColor = .primary

        var result = prefix + body

        if let notes, notes.isEmpty == false {
            var suffix = AttributedString(" (\(notes))")
            suffix.font = .body
            suffix.foregroundColor = .primary
            result += suffix
        }

        return result
    }

    func joinedGlossLine(for sense: DictionaryEntrySense) -> String? {
        func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let english = sense.glosses.filter { $0.language == "eng" || $0.language.isEmpty }
        let source = english.isEmpty ? sense.glosses : english
        let parts = source.map { normalize($0.text) }.filter { $0.isEmpty == false }
        guard parts.isEmpty == false else { return nil }
        return parts.joined(separator: "; ")
    }
}
