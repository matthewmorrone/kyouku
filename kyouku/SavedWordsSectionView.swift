import SwiftUI

fileprivate struct WordRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SavedWordsSectionView: View {
    let words: [Word]
    @Binding var isSelecting: Bool
    @Binding var selectedWordIDs: Set<UUID>
    var onDelete: (IndexSet) -> Void
    var onWordTapped: (Word) -> Void

    var body: some View {
        Section("Saved Words") {
            ForEach(words) { word in
                SavedWordRow(word: word, isSelecting: $isSelecting, selectedWordIDs: $selectedWordIDs) {
                    onWordTapped(word)
                }
            }
            .onDelete(perform: onDelete)
        }
    }
}

private struct SavedWordRow: View {
    let word: Word
    @Binding var isSelecting: Bool
    @Binding var selectedWordIDs: Set<UUID>
    var onTapped: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelecting {
                Button(action: {
                    if selectedWordIDs.contains(word.id) {
                        selectedWordIDs.remove(word.id)
                    } else {
                        selectedWordIDs.insert(word.id)
                    }
                }) {
                    Image(systemName: selectedWordIDs.contains(word.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedWordIDs.contains(word.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(word.surface)
                        .font(.title3)
                    Text("【\(word.reading)】")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if !word.meaning.isEmpty {
                    Text(word.meaning)
                        .font(.subheadline)
                }
                if let note = word.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: WordRowFramePreferenceKey.self,
                        value: [word.id: geo.frame(in: .named("WordsListSpace"))]
                    )
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                if selectedWordIDs.contains(word.id) {
                    selectedWordIDs.remove(word.id)
                } else {
                    selectedWordIDs.insert(word.id)
                }
            } else {
                onTapped()
            }
        }
    }
}
