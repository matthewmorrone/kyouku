//
//  NotesView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI
import UIKit

struct NotesView: View {
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var readingOverrides: ReadingOverridesStore
    @EnvironmentObject var tokenBoundaries: TokenBoundariesStore

    @AppStorage("notesPreviewLineCount") private var notesPreviewLineCount: Int = 3
    @AppStorage("clipboardAccessEnabled") private var clipboardAccessEnabled: Bool = true

    @State private var pendingDeleteOffsets: IndexSet? = nil
    @State private var pendingDeleteNoteTitle: String? = nil
    @State private var showDeleteAlert: Bool = false
    @State private var pendingDeleteHasAssociatedWords: Bool = false
    @State private var deleteAssociatedWords: Bool = false
    @State private var editModeState: EditMode = .inactive
    @State private var showRenameAlert: Bool = false
    @State private var renameTarget: Note? = nil
    @State private var renameText: String = ""
    @State private var toastText: String? = nil
    @State private var toastDismissWorkItem: DispatchWorkItem? = nil

    var body: some View {
        NavigationStack {
            List {
                if notesStore.notes.isEmpty {
                    Button {
                        router.noteToOpen = nil
                        router.selectedTab = .paste
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No notes yet")
                                .font(.headline)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    ForEach(notesStore.notes) { note in
                        Button {
                            router.noteToOpen = note
                            router.selectedTab = .paste
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text((note.title?.isEmpty == false ? note.title! : "Untitled") as String)
                                    .font(.headline)

                                if notesPreviewLineCount > 0 {
                                    Text(note.text)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.appTextSecondary)
                                        .lineLimit(notesPreviewLineCount)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .contextMenu {
                            Button {
                                guard clipboardAccessEnabled else {
                                    showToast("Clipboard access is disabled in Settings")
                                    return
                                }
                                UIPasteboard.general.string = note.text
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .disabled(clipboardAccessEnabled == false)
                            Button {
                                // Duplicate note: insert a copy at the top and save
                                let copy = Note(id: UUID(), title: note.title, text: note.text, createdAt: Date())
                                notesStore.notes.insert(copy, at: 0)
                                notesStore.save()
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button {
                                resetCustomSpans(noteID: note.id)
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            // Divider()

                            Button {
                                presentRenameAlert(for: note)
                            } label: {
                                Label("Rename", systemImage: "text.cursor")
                            }
                            Button {
                                router.noteToOpen = note
                                router.pasteShouldBeginEditing = true
                                router.selectedTab = .paste
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                    // Trigger existing delete flow by setting pending offsets for this single note
                                if let index = notesStore.notes.firstIndex(where: { $0.id == note.id }) {
                                    pendingDeleteOffsets = IndexSet(integer: index)
                                    pendingDeleteNoteTitle = (note.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                                        ? note.title
                                        : "Untitled"
                                    let noteID = notesStore.notes[index].id
                                    pendingDeleteHasAssociatedWords = store.words.contains { $0.sourceNoteIDs.contains(noteID) }
                                    deleteAssociatedWords = false
                                    showDeleteAlert = true
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, destination in
                        notesStore.moveNotes(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                        var hasAssociatedWords = false
                        for index in offsets {
                            guard index < notesStore.notes.count else { continue }
                            let noteID = notesStore.notes[index].id
                            if store.words.contains(where: { $0.sourceNoteIDs.contains(noteID) }) {
                                hasAssociatedWords = true
                                break
                            }
                        }
                        pendingDeleteHasAssociatedWords = hasAssociatedWords
                        if offsets.count == 1, let only = offsets.first, only < notesStore.notes.count {
                            let note = notesStore.notes[only]
                            pendingDeleteNoteTitle = (note.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                                ? note.title
                                : "Untitled"
                        } else {
                            pendingDeleteNoteTitle = nil
                        }
                        deleteAssociatedWords = false
                        showDeleteAlert = true
                    }
                }
            }
            .appThemedScrollBackground()
            .navigationTitle("Notes")
            .environment(\.editMode, $editModeState)
            .overlay(alignment: .bottom) {
                if let toastText {
                    Text(toastText)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { PasteView.createNewNote(notes: notesStore, router: router) }) {
                        Image(systemName: "plus.square")
                            .font(.title2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            if editModeState.isEditing {
                                editModeState = .inactive
                            } else {
                                editModeState = .active
                            }
                        }
                    } label: {
                        Image(systemName: "pencil.line")
                            .font(.title2)
                    }
                }
            }
            // NOTE: `.confirmationDialog` uses a popover on iPad (arrow + anchor), which is
            // often positioned poorly for context-menu actions. Present a true alert instead.
            .background(
                DeleteNotesAlertPresenter(
                    isPresented: $showDeleteAlert,
                    noteCount: pendingDeleteOffsets?.count ?? 0,
                    noteTitle: pendingDeleteNoteTitle,
                    hasAssociatedWords: pendingDeleteHasAssociatedWords,
                    deleteAssociatedWords: $deleteAssociatedWords,
                    onCancel: {
                        pendingDeleteOffsets = nil
                        pendingDeleteHasAssociatedWords = false
                        deleteAssociatedWords = false
                        pendingDeleteNoteTitle = nil
                    },
                    onConfirmDelete: {
                        handleDeleteNotes(deleteWords: pendingDeleteHasAssociatedWords && deleteAssociatedWords)
                        pendingDeleteNoteTitle = nil
                    }
                )
            )
            .alert("Rename Note", isPresented: $showRenameAlert, presenting: renameTarget) { note in
                TextField("Title", text: $renameText)
                Button("Save") {
                    commitRename(note, title: renameText)
                }
                Button("Cancel", role: .cancel) {
                    resetRenameState()
                }
            } message: { _ in
                Text("Enter a new title for this note.")
            }
        }
        .appThemedRoot()
    }

    private func handleDeleteNotes(deleteWords: Bool) {
        guard let offsets = pendingDeleteOffsets else { return }
        let ids = offsets.map { notesStore.notes[$0].id }
        // Delete notes first
        notesStore.notes.remove(atOffsets: offsets)
        notesStore.save()
        // Optionally delete associated words
        if deleteWords {
            for id in ids {
                store.deleteWords(fromNoteID: id)
            }
        }
        pendingDeleteOffsets = nil
        pendingDeleteHasAssociatedWords = false
    }

    private func presentRenameAlert(for note: Note) {
        renameTarget = note
        renameText = note.title ?? ""
        showRenameAlert = true
    }

    private func commitRename(_ note: Note, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = note
        updated.title = trimmed.isEmpty ? nil : trimmed
        notesStore.updateNote(updated)
        resetRenameState()
    }

    private func resetRenameState() {
        renameTarget = nil
        renameText = ""
        showRenameAlert = false
    }

    private func resetCustomSpans(noteID: UUID) {
        router.pendingResetNoteID = nil
        readingOverrides.removeAll(for: noteID)
        tokenBoundaries.removeAll(for: noteID)
        showToast("Reset custom spans")
    }

    private func showToast(_ message: String) {
        toastDismissWorkItem?.cancel()
        withAnimation {
            toastText = message
        }

        let workItem = DispatchWorkItem {
            withAnimation {
                toastText = nil
            }
        }
        toastDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
}

private struct DeleteNotesAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let noteCount: Int
    let noteTitle: String?
    let hasAssociatedWords: Bool
    @Binding var deleteAssociatedWords: Bool
    let onCancel: () -> Void
    let onConfirmDelete: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else {
            // If our alert is still presented, dismiss it.
            if let alert = context.coordinator.alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true)
            }
            context.coordinator.alert = nil
            context.coordinator.toggleController = nil
            return
        }

        // Avoid presenting twice.
        if let alert = context.coordinator.alert {
            // Keep the embedded toggle in sync if SwiftUI state changes while the alert is up.
            context.coordinator.toggleController?.apply(
                isOn: deleteAssociatedWords,
                enabled: hasAssociatedWords,
                onChanged: { newValue in
                    deleteAssociatedWords = newValue
                }
            )
            // Ensure the message stays accurate if association state changes.
            let message: String = {
                if hasAssociatedWords {
                    return "This will delete the selected note(s). You can also delete any words saved from them."
                }
                return "This will delete the selected note(s)."
            }()
            if alert.message != message {
                alert.message = message
            }
            return
        }

        let title: String = {
            if noteCount == 1, let noteTitle, noteTitle.isEmpty == false {
                return "Delete \"\(noteTitle)\"?"
            }
            if noteCount > 1 {
                return "Delete \(noteCount) notes?"
            }
            return "Delete note?"
        }()
        let message: String = {
            if hasAssociatedWords {
                return "This will delete the selected note(s). You can also delete any words saved from them."
            }
            return "This will delete the selected note(s)."
        }()

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        if hasAssociatedWords {
            // Embed a checkbox-like control (UISwitch) inside the alert using a dedicated content VC.
            // This avoids brittle constraints against private UIAlertController subviews and prevents
            // spacing/hit-testing issues.
            let toggleController = AssociatedWordsToggleViewController()
            toggleController.apply(
                isOn: deleteAssociatedWords,
                enabled: true,
                onChanged: { newValue in
                    deleteAssociatedWords = newValue
                }
            )
            // Undocumented but common and stable: supplies a custom content view in `.alert` style.
            alert.setValue(toggleController, forKey: "contentViewController")
            context.coordinator.toggleController = toggleController
        } else {
            context.coordinator.toggleController = nil
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            onCancel()
            isPresented = false
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            onConfirmDelete()
            isPresented = false
        })

        context.coordinator.alert = alert
        uiViewController.present(alert, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var alert: UIAlertController? = nil
        var toggleController: AssociatedWordsToggleViewController? = nil
    }
}

private final class AssociatedWordsToggleViewController: UIViewController {
    private let label = UILabel()
    private let toggle = UISwitch()
    private var onChanged: ((Bool) -> Void)? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.preservesSuperviewLayoutMargins = true
        // Match UIAlertController's internal margins more closely.
        view.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        label.text = "Delete associated words"
        label.font = UIFont.systemFont(ofSize: 15)
        label.numberOfLines = 1

        let container = UIStackView(arrangedSubviews: [label, UIView(), toggle])
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onChanged?(self.toggle.isOn)
        }, for: .valueChanged)

        preferredContentSize = CGSize(width: 0, height: 44)
    }

    func apply(isOn: Bool, enabled: Bool, onChanged: @escaping (Bool) -> Void) {
        self.onChanged = onChanged
        if isViewLoaded {
            toggle.isOn = isOn
            toggle.isEnabled = enabled
            label.textColor = enabled ? UIColor.label : UIColor.secondaryLabel
            view.alpha = enabled ? 1.0 : 0.65
        } else {
            // Ensure initial state is applied when view loads.
            loadViewIfNeeded()
            toggle.isOn = isOn
            toggle.isEnabled = enabled
            label.textColor = enabled ? UIColor.label : UIColor.secondaryLabel
            view.alpha = enabled ? 1.0 : 0.65
        }
    }
}

extension Notification.Name {

}

