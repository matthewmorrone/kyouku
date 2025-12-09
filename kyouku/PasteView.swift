//
//  ContentView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct PasteView: View {
    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore
    
    @State private var inputText: String = ""
    @State private var tokens: [ParsedToken] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                
                Button("Paste from Clipboard") {
                    if let str = UIPasteboard.general.string {
                        inputText = str
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                
                ScrollView {
                    Text(inputText.isEmpty ? "Nothing pasted yet" : inputText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .frame(minHeight: 160)
                
                TextEditor(text: $inputText)
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4))
                    )
                    .padding(.horizontal)
                
                Button("Analyze Text") {
                    tokens = JapaneseParser.parse(text: inputText)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Save Note") {
                    if !inputText.isEmpty {
                        notes.addNote(inputText)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, -8)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(tokens) { token in
                            Button {
                                store.add(from: token)
                            } label: {
                                FuriganaTokenView(token: token)
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
