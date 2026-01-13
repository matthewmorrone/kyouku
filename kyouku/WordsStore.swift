//
//  WordStore.swift
//  WordStore.swift
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation
import SwiftUI
import Combine

final class WordsStore: ObservableObject {
    @Published private(set) var words: [Word] = []
    
    private let fileName = "words.json"
    
    init() {
        load()
    }

    /// The one and only add method.
    ///
    /// - Parameters:
    ///   - surface: The written form captured from a dictionary lookup.
    ///   - kana: The reading to store for the saved word. This is typically the
    ///     dictionary kana, but may be a user-confirmed reading override.
    ///     Pass `nil` when no reading is available; do not pass heuristics from pasted text.
    ///   - meaning: Required localized gloss.
    /// Callers must provide a non-empty meaning/definition.
    func add(surface: String, dictionarySurface: String? = nil, kana: String?, meaning: String, note: String? = nil, sourceNoteID: UUID? = nil) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds = dictionarySurface?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDictionarySurface: String?
        if let ds, ds.isEmpty == false {
            normalizedDictionarySurface = ds
        } else {
            normalizedDictionarySurface = nil
        }
        let trimmedKana = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana: String?
        if let tk = trimmedKana, tk.isEmpty == false {
            normalizedKana = tk
        } else {
            normalizedKana = nil
        }
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s.isEmpty else { return }
        guard !m.isEmpty else { return }

        if words.contains(where: { $0.surface == s && $0.kana == normalizedKana && $0.sourceNoteID == sourceNoteID }) {
            return
        }

        let word = Word(
            surface: s,
            dictionarySurface: normalizedDictionarySurface,
            kana: normalizedKana,
            meaning: m,
            note: note,
            sourceNoteID: sourceNoteID
        )
        words.append(word)
        save()
    }

    struct WordToAdd: Hashable {
        let surface: String
        let dictionarySurface: String?
        let kana: String?
        let meaning: String
        let note: String?

        init(surface: String, dictionarySurface: String? = nil, kana: String?, meaning: String, note: String? = nil) {
            self.surface = surface
            self.dictionarySurface = dictionarySurface
            self.kana = kana
            self.meaning = meaning
            self.note = note
        }
    }

    /// Batch add for bulk operations (e.g. "Save All" from a note).
    ///
    /// This dedupes efficiently and writes to disk once.
    func addMany(_ items: [WordToAdd], sourceNoteID: UUID? = nil) {
        guard items.isEmpty == false else { return }

        var existingKeys: Set<String> = []
        existingKeys.reserveCapacity(words.count)
        for w in words {
            let surface = w.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let kana = w.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKana = (kana?.isEmpty == false) ? kana : nil
            let key = "\(surface)|\(normalizedKana ?? "")|\(w.sourceNoteID?.uuidString ?? "")"
            existingKeys.insert(key)
        }

        var newWords: [Word] = []
        newWords.reserveCapacity(items.count)

        for item in items {
            let s = item.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let ds = item.dictionarySurface?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDictionarySurface: String?
            if let ds, ds.isEmpty == false {
                normalizedDictionarySurface = ds
            } else {
                normalizedDictionarySurface = nil
            }
            let trimmedKana = item.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKana: String?
            if let tk = trimmedKana, tk.isEmpty == false {
                normalizedKana = tk
            } else {
                normalizedKana = nil
            }
            let m = item.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = item.note

            guard s.isEmpty == false else { continue }
            guard m.isEmpty == false else { continue }

            let key = "\(s)|\(normalizedKana ?? "")|\(sourceNoteID?.uuidString ?? "")"
            guard existingKeys.insert(key).inserted else { continue }

            newWords.append(
                Word(
                    surface: s,
                    dictionarySurface: normalizedDictionarySurface,
                    kana: normalizedKana,
                    meaning: m,
                    note: n,
                    sourceNoteID: sourceNoteID
                )
            )
        }

        guard newWords.isEmpty == false else { return }
        words.append(contentsOf: newWords)
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

    /// Removes every saved word.
    func deleteAll() {
        guard words.isEmpty == false else { return }
        words.removeAll()
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
            CustomLogger.shared.error("Failed to load words: \(error)")
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
            CustomLogger.shared.error("Failed to save words: \(error)")
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

