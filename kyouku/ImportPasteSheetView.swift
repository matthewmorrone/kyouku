import SwiftUI

struct ImportPasteSheetView: View {
    @Binding var importRawText: String
    @Binding var isImportingWords: Bool
    @Binding var delimiterSelection: WordsDelimiterChoice
    var onPreview: ([WordsImport.ImportItem]) -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        importRawText = ""
                    } label: {
                        Image(systemName: "trash")
                    }

                    Button {
                        hideKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }

                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            importRawText = pasted
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }

                    Spacer()

                    Button {
                        let text = importRawText
                        let delimiter = delimiterSelection.character
                        let items = (delimiter == nil)
                            ? WordsImport.parseItems(fromString: text)
                            : WordsImport.parseItems(fromString: text, delimiter: delimiter)
                        onPreview(items)
                        onClose()
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                Text("Paste CSV or list")
                    .font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $importRawText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .frame(minHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    if importRawText.isEmpty {
                        Text("Paste here…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                    }
                }

                Divider()

                Text("Options").font(.subheadline).foregroundStyle(.secondary)
                Picker("Column Delimiter", selection: $delimiterSelection) {
                    ForEach(WordsDelimiterChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding()
            .navigationTitle("Import Words")
        }
    }
}

// Local helper to dismiss keyboard
private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

