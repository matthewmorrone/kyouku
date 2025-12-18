//
//  SettingsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: WordStore
    @EnvironmentObject private var notesStore: NotesStore

    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4
    @AppStorage("wotdHour") private var wotdHour: Int = 9
    @AppStorage("wotdMinute") private var wotdMinute: Int = 0
    @AppStorage(SegmentationEngine.storageKey) private var segmentationEngineRaw: String = SegmentationEngine.defaultValue.rawValue

    @State private var preview: NSAttributedString = NSAttributedString(string: "")
    @State private var wotdPreviewWord: Word? = nil
    @State private var deliveryTime = Date()
    @State private var schedulingFeedback: String? = nil

    @State private var exportURL: URL? = nil
    @State private var isImporting: Bool = false
    @State private var importError: String? = nil
    @State private var isImportingWords: Bool = false
    @State private var preferKanaOnly: Bool = false
    @State private var importSummary: String? = nil

    @State private var importPreviewURL: URL? = nil
    @State private var previewItems: [ImportPreviewItem] = []
    @State private var showImportPreview: Bool = false

    // MARK: - Import bridging helpers
    private func toImporterItems(_ items: [ImportPreviewItem]) -> [WordImporter.ImportItem] {
        return items.map { it in
            WordImporter.ImportItem(
                lineNumber: it.lineNumber,
                providedSurface: it.providedSurface,
                providedReading: it.providedReading,
                providedMeaning: it.providedMeaning,
                note: it.note,
                computedSurface: it.computedSurface,
                computedReading: it.computedReading,
                computedMeaning: it.computedMeaning
            )
        }
    }

    private func updatePreviewItems(from importerItems: [WordImporter.ImportItem]) {
        self.previewItems = importerItems.map { it in
            ImportPreviewItem(
                lineNumber: it.lineNumber,
                providedSurface: it.providedSurface,
                providedReading: it.providedReading,
                providedMeaning: it.providedMeaning,
                note: it.note,
                computedSurface: it.computedSurface,
                computedReading: it.computedReading,
                computedMeaning: it.computedMeaning
            )
        }
    }

    @MainActor
    private func fillMissingForPreviewItems() async {
        var importerItems = toImporterItems(self.previewItems)
        await WordImporter.fillMissing(items: &importerItems, preferKanaOnly: self.preferKanaOnly)
        updatePreviewItems(from: importerItems)
    }

    private func finalizePreviewItems() -> [(surface: String, reading: String, meaning: String, note: String?)] {
        let prepared = WordImporter.finalize(items: toImporterItems(self.previewItems), preferKanaOnly: self.preferKanaOnly)
        return prepared.map { (surface: $0.surface, reading: $0.reading, meaning: $0.meaning, note: $0.note) }
    }

    var body: some View {
        NavigationStack {
            Form {
                readingAppearanceSection
                tokenizerSection
                wordOfTheDaySection
                backupRestoreSection
            }
            .navigationTitle("Settings")
            .onAppear { rebuildPreview() }
            .onChange(of: textSize) { rebuildPreview() }
            .onChange(of: furiganaSize) { rebuildPreview() }
            .onChange(of: lineSpacing) { rebuildPreview() }
            .onAppear {
                syncWotdTime()
                refreshPreviewWord()
            }
            .onReceive(store.$words) { _ in refreshPreviewWord() }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], onCompletion: handleBackupImport)
            .fileImporter(isPresented: $isImportingWords, allowedContentTypes: [.commaSeparatedText, .plainText], onCompletion: handleWordsImport)
            .sheet(isPresented: exportSheetBinding) {
                if let exportURL {
                    ShareLink(item: exportURL) { Text("Share Backup") }
                        .presentationDetents([.medium, .large])
                }
            }
            .alert("Import Error", isPresented: .constant(importError != nil), actions: {
                Button("OK") { importError = nil }
            }, message: {
                Text(importError ?? "Unknown error")
            })
            .alert("Import Summary", isPresented: importSummaryBinding) {
                Button("OK") { importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
            .sheet(isPresented: $showImportPreview) {
                makeImportPreviewSheet()
                    .presentationDetents([.large])
            }
        }
    }

    private var readingAppearanceSection: some View {
        Section("Reading Appearance") {
            FuriganaTextView(attributedText: preview)
                .frame(maxWidth: .infinity, idealHeight: 80, alignment: .leading)
                .padding(.vertical, 8)

            HStack {
                Text("Text Size")
                Spacer()
                Text("\(Int(textSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $textSize, in: 1...30, step: 1)

            HStack {
                Text("Furigana Size")
                Spacer()
                Text("\(Int(furiganaSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $furiganaSize, in: 1...30, step: 1)
            
            HStack {
                Text("Line Spacing")
                Spacer()
                Text("\(Int(lineSpacing))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $lineSpacing, in: 1...30, step: 1)
        }
    }

    private var tokenizerSection: some View {
        Section("Tokenizer") {
            Picker("Engine", selection: $segmentationEngineRaw) {
                ForEach(SegmentationEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedSegmentationEngine.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var wordOfTheDaySection: some View {
        Section("Word of the Day") {
            DatePicker(
                "Delivery Time",
                selection: $deliveryTime,
                displayedComponents: .hourAndMinute
            )
            .disabled(store.words.isEmpty)
            .onChange(of: deliveryTime) { _, newValue in updateStoredWotdTime(with: newValue) }

            if store.words.isEmpty {
                Text("Add words to your list to enable Word of the Day notifications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Schedule Daily Notification") { scheduleDailyNotification() }
                Button("Send Word Now") { sendWordNow() }
                    .tint(.accentColor)
            }

            if let feedback = schedulingFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let word = wotdPreviewWord {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest WotD pick")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(word.surface)【\(word.reading)】")
                        .font(.headline)
                    Text(word.meaning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let jURL = jishoURL(for: word) {
                        Link("Open on Jisho", destination: jURL)
                            .font(.callout)
                    }
                    if let url = NotificationManager.shared.dictionaryURL(for: word) {
                        Link("Open on Wiktionary", destination: url)
                            .font(.callout)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var backupRestoreSection: some View {
        Section("Backup & Restore") {
            Button("Export…") { exportAll() }
            Button("Import…") { isImporting = true }
                .tint(.red)
                .foregroundStyle(.red)

            Button("Import Words…") { isImportingWords = true }
        }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(get: { exportURL != nil }, set: { if $0 == false { exportURL = nil } })
    }

    private var importSummaryBinding: Binding<Bool> {
        Binding(get: { importSummary != nil }, set: { if $0 == false { importSummary = nil } })
    }

    private func handleBackupImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let backup = try AppDataBackup.importData(from: url)
                store.replaceAll(with: backup.words)
                NotificationCenter.default.post(name: .didImportNotesBackup, object: backup.notes)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    private func handleWordsImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let items = try WordImporter.parseItems(from: url)
                importPreviewURL = url
                self.updatePreviewItems(from: items)
                showImportPreview = true
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    @MainActor
    private func rebuildPreview() {
        let sample = "日本語の文章です。\n日本語の文章です。"
        preview = JapaneseFuriganaBuilder.buildAttributedText(
            text: sample,
            showFurigana: true,
            baseFontSize: CGFloat(textSize),
            rubyFontSize: CGFloat(furiganaSize),
            lineSpacing: CGFloat(lineSpacing)
        )
    }

    private func syncWotdTime() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = wotdHour
        comps.minute = wotdMinute
        deliveryTime = Calendar.current.date(from: comps) ?? Date()
    }

    private func updateStoredWotdTime(with date: Date) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        wotdHour = comps.hour ?? wotdHour
        wotdMinute = comps.minute ?? wotdMinute
    }

    private func refreshPreviewWord() {
        wotdPreviewWord = store.randomWord()
        if store.words.isEmpty {
            schedulingFeedback = nil
        }
    }

    private func scheduleDailyNotification() {
        guard let word = store.randomWord() else {
            schedulingFeedback = "No words available."
            return
        }
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.scheduleDailyWord(at: wotdHour, minute: wotdMinute, word: word)
        wotdPreviewWord = word
        schedulingFeedback = "Scheduled daily WotD for \(formattedTime())."
    }

    private func sendWordNow() {
        guard let word = store.randomWord() else {
            schedulingFeedback = "No words available."
            return
        }
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.sendWordImmediately(word)
        wotdPreviewWord = word
        schedulingFeedback = "Sent \(word.surface) just now."
    }

    private func formattedTime() -> String {
        var comps = DateComponents()
        comps.hour = wotdHour
        comps.minute = wotdMinute
        let calendar = Calendar.current
        if let date = calendar.date(from: comps) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
        return "your chosen time"
    }

    private var selectedSegmentationEngine: SegmentationEngine {
        SegmentationEngine(rawValue: segmentationEngineRaw) ?? .dictionaryTrie
    }

    private func jishoURL(for word: Word) -> URL? {
        let query = word.surface.isEmpty ? word.reading : word.surface
        guard query.isEmpty == false else { return nil }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://jisho.org/search/\(encoded)")
    }

    private func exportAll() {
        do {
            let words = store.allWords()
            let notes = notesStore.allNotes()
            let url = try AppDataBackup.exportData(words: words, notes: notes)
            exportURL = url
        } catch {
            importError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func makeImportPreviewSheet() -> some View {
        ImportPreviewSheet(
            items: $previewItems,
            preferKanaOnly: $preferKanaOnly,
            onFill: {
                Task { await fillMissingForPreviewItems() }
            },
            onConfirm: {
                let prepared = finalizePreviewItems()
                var added = 0
                for w in prepared {
                    let before = store.allWords().count
                    store.add(surface: w.surface, reading: w.reading, meaning: w.meaning, note: w.note)
                    let after = store.allWords().count
                    if after > before { added += 1 }
                }
                importSummary = "Imported words: \(added). Skipped: \(prepared.count - added)."
                showImportPreview = false
            },
            onCancel: {
                showImportPreview = false
            }
        )
    }
}

extension Notification.Name {
    static let didImportNotesBackup = Notification.Name("didImportNotesBackup")
}

// Local mirror of WordImporter.ImportItem to avoid direct cross-file type dependency at property level
private struct ImportPreviewItem: Identifiable, Hashable {
    let id: UUID
    let lineNumber: Int
    var providedSurface: String?
    var providedReading: String?
    var providedMeaning: String?
    var note: String?
    var computedSurface: String?
    var computedReading: String?
    var computedMeaning: String?

    init(id: UUID = UUID(), lineNumber: Int, providedSurface: String?, providedReading: String?, providedMeaning: String?, note: String?, computedSurface: String?, computedReading: String?, computedMeaning: String?) {
        self.id = id
        self.lineNumber = lineNumber
        self.providedSurface = providedSurface
        self.providedReading = providedReading
        self.providedMeaning = providedMeaning
        self.note = note
        self.computedSurface = computedSurface
        self.computedReading = computedReading
        self.computedMeaning = computedMeaning
    }
}
private struct ImportPreviewSheet: View {
    @Binding var items: [ImportPreviewItem]
    @Binding var preferKanaOnly: Bool
    var onFill: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Options") {
                    Toggle("Prefer kana-only surface when only kana provided", isOn: $preferKanaOnly)
                        .tint(.accentColor)
                }
                Section("Preview") {
                    if items.isEmpty {
                        Text("No items parsed.").foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { it in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text((it.providedSurface ?? it.computedSurface) ?? "—")
                                        .font(.headline)
                                    let kana = (it.providedReading ?? it.computedReading) ?? ""
                                    if !kana.isEmpty {
                                        Text(kana)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let m = (it.providedMeaning ?? it.computedMeaning), !m.isEmpty {
                                    Text(m)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("<no meaning>")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                                if let n = it.note, !n.isEmpty {
                                    Text(n)
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Import Preview")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button("Fill Missing") { onFill() }
                        Button("Confirm") { onConfirm() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

