import SwiftUI
import OSLog

fileprivate let extractLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Extract")

struct ExtractWordsView: View {
    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore

    let text: String
    var sourceNoteID: UUID? = nil

    @State private var tokens: [ParsedToken] = []
    @State private var selectedToken: ParsedToken? = nil
    @State private var showingDefinition = false

    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil

    @State private var hideDuplicates: Bool = true
    @State private var hideParticles: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Toggle("Hide duplicates", isOn: $hideDuplicates)
                    .toggleStyle(.switch)
                Toggle("Hide particles", isOn: $hideParticles)
                    .toggleStyle(.switch)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            List {
                ForEach(filteredTokens) { token in
                    HStack(spacing: 12) {
                        FuriganaTextView(token: token)
                        Spacer()

                        Button {
                            selectedToken = token
                            extractLogger.info("Word tapped: surface='\(token.surface, privacy: .public)', reading='\(token.reading, privacy: .public)'")
                            showingDefinition = true
                            Task { await lookupDefinitions(for: token) }
                        } label: {
                            if store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedToken = token
                        extractLogger.info("Word tapped: surface='\(token.surface, privacy: .public)', reading='\(token.reading, privacy: .public)'")
                        showingDefinition = true
                        Task { await lookupDefinitions(for: token) }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Extract Words")
        .onAppear {
            let parsed = JapaneseParser.parse(text: text)
            tokens = parsed.filter { tok in
                tok.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }
        .sheet(isPresented: $showingDefinition) {
            if selectedToken != nil {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            if let entry = dictResults.first {
                                let surface = entry.kanji.isEmpty ? entry.reading : entry.kanji
                                let meaning = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
                                store.add(surface: surface, reading: entry.reading, meaning: meaning, sourceNoteID: sourceNoteID)
                            }
                            showingDefinition = false
                        }) {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .disabled(isLookingUp || dictResults.first == nil)

                        Spacer()

                        Button(action: { showingDefinition = false }) {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                    }

                    if isLookingUp {
                        ProgressView("Looking up definitions…")
                    } else if let err = lookupError {
                        Text(err).foregroundStyle(.secondary)
                    } else if let entry = dictResults.first {
                        Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                            .font(.title2).bold()
                        if !entry.reading.isEmpty {
                            Text(entry.reading)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        let firstGloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
                        Text(firstGloss)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No definitions found.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .presentationDetents([.medium, .large])
            } else {
                Text("No selection").padding()
            }
        }
    }

    private func lookupDefinitions(for token: ParsedToken) async {
        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictResults = []
        }
        do {
            var results = try await DictionarySQLiteStore.shared.lookup(term: token.surface, limit: 1)
            if results.isEmpty && !token.reading.isEmpty {
                let alt = try await DictionarySQLiteStore.shared.lookup(term: token.reading, limit: 1)
                if !alt.isEmpty { results = alt }
            }
            await MainActor.run {
                dictResults = results
                isLookingUp = false
            }
            if let e = dictResults.first {
                let surface = e.kanji.isEmpty ? e.reading : e.kanji
                let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                extractLogger.info("Popup will show: surface='\(surface, privacy: .public)', reading='\(e.reading, privacy: .public)', gloss='\(firstGloss, privacy: .public)'")
            } else if let err = lookupError {
                extractLogger.error("Popup error: \(err, privacy: .public)")
            } else {
                extractLogger.info("Popup will show: no definitions found for surface='\(token.surface, privacy: .public)', reading='\(token.reading, privacy: .public)'")
            }
        } catch {
            await MainActor.run {
                lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
                isLookingUp = false
            }
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
}

