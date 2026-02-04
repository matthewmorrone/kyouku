import SwiftUI

struct ClozeStudyHomeView: View {
    @EnvironmentObject var notes: NotesStore

    @State private var mode: ClozeStudyViewModel.Mode = .random
    @State private var blanksPerSentence: Int = 1
    @State private var selectedNoteID: UUID? = nil

    @AppStorage("clozeExcludeDuplicateLines") private var excludeDuplicateLines: Bool = true

    @State private var activeNote: Note? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
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

                    Toggle("Exclude duplicate lines", isOn: $excludeDuplicateLines)
                }/* header: {
                    Label("Cloze", systemImage: "rectangle.and.pencil.and.ellipsis")
                }*/

                Section {
                    if notes.notes.isEmpty {
                        Text("Add a note to study.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Note", selection: $selectedNoteID) {
                            Text("Select a note").tag(UUID?.none)
                            ForEach(notes.notes) { note in
                                Text(note.title?.isEmpty == false ? note.title! : "Untitled")
                                    .tag(UUID?.some(note.id))
                            }
                        }
                    }
                } header: {
                    Text("Source")
                }

                Section {
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
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        Text("Cloze")
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cloze")
                }
            }
            .navigationDestination(item: $activeNote) { note in
                ClozeStudyView(
                    note: note,
                    initialMode: mode,
                    initialBlanksPerSentence: blanksPerSentence,
                    excludeDuplicateLines: excludeDuplicateLines
                )
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
