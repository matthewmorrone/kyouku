//
//  WordImporter.swift
//
//  IMPORTANT:
//  This file provides the WordImporter implementation for the current target.
//  If both WordImporter.swift and WordImporter+Dummy.swift exist in the same target,
//  you must exclude one of them to avoid duplicate type definitions.
//

import Foundation

public struct WordsImport {
    public init() {}

    // MARK: - Types
    public struct ImportItem: Identifiable, Hashable {
        public let id: UUID
        public let lineNumber: Int
        public var providedSurface: String?
        public var providedReading: String?
        public var providedMeaning: String?
        public var note: String?
        public var computedSurface: String?
        public var computedReading: String?
        public var computedMeaning: String?

        public init(
            id: UUID = UUID(),
            lineNumber: Int,
            providedSurface: String?,
            providedReading: String?,
            providedMeaning: String?,
            note: String?,
            computedSurface: String? = nil,
            computedReading: String? = nil,
            computedMeaning: String? = nil
        ) {
            self.id = id
            self.lineNumber = lineNumber
            self.providedSurface = providedSurface
            self.providedReading = providedReading
            self.providedMeaning = providedMeaning
            self.note = note
            self.computedSurface = computedSurface
            self.computedReading = computedReading
            self.computedMeaning = computedMeaning
        }
    }

    public struct FinalizedItem: Identifiable, Hashable {
        public let id: UUID
        public let surface: String
        public let reading: String
        public let meaning: String
        public let note: String?

        public init(id: UUID = UUID(), surface: String, reading: String, meaning: String, note: String?) {
            self.id = id
            self.surface = surface
            self.reading = reading
            self.meaning = meaning
            self.note = note
        }
    }

    // Existing simple file import (kept for compatibility)
    public func importWords(from url: URL) throws -> [String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let words = content.components(separatedBy: .newlines)
        return words.filter { !$0.isEmpty }
    }

    // MARK: - Parsing
    public static func parseItems(fromString text: String) -> [ImportItem] {
        // Find first non-empty line
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
        guard let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }) else {
            return []
        }
        let firstLine = String(firstNonEmpty)
        if let delim = autoDelimiter(forFirstLine: firstLine) {
            return parseItems(fromString: text, delimiter: delim)
        }
        // List mode: each non-empty line is one item
        var items: [ImportItem] = []
        var lineNo = 0
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            lineNo += 1
            let trimmedLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            let value = trimmed(trimmedLine)
            let surface: String?
            let reading: String?
            if let v = value {
                if containsKanji(v) {
                    surface = v
                    reading = nil
                } else {
                    surface = nil
                    reading = v
                }
            } else {
                surface = nil
                reading = nil
            }
            items.append(ImportItem(lineNumber: lineNo, providedSurface: surface, providedReading: reading, providedMeaning: nil, note: nil))
        }
        return items
    }

    public static func parseItems(fromString text: String, delimiter: Character?) -> [ImportItem] {
        guard let delimiter = delimiter else { return parseItems(fromString: text) }
        var items: [ImportItem] = []
        var lineNo = 0
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let cols = splitCSVLine(line, delimiter: delimiter)
            let c0 = cols.indices.contains(0) ? trimmed(cols[0]) : nil
            let c1 = cols.indices.contains(1) ? trimmed(cols[1]) : nil
            let c2 = cols.indices.contains(2) ? trimmed(cols[2]) : nil
            let c3 = cols.indices.contains(3) ? trimmed(cols[3]) : nil
            let item = ImportItem(
                lineNumber: lineNo,
                providedSurface: c0,
                providedReading: c1,
                providedMeaning: c2,
                note: c3
            )
            items.append(item)
        }
        return items
    }

    // MARK: - Enrichment
    public static func fillMissing(items: inout [ImportItem], preferKanaOnly: Bool) async {
        let count = items.count
        guard count > 0 else { return }

        var updated = Array<ImportItem?>(repeating: nil, count: count)

        await withTaskGroup(of: (Int, ImportItem).self) { group in
            for i in items.indices {
                let original = items[i]
                group.addTask {
                    var item = original
                    let providedSurface = item.providedSurface?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let providedReading = item.providedReading?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let providedMeaning = item.providedMeaning?.trimmingCharacters(in: .whitespacesAndNewlines)

                    let needsReading = (providedReading?.isEmpty ?? true) && (item.computedReading?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    let needsMeaning = (providedMeaning?.isEmpty ?? true) && (item.computedMeaning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    let needsSurface = (providedSurface?.isEmpty ?? true) && (item.computedSurface?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                    var candidates: [String] = []
                    if let s = providedSurface, !s.isEmpty { candidates.append(s) }
                    if let r = providedReading, !r.isEmpty { candidates.append(r) }
                    if let s = item.computedSurface?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { candidates.append(s) }
                    if let r = item.computedReading?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { candidates.append(r) }
                    if let pm = providedMeaning, !pm.isEmpty, (Self.containsKanji(pm) || Self.isKana(pm)) { candidates.append(pm) }

                    var seen = Set<String>()
                    candidates = candidates.filter { seen.insert($0).inserted }

                    var hit: DictionaryEntry? = nil
                    for cand in candidates {
                        if let res = try? await DictionarySQLiteStore.shared.lookup(term: cand, limit: 1), let first = res.first {
                            hit = first
                            break
                        }
                    }

                    if let entry = hit {
                        if needsReading {
                            item.computedReading = entry.reading
                        }
                        if needsMeaning {
                            item.computedMeaning = firstGloss(entry.gloss)
                        }
                        if needsSurface {
                            let surfaceCandidate = entry.kanji.isEmpty ? entry.reading : entry.kanji
                            item.computedSurface = surfaceCandidate
                        } else if !preferKanaOnly {
                            // If insert-kanji is enabled, and current surface lacks kanji, prefer the dictionary kanji form for preview
                            let providedSurfaceHasKanji = containsKanji(providedSurface ?? "")
                            let computedSurfaceHasKanji = containsKanji(item.computedSurface ?? "")
                            if !providedSurfaceHasKanji && !computedSurfaceHasKanji && !entry.kanji.isEmpty {
                                item.computedSurface = entry.kanji
                            }
                        }
                    }

                    return (i, item)
                }
            }

            for await (idx, newItem) in group {
                updated[idx] = newItem
            }
        }

        for i in items.indices {
            if let u = updated[i] {
                items[i] = u
            }
        }
    }

    public static func finalize(items: [ImportItem], preferKanaOnly: Bool) -> [FinalizedItem] {
        var out: [FinalizedItem] = []
        for it in items {
            // Choose provided over computed
            let s0 = trimmed(it.providedSurface ?? it.computedSurface)
            let r0 = trimmed(it.providedReading ?? it.computedReading)
            let m0 = trimmed(it.providedMeaning ?? it.computedMeaning)
            let note = trimmed(it.note)

            var surface = s0 ?? ""
            let reading = r0 ?? ""
            let meaning = m0 ?? ""

            if preferKanaOnly {
                // If chosen surface has no kanji and we have a reading, prefer reading as surface (for kana-only entries)
                if !surface.isEmpty && !containsKanji(surface), !reading.isEmpty {
                    surface = reading
                }
                if surface.isEmpty, !reading.isEmpty {
                    surface = reading
                }
            } else {
                if surface.isEmpty, !reading.isEmpty {
                    surface = reading
                }
            }

            if surface.isEmpty || reading.isEmpty || meaning.isEmpty {
                continue
            }
            out.append(FinalizedItem(surface: surface, reading: reading, meaning: meaning, note: note))
        }
        return out
    }

    // MARK: - Helpers
    private nonisolated static func containsKanji(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
        }
        return false
    }

    private nonisolated static func isKana(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let isHiragana = (0x3040...0x309F).contains(v)
            let isKatakana = (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
            let isProlonged = v == 0x30FC // ー
            let isSmallTsu = v == 0x3063 || v == 0x30C3
            let isPunctuation = v == 0x3001 || v == 0x3002 // 、 。
            if !(isHiragana || isKatakana || isProlonged || isSmallTsu || isPunctuation) {
                return false
            }
        }
        return true
    }

    private nonisolated static func firstGloss(_ gloss: String) -> String {
        let parts = gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.first.map(String.init) ?? gloss
    }

    private nonisolated static func autoDelimiter(forFirstLine line: String) -> Character? {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: (ch: Character, count: Int)? = nil
        for c in candidates {
            let count = line.filter { $0 == c }.count
            if count > 0 {
                if best == nil || count > best!.count { best = (c, count) }
            }
        }
        return best?.ch
    }

    private nonisolated static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" { // double quote
                if inQuotes {
                    // lookahead for escaped double quote
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if ch == delimiter && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    private nonisolated static func trimmed(_ s: String?) -> String? {
        guard var str = s?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard !str.isEmpty else { return nil }
        // Remove surrounding matching quotes
        if str.count >= 2, str.first == "\"", str.last == "\"" {
            str.removeFirst()
            str.removeLast()
        }
        // Un-escape doubled quotes
        str = str.replacingOccurrences(of: "\"\"", with: "\"")
        let final = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty ? nil : final
    }
}

