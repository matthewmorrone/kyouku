//
//  PasteView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI

struct PasteView: View {
    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore

    @State private var inputText: String = ""
    @State private var noteTitle: String = ""
    @State private var tokens: [ParsedToken] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                // TOP BAR: Paste + Save icons
                HStack(spacing: 24) {

                    // PASTE BUTTON
                    Button {
                        if let str = UIPasteboard.general.string {
                            inputText = str
                            tokens = JapaneseParser.parse(text: str)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title2)
                    }

                    // SAVE NOTE BUTTON
                    Button {
                        guard !inputText.isEmpty else { return }
                        let fullText = noteTitle.isEmpty
                            ? inputText
                            : "\(noteTitle)\n\(inputText)"
                        notes.addNote(fullText)
                        noteTitle = ""
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title2)
                    }
                }
                .padding(.horizontal)

                // OPTIONAL NOTE TITLE
                TextField("Title (optional)", text: $noteTitle)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // DISPLAY PASTED TEXT
                ScrollView {
                    Text(inputText.isEmpty ? "Tap the clipboard icon to paste text" : inputText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .frame(minHeight: 160)

                // TOKENS BELOW
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(tokens) { token in
                            Button {
                                store.add(from: token)
                            } label: {
                                FuriganaTextView(token: token)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }

            }
            .navigationTitle("Paste")
        }
    }
}
