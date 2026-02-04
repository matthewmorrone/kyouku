import SwiftUI

struct ClozeStudyView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ClozeStudyViewModel

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
            }
            .onAppear { model.start() }
        }
        .appThemedRoot()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Study")
                    .font(.headline)
                Spacer()
                Picker("Mode", selection: $model.mode) {
                    ForEach(ClozeStudyViewModel.Mode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if let q = model.currentQuestion {
                let maxBlanks = max(1, q.wordCount - 1)
                Stepper(
                    "Dropdowns: \(min(model.blanksPerSentence, maxBlanks))",
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

            HStack {
                Text("Score")
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
                Text("\(model.correctCount)/\(model.totalCount)")
                    .foregroundStyle(Color.appTextSecondary)
            }
            .font(.subheadline)

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

                    Text("Pick the best word(s) for the blank(s).")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
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
                .foregroundStyle(checked ? (isCorrect ? Color.appHighlight : Color.appDestructive) : Color.appAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 110, alignment: .center)
                .background(Color.appSoftFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(checked ? (isCorrect ? Color.appHighlight : Color.appDestructive) : Color.appBorder, lineWidth: 1)
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
