//
//  NotesStore.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation
import SwiftUI
import Combine

class NotesStore: ObservableObject {
    @Published var notes: [Note] = []

    private let saveURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("notes.json")
    }()

    init() {
        load()
    }

    func addNote(_ text: String) {
        let note = Note(id: UUID(), text: text, createdAt: Date())
        notes.insert(note, at: 0)
        save()
    }

    func deleteNote(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
        save()
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("Failed to save notes:", error)
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: saveURL)
            let loaded = try JSONDecoder().decode([Note].self, from: data)
            notes = loaded
        } catch {
            notes = []
        }
    }
}
