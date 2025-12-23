//
//  PasteView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//
import SwiftUI
import UIKit
import Foundation
import OSLog

struct PasteView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    @State private var furiganaAttributedText: NSAttributedString? = nil
    @State private var furiganaRefreshToken: Int = 0
    @State private var furiganaTaskHandle: Task<Void, Never>? = nil
    @State private var suppressNextEditingRefresh: Bool = false

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4
    @AppStorage("readingShowFurigana") private var showFurigana: Bool = true

    private static let furiganaLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "FuriganaPipeline")

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

                EditorContainer(
                    text: $inputText,
                    furiganaText: furiganaAttributedText,
                    textSize: readingTextSize,
                    isEditing: isEditing,
                    showFurigana: showFurigana,
                    lineSpacing: readingLineSpacing
                )
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
                        Button {
                            showFurigana.toggle()
                            // Immediately schedule a recompute when enabling
                            if showFurigana { triggerFuriganaRefreshIfNeeded(reason: "manual toggle button") }
                        } label: {
                            ZStack {
                                Color.clear.frame(width: 28, height: 28)
                                Image(showFurigana ? "furigana.on" : "furigana.off")
                                    .symbolRenderingMode(.monochrome)
                                    .font(.system(size: 22))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .tint(.accentColor)
                        .buttonStyle(.plain)
                        .accessibilityLabel(showFurigana ? "Disable Furigana" : "Enable Furigana")
                        .disabled(isEditing)
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
            .navigationTitle(currentNote?.title ?? "Paste")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 24) }
            .onAppear {
                onAppearHandler()
            }
            .onDisappear {
                NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
                furiganaTaskHandle?.cancel()
            }
            .onChange(of: inputText) { _, newValue in
                syncNoteForInputChange(newValue)
                PasteBufferStore.save(newValue)
                if newValue.isEmpty {
                    furiganaAttributedText = nil
                    furiganaTaskHandle?.cancel()
                }
                triggerFuriganaRefreshIfNeeded(reason: "input changed")
            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    furiganaAttributedText = nil
                    furiganaTaskHandle?.cancel()
                } else {
                    if suppressNextEditingRefresh {
                        suppressNextEditingRefresh = false
                        Self.logFurigana("Skipping refresh: editing toggle was programmatic.")
                        return
                    }
                    triggerFuriganaRefreshIfNeeded(reason: "editing toggled off")
                }
            }
            .onChange(of: showFurigana) { _, enabled in
                if enabled {
                    triggerFuriganaRefreshIfNeeded(reason: "show furigana toggled on")
                } else {
                    furiganaAttributedText = nil
                    furiganaTaskHandle?.cancel()
                }
            }
            .onChange(of: readingFuriganaSize) { _, _ in
                triggerFuriganaRefreshIfNeeded(reason: "furigana font size changed")
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
        setEditing(true)

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
        furiganaAttributedText = nil
    }

    private func onAppearHandler() {
        if let note = router.noteToOpen {
            currentNote = note
            inputText = note.text
            setEditing(false, suppressRefresh: true)
            router.noteToOpen = nil
        }
        if !hasInitialized {
            if inputText.isEmpty {
                // Default to edit mode when starting with empty paste area
                setEditing(true)
            }
            hasInitialized = true
        }
        if currentNote == nil && inputText.isEmpty {
            let persisted = PasteBufferStore.load()
            if !persisted.isEmpty {
                inputText = persisted
                setEditing(false, suppressRefresh: true)
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

    private func setEditing(_ editing: Bool, suppressRefresh: Bool = false) {
        if suppressRefresh && editing == false {
            suppressNextEditingRefresh = true
        }
        isEditing = editing
    }

    private func triggerFuriganaRefreshIfNeeded(reason: String = "state change") {
        guard showFurigana else {
            Self.logFurigana("Skipping refresh (\(reason)): furigana toggle is off.")
            return
        }
        guard isEditing == false else {
            Self.logFurigana("Skipping refresh (\(reason)): editor is in edit mode.")
            return
        }
        guard inputText.isEmpty == false else {
            Self.logFurigana("Skipping refresh (\(reason)): paste text is empty.")
            return
        }
        furiganaRefreshToken &+= 1
        Self.logFurigana("Queued refresh token \(furiganaRefreshToken) for text length \(inputText.count). Reason: \(reason)")
        startFuriganaTask(token: furiganaRefreshToken)
    }

    private func startFuriganaTask(token: Int) {
        guard let taskBody = makeFuriganaTask(token: token) else { return }
        furiganaTaskHandle?.cancel()
        furiganaTaskHandle = Task {
            await taskBody()
        }
    }

    private func makeFuriganaTask(token: Int) -> (() async -> Void)? {
        guard showFurigana else {
            Self.logFurigana("No furigana task created because toggle is off.")
            return nil
        }
        guard inputText.isEmpty == false else {
            Self.logFurigana("No furigana task created because text is empty.")
            return nil
        }
        // Capture current values by value to avoid capturing self
        let currentText = inputText
        let currentShowFurigana = showFurigana
        let currentIsEditing = isEditing
        let currentTextSize = readingTextSize
        let currentFuriganaSize = readingFuriganaSize
        Self.logFurigana("Creating furigana task token \(token) for text length \(currentText.count). ShowF: \(currentShowFurigana), isEditing: \(currentIsEditing)")
        return {
            await PasteView.recomputeFurigana(
                text: currentText,
                showFurigana: currentShowFurigana,
                isEditing: currentIsEditing,
                textSize: currentTextSize,
                furiganaSize: currentFuriganaSize
            ) { newAttributed in
                // Only update if state still matches to avoid stale updates
                if inputText == currentText && showFurigana == currentShowFurigana && isEditing == currentIsEditing {
                    furiganaAttributedText = newAttributed
                }
            }
        }
    }

    private static func recomputeFurigana(
        text: String,
        showFurigana: Bool,
        isEditing: Bool,
        textSize: Double,
        furiganaSize: Double,
        update: @escaping (NSAttributedString?) -> Void
    ) async {
        guard showFurigana else {
            logFurigana("Aborting recompute: furigana toggle is off.")
            await MainActor.run { update(nil) }
            return
        }
        guard isEditing == false else {
            logFurigana("Aborting recompute: editor is in edit mode.")
            await MainActor.run { update(nil) }
            return
        }
        guard text.isEmpty == false else {
            logFurigana("Aborting recompute: paste text is empty.")
            await MainActor.run { update(nil) }
            return
        }

        logFurigana("Starting furigana recompute for text length \(text.count).")
        // Debounce to avoid hammering the dictionary during rapid edits/toggles
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        do {
            let attributed = try await FuriganaAttributedTextBuilder.build(
                text: text,
                textSize: textSize,
                furiganaSize: furiganaSize,
                context: "PasteView"
            )
            logFurigana("Furigana rebuild succeeded with attributed length \(attributed.length).")
            await MainActor.run { update(attributed) }
        } catch {
            logFurigana("Furigana rebuild failed: \(String(describing: error)).")
            await MainActor.run { update(nil) }
        }
    }

    private static func logFurigana(_ message: String) {
        furiganaLogger.info("\(message, privacy: .public)")
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
    var furiganaText: NSAttributedString?
    var textSize: Double
    var isEditing: Bool
    var showFurigana: Bool
    var lineSpacing: Double

    private let placeholder = "Paste or type Japanese text"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if isEditing == false {
                    ScrollView {
                        Group {
                            if text.isEmpty {
                                Text(placeholder)
                                    .foregroundColor(.secondary)
                            } else {
                                if showFurigana {
                                    RubyText(
                                        attributed: furiganaText ?? NSAttributedString(string: text),
                                        fontSize: CGFloat(textSize),
                                        lineHeightMultiple: 1.0,
                                        extraGap: CGFloat(max(0, lineSpacing))
                                    )
                                } else {
                                    Text(text)
                                        .foregroundColor(.primary)
                                        .lineSpacing(CGFloat(max(0, lineSpacing)))
                                }
                            }
                        }
                        .font(.system(size: textSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: textSize))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)

                }
            }

            if isEditing && text.isEmpty {
                Text(placeholder)
                    .font(.system(size: textSize))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
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

