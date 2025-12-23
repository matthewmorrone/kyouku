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
            .task {
                await rebuildPreviewAttributedText()
            }
        }
    }

    private var textAppearanceSection: some View {
        Section("Reading Appearance") {
            RubyText(
                attributed: previewAttributedText,
                fontSize: CGFloat(readingTextSize),
                lineHeightMultiple: 1.0,
                extraGap: CGFloat(readingLineSpacing)
            )
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(.vertical, 8)

            HStack {
                Text("Text Size")
                Spacer()
                Text("\(Int(readingTextSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $readingTextSize, in: 1...30, step: 1)

            HStack {
                Text("Furigana Size")
                Spacer()
                Text("\(Int(readingFuriganaSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $readingFuriganaSize, in: 1...30, step: 1)

            HStack {
                Text("Line Spacing")
                Spacer()
                Text("\(Int(readingLineSpacing))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $readingLineSpacing, in: 1...30, step: 1)

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

    private func rebuildPreviewAttributedText() async {
        do {
            let attributed = try await FuriganaAttributedTextBuilder.build(
                text: previewSampleText,
                textSize: readingTextSize,
                furiganaSize: readingFuriganaSize,
                context: "SettingsPreview"
            )
            await MainActor.run {
                previewAttributedText = attributed
            }
        } catch {
            await MainActor.run {
                previewAttributedText = NSAttributedString(string: previewSampleText)
            }
        }
    }
}

extension Notification.Name {
    static let didImportNotesBackup = Notification.Name("didImportNotesBackup")
}
