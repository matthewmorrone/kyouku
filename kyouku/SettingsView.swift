import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore

    @State private var exportURL: URL? = nil
    @State private var isImporting: Bool = false
    @State private var importError: String? = nil
    @State private var importSummary: String? = nil

    var body: some View {
        NavigationStack {
            Form {
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
                NotificationCenter.default.post(name: .didImportNotesBackup, object: backup.notes)
                importSummary = "Imported \(backup.words.count) words and \(backup.notes.count) notes."
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
            exportURL = try AppDataBackup.exportData(words: words, notes: notes)
        } catch {
            importError = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let didImportNotesBackup = Notification.Name("didImportNotesBackup")
}
