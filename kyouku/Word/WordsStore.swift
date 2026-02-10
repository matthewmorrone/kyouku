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

        let normalizedLists = normalizedListIDs(listIDs)
        if let idx = words.firstIndex(where: { $0.surface == s && $0.kana == normalizedKana }) {
            var changed = false

            if words[idx].dictionarySurface == nil, let normalizedDictionarySurface {
                words[idx].dictionarySurface = normalizedDictionarySurface
                changed = true
            }
            if words[idx].meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, m.isEmpty == false {
                words[idx].meaning = m
                changed = true
            }
            if words[idx].note == nil, let note, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                words[idx].note = note
                changed = true
            }
            if let sourceNoteID, words[idx].sourceNoteIDs.contains(sourceNoteID) == false {
                words[idx].sourceNoteIDs.append(sourceNoteID)
                words[idx].sourceNoteIDs.sort { $0.uuidString < $1.uuidString }
                changed = true
            }

            if normalizedLists.isEmpty == false {
                let merged = Array(Set(words[idx].listIDs).union(normalizedLists))
                if merged.count != words[idx].listIDs.count {
                    words[idx].listIDs = merged
                    changed = true
                }
            }

            if changed { save() }
            return
        }

        let word = Word(
            surface: s,
            dictionarySurface: normalizedDictionarySurface,
            kana: normalizedKana,
            meaning: m,
            note: note,
            sourceNoteID: sourceNoteID,
            listIDs: normalizedLists
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

        var indexByKey: [String: Int] = [:]
        indexByKey.reserveCapacity(words.count)
        for (idx, w) in words.enumerated() {
            let surface = w.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let kana = w.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKana = (kana?.isEmpty == false) ? kana : nil
            let key = "\(surface)|\(normalizedKana ?? "")"
            indexByKey[key] = idx
        }

        var changed = false

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

            let key = "\(s)|\(normalizedKana ?? "")"
            if let existingIdx = indexByKey[key] {
                var didChange = false
                if words[existingIdx].dictionarySurface == nil, let normalizedDictionarySurface {
                    words[existingIdx].dictionarySurface = normalizedDictionarySurface
                    didChange = true
                }
                if words[existingIdx].meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    words[existingIdx].meaning = m
                    didChange = true
                }
                if words[existingIdx].note == nil, let n, n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    words[existingIdx].note = n
                    didChange = true
                }
                if let sourceNoteID, words[existingIdx].sourceNoteIDs.contains(sourceNoteID) == false {
                    words[existingIdx].sourceNoteIDs.append(sourceNoteID)
                    words[existingIdx].sourceNoteIDs.sort { $0.uuidString < $1.uuidString }
                    didChange = true
                }
                if normalizedLists.isEmpty == false {
                    let merged = Array(Set(words[existingIdx].listIDs).union(normalizedLists))
                    if merged.count != words[existingIdx].listIDs.count {
                        words[existingIdx].listIDs = merged
                        didChange = true
                    }
                }
                if didChange { changed = true }
                continue
            }

            let newWord = Word(
                surface: s,
                dictionarySurface: normalizedDictionarySurface,
                kana: normalizedKana,
                meaning: m,
                note: n,
                sourceNoteID: sourceNoteID,
                listIDs: normalizedLists
            )
            words.append(newWord)
            indexByKey[key] = words.count - 1
            changed = true
        }

        if changed {
            save()
        }
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

    /// Removes any `sourceNoteIDs` that no longer exist.
    ///
    /// This prevents UI from needing to represent missing/deleted notes.
    func pruneMissingNoteAssociations(validNoteIDs: Set<UUID>) {
        var changed = false
        for idx in words.indices {
            let before = words[idx].sourceNoteIDs
            if before.isEmpty { continue }

            let filtered = Array(Set(before)).filter { validNoteIDs.contains($0) }
            if filtered.count != before.count {
                words[idx].sourceNoteIDs = filtered.sorted { $0.uuidString < $1.uuidString }
                changed = true
            }
        }

        if changed {
            save()
        }
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

    func wordCount(inList id: UUID) -> Int {
        words.reduce(0) { acc, w in
            acc + (w.listIDs.contains(id) ? 1 : 0)
        }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(lists)
            try data.write(to: url, options: [.atomic])
        } catch {
            CustomLogger.shared.error("Failed to save lists: \(error)")
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
        guard words.isEmpty == false else { return }
        var changed = false
        var idsToDelete: Set<UUID> = []

        for idx in words.indices {
            if words[idx].sourceNoteIDs.contains(id) {
                words[idx].sourceNoteIDs.removeAll { $0 == id }
                changed = true
                if words[idx].sourceNoteIDs.isEmpty {
                    idsToDelete.insert(words[idx].id)
                }
            }
        }

        if idsToDelete.isEmpty == false {
            words.removeAll { idsToDelete.contains($0.id) }
        }
        if changed {
            save()
        }
    }

    func removeWords(ids: Set<UUID>, fromNoteID noteID: UUID) {
        guard ids.isEmpty == false else { return }
        guard words.isEmpty == false else { return }

        var changed = false
        var idsToDelete: Set<UUID> = []

        for idx in words.indices {
            guard ids.contains(words[idx].id) else { continue }
            if words[idx].sourceNoteIDs.contains(noteID) {
                words[idx].sourceNoteIDs.removeAll { $0 == noteID }
                changed = true
                if words[idx].sourceNoteIDs.isEmpty {
                    idsToDelete.insert(words[idx].id)
                }
            }
        }

        if idsToDelete.isEmpty == false {
            words.removeAll { idsToDelete.contains($0.id) }
        }

        if changed {
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
