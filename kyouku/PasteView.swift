//
//  PasteView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI
import UIKit
import Foundation

struct PasteView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    
    @AppStorage("editorTextSize") private var textSize: Double = 17

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ControlCell {
                    Button(action: newNote) {
                        Image(systemName: "plus.square").font(.title2)
                    }
                    .accessibilityLabel("New Note")
                    .disabled(isEditing)
                }

                EditorContainer(text: $inputText, textSize: textSize, isEditing: isEditing)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)

                HStack(alignment: .center, spacing: 0) {
                    ControlCell {
                        Button { hideKeyboard() } label: {
                            Image(systemName: "keyboard.chevron.compact.down").font(.title2)
                        }
                        .accessibilityLabel("Hide Keyboard")
                    }

                    ControlCell {
                        Button(action: pasteFromClipboard) {
                            Image(systemName: "doc.on.clipboard").font(.title2)
                        }
                        .accessibilityLabel("Paste")
                    }

                    ControlCell {
                        Button(action: saveNote) {
                            Image(systemName: "square.and.arrow.down").font(.title2)
                        }
                        .accessibilityLabel("Save")
                    }

                    ControlCell {
                        Toggle(isOn: $isEditing) {
                            if UIImage(systemName: "character.cursor.ibeam.ja") != nil {
                                Image(systemName: "character.cursor.ibeam.ja")
                            } else {
                                Image(systemName: "character.cursor.ibeam")
                            }
                        }
                        .labelsHidden()
                        .toggleStyle(.button)
                        .tint(.accentColor)
                        .font(.title2)
                        .accessibilityLabel("Edit")
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 24) }
            .navigationTitle(currentNote?.title ?? "Paste")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: onAppearHandler)
            .onDisappear {
                NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            }
            .onChange(of: inputText) { _, newValue in
                syncNoteForInputChange(newValue)
                PasteBufferStore.save(newValue)
            }
        }
    }

    private func pasteFromClipboard() {
        if let str = UIPasteboard.general.string {
            inputText = str
            // Update current note's title to the first line of the pasted text
            let firstLine = str.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let existing = currentNote {
                // Update the note's title and text in the store
                notes.notes = notes.notes.map { n in
                    if n.id == existing.id {
                        return Note(id: n.id, title: firstLine.isEmpty ? nil : firstLine, text: str, createdAt: n.createdAt)
                    } else {
                        return n
                    }
                }
                notes.save()
                // Keep our local currentNote in sync
                if let updated = notes.notes.first(where: { $0.id == existing.id }) {
                    currentNote = updated
                }
            }
        }
    }

    private func saveNote() {
        guard !inputText.isEmpty else { return }
        if let existing = currentNote {
            notes.notes = notes.notes.map { n in
                if n.id == existing.id {
                    return Note(id: n.id, title: n.title, text: inputText, createdAt: n.createdAt)
                } else {
                    return n
                }
            }
            notes.save()
        } else {
            let firstLine = inputText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            let title = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            notes.addNote(title: (title?.isEmpty == true) ? nil : title, text: inputText)
            currentNote = notes.notes.first
        }
    }

    public func newNote() {
        hideKeyboard()
        isEditing = true

        inputText = ""
        notes.addNote(title: nil, text: "")
        notes.save()

        if let newest = notes.notes.first {
            currentNote = newest
        } else if let last = notes.notes.last {
            currentNote = last
        } else {
            currentNote = nil
        }

        PasteBufferStore.save("")
    }

    private func onAppearHandler() {
        if let note = router.noteToOpen {
            currentNote = note
            inputText = note.text
            isEditing = false
            router.noteToOpen = nil
        }
        if !hasInitialized {
            if inputText.isEmpty {
                // Default to edit mode when starting with empty paste area
                isEditing = true
            }
            hasInitialized = true
        }
        if currentNote == nil && inputText.isEmpty {
            let persisted = PasteBufferStore.load()
            if !persisted.isEmpty {
                inputText = persisted
                isEditing = false
            }
        }
    }

    private func syncNoteForInputChange(_ newValue: String) {
        // Keep current note's title synced to the first line of the text
        guard let existing = currentNote else { return }
        let firstLine = newValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        notes.notes = notes.notes.map { n in
            if n.id == existing.id {
                return Note(id: n.id, title: firstLine.isEmpty ? nil : firstLine, text: newValue, createdAt: n.createdAt)
            } else {
                return n
            }
        }
        notes.save()
        if let updated = notes.notes.first(where: { $0.id == existing.id }) {
            currentNote = updated
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct ControlCell<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}

private struct EditorContainer: View {
    @Binding var text: String
    var textSize: Double
    var isEditing: Bool

    private let placeholder = "Paste or type Japanese text"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if isEditing == false {
                    ScrollView {
                        Text(text.isEmpty ? placeholder : text)
                            .font(.system(size: textSize))
                            .foregroundColor(text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: textSize))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .foregroundColor(.primary)

                }
            }

            if isEditing && text.isEmpty {
                Text(placeholder)
                    .font(.system(size: textSize))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color(.systemBackground))
        .cornerRadius(12)
    }
}

extension PasteView {
    static func createNewNote(notes: NotesStore, router: AppRouter) {
        notes.addNote(title: nil, text: "")
        notes.save()
        router.noteToOpen = notes.notes.first ?? notes.notes.last
        router.selectedTab = .paste
        PasteBufferStore.save("")
    }
}

