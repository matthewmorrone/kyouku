import SwiftUI
import OSLog

fileprivate let extractLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Extract")

struct ExtractWordsView: View {
    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore

    let text: String
    var sourceNoteID: UUID? = nil
    var onTokensUpdated: (([ParsedToken]) -> Void)? = nil

    @State private var tokens: [ParsedToken] = []
    @State private var selectedToken: ParsedToken? = nil
    @State private var activeLookupTokenID: UUID? = nil
    @State private var lookupTask: Task<Void, Never>? = nil

    @State private var dictResults: [DictionaryEntry] = []
    @State private var lookupError: String? = nil

    @State private var hideDuplicates: Bool = true
    @State private var hideParticles: Bool = true
        // Removed unused toggle state
    @State private var selectedDefinitionIndex: Int = 0
    @State private var didLookup: Bool = false

    @State private var isSelecting: Bool = false
    @State private var selectedTokenIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Toggle("Hide Duplicates", isOn: $hideDuplicates)
                    .toggleStyle(.switch).lineLimit(1)
                Toggle("Hide Particles", isOn: $hideParticles)
                    .toggleStyle(.switch).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            List {
                TokensListView(
                    tokens: filteredTokens,
                    isSelecting: $isSelecting,
                    selectedTokenIDs: $selectedTokenIDs,
                    store: store,
                    presentDefinition: { token in
                        presentDefinition(for: token)
                    }
                )
            }
        }
        .navigationTitle("Extract Words")
        .onAppear {
            let parsed = JapaneseParser.parse(text: text)
            tokens = parsed.filter { tok in
                tok.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            // Pre-warm the dictionary to avoid first-use lag
            Task {
                _ = try? await DictionarySQLiteStore.shared.lookup(term: "の", limit: 1)
            }
        }
        .onDisappear {
            onTokensUpdated?(tokens)
            dismissDefinitionSheet()
            isSelecting = false
            selectedTokenIDs.removeAll()
        }
        .onChange(of: selectedToken) { _, newValue in
            if newValue == nil {
                resetLookupState()
            }
        }
        .sheet(item: $selectedToken, onDismiss: { dismissDefinitionSheet() }) { token in
            let hasKanjiInToken: Bool = containsKanji(token.surface)
            let orderedResults = orderedEntries(for: token, entries: dictResults)
            let totalResults = orderedResults.count
            let currentIndex = clampDefinitionSelection(total: totalResults)
            let currentEntry = (currentIndex >= 0 && currentIndex < totalResults) ? orderedResults[currentIndex] : nil
            let displayKanji: String = {
                if !hasKanjiInToken {
                    return token.reading.isEmpty ? token.surface : token.reading
                }
                if let entry = currentEntry {
                    return entry.kanji.isEmpty ? entry.reading : entry.kanji
                }
                return token.surface
            }()
            let displayKana: String = currentEntry?.reading ?? token.reading

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            addWord(from: token, with: orderedResults, at: currentEntry == nil ? nil : currentIndex, translation: nil)
                            dismissDefinitionSheet()
                        }) {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .disabled(currentEntry == nil)

                        Spacer()

                        Button(action: { dismissDefinitionSheet() }) {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                    }

                    if totalResults > 1 {
                        HStack(spacing: 16) {
                            Button {
                                stepDefinitionSelection(-1, total: totalResults)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.title3)
                            }
                            .disabled(currentIndex <= 0)

                            Text("Definition \(currentIndex + 1) / \(totalResults)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button {
                                stepDefinitionSelection(1, total: totalResults)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.title3)
                            }
                            .disabled(currentIndex >= totalResults - 1)
                        }
                    }

                    Text(displayKanji)
                        .font(.title2).bold()

                    if !displayKana.isEmpty && displayKana != displayKanji {
                        Text(displayKana)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    if didLookup {
                        if let err = lookupError {
                            Text(err).foregroundStyle(.secondary)
                        } else if orderedResults.isEmpty {
                            Text("No definitions found.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                if let entry = currentEntry {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                            .font(.headline)
                                        Text(entry.gloss)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 16)
            }
            .safeAreaPadding(.top, 8)
            .onAppear {
                extractLogger.info("Dictionary popup: word='\(displayKanji, privacy: .public)', kana='\(displayKana, privacy: .public)'")
            }
            .onChange(of: dictResults) { _, _ in
                let ordered = orderedEntries(for: token, entries: dictResults)
                if ordered.isEmpty {
                    selectedDefinitionIndex = 0
                } else if selectedDefinitionIndex >= ordered.count {
                    selectedDefinitionIndex = max(0, ordered.count - 1)
                }
                let currentKanji: String = {
                    if !hasKanjiInToken {
                        return token.reading.isEmpty ? token.surface : token.reading
                    }
                    if let entry = ordered.first {
                        return entry.kanji.isEmpty ? entry.reading : entry.kanji
                    }
                    return token.surface
                }()
                let currentKana: String = ordered.first?.reading ?? token.reading
                extractLogger.info("Dictionary popup updated: word='\(currentKanji, privacy: .public)', kana='\(currentKana, privacy: .public)'")
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting {
                        isSelecting = false
                        selectedTokenIDs.removeAll()
                    } else {
                        isSelecting = true
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            isSelecting = false
                            selectedTokenIDs.removeAll()
                        }
                        Spacer()
                        Button("Combine Selected") {
                            combineSelectedTokens()
                        }
                        .disabled(!canCombineSelected())
                        Button("Add Selected (\(selectedTokenIDs.count))") {
                            addSelectedTokens()
                        }
                        .disabled(selectedTokenIDs.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(.regularMaterial)
            }
        }
    }

    private struct TokensListView: View {
        let tokens: [ParsedToken]
        @Binding var isSelecting: Bool
        @Binding var selectedTokenIDs: Set<UUID>
        let store: WordStore
        let presentDefinition: (ParsedToken) -> Void

        var body: some View {
            ForEach(tokens) { token in
                TokenRowView(
                    token: token,
                    isSelecting: $isSelecting,
                    selectedTokenIDs: $selectedTokenIDs,
                    isAlreadyAdded: store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }),
                    onTap: { presentDefinition(token) }
                )
            }
        }
    }

    private struct TokenRowView: View {
        let token: ParsedToken
        @Binding var isSelecting: Bool
        @Binding var selectedTokenIDs: Set<UUID>
        let isAlreadyAdded: Bool
        let onTap: () -> Void

        var body: some View {
            let isSelected = selectedTokenIDs.contains(token.id)
            HStack(spacing: 12) {
                if isSelecting {
                    Button(action: { toggleSelect(token) }) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

                FuriganaTextView(token: token)
                Spacer()

                if !isSelecting {
                    Button(action: { onTap() }) {
                        if isAlreadyAdded {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isAlreadyAdded)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    toggleSelect(token)
                } else {
                    onTap()
                }
            }
            .padding(.vertical, 6)
        }

        private func toggleSelect(_ token: ParsedToken) {
            if selectedTokenIDs.contains(token.id) {
                selectedTokenIDs.remove(token.id)
            } else {
                selectedTokenIDs.insert(token.id)
            }
        }
    }

    private func containsKanji(_ text: String) -> Bool {
        for ch in text { if ("\u{4E00}"..."\u{9FFF}").contains(String(ch)) { return true } }
        return false
    }

    private func latinToHiragana(_ text: String) -> String? {
        let lower = text.lowercased() as NSString
        let mutable = NSMutableString(string: lower as String)
        let transformed = CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
        return transformed ? (mutable as String) : nil
    }

    private func latinToKatakana(_ text: String) -> String? {
        let lower = text.lowercased() as NSString
        let mutable = NSMutableString(string: lower as String)
        let transformed = CFStringTransform(mutable, nil, kCFStringTransformLatinKatakana, false)
        return transformed ? (mutable as String) : nil
    }

    private struct TimeoutError: Error {}

    private func withTimeout<T>(_ seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func clampDefinitionSelection(total: Int) -> Int {
        guard total > 0 else { return 0 }
        return min(max(selectedDefinitionIndex, 0), total - 1)
    }

    private func stepDefinitionSelection(_ delta: Int, total: Int) {
        guard total > 0 else { return }
        let current = clampDefinitionSelection(total: total)
        let next = current + delta
        guard next >= 0 && next < total else { return }
        selectedDefinitionIndex = next
    }

    private func resetLookupState() {
        lookupTask?.cancel()
        lookupTask = nil
        dictResults = []
        lookupError = nil
        activeLookupTokenID = nil
        selectedDefinitionIndex = 0
    }

    private func presentDefinition(for token: ParsedToken) {
        lookupTask?.cancel()
        activeLookupTokenID = nil

        extractLogger.info("Word tapped: surface='\(token.surface, privacy: .public)', reading='\(token.reading, privacy: .public)'")
        resetLookupState()
        selectedDefinitionIndex = 0
        didLookup = false
        selectedToken = token
        lookupTask = Task {
            await lookupDefinitions(for: token)
        }
        // keep a strong reference to avoid 'unused Task' warning and allow cancellation
    }

    private func dismissDefinitionSheet() {
        lookupTask?.cancel()
        resetLookupState()
        selectedToken = nil
    }

    private func toggleSelect(_ token: ParsedToken) {
        if selectedTokenIDs.contains(token.id) {
            selectedTokenIDs.remove(token.id)
        } else {
            selectedTokenIDs.insert(token.id)
        }
    }

    private func addSelectedTokens() {
        let tokensToAdd = filteredTokens.filter { selectedTokenIDs.contains($0.id) }
        for token in tokensToAdd {
            // Skip if already added
            if store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
                continue
            }
            // Batch add without dictionary definition; will use token.meaning if available
            addWord(from: token, with: [], at: nil, translation: nil)
        }
        // Clear selection state after adding
        selectedTokenIDs.removeAll()
        isSelecting = false
    }

    private func selectedIndicesInTokens() -> [Int] {
        // Map selected IDs to indices in the original tokens array and sort them
        var indexMap: [UUID: Int] = [:]
        for (i, t) in tokens.enumerated() { indexMap[t.id] = i }
        return selectedTokenIDs.compactMap { indexMap[$0] }.sorted()
    }

    private func canCombineSelected() -> Bool {
        let idxs = selectedIndicesInTokens()
        guard idxs.count >= 2 else { return false }
        for i in 0..<(idxs.count - 1) {
            if idxs[i + 1] != idxs[i] + 1 { return false }
        }
        return true
    }

    private func combineSelectedTokens() {
        let idxs = selectedIndicesInTokens()
        guard idxs.count >= 2 else { return }
        // Ensure contiguity in the original tokens array
        for i in 0..<(idxs.count - 1) {
            if idxs[i + 1] != idxs[i] + 1 { return }
        }
        let start = idxs.first!
        let end = idxs.last!
        let slice = tokens[start...end]
        let combinedSurface = slice.map { $0.surface }.joined()
        let combinedReading = slice.map { $0.reading }.joined()
        let newToken = ParsedToken(surface: combinedSurface, reading: combinedReading, meaning: nil)
        tokens.replaceSubrange(start...end, with: [newToken])
        // Clear selection state and exit selection mode
        selectedTokenIDs.removeAll()
        isSelecting = false
        onTokensUpdated?(tokens)
    }

    private func addWord(from token: ParsedToken, with filteredResults: [DictionaryEntry], at index: Int?, translation: String?) {
        let chosenEntry: DictionaryEntry? = {
            guard let idx = index, idx >= 0, idx < filteredResults.count else {
                return filteredResults.first
            }
            return filteredResults[idx]
        }()

        if let entry = chosenEntry {
            let surface = entry.kanji.isEmpty ? entry.reading : entry.kanji
            let meaning = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
            store.add(surface: surface, reading: entry.reading, meaning: meaning, sourceNoteID: sourceNoteID)
        } else if let translation, translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            store.add(surface: token.surface, reading: token.reading, meaning: translation, sourceNoteID: sourceNoteID)
        } else if let meaning = token.meaning, !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.add(surface: token.surface, reading: token.reading, meaning: meaning, sourceNoteID: sourceNoteID)
        }
    }

    private func lookupDefinitions(for token: ParsedToken) async {
        let tokenID = token.id

        await MainActor.run {
            activeLookupTokenID = tokenID
            lookupError = nil
            dictResults = []
            selectedDefinitionIndex = 0
            didLookup = false
        }

        if Task.isCancelled { return }

        let limit = 10
        let rawSurface = token.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawReading = token.reading.trimmingCharacters(in: .whitespacesAndNewlines)

        let latinRegex = "^[A-Za-z0-9]+$"
        let isLatin = rawSurface.range(of: latinRegex, options: .regularExpression) != nil
        if rawSurface.isEmpty && rawReading.isEmpty {
            await MainActor.run {
                guard activeLookupTokenID == tokenID else { return }
                dictResults = []
                lookupError = nil
                selectedDefinitionIndex = 0
                didLookup = true
            }
            return
        }

        var results: [DictionaryEntry] = []

        if isLatin {
            if let hira = latinToHiragana(rawSurface), !hira.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = (try? await withTimeout(0.15) { try await DictionarySQLiteStore.shared.lookup(term: hira, limit: limit) }) ?? []
            }
            if results.isEmpty, let kata = latinToKatakana(rawSurface), !kata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Task.isCancelled {
                results = (try? await withTimeout(0.15) { try await DictionarySQLiteStore.shared.lookup(term: kata, limit: limit) }) ?? []
            }
        } else {
            if !rawSurface.isEmpty {
                results = (try? await withTimeout(0.15) { try await DictionarySQLiteStore.shared.lookup(term: rawSurface, limit: limit) }) ?? []
            }
            if results.isEmpty && !rawReading.isEmpty && !Task.isCancelled {
                results = (try? await withTimeout(0.15) { try await DictionarySQLiteStore.shared.lookup(term: rawReading, limit: limit) }) ?? []
            }
        }

        if Task.isCancelled { return }

        await MainActor.run {
            guard activeLookupTokenID == tokenID else { return }
            dictResults = results
            selectedDefinitionIndex = 0
            lookupError = nil
            didLookup = true
        }
    }

    private var filteredTokens: [ParsedToken] {
        var base = tokens
        if hideDuplicates {
            var seen = Set<String>()
            base = base.filter { t in
                let key = t.surface + "\u{241F}" + t.reading
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
        }
        if hideParticles {
            let particles: Set<String> = ["は","が","を","に","へ","と","で","や","の","も","ね","よ","な"]
            base = base.filter { t in
                let s = t.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                return !particles.contains(s)
            }
        }
        return base
    }

    private func orderedEntries(for token: ParsedToken, entries: [DictionaryEntry]) -> [DictionaryEntry] {
        guard !entries.isEmpty else { return [] }
        if containsKanji(token.surface) { return entries }
        let target = token.reading.isEmpty ? token.surface : token.reading
        let matches = entries.filter { $0.reading == target }
        if matches.isEmpty { return entries }
        let remainder = entries.filter { $0.reading != target }
        return matches + remainder
    }
}

