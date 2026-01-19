//
//  NotesStore.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI
import Combine
import Foundation

class NotesStore: ObservableObject {
    @Published var notes: [Note] = []

    private let saveURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("notes.json")
    }()
    private weak var overridesStore: ReadingOverridesStore?
    private var overridesObserver: AnyCancellable?

    init(readingOverrides: ReadingOverridesStore? = nil) {
        self.overridesStore = readingOverrides
        if let overrides = readingOverrides {
            overridesObserver = NotificationCenter.default
                .publisher(for: .readingOverridesDidChange, object: overrides)
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.save()
                }
        }
        load()
    }

    // Backward-compatible convenience: still allows adding just text
    func addNote(_ text: String) {
        addNote(title: nil, text: text)
    }

    func addNote(title: String?, text: String) {
        let cleanTitle = (title?.isEmpty == true) ? nil : title
        let note = Note(
            id: UUID(),
            title: cleanTitle,
            text: text,
            createdAt: Date()
        )
        notes.insert(note, at: 0)
        save()
    }

    func deleteNote(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
        save()
    }
    
    func delete(_ offsets: IndexSet) {
        deleteNote(at: offsets)
    }
    
    func updateNote(_ note: Note) {
        notes = notes.map { $0.id == note.id ? note : $0 }
        save()
    }

    func moveNotes(fromOffsets source: IndexSet, toOffset destination: Int) {
        notes.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func save() {
        do {
            let archive = NotesArchive(
                version: 1,
                notes: notes,
                overrides: []
            )
            let data = try JSONEncoder().encode(archive)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            CustomLogger.shared.error("Failed to save notes: \(error)")
        }
    }

    func load() {
        var needsUpgrade = false
        do {
            let data = try Data(contentsOf: saveURL)
            let decoder = JSONDecoder()
            if let archive = try? decoder.decode(NotesArchive.self, from: data) {
                notes = archive.notes
                if archive.overrides.isEmpty == false,
                   (overridesStore?.allOverrides().isEmpty ?? true) {
                    overridesStore?.replaceAll(with: archive.overrides)
                    needsUpgrade = true
                }
            } else {
                let loaded = try decoder.decode([Note].self, from: data)
                notes = loaded
                needsUpgrade = true
            }
        } catch {
            notes = []
            CustomLogger.shared.error("Failed to load notes archive: \(error)")
        }
        if needsUpgrade {
            save()
        }
    }
    
    // MARK: - Bulk Replace / Export
    func replaceAll(with newNotes: [Note]) {
        self.notes = newNotes
        save()
    }

    func allNotes() -> [Note] { notes }
}

private struct NotesArchive: Codable {
    let version: Int
    var notes: [Note]
    var overrides: [ReadingOverride]
}
