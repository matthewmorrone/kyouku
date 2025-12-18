import Foundation

struct WordImporter {
    struct PreparedWord {
        let surface: String
        let reading: String
        let meaning: String
        let note: String?
    }

    struct ImportResult {
        let prepared: [PreparedWord]
        let errors: [String]
    }

    struct ImportItem: Identifiable, Hashable {
        let id = UUID()
        let lineNumber: Int
        var providedSurface: String?
        var providedReading: String?
        var providedMeaning: String?
        var note: String?
        // Filled by dictionary when requested
        var computedSurface: String?
        var computedReading: String?
        var computedMeaning: String?
    }

    /// Public entry point: parse CSV or plain text and enrich via dictionary lookups.
    /// - Parameters:
    ///   - url: File URL to import
    ///   - preferKanaOnly: If true and only kana (reading) is provided without kanji, do not backfill kanji; use the kana as surface.
    static func importWords(from url: URL, preferKanaOnly: Bool) async throws -> ImportResult {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) ?? String(data: data, encoding: .ascii) else {
            throw NSError(domain: "WordImporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding."])
        }
        return try await importWords(fromString: text, preferKanaOnly: preferKanaOnly)
    }

    static func importWords(fromString text: String, preferKanaOnly: Bool) async throws -> ImportResult {
        let items = parseItems(fromString: text)
        var mutable = items
        await fillMissing(items: &mutable, preferKanaOnly: preferKanaOnly)
        let prepared = finalize(items: mutable, preferKanaOnly: preferKanaOnly)
        // Generate basic errors for lines that could not produce a meaning
        var errors: [String] = []
        for it in mutable where (it.providedMeaning?.nilIfEmpty ?? it.computedMeaning?.nilIfEmpty) == nil {
            errors.append("Line \(it.lineNumber): insufficient data (meaning unresolved)")
        }
        return ImportResult(prepared: prepared, errors: errors)
    }

    static func parseItems(from url: URL) throws -> [ImportItem] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) ?? String(data: data, encoding: .ascii) else {
            throw NSError(domain: "WordImporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding."])
        }
        return parseItems(fromString: text)
    }

    static func parseItems(fromString text: String) -> [ImportItem] {
        var items: [ImportItem] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains(",") {
            // CSV path
            let rows = parseCSV(normalized)
            var headerMap: [Int: String] = [:]
            var startIndex = 0
            if !rows.isEmpty, looksLikeHeader(rows[0]) {
                for (i, h) in rows[0].enumerated() { headerMap[i] = canonicalHeaderName(h) }
                startIndex = 1
            }
            for (idx, row) in rows[startIndex...].enumerated() {
                let provided = mapRow(row, headerMap: headerMap)
                let item = ImportItem(
                    lineNumber: startIndex + idx + 1,
                    providedSurface: provided.surface?.nilIfEmpty,
                    providedReading: provided.reading?.nilIfEmpty,
                    providedMeaning: provided.meaning?.nilIfEmpty,
                    note: provided.note?.nilIfEmpty,
                    computedSurface: nil,
                    computedReading: nil,
                    computedMeaning: nil
                )
                items.append(item)
            }
        } else {
            // List path
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in lines.enumerated() {
                let provided = parseLineHeuristics(line.trimmingCharacters(in: .whitespacesAndNewlines))
                let item = ImportItem(
                    lineNumber: i + 1,
                    providedSurface: provided.surface?.nilIfEmpty,
                    providedReading: provided.reading?.nilIfEmpty,
                    providedMeaning: provided.meaning?.nilIfEmpty,
                    note: provided.note?.nilIfEmpty,
                    computedSurface: nil,
                    computedReading: nil,
                    computedMeaning: nil
                )
                items.append(item)
            }
        }
        return items
    }

    static func fillMissing(items: inout [ImportItem], preferKanaOnly: Bool) async {
        for i in items.indices {
            let prov = ProvidedRow(
                surface: items[i].providedSurface,
                reading: items[i].providedReading,
                meaning: items[i].providedMeaning,
                note: items[i].note
            )
            if let prepared = try? await fillRow(prov, preferKanaOnly: preferKanaOnly) {
                // Only set computed fields where provided is missing
                if (items[i].providedSurface?.isEmpty ?? true) { items[i].computedSurface = prepared.surface }
                if (items[i].providedReading?.isEmpty ?? true) { items[i].computedReading = prepared.reading }
                if (items[i].providedMeaning?.isEmpty ?? true) { items[i].computedMeaning = prepared.meaning }
            }
        }
    }

    static func finalize(items: [ImportItem], preferKanaOnly: Bool) -> [PreparedWord] {
        var out: [PreparedWord] = []
        for it in items {
            var surface = (it.providedSurface?.nilIfEmpty) ?? (it.computedSurface?.nilIfEmpty) ?? ""
            var reading = (it.providedReading?.nilIfEmpty) ?? (it.computedReading?.nilIfEmpty) ?? ""
            var meaning = (it.providedMeaning?.nilIfEmpty) ?? (it.computedMeaning?.nilIfEmpty) ?? ""
            let note = it.note?.nilIfEmpty
            if surface.isEmpty && !reading.isEmpty { surface = reading }
            if preferKanaOnly, (it.providedSurface?.isEmpty ?? true), !(it.providedReading?.isEmpty ?? true), !reading.isEmpty {
                surface = reading
            }
            guard !meaning.isEmpty else { continue }
            out.append(PreparedWord(surface: surface, reading: reading, meaning: meaning, note: note))
        }
        return out
    }

    // MARK: - CSV

    private struct ProvidedRow { var surface: String?; var reading: String?; var meaning: String?; var note: String? }

    private static func importCSV(_ text: String, preferKanaOnly: Bool) async throws -> ImportResult {
        let rows = parseCSV(text)
        guard !rows.isEmpty else { return ImportResult(prepared: [], errors: []) }

        var headerMap: [Int: String] = [:]
        var startIndex = 0
        if looksLikeHeader(rows[0]) {
            let header = rows[0]
            for (i, h) in header.enumerated() { headerMap[i] = canonicalHeaderName(h) }
            startIndex = 1
        }

        var prepared: [PreparedWord] = []
        var errors: [String] = []

        for (idx, row) in rows[startIndex...].enumerated() {
            let provided = mapRow(row, headerMap: headerMap)
            do {
                if let w = try await fillRow(provided, preferKanaOnly: preferKanaOnly) {
                    prepared.append(w)
                } else {
                    errors.append("Line \(startIndex + idx + 1): insufficient data (meaning unresolved)")
                }
            } catch {
                errors.append("Line \(startIndex + idx + 1): \(error.localizedDescription)")
            }
        }
        return ImportResult(prepared: prepared, errors: errors)
    }

    private static func looksLikeHeader(_ fields: [String]) -> Bool {
        guard !fields.isEmpty else { return false }
        let keys = Set(fields.map { canonicalHeaderName($0) })
        let known: Set<String> = ["kanji", "surface", "word", "term", "kana", "reading", "furigana", "yomi", "english", "meaning", "gloss", "definition", "def", "note", "notes", "comment"]
        return !keys.intersection(known).isEmpty
    }

    private static func canonicalHeaderName(_ raw: String) -> String {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func mapRow(_ row: [String], headerMap: [Int: String]) -> ProvidedRow {
        var out = ProvidedRow()
        if headerMap.isEmpty {
            // Positional default: kanji, kana, english, note
            if row.indices.contains(0) { out.surface = row[0].trimmingCharacters(in: .whitespacesAndNewlines) }
            if row.indices.contains(1) { out.reading = row[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            if row.indices.contains(2) { out.meaning = row[2].trimmingCharacters(in: .whitespacesAndNewlines) }
            if row.indices.contains(3) { out.note = row[3].trimmingCharacters(in: .whitespacesAndNewlines) }
            return out
        }
        for (i, valRaw) in row.enumerated() {
            let val = valRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !val.isEmpty else { continue }
            switch headerMap[i] ?? "" {
            case "kanji", "surface", "word", "term": out.surface = val
            case "kana", "reading", "furigana", "yomi": out.reading = val
            case "english", "meaning", "gloss", "definition", "def": out.meaning = val
            case "note", "notes", "comment": out.note = val
            default:
                // If unknown header, try to place into first empty slot in order: meaning, reading, surface, note
                if out.meaning == nil { out.meaning = val }
                else if out.reading == nil { out.reading = val }
                else if out.surface == nil { out.surface = val }
                else if out.note == nil { out.note = val }
            }
        }
        return out
    }

    // RFC4180-ish CSV parser supporting quoted fields and escaped quotes
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        var iter = text.makeIterator()
        var prevChar: Character? = nil

        func endField() { current.append(field); field = "" }
        func endRow() { endField(); rows.append(current); current = [] }

        while let ch = iter.next() {
            if inQuotes {
                if ch == "\"" {
                    if let next = iter.next() {
                        if next == "\"" { field.append("\"") } else if next == "," { endField(); inQuotes = false } else if next == "\n" { endRow(); inQuotes = false } else { field.append(next) }
                    } else {
                        // End of input after quote
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": endField()
                case "\n": endRow()
                case "\r": continue // normalize earlier
                default: field.append(ch)
                }
            }
            prevChar = ch
        }
        // Flush last field/row
        if !field.isEmpty || !current.isEmpty { endRow() }
        return rows
    }

    // MARK: - Plain list parsing

    private static func importList(_ text: String, preferKanaOnly: Bool) async throws -> ImportResult {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var prepared: [PreparedWord] = []
        var errors: [String] = []
        for (i, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let provided = parseLineHeuristics(line)
            do {
                if let w = try await fillRow(provided, preferKanaOnly: preferKanaOnly) {
                    prepared.append(w)
                } else {
                    errors.append("Line \(i + 1): insufficient data (meaning unresolved)")
                }
            } catch {
                errors.append("Line \(i + 1): \(error.localizedDescription)")
            }
        }
        return ImportResult(prepared: prepared, errors: errors)
    }

    private static func parseLineHeuristics(_ line: String) -> ProvidedRow {
        var out = ProvidedRow()
        // Pattern 1: Kanji【reading】 - meaning
        if let open = line.firstIndex(of: "【"), let close = line.firstIndex(of: "】"), open < close {
            let kanji = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            let reading = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            out.surface = kanji
            out.reading = reading
            if let dash = rest.firstIndex(of: "-") {
                let meaning = String(rest[rest.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
                if !meaning.isEmpty { out.meaning = meaning }
            } else if !rest.isEmpty {
                out.meaning = rest
            }
            return out
        }
        // Pattern 2: split by tab or 2+ spaces (kanji [kana] english)
        let tabParts = line.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
        if tabParts.count >= 2 {
            // Heuristic: first -> surface, second -> reading or meaning; third -> meaning if present
            out.surface = tabParts[safe: 0]
            if tabParts.count >= 3 {
                out.reading = tabParts[safe: 1]
                out.meaning = tabParts[safe: 2]
            } else {
                // two columns: try to detect if second is kana or meaning by Unicode range
                let second = tabParts[1]
                if containsKana(second) || containsKanji(second) {
                    out.reading = second
                } else {
                    out.meaning = second
                }
            }
            return out
        }
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 3 {
            out.surface = parts[0]
            let second = parts[1]
            if containsKana(second) || containsKanji(second) {
                out.reading = second
                out.meaning = parts.dropFirst(2).joined(separator: " ")
            } else {
                out.meaning = parts.dropFirst(1).joined(separator: " ")
            }
            return out
        }
        // Fallback: single token -> could be kanji/kana/english
        if !line.isEmpty {
            if containsKana(line) || containsKanji(line) {
                // Japanese token; unknown whether kanji or kana
                out.surface = line
            } else {
                // English token
                out.meaning = line
            }
        }
        return out
    }

    private static func containsKanji(_ s: String) -> Bool {
        for ch in s.unicodeScalars { if ch.value >= 0x4E00 && ch.value <= 0x9FFF { return true } }
        return false
    }
    private static func containsKana(_ s: String) -> Bool {
        for ch in s.unicodeScalars {
            if (0x3040...0x309F).contains(ch.value) { return true } // Hiragana
            if (0x30A0...0x30FF).contains(ch.value) { return true } // Katakana
        }
        return false
    }

    // MARK: - Enrichment

    private static func fillRow(_ row: ProvidedRow, preferKanaOnly: Bool) async throws -> PreparedWord? {
        var surface = row.surface?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var reading = row.reading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var meaning = row.meaning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = row.note?.trimmingCharacters(in: .whitespacesAndNewlines)

        func primaryGloss(_ e: DictionaryEntry) -> String {
            e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
        }

        // Try to lookup if we are missing any of reading/meaning/surface
        let needLookup = (meaning.isEmpty || reading.isEmpty || surface.isEmpty)
        if needLookup {
            let term: String? = {
                if !surface.isEmpty { return surface }
                if !reading.isEmpty { return reading }
                if !meaning.isEmpty { return meaning }
                return nil
            }()

            if let t = term, !t.isEmpty {
                let entries = try await DictionarySQLiteStore.shared.lookup(term: t, limit: 1)
                if let e = entries.first {
                    if meaning.isEmpty { meaning = primaryGloss(e) }
                    if reading.isEmpty { reading = e.reading }
                    if surface.isEmpty {
                        if preferKanaOnly && !reading.isEmpty && row.surface?.isEmpty != false && row.reading?.isEmpty == false {
                            // Caller provided only kana and prefers kana-only surface
                            surface = reading
                        } else {
                            surface = e.kanji.isEmpty ? e.reading : e.kanji
                        }
                    }
                }
            }
        }

        // If still missing meaning, we cannot add a word (the app requires a non-empty meaning)
        guard !meaning.isEmpty else { return nil }
        if surface.isEmpty && !reading.isEmpty { surface = reading }
        // Reading can be empty; WordStore.add will accept empty reading

        return PreparedWord(surface: surface, reading: reading, meaning: meaning, note: note)
    }
}

// Safe subscript helper
private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        switch self {
        case .some(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case .none:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

