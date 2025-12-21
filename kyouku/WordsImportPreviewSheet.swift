import SwiftUI

struct WordsImportPreviewSheet: View {
    @Binding var items: [WordsImportPreviewItem]
    @Binding var preferKanaOnly: Bool
    var onFill: () async -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var isFilling: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section("Options") {
                    Toggle("Insert Kanji?", isOn: Binding(get: { !preferKanaOnly }, set: { preferKanaOnly = !$0 }))
                        .tint(.accentColor)
                }
                Section("Preview") {
                    let filtered = items.filter { it in
                        let s = ((it.providedSurface ?? it.computedSurface) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let r = ((it.providedReading ?? it.computedReading) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let m = ((it.providedMeaning ?? it.computedMeaning) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return !(s.isEmpty && r.isEmpty && m.isEmpty)
                    }
                    if filtered.isEmpty {
                        Text("No items parsed.").foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered) { it in
                            let surface = (it.providedSurface ?? it.computedSurface) ?? ""
                            let reading = (it.providedReading ?? it.computedReading) ?? ""
                            let meaning = (it.providedMeaning ?? it.computedMeaning) ?? ""
                            ImportPreviewDetectedRow(surface: surface, reading: reading, meaning: meaning, note: it.note)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Import Preview")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if isFilling {
                            ProgressView().controlSize(.small)
                        }
                        Button("Fill Missing") {
                            isFilling = true
                            Task {
                                await onFill()
                                isFilling = false
                            }
                        }
                        Button("Confirm") { onConfirm() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}
