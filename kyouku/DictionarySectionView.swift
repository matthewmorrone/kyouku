import SwiftUI

struct DictionarySectionView: View {
    @ObservedObject var vm: DictionaryLookupViewModel
    var isSaved: (DictionaryEntry) -> Bool
    var onAdd: (DictionaryEntry) -> Void

    var body: some View {
        Section("Dictionary") {
            if vm.isLoading {
                HStack { ProgressView(); Text("Searching…") }
            } else if let msg = vm.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            } else if vm.results.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.results) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                .font(.headline)
                            Text(entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            onAdd(entry)
                        } label: {
                            if isSaved(entry) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaved(entry))
                    }
                }
            }
        }
    }
}
