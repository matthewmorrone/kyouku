import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var readingOverrides: ReadingOverridesStore

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4

    @State private var exportURL: URL? = nil
    @State private var isImporting: Bool = false
    @State private var importError: String? = nil
    @State private var importSummary: String? = nil

    @State private var previewAttributedText = NSAttributedString(string: SettingsView.previewSampleTextValue)
    @State private var previewRebuildTask: Task<Void, Never>? = nil
    @State private var previewSpans: [AnnotatedSpan]? = nil
    @State private var previewValuesInitialized = false
    @State private var pendingReadingTextSize: Double = 17
    @State private var pendingReadingFuriganaSize: Double = 9
    @State private var pendingReadingLineSpacing: Double = 4

    private static let previewPlainLine = "かなだけのぎょうです。"
    private static let previewFuriganaLine = "京都で日本語を勉強しています。"
    private static let previewSampleTextValue = "\(previewPlainLine)\n\(previewFuriganaLine)"

    private var previewSampleText: String { Self.previewSampleTextValue }

    var body: some View {
        NavigationStack {
            Form {
                textAppearanceSection
                Section("Backup & Restore") {
                    Button("Export…") {
                        exportAll()
                    }
                    Button("Import…") {
                        isImporting = true
                    }
                    .tint(.red)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                onCompletion: handleBackupImport
            )
            .sheet(isPresented: exportSheetBinding) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Text("Share Backup")
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .alert(
                "Import Error",
                isPresented: .constant(importError != nil),
                actions: { Button("OK") { importError = nil } },
                message: { Text(importError ?? "Unknown error") }
            )
            .alert("Import Summary", isPresented: importSummaryBinding) {
                Button("OK") { importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
            .task { await initializePreviewValuesIfNeeded() }
            .onChange(of: readingTextSize) { _, newValue in syncPendingTextSize(to: newValue) }
            .onChange(of: readingFuriganaSize) { _, newValue in syncPendingFuriganaSize(to: newValue) }
            .onChange(of: readingLineSpacing) { _, newValue in syncPendingLineSpacing(to: newValue) }
            .onDisappear { previewRebuildTask?.cancel() }
        }
    }

    private var textAppearanceSection: some View {
        Section("Reading Appearance") {
            RubyText(
                attributed: previewAttributedText,
                fontSize: CGFloat(pendingReadingTextSize),
                lineHeightMultiple: 1.0,
                extraGap: CGFloat(pendingReadingLineSpacing)
            )
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(.vertical, 8)

            HStack {
                Text("Text Size")
                Spacer()
                Text("\(Int(pendingReadingTextSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { pendingReadingTextSize },
                    set: { pendingReadingTextSize = $0; schedulePreviewRebuild() }
                ),
                in: 1...30,
                step: 1,
                onEditingChanged: { editing in
                    if editing == false { readingTextSize = pendingReadingTextSize }
                }
            )

            HStack {
                Text("Furigana Size")
                Spacer()
                Text("\(Int(pendingReadingFuriganaSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { pendingReadingFuriganaSize },
                    set: { pendingReadingFuriganaSize = $0; schedulePreviewRebuild() }
                ),
                in: 1...30,
                step: 1,
                onEditingChanged: { editing in
                    if editing == false { readingFuriganaSize = pendingReadingFuriganaSize }
                }
            )

            HStack {
                Text("Line Spacing")
                Spacer()
                Text("\(Int(pendingReadingLineSpacing))")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { pendingReadingLineSpacing },
                    set: { pendingReadingLineSpacing = $0 }
                ),
                in: 1...30,
                step: 1,
                onEditingChanged: { editing in
                    if editing == false { readingLineSpacing = pendingReadingLineSpacing }
                }
            )

        }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { exportURL != nil },
            set: { if $0 == false { exportURL = nil } }
        )
    }

    private var importSummaryBinding: Binding<Bool> {
        Binding(
            get: { importSummary != nil },
            set: { if $0 == false { importSummary = nil } }
        )
    }

    private func handleBackupImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer {
                if needsStop {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                let backup = try AppDataBackup.importData(from: url)
                wordsStore.replaceAll(with: backup.words)
                notesStore.replaceAll(with: backup.notes)
                readingOverrides.replaceAll(with: backup.readingOverrides)
                NotificationCenter.default.post(name: .didImportNotesBackup, object: backup.notes)
                importSummary = "Imported \(backup.words.count) words, \(backup.notes.count) notes, and \(backup.readingOverrides.count) reading overrides."
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    private func exportAll() {
        do {
            let words = wordsStore.allWords()
            let notes = notesStore.allNotes()
            let overrides = readingOverrides.allOverrides()
            exportURL = try AppDataBackup.exportData(words: words, notes: notes, readingOverrides: overrides)
        } catch {
            importError = error.localizedDescription
        }
    }

    @MainActor
    private func initializePreviewValuesIfNeeded() async {
        guard previewValuesInitialized == false else { return }
        previewValuesInitialized = true
        pendingReadingTextSize = readingTextSize
        pendingReadingFuriganaSize = readingFuriganaSize
        pendingReadingLineSpacing = readingLineSpacing
        _ = await ensurePreviewSpans()
        schedulePreviewRebuild()
    }

    private func syncPendingTextSize(to newValue: Double) {
        guard previewValuesInitialized else { return }
        if abs(pendingReadingTextSize - newValue) > .ulpOfOne {
            pendingReadingTextSize = newValue
            schedulePreviewRebuild()
        }
    }

    private func syncPendingFuriganaSize(to newValue: Double) {
        guard previewValuesInitialized else { return }
        if abs(pendingReadingFuriganaSize - newValue) > .ulpOfOne {
            pendingReadingFuriganaSize = newValue
            schedulePreviewRebuild()
        }
    }

    private func syncPendingLineSpacing(to newValue: Double) {
        guard previewValuesInitialized else { return }
        if abs(pendingReadingLineSpacing - newValue) > .ulpOfOne {
            pendingReadingLineSpacing = newValue
        }
    }

    private func schedulePreviewRebuild() {
        let textSize = pendingReadingTextSize
        let furiganaSize = pendingReadingFuriganaSize
        previewRebuildTask?.cancel()
        previewRebuildTask = Task {
            await rebuildPreviewAttributedText(textSize: textSize, furiganaSize: furiganaSize)
        }
    }

    private func rebuildPreviewAttributedText(textSize: Double, furiganaSize: Double) async {
        let spans = await ensurePreviewSpans()
        if Task.isCancelled { return }
        let attributed = FuriganaAttributedTextBuilder.project(
            text: previewSampleText,
            annotatedSpans: spans,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: "SettingsPreview"
        )
        if Task.isCancelled { return }
        await MainActor.run {
            previewAttributedText = attributed
        }
    }

    private func ensurePreviewSpans() async -> [AnnotatedSpan] {
        if let cached = await MainActor.run(body: { () -> [AnnotatedSpan]? in previewSpans }) {
            return cached
        }

        do {
            let spans = try await FuriganaAttributedTextBuilder.computeAnnotatedSpans(
                text: previewSampleText,
                context: "SettingsPreview"
            )
            await MainActor.run { previewSpans = spans }
            return spans
        } catch {
            await MainActor.run { previewSpans = [] }
            return []
        }
    }
}

extension Notification.Name {
    static let didImportNotesBackup = Notification.Name("didImportNotesBackup")
}
