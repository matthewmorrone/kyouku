import SwiftUI

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


