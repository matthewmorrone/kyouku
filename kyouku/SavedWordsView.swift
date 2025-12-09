import SwiftUI

struct SavedWordsView: View {
    @EnvironmentObject var store: WordStore
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.words.sorted(by: { $0.createdAt > $1.createdAt })) { word in
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
                    .padding(.vertical, 4)
                }
                .onDelete(perform: store.delete)
            }
            .navigationTitle("Words")
            .toolbar {
                EditButton()
            }
        }
    }
}
