//
//  WordStore.swift
//  WordStore.swift
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation
import SwiftUI
import Combine

final class WordStore: ObservableObject {
    @Published private(set) var words: [Word] = []
    
    private let fileName = "words.json"
    
    init() {
        load()
    }

    /// The one and only add method.
    /// Callers must provide a non-empty meaning/definition.
    func add(surface: String, reading: String, meaning: String, note: String? = nil, sourceNoteID: UUID? = nil) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s.isEmpty else { return }
        guard !m.isEmpty else { return }

        if words.contains(where: { $0.surface == s && $0.reading == r }) {
            return
        }

        let word = Word(
            surface: s,
            reading: r,
            meaning: m,
            note: note,
            sourceNoteID: sourceNoteID
        )
        words.append(word)
        save()
    }
    
    func delete(at offsets: IndexSet) {
        words.remove(atOffsets: offsets)
        save()
    }
    
    func delete(_ offsets: IndexSet) {
        delete(at: offsets)
    }

    /// Robust deletion that works even when the UI list is sorted/filtered.
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        words.removeAll { ids.contains($0.id) }
        save()
    }

    /// Convenience for deleting a single word by id.
    func delete(id: UUID) {
        delete(ids: [id])
    }
    
    func randomWord() -> Word? {
        words.randomElement()
    }
    
    // MARK: - File I/O
    
    private func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    
    private func fileURL() -> URL? {
        documentsURL()?.appendingPathComponent(fileName)
    }
    
    private func load() {
        guard let url = fileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([Word].self, from: data)
            self.words = decoded
        } catch {
            print("Failed to load words: \(error)")
        }
    }
    
    private func save() {
        guard let url = fileURL() else {
            return
        }
        do {
            let data = try JSONEncoder().encode(words)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save words: \(error)")
        }
    }
    
    func deleteWords(fromNoteID id: UUID) {
        let before = words.count
        words.removeAll { $0.sourceNoteID == id }
        if words.count != before {
            save()
        }
    }

    // MARK: - Bulk Replace / Export
    func replaceAll(with newWords: [Word]) {
        self.words = newWords
        save()
    }

    func allWords() -> [Word] { words }
}
