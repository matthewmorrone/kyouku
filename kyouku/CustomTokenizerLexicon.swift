import Foundation

enum CustomTokenizerLexicon {
    static let storageKey = "customTokenizerWords"
    private static let boundaryMetadataKey = "customTokenizerBoundaryMetadata"

    enum BoundaryKind: String, Codable {
        case merged
        case splitChild
    }

    struct BoundaryMetadata: Codable {
        let kind: BoundaryKind
        let parentSurface: String?
        let components: [String]
    }

    /// Returns user-defined words (one per line) from UserDefaults.
    static func words() -> [String] {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return raw
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Adds a word to the custom lexicon if not already present. Returns true if added.
    @discardableResult
    static func add(word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var set = Set(words())
        let inserted = set.insert(trimmed).inserted
        guard inserted else { return false }
        let joined = set.sorted().joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: storageKey)
        NotificationCenter.default.post(name: .customTokenizerLexiconDidChange, object: nil)
        return true
    }

    /// Removes a word from the custom lexicon. Returns true if removed.
    @discardableResult
    static func remove(word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var set = Set(words())
        let removed = set.remove(trimmed) != nil
        guard removed else { return false }
        let joined = set.sorted().joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: storageKey)
        clearBoundaryMetadata(for: [trimmed])
        NotificationCenter.default.post(name: .customTokenizerLexiconDidChange, object: nil)
        return true
    }

    /// Removes every custom entry and rebuilds the cache. Returns true if anything changed.
    @discardableResult
    static func clearAll() -> Bool {
        let existing = words()
        guard existing.isEmpty == false else { return false }
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: boundaryMetadataKey)
        NotificationCenter.default.post(name: .customTokenizerLexiconDidChange, object: nil)
        return true
    }

    static func boundaryMetadata(for word: String) -> BoundaryMetadata? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return loadBoundaryMetadata()[trimmed]
    }

    static func markMergeResult(word: String, components: [String]) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedWord.isEmpty == false else { return }
        let trimmedComponents = components.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var metadata = loadBoundaryMetadata()
        metadata[trimmedWord] = BoundaryMetadata(kind: .merged, parentSurface: nil, components: trimmedComponents)
        saveBoundaryMetadata(metadata)
    }

    static func markSplitChildren(parentSurface: String, parts: [String]) {
        let trimmedParent = parentSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard trimmedParts.count >= 2 else { return }
        var metadata = loadBoundaryMetadata()
        for part in trimmedParts {
            metadata[part] = BoundaryMetadata(kind: .splitChild, parentSurface: trimmedParent, components: trimmedParts)
        }
        if !trimmedParent.isEmpty {
            metadata.removeValue(forKey: trimmedParent)
        }
        saveBoundaryMetadata(metadata)
    }

    static func clearBoundaryMetadata(for words: [String]) {
        var metadata = loadBoundaryMetadata()
        var didChange = false
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if metadata.removeValue(forKey: trimmed) != nil {
                didChange = true
            }
        }
        if didChange {
            saveBoundaryMetadata(metadata)
        }
    }

    private static func loadBoundaryMetadata() -> [String: BoundaryMetadata] {
        guard let data = UserDefaults.standard.data(forKey: boundaryMetadataKey) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: BoundaryMetadata].self, from: data) {
            return decoded
        }
        return [:]
    }

    private static func saveBoundaryMetadata(_ metadata: [String: BoundaryMetadata]) {
        if metadata.isEmpty {
            UserDefaults.standard.removeObject(forKey: boundaryMetadataKey)
        } else if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: boundaryMetadataKey)
        }
    }
}



