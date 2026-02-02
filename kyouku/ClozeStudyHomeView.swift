import SwiftUI

struct ClozeStudyHomeView: View {
    @EnvironmentObject var notes: NotesStore

    @State private var mode: ClozeStudyViewModel.Mode = .random
    @State private var blanksPerSentence: Int = 1
    @State private var selectedNoteID: UUID? = nil

    @State private var activeNote: Note? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Cloze", systemImage: "rectangle.and.pencil.and.ellipsis")
                            .font(.headline)

                        Picker("Order", selection: $mode) {
                            ForEach(ClozeStudyViewModel.Mode.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        Stepper(
                            "Dropdowns per sentence: \(blanksPerSentence)",
                            value: $blanksPerSentence,
                            in: 1...10,
                            step: 1
                        )

                        if notes.notes.isEmpty {
                            Text("Add a note to study.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Note", selection: $selectedNoteID) {
                                Text("Select a note").tag(UUID?.none)
                                ForEach(notes.notes) { note in
                                    Text(note.title?.isEmpty == false ? note.title! : "Untitled")
                                        .tag(UUID?.some(note.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Button {
                            guard let id = selectedNoteID else { return }
                            activeNote = notes.notes.first(where: { $0.id == id })
                        } label: {
                            Label("Start Cloze", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedNoteID == nil)
                    }
                    .padding(12)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.appBorder, lineWidth: 1)
                    )
                }
                .padding()
            }
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $activeNote) { note in
                ClozeStudyView(note: note, initialMode: mode, initialBlanksPerSentence: blanksPerSentence)
            }
            .onAppear {
                if selectedNoteID == nil {
                    selectedNoteID = notes.notes.first?.id
                }
            }
        }
        .appThemedRoot()
    }
}
