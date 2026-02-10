import SwiftUI

extension WordDefinitionsView {
    // MARK: Utilities
    func preferredReading(from kanaVariants: [String]) -> String? {
        let cleaned = kanaVariants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard cleaned.isEmpty == false else { return nil }

        func isAllHiragana(_ text: String) -> Bool {
            guard text.isEmpty == false else { return false }
            return text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
        }

        // Prefer a hiragana reading when available; otherwise fall back to the shortest.
        if let hira = cleaned.first(where: isAllHiragana) { return hira }
        return cleaned.min(by: { $0.count < $1.count })
    }

    func glossParts(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let parts = trimmed
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        return parts.isEmpty ? [trimmed] : parts
    }

    func containsKanji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    func kanaFoldToHiragana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    func firstGloss(for gloss: String) -> String {
        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gloss
    }

    func isSaved(surface: String, kana: String?) -> Bool {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return false }
        if let sourceNoteID {
            return store.words.contains {
                $0.surface == s && $0.kana == normalizedKana && $0.sourceNoteIDs.contains(sourceNoteID)
            }
        }
        return store.words.contains { $0.surface == s && $0.kana == normalizedKana }
    }

    func savedWordID(surface: String, kana: String?) -> UUID? {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return nil }
        return store.words.first(where: { $0.surface == s && $0.kana == normalizedKana })?.id
    }

    func savedWordCreatedAt(surface: String, kana: String?) -> Date? {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return nil }
        return store.words.first(where: { $0.surface == s && $0.kana == normalizedKana })?.createdAt
    }

    /// Ensures the word is saved, returning its Word.ID if possible.
    func ensureSavedWordID(surface: String, kana: String?, meaning: String) -> UUID? {
        if let id = savedWordID(surface: surface, kana: kana) {
            return id
        }

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false, m.isEmpty == false else { return nil }

        store.add(surface: s, kana: normalizedKana, meaning: m, sourceNoteID: sourceNoteID)
        return savedWordID(surface: s, kana: normalizedKana)
    }

    func toggleSaved(surface: String, kana: String?, meaning: String) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false, m.isEmpty == false else { return }

        let matchingIDs = Set(
            store.words
                .filter { $0.surface == s && $0.kana == normalizedKana }
                .map(\.id)
        )

        if matchingIDs.isEmpty {
            store.add(surface: s, kana: normalizedKana, meaning: m, sourceNoteID: sourceNoteID)
            return
        }

        if let sourceNoteID {
            let isAssociatedWithThisNote = store.words.contains {
                $0.surface == s && $0.kana == normalizedKana && $0.sourceNoteIDs.contains(sourceNoteID)
            }
            if isAssociatedWithThisNote {
                store.removeWords(ids: matchingIDs, fromNoteID: sourceNoteID)
            } else {
                store.add(surface: s, kana: normalizedKana, meaning: m, sourceNoteID: sourceNoteID)
            }
        } else {
            store.delete(ids: matchingIDs)
        }
    }

    var activeSavedWord: Word? {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return nil }
        return store.words.first(where: { $0.surface == s && $0.kana == normalizedKana })
    }

    func assignedLists(for word: Word) -> [WordList] {
        guard word.listIDs.isEmpty == false else { return [] }
        let out = store.lists.filter { word.listIDs.contains($0.id) }
        return out.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
