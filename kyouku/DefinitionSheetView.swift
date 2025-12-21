import SwiftUI

struct DefinitionSheetView: View {
    let isLookingUp: Bool
    let selectedWord: Word?
    let lookupError: String?
    let dictEntry: DictionaryEntry?
    var onAddFromWord: (Word) -> Void
    var onAddFromEntry: (DictionaryEntry) -> Void
    var onClose: () -> Void

    var body: some View {
        Group {
            if isLookingUp {
                VStack(spacing: 12) {
                    ProgressView("Looking up…")
                    if let w = selectedWord {
                        Text("\(w.surface)【\(w.reading)】")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            } else if let msg = lookupError {
                VStack(spacing: 10) {
                    HStack {
                        Button(action: {
                            if let w = selectedWord { onAddFromWord(w) }
                            onClose()
                        }) {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        Spacer()
                        Button("Close") { onClose() }
                    }
                    .padding(.bottom, 8)

                    Text("Lookup failed")
                        .font(.headline)
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            } else if let entry = dictEntry {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            onAddFromEntry(entry)
                            onClose()
                        }) {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        Spacer()
                        Button(action: { onClose() }) {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                    }

                    Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                        .font(.title2).bold()
                    if !entry.reading.isEmpty {
                        Text(entry.reading)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .presentationDetents([.medium, .large])
            } else {
                VStack {
                    Text("No definition found")
                    Button("Close") { onClose() }
                }
                .padding()
            }
        }
    }
}
