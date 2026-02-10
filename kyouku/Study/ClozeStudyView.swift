import SwiftUI

struct ClozeStudyView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ClozeStudyViewModel

    @State private var showingSettings: Bool = false

    @ScaledMetric(relativeTo: .title3) private var blankControlMinWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .title3) private var blankControlHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var blankControlHPadding: CGFloat = 10

    init(
        note: Note,
        initialMode: ClozeStudyViewModel.Mode = .random,
        initialBlanksPerSentence: Int = 1,
        excludeDuplicateLines: Bool = true
    ) {
        _model = StateObject(
            wrappedValue: ClozeStudyViewModel(
                note: note,
                initialMode: initialMode,
                initialBlanksPerSentence: initialBlanksPerSentence,
                excludeDuplicateLines: excludeDuplicateLines
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header
                Divider()
                prompt
                controls
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    let titleText = (model.note.title?.isEmpty == false ? model.note.title! : "Study")

                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        Text(titleText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(titleText)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Study settings")
                }
            }
            .onAppear { model.start() }
        }
        .appThemedRoot()
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Section("Mode") {
                        Picker("Order", selection: $model.mode) {
                            ForEach(ClozeStudyViewModel.Mode.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("Question") {
                        let maxBlanks = max(1, (model.currentQuestion?.wordCount ?? 2) - 1)
                        Stepper(
                            "Dropdowns per sentence: \(min(model.blanksPerSentence, maxBlanks))",
                            value: Binding(
                                get: { min(model.blanksPerSentence, maxBlanks) },
                                set: { model.blanksPerSentence = $0 }
                            ),
                            in: 1...maxBlanks,
                            step: 1
                        )
                        .onChange(of: model.blanksPerSentence) { _, _ in
                            model.rebuildCurrentQuestion()
                        }
                    }

                    Section {
                        Text("Settings apply immediately.")
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingSettings = false }
                    }
                }
            }
            .appThemedRoot()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Score")
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
                Text("\(model.correctCount)/\(model.totalCount)")
                    .foregroundStyle(Color.appTextSecondary)
            }
            .font(.subheadline)

            if let q = model.currentQuestion {
                Text("Mode: \(model.mode.displayName) • \(q.blanks.count) blank(s)")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            if model.sentenceCount > 0 {
                Text("\(model.sentenceCount) sentence(s) in note")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    private var prompt: some View {
        Group {
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Building question…")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if let q = model.currentQuestion {
                VStack(alignment: .leading, spacing: 12) {
                    if #available(iOS 16.0, *) {
                        InlineWrapLayout(spacing: 0, lineSpacing: 8) {
                            ForEach(q.segments) { seg in
                                switch seg.kind {
                                case .text(let s):
                                    Text(s)
                                        .font(.title3)
                                        .foregroundStyle(Color.appTextPrimary)
                                case .blank(let b):
                                    inlineDropdown(blank: b)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(q.sentenceText)
                            .font(.title3)
                            .foregroundStyle(Color.appTextPrimary)
                    }
                    /*
                    Text("Pick the best word(s) for the blank(s).")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                    */
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.appBorder, lineWidth: 1)
                )
            } else {
                VStack(spacing: 10) {
                    Text("No questions available")
                        .font(.headline)
                    Text("This note might be too short, or contains no eligible tokens.")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private func inlineDropdown(blank b: ClozeStudyViewModel.Blank) -> some View {
        let selection = model.selectedOptionByBlankID[b.id] ?? "▾"
        let checked = model.checkedBlankIDs.contains(b.id)
        let isCorrect = checked && selection == b.correct
        let correctColor: Color = .green
        return Menu {
            ForEach(b.options, id: \.self) { option in
                Button {
                    model.submitSelection(blankID: b.id, option: option)
                } label: {
                    Text(option)
                }
            }
        } label: {
            Text(selection)
                .font(.title3)
                .lineLimit(1)
                .foregroundStyle(checked ? (isCorrect ? correctColor : Color.appDestructive) : Color.appAccent)
                .padding(.horizontal, blankControlHPadding)
                .frame(minWidth: blankControlMinWidth, minHeight: blankControlHeight, alignment: .center)
                .background(Color.appSoftFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(checked ? (isCorrect ? correctColor : Color.appDestructive) : Color.appBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer choices")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.revealAnswer()
            } label: {
                Label("Reveal", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .disabled(model.currentQuestion == nil || model.isLoading)

            Spacer()

            Button {
                Task { await model.nextQuestion() }
            } label: {
                Label("Next", systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isLoading)
        }
    }
}
