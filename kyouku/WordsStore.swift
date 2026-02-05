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
    @Published private(set) var lists: [WordList] = []
    
    private let fileName = "words.json"
    private let listsFileName = "word-lists.json"
    
    init() {
        load()
        loadLists()
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
    func add(
        surface: String,
        dictionarySurface: String? = nil,
        kana: String?,
        meaning: String,
        note: String? = nil,
        sourceNoteID: UUID? = nil,
        listIDs: [UUID] = []
    ) {
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
            sourceNoteID: sourceNoteID,
            listIDs: normalizedListIDs(listIDs)
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
    func addMany(_ items: [WordToAdd], sourceNoteID: UUID? = nil, listIDs: [UUID] = []) {
        guard items.isEmpty == false else { return }
        let normalizedLists = normalizedListIDs(listIDs)

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
                    sourceNoteID: sourceNoteID,
                    listIDs: normalizedLists
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

    /// Update an existing saved word by id.
    ///
    /// - Note: Updates are intentionally more permissive than `add(...)` so the user
    ///   can repair legacy/partial entries.
    func update(
        id: UUID,
        surface: String,
        dictionarySurface: String?,
        kana: String?,
        meaning: String,
        note: String?
    ) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else { return }

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
        let nTrim = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let n: String? = (nTrim?.isEmpty == false) ? nTrim : nil

        guard let idx = words.firstIndex(where: { $0.id == id }) else { return }
        words[idx].surface = s
        words[idx].dictionarySurface = normalizedDictionarySurface
        words[idx].kana = normalizedKana
        words[idx].meaning = m
        words[idx].note = n
        save()
    }

    // MARK: - Lists
    func createList(name: String) -> WordList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        // De-dupe by case-insensitive name.
        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if lists.contains(where: { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized }) {
            return nil
        }

        let list = WordList(name: trimmed)
        lists.append(list)
        lists.sort { $0.createdAt < $1.createdAt }
        saveLists()
        return list
    }

    func renameList(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard let idx = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[idx].name = trimmed
        saveLists()
    }

    func deleteList(id: UUID) {
        lists.removeAll { $0.id == id }
        // Remove membership from all words.
        if words.isEmpty == false {
            var changed = false
            for i in words.indices {
                let before = words[i].listIDs
                let after = before.filter { $0 != id }
                if after.count != before.count {
                    words[i].listIDs = after
                    changed = true
                }
            }
            if changed {
                save()
            }
        }
        saveLists()
    }

    func setLists(forWordID id: UUID, listIDs: [UUID]) {
        guard let idx = words.firstIndex(where: { $0.id == id }) else { return }
        words[idx].listIDs = normalizedListIDs(listIDs)
        save()
    }

    func addWord(id: UUID, toList listID: UUID) {
        guard let idx = words.firstIndex(where: { $0.id == id }) else { return }
        if words[idx].listIDs.contains(listID) == false {
            words[idx].listIDs.append(listID)
            save()
        }
    }

    func addWords(ids: Set<UUID>, toList listID: UUID) {
        guard ids.isEmpty == false else { return }
        guard words.isEmpty == false else { return }

        var changed = false
        for i in words.indices {
            if ids.contains(words[i].id) {
                if words[i].listIDs.contains(listID) == false {
                    words[i].listIDs.append(listID)
                    changed = true
                }
            }
        }

        if changed {
            save()
        }
    }

    func removeWord(id: UUID, fromList listID: UUID) {
        guard let idx = words.firstIndex(where: { $0.id == id }) else { return }
        let before = words[idx].listIDs
        let after = before.filter { $0 != listID }
        if after.count != before.count {
            words[idx].listIDs = after
            save()
        }
    }

    func wordCount(inList id: UUID) -> Int {
        words.reduce(0) { acc, w in
            acc + (w.listIDs.contains(id) ? 1 : 0)
        }
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

    private func listsURL() -> URL {
        let fm = FileManager.default
        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent(listsFileName)
    }

    private func loadLists() {
        let url = listsURL()
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            lists = try decoder.decode([WordList].self, from: data)
        } catch {
            lists = []
        }
    }

    private func saveLists() {
        let url = listsURL()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(lists)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort.
        }
    }

    private func normalizedListIDs(_ ids: [UUID]) -> [UUID] {
        guard ids.isEmpty == false else { return [] }
        let valid = Set(lists.map { $0.id })
        var out: [UUID] = []
        out.reserveCapacity(ids.count)
        var seen: Set<UUID> = []
        for id in ids {
            guard valid.contains(id) else { continue }
            guard seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
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

    func word(id: UUID) -> Word? {
        words.first { $0.id == id }
    }
}

