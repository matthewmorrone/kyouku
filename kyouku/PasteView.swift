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
    @State private var furiganaSpans: [AnnotatedSpan]? = nil
    @State private var furiganaRefreshToken: Int = 0
    @State private var furiganaTaskHandle: Task<Void, Never>? = nil
    @State private var suppressNextEditingRefresh: Bool = false

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4
    @AppStorage("readingShowFurigana") private var showFurigana: Bool = true
    @AppStorage("readingAlternateTokenColors") private var alternateTokenColors: Bool = false

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
                    furiganaSpans: furiganaSpans,
                    textSize: readingTextSize,
                    isEditing: isEditing,
                    showFurigana: showFurigana,
                    lineSpacing: readingLineSpacing,
                    alternateTokenColors: alternateTokenColors
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
                                    .renderingMode(.template)
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 22))
                            }
                        }
                        .tint(.accentColor)
                        .buttonStyle(.plain)
                        .accessibilityLabel(showFurigana ? "Disable Furigana" : "Enable Furigana")
                        .disabled(isEditing)
                    }

                    ControlCell {
                        Toggle(isOn: $alternateTokenColors) {
                            Image(systemName: "textformat.alt")
                        }
                        .labelsHidden()
                        .toggleStyle(.button)
                        .tint(.accentColor)
                        .font(.title2)
                        .accessibilityLabel("Alternate Token Colors")
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
                    furiganaSpans = nil
                    furiganaTaskHandle?.cancel()
                }
                triggerFuriganaRefreshIfNeeded(reason: "input changed", recomputeSpans: true)
            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    furiganaAttributedText = nil
                    furiganaSpans = nil
                    furiganaTaskHandle?.cancel()
                } else {
                    if suppressNextEditingRefresh {
                        suppressNextEditingRefresh = false
                        Self.logFurigana("Skipping refresh: editing toggle was programmatic.")
                        return
                    }
                    triggerFuriganaRefreshIfNeeded(reason: "editing toggled off", recomputeSpans: true)
                }
            }
            .onChange(of: showFurigana) { _, enabled in
                if enabled {
                    triggerFuriganaRefreshIfNeeded(reason: "show furigana toggled on", recomputeSpans: false)
                } else {
                    furiganaTaskHandle?.cancel()
                }
            }
            .onChange(of: alternateTokenColors) { _, enabled in
                if enabled {
                    triggerFuriganaRefreshIfNeeded(reason: "alternate token colors toggled on", recomputeSpans: false)
                }
            }
            .onChange(of: readingFuriganaSize) { _, _ in
                triggerFuriganaRefreshIfNeeded(reason: "furigana font size changed", recomputeSpans: false)
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
        furiganaSpans = nil
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

    private func triggerFuriganaRefreshIfNeeded(reason: String = "state change", recomputeSpans: Bool = true) {
        guard showFurigana || alternateTokenColors else {
            Self.logFurigana("Skipping refresh (\(reason)): no consumers need annotated spans.")
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
        startFuriganaTask(token: furiganaRefreshToken, recomputeSpans: recomputeSpans)
    }

    private func startFuriganaTask(token: Int, recomputeSpans: Bool) {
        guard let taskBody = makeFuriganaTask(token: token, recomputeSpans: recomputeSpans) else { return }
        furiganaTaskHandle?.cancel()
        furiganaTaskHandle = Task {
            await taskBody()
        }
    }

    private func makeFuriganaTask(token: Int, recomputeSpans: Bool) -> (() async -> Void)? {
        guard showFurigana || alternateTokenColors else {
            Self.logFurigana("No furigana task created because no consumer requires spans.")
            return nil
        }
        guard inputText.isEmpty == false else {
            Self.logFurigana("No furigana task created because text is empty.")
            return nil
        }
        // Capture current values by value to avoid capturing self
        let currentText = inputText
        let currentShowFurigana = showFurigana
        let currentAlternateTokenColors = alternateTokenColors
        let currentIsEditing = isEditing
        let currentTextSize = readingTextSize
        let currentFuriganaSize = readingFuriganaSize
        let currentSpans = furiganaSpans
        Self.logFurigana("Creating furigana task token \(token) for text length \(currentText.count). ShowF: \(currentShowFurigana), isEditing: \(currentIsEditing)")
        return {
            await PasteView.recomputeFurigana(
                text: currentText,
                showFurigana: currentShowFurigana,
                needsTokenHighlights: currentAlternateTokenColors,
                isEditing: currentIsEditing,
                textSize: currentTextSize,
                furiganaSize: currentFuriganaSize,
                recomputeSpans: recomputeSpans,
                existingSpans: currentSpans
            ) { newSpans, newAttributed in
                // Only update if state still matches to avoid stale updates
                if inputText == currentText && showFurigana == currentShowFurigana && isEditing == currentIsEditing {
                    furiganaSpans = newSpans
                    furiganaAttributedText = newAttributed
                }
            }
        }
    }

    private static func recomputeFurigana(
        text: String,
        showFurigana: Bool,
        needsTokenHighlights: Bool,
        isEditing: Bool,
        textSize: Double,
        furiganaSize: Double,
        recomputeSpans: Bool,
        existingSpans: [AnnotatedSpan]?,
        update: @escaping ([AnnotatedSpan]?, NSAttributedString?) -> Void
    ) async {
        guard showFurigana || needsTokenHighlights else {
            logFurigana("Aborting recompute: no consumers require annotated spans.")
            await MainActor.run { update(existingSpans, nil) }
            return
        }
        guard isEditing == false else {
            logFurigana("Aborting recompute: editor is in edit mode.")
            await MainActor.run { update(existingSpans, nil) }
            return
        }
        guard text.isEmpty == false else {
            logFurigana("Aborting recompute: paste text is empty.")
            await MainActor.run { update(nil, nil) }
            return
        }

        logFurigana("Starting furigana recompute for text length \(text.count). Recompute spans: \(recomputeSpans ? "yes" : "no").")
        if Task.isCancelled { return }

        var spans = existingSpans
        if recomputeSpans || spans == nil {
            do {
                spans = try await FuriganaAttributedTextBuilder.computeAnnotatedSpans(
                    text: text,
                    context: "PasteView"
                )
            } catch {
                logFurigana("Span computation failed: \(String(describing: error)).")
                await MainActor.run { update(nil, nil) }
                return
            }
        }

        guard let readySpans = spans else {
            logFurigana("No spans available after recompute; returning plain text.")
            await MainActor.run { update(nil, NSAttributedString(string: text)) }
            return
        }

        let attributed = FuriganaAttributedTextBuilder.project(
            text: text,
            annotatedSpans: readySpans,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: "PasteView"
        )
        logFurigana("Furigana projection succeeded with length \(attributed.length).")
        await MainActor.run { update(readySpans, attributed) }
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
    var furiganaSpans: [AnnotatedSpan]?
    var textSize: Double
    var isEditing: Bool
    var showFurigana: Bool
    var lineSpacing: Double
    var alternateTokenColors: Bool

    private let placeholder = "Paste or type Japanese text"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isEditing {
                editorContent
            } else if text.isEmpty {
                displayShell {
                    EmptyView()
                }
            } else if showFurigana {
                displayShell {
                    rubyBlock(annotationVisibility: .visible)
                        .fixedSize(horizontal: false, vertical: true) // prevent vertical compression
                }
            } else {
                displayShell {
                    rubyBlock(annotationVisibility: .removed)
                }
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color(.systemBackground))
        .cornerRadius(12)
    }

    private var editorContent: some View {
        TextEditor(text: $text)
            .font(.system(size: textSize))
            .lineSpacing(lineSpacing)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .foregroundColor(.primary)
            .padding(editorInsets)
    }

    private var editorInsets: EdgeInsets {
        let rubyHeadroom = max(0.0, textSize * 0.6 + lineSpacing)
        let topInset = max(8.0, rubyHeadroom)
        return EdgeInsets(top: CGFloat(topInset), leading: 11, bottom: 12, trailing: 12)
    }

    private func displayShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                content()
                    .padding(8)
            }
            .font(.system(size: textSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rubyBlock(annotationVisibility: RubyAnnotationVisibility) -> some View {
        RubyText(
            attributed: resolvedAttributedText,
            fontSize: CGFloat(textSize),
            lineHeightMultiple: 1.0,
            extraGap: CGFloat(max(0, lineSpacing)),
            annotationVisibility: annotationVisibility,
            tokenOverlays: tokenBorderOverlays
        )
    }

    private var resolvedAttributedText: NSAttributedString {
        furiganaText ?? NSAttributedString(string: text)
    }

    private var tokenBorderOverlays: [RubyText.TokenOverlay] {
        guard alternateTokenColors, let spans = furiganaSpans else { return [] }
        let palette: [UIColor] = [UIColor.systemBlue, UIColor.systemPink]
        guard palette.isEmpty == false else { return [] }
        let maxLength = furiganaText?.length ?? (text as NSString).length
        let coverageRanges = Self.coverageRanges(from: spans, textLength: maxLength)
        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(coverageRanges.count)
        for (index, range) in coverageRanges.enumerated() {
            let color = palette[index % palette.count]
            overlays.append(RubyText.TokenOverlay(range: range, color: color))
        }
        return overlays
    }

    private static func coverageRanges(from spans: [AnnotatedSpan], textLength: Int) -> [NSRange] {
        guard textLength > 0 else { return [] }
        let bounds = NSRange(location: 0, length: textLength)
        let sorted = spans
            .map { $0.span.range }
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .map { NSIntersectionRange($0, bounds) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(sorted.count + 4)
        var cursor = 0
        for range in sorted {
            if range.location > cursor {
                ranges.append(NSRange(location: cursor, length: range.location - cursor))
            }
            ranges.append(range)
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < textLength {
            ranges.append(NSRange(location: cursor, length: textLength - cursor))
        }
        return ranges
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

