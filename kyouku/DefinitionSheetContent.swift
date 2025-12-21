import SwiftUI

// Extracted from PasteView to reduce file size and complexity.
// Presents dictionary results for a selected token and allows adding to the WordStore.
struct DefinitionSheetContent: View {
    @Binding var selectedToken: ParsedToken?
    @Binding var showingDefinition: Bool
    @Binding var dictResults: [DictionaryEntry]
    @Binding var isLookingUp: Bool
    @Binding var lookupError: String?
    @Binding var selectedEntryIndex: Int?
    @Binding var fallbackTranslation: String?
    var onAdd: (ParsedToken, [DictionaryEntry], Int?, String?) -> Void

    @EnvironmentObject var store: WordStore

    var body: some View {
        Group {
            if let token = selectedToken {
                DefinitionSheetInnerContent(
                    token: token,
                    showingDefinition: $showingDefinition,
                    dictResults: $dictResults,
                    isLookingUp: $isLookingUp,
                    lookupError: $lookupError,
                    selectedEntryIndex: $selectedEntryIndex,
                    fallbackTranslation: $fallbackTranslation,
                    onAdd: onAdd
                )
                .padding()
                .presentationDetents([.fraction(0.33)])
                .presentationDragIndicator(.visible)
            } else {
                Text("No selection").padding()
            }
        }
    }

    struct DefinitionSheetInnerContent: View {
        let token: ParsedToken
        @Binding var showingDefinition: Bool
        @Binding var dictResults: [DictionaryEntry]
        @Binding var isLookingUp: Bool
        @Binding var lookupError: String?
        @Binding var selectedEntryIndex: Int?
        @Binding var fallbackTranslation: String?
        var onAdd: (ParsedToken, [DictionaryEntry], Int?, String?) -> Void

        // MARK: - Derived values
        private var hasKanjiInToken: Bool {
            token.surface.contains { ch in
                ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
            }
        }
        private var orderedResultsLocal: [DictionaryEntry] {
            orderedEntries(for: token, hasKanjiInToken: hasKanjiInToken)
        }
        private var totalLocal: Int { orderedResultsLocal.count }
        private var currentIndexLocal: Int { clampSelection(totalCount: totalLocal) }
        private var entryLocal: DictionaryEntry? {
            guard currentIndexLocal >= 0, currentIndexLocal < totalLocal else { return nil }
            return orderedResultsLocal[currentIndexLocal]
        }
        private var displayKanji: String {
            if !hasKanjiInToken {
                return token.reading.isEmpty ? token.surface : token.reading
            }
            if let e = entryLocal {
                return (e.kanji.isEmpty == false) ? e.kanji : e.reading
            }
            return token.surface
        }
        private var displayKana: String {
            entryLocal?.reading ?? token.reading
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: {
                        // Apply override for current token range in the editor
                        if let range = token.range {
                            let nsRange = range
                            let reading = displayKana
                            NotificationCenter.default.post(name: .applyReadingOverride, object: ReadingOverride(range: nsRange, reading: reading))
                        }
                    }) {
                        Image(systemName: "character.textbox")
                            .font(.title3)
                    }
                    .help("Use this reading for furigana")
                    .disabled(displayKana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button(action: {
                        onAdd(token, orderedResultsLocal, entryLocal == nil ? nil : currentIndexLocal, nil)
                        showingDefinition = false
                        selectedEntryIndex = nil
                    }) {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .disabled(isLookingUp || (entryLocal == nil && (fallbackTranslation?.isEmpty ?? true)))
                }

                if totalLocal > 1 {
                    HStack(spacing: 16) {
                        Button {
                            stepSelection(-1, totalCount: totalLocal)
                        } label: {
                            Image(systemName: "chevron.left").font(.title3)
                        }
                        .disabled(currentIndexLocal <= 0)

                        Text("Definition \(currentIndexLocal + 1) / \(totalLocal)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            stepSelection(1, totalCount: totalLocal)
                        } label: {
                            Image(systemName: "chevron.right").font(.title3)
                        }
                        .disabled(currentIndexLocal >= totalLocal - 1)
                    }
                }

                Text(displayKanji)
                    .font(.title2).bold()

                if !displayKana.isEmpty && displayKana != displayKanji {
                    Text(displayKana)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                resultsSection()
            }
            .onAppear {
                if selectedEntryIndex == nil { selectedEntryIndex = 0 }
            }
            .onChange(of: dictResults) { _, _ in
                let count = orderedResultsLocal.count
                if count > 0 {
                    let clamped = clampSelection(totalCount: count)
                    if clamped != (selectedEntryIndex ?? 0) {
                        selectedEntryIndex = clamped
                    }
                } else {
                    selectedEntryIndex = nil
                }
            }
        }

        // MARK: - Subviews
        @ViewBuilder
        private func resultsSection() -> some View {
            if isLookingUp {
                ProgressView("Looking up definitions…")
            } else if let err = lookupError {
                Text(err).foregroundStyle(.secondary)
            } else if orderedResultsLocal.isEmpty, let fallback = fallbackTranslation, !fallback.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apple Translation")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(fallback)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if orderedResultsLocal.isEmpty {
                Text("No definitions found.")
                    .foregroundStyle(.secondary)
            } else if let entryLocal {
                VStack(alignment: .leading, spacing: 8) {
                    Text(primaryGloss(from: entryLocal))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if entryLocal.gloss.contains(";") {
                        Text(entryLocal.gloss)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                    }
                }
            }
        }

        // MARK: - Helpers (duplicated for isolation)
        private func orderedEntries(for token: ParsedToken, hasKanjiInToken: Bool) -> [DictionaryEntry] {
            guard !dictResults.isEmpty else { return [] }
            guard !hasKanjiInToken else { return dictResults }
            let targetReading = token.reading.isEmpty ? token.surface : token.reading
            guard !targetReading.isEmpty else { return dictResults }
            let matching = dictResults.filter { $0.reading == targetReading }
            guard !matching.isEmpty else { return dictResults }
            let nonMatching = dictResults.filter { $0.reading != targetReading }
            return matching + nonMatching
        }

        private func clampSelection(totalCount: Int) -> Int {
            guard totalCount > 0 else { return 0 }
            let raw = selectedEntryIndex ?? 0
            return min(max(raw, 0), totalCount - 1)
        }

        private func stepSelection(_ delta: Int, totalCount: Int) {
            guard totalCount > 0 else { return }
            let current = clampSelection(totalCount: totalCount)
            let next = current + delta
            guard next >= 0 && next < totalCount else { return }
            selectedEntryIndex = next
        }

        private func primaryGloss(from entry: DictionaryEntry) -> String {
            entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
        }
    }
}
