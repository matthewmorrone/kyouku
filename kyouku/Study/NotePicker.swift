import SwiftUI

struct NotePicker: View {
    @EnvironmentObject var notes: NotesStore
    @Binding var selectedNoteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notes.notes.isEmpty {
                Text("No notes available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Note", selection: $selectedNoteID) {
                    Text("Any Note").tag(UUID?.none)
                    ForEach(notes.notes) { note in
                        Text(note.title?.isEmpty == false ? note.title! : "Untitled").tag(UUID?.some(note.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

