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
    var onAddCustomEntry: (CustomEntryDraft) -> Void
    var boundaryActions: BoundaryActionContext? = nil

    @EnvironmentObject var store: WordsStore

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
                    onAdd: onAdd,
                    onAddCustomEntry: onAddCustomEntry,
                    boundaryActions: boundaryActions
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
        var onAddCustomEntry: (CustomEntryDraft) -> Void
        var boundaryActions: BoundaryActionContext?

        @State private var showBoundaryTools = false
        @State private var showingCustomEntryEditor = false
        @State private var customEntryDraft = CustomEntryDraft()
        @State private var customEntryError: String? = nil

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
                HStack(spacing: 12) {
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

                    Button(action: beginCustomEntry) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                    }
                    .help("Customize the entry before saving")

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

                if let ctx = boundaryActions {
                    boundaryControls(ctx)
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
            .sheet(isPresented: $showingCustomEntryEditor) {
                customEntrySheet()
            }
        }

        @ViewBuilder
        private func boundaryControls(_ ctx: BoundaryActionContext) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Word Boundaries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Tools", isOn: $showBoundaryTools)
                        .font(.caption)
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .accessibilityLabel("Toggle boundary tools")
                }
                if showBoundaryTools {
                    HStack(alignment: .top, spacing: 16) {
                        if let marker = ctx.customStatus {
                            customBoundaryIndicator(marker)
                            if marker.undo != nil {
                                Divider()
                                    .frame(height: 32)
                            }
                        }
                        boundaryButtonsStack(ctx: ctx)
                    }
                }
            }
        }

        private func boundaryButtonsStack(ctx: BoundaryActionContext) -> some View {
            HStack(spacing: 12) {
                boundaryButton(title: "Merge ←", systemImage: "arrowtriangle.left.fill", isEnabled: ctx.canCombineLeft, action: ctx.combineLeft)
                boundaryButton(title: "Merge →", systemImage: "arrowtriangle.right.fill", isEnabled: ctx.canCombineRight, action: ctx.combineRight)
                boundaryButton(title: "Split", systemImage: "scissors", isEnabled: ctx.canSplit, action: ctx.beginSplit)
            }
        }

        private func boundaryButton(title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
            VStack(spacing: 4) {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .disabled(!isEnabled)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
            }
        }

        private func customBoundaryIndicator(_ status: CustomStatus) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Label(status.description, systemImage: status.iconName)
                    .font(.caption)
                    .foregroundStyle(status.kind == CustomStatus.Kind.merged ? .orange : .blue)
                if let undo = status.undo {
                    Button("Undo", action: undo)
                        .font(.caption)
                        .buttonStyle(.bordered)
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

        private func beginCustomEntry() {
            customEntryDraft = CustomEntryDraft(
                surface: displayKanji,
                reading: displayKana.isEmpty ? (token.reading.isEmpty ? token.surface : token.reading) : displayKana,
                meaning: entryLocal.map { primaryGloss(from: $0) } ?? (fallbackTranslation ?? "")
            )
            customEntryError = nil
            showingCustomEntryEditor = true
        }

        private func customEntrySheet() -> some View {
            NavigationStack {
                Form {
                    Section("Surface / Kanji") {
                        TextField("Surface", text: $customEntryDraft.surface)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    Section("Reading") {
                        TextField("Reading", text: $customEntryDraft.reading)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    Section("Meaning") {
                        TextField("Meaning", text: $customEntryDraft.meaning, axis: .vertical)
                            .lineLimit(5)
                    }
                    if let customEntryError {
                        Section {
                            Text(customEntryError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("Customize Entry")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingCustomEntryEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveCustomEntry() }
                            .disabled(customEntryDraft.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }

        private func saveCustomEntry() {
            let trimmedSurface = customEntryDraft.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedSurface.isEmpty == false else {
                customEntryError = "Surface cannot be empty."
                return
            }
            let trimmedMeaning = customEntryDraft.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedMeaning.isEmpty == false else {
                customEntryError = "Meaning cannot be empty."
                return
            }
            let trimmedReading = customEntryDraft.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            let draft = CustomEntryDraft(surface: trimmedSurface, reading: trimmedReading, meaning: trimmedMeaning)
            customEntryError = nil
            onAddCustomEntry(draft)
            showingCustomEntryEditor = false
        }
    }
}

extension DefinitionSheetContent {
    struct BoundaryActionContext {
        let canCombineLeft: Bool
        let canCombineRight: Bool
        let canSplit: Bool
        let combineLeft: () -> Void
        let combineRight: () -> Void
        let beginSplit: () -> Void
        let customStatus: CustomStatus?
    }

    struct CustomStatus {
        enum Kind {
            case merged
            case split
        }
        let kind: Kind
        let description: String
        let iconName: String
        let undo: (() -> Void)?
    }

    struct CustomEntryDraft {
        var surface: String
        var reading: String
        var meaning: String

        init(surface: String = "", reading: String = "", meaning: String = "") {
            self.surface = surface
            self.reading = reading
            self.meaning = meaning
        }
    }
}
