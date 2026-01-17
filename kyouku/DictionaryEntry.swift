//
//  DictionaryEntry.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation
import SQLite3

/// Dictionary lookup result.
///
/// - Note: `kana` is the authoritative kana reading supplied by the dictionary
///   database. It reflects the canonical reading of the lexical entry but may
///   differ from how a word appears in running user text.
struct DictionaryEntry: Identifiable, Hashable {
    let entryID: Int64
    let kanji: String
    let kana: String?
    let gloss: String
    let isCommon: Bool
    private let stableIdentifier: String

    nonisolated init(entryID: Int64, kanji: String, kana: String?, gloss: String, isCommon: Bool) {
        self.entryID = entryID
        self.kanji = kanji
        self.kana = kana
        self.gloss = gloss
        self.isCommon = isCommon
        let kanaComponent = kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.stableIdentifier = "\(entryID)#\(kanaComponent)"
    }

    var id: String { stableIdentifier }
}

private struct RawDictionaryRow {
    let entryID: Int64
    let kanji: String
    let gloss: String
    let isCommon: Bool
}



struct SurfaceReadingOverride: Hashable, Sendable {
    let surface: String
    let reading: String
}



enum DictionarySearchMode {
    case auto
    case englishFirst
}


actor DictionarySQLiteStore {
    static let shared = DictionarySQLiteStore()

    // Swift doesn't import SQLite's `SQLITE_TRANSIENT` macro. Define an equivalent
    // destructor so SQLite copies bound text. Marked nonisolated so it can be used
    // freely from async actor methods without crossing actor isolation.
    nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let surfaceTokenMaxLength = 10
    private var hasGlossesFTS = false
    private var hasSurfaceIndex = false
    private var surfaceIndexUsesHash = false
    private var lastQueryDescription: String = ""

    private init() {
        self.db = nil
    }

    // Keep the core implementation synchronous inside the actor.
    // We'll expose async wrappers for call sites.
    private func lookupSync(term: String, limit: Int = 30, mode: DictionarySearchMode) throws -> [DictionaryEntry] {
        try ensureOpen()

        guard db != nil else {
            return []
        }

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let normalized = normalizeFullWidthASCII(trimmed)

        // When English is explicitly requested, prioritize gloss search.
        if case .englishFirst = mode {
            let results = try selectEntriesByGloss(matching: normalized, limit: limit)
            if !results.isEmpty { return results }
            // Fall back to the default lookup path.
            return try lookupSync(term: term, limit: limit, mode: .auto)
        }

        // Default behavior: prefer Japanese surface/readings, then gloss.
        // 1) Exact match on kanji/kana_forms + simple conjugation fallbacks
        var results = try queryExactMatches(for: normalized, limit: limit)
        if !results.isEmpty { return results }

        // 2) If input looks like Latin (romaji/English), try converting to kana and match kana/kanji.
        //    This enables searching by romaji even when the user types a partial reading.
        if looksLikeLatinQuery(normalized) {
            let kanaCandidates = latinToKanaCandidates(for: normalized)
            for cand in kanaCandidates where !cand.isEmpty {
                results = try queryExactMatches(for: cand, limit: limit)
                if !results.isEmpty { return results }

                // Try substring match on kana tokens too (surface_index indexes kana as well).
                results = try selectEntriesBySurfaceToken(matching: cand, limit: limit)
                if !results.isEmpty { return results }
            }

            // English gloss search via FTS (works for both English and romaji-like Latin strings).
            results = try selectEntriesByGloss(matching: normalized, limit: limit)
            return results
        }

        // 2b) Surface substring match via indexed tokens if no hits yet
        results = try selectEntriesBySurfaceToken(matching: normalized, limit: limit)
        if !results.isEmpty { return results }

        // 3) English gloss search via FTS
        results = try selectEntriesByGloss(matching: normalized, limit: limit)
        return results
    }

    private func looksLikeLatinQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard containsJapaneseScript(trimmed) == false else { return false }

        var hasLatinLetter = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "'" || scalar == "-" { continue }

            // Common macron vowels used in romaji.
            if scalar == "ā" || scalar == "ī" || scalar == "ū" || scalar == "ē" || scalar == "ō" {
                hasLatinLetter = true
                continue
            }
            if scalar == "Ā" || scalar == "Ī" || scalar == "Ū" || scalar == "Ē" || scalar == "Ō" {
                hasLatinLetter = true
                continue
            }

            if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                hasLatinLetter = true
                continue
            }

            // Allow ASCII digits (e.g., "jlpt5") and basic punctuation without rejecting the query.
            if (0x0030...0x0039).contains(scalar.value) { continue }
        }
        return hasLatinLetter
    }

    private func containsJapaneseScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F, // Half-width katakana
                 0x3400...0x4DBF, // CJK Ext A
                 0x4E00...0x9FFF: // CJK Unified
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Public async API used by the rest of the app.
    /// This matches the existing `try await DictionarySQLiteStore.shared.lookup(...)` call sites.
    func lookup(term: String, limit: Int = 30) async throws -> [DictionaryEntry] {
        // Actor isolation ensures safe access to `db`, but the SQL work can still be heavy.
        // We keep the work inside the actor; since callers are often on @MainActor,
        // the `await` prevents blocking UI.
        try lookupSync(term: term, limit: limit, mode: .auto)
    }

    /// Variant that allows callers to influence how the query is interpreted
    /// (e.g., prefer English gloss matches for Latin input).
    func lookup(term: String, limit: Int = 30, mode: DictionarySearchMode) async throws -> [DictionaryEntry] {
        try lookupSync(term: term, limit: limit, mode: mode)
    }

    private func queryExactMatches(for term: String, limit: Int) throws -> [DictionaryEntry] {
        for candidate in exactMatchCandidates(for: term) {
            let rows = try selectEntries(matching: candidate, limit: limit)
            if !rows.isEmpty { return rows }
        }
        return []
    }

    func listAllSurfaceForms() async throws -> [String] {
        try ensureOpen()
        guard let db else { return [] }
        let sql = """
        SELECT text FROM kanji
        UNION
        SELECT text FROM kana_forms;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = String(cString: sqlite3_column_text(stmt, 0))
            if s.isEmpty == false {
                out.append(s)
            }
        }
        return out
    }

    func listDeterministicSurfaceReadings() async throws -> [SurfaceReadingOverride] {
        try ensureOpen()
        guard let db else { return [] }
        let sql = """
        WITH surface_pairs AS (
            SELECT k.text AS surface, r.text AS reading
            FROM kanji k
            JOIN kana_forms r ON r.entry_id = k.entry_id
            UNION ALL
            SELECT r.text AS surface, r.text AS reading
            FROM kana_forms r
        ),
        aggregated AS (
            SELECT surface,
                   MIN(reading) AS reading,
                   COUNT(DISTINCT reading) AS reading_count
            FROM surface_pairs
            WHERE surface IS NOT NULL
              AND reading IS NOT NULL
              AND surface <> ''
              AND reading <> ''
            GROUP BY surface
        )
        SELECT surface, reading
        FROM aggregated
        WHERE reading_count = 1;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var overrides: [SurfaceReadingOverride] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let surfacePtr = sqlite3_column_text(stmt, 0),
                  let readingPtr = sqlite3_column_text(stmt, 1) else { continue }
            let rawSurface = String(cString: surfacePtr)
            let rawReading = String(cString: readingPtr)
            let surface = rawSurface.precomposedStringWithCanonicalMapping
            let reading = rawReading.precomposedStringWithCanonicalMapping
            guard surface.isEmpty == false, reading.isEmpty == false else { continue }
            overrides.append(SurfaceReadingOverride(surface: surface, reading: reading))
        }

        return overrides
    }

    /// Returns distinct kana readings for a given surface form.
    ///
    /// This is used to offer alternative readings in the token action UI for
    /// surfaces that legitimately have multiple readings (e.g. "二人": ふたり / ににん).
    func listKanaReadings(forSurface surface: String, limit: Int = 12) async throws -> [String] {
        try ensureOpen()
        guard let db else { return [] }

        let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let sql = """
        WITH entry_ids AS (
            SELECT entry_id FROM kanji WHERE text = ?1
            UNION
            SELECT entry_id FROM kana_forms WHERE text = ?1
        )
        SELECT DISTINCT r.text
        FROM kana_forms r
        JOIN entry_ids e ON e.entry_id = r.entry_id
        WHERE r.text IS NOT NULL
          AND r.text <> ''
        ORDER BY r.is_common DESC, r.id ASC
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [String] = []
        out.reserveCapacity(min(limit, 12))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            let raw = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = raw.precomposedStringWithCanonicalMapping
            guard normalized.isEmpty == false else { continue }
            if out.contains(normalized) == false {
                out.append(normalized)
            }
        }
        return out
    }

    private func ensureOpen() throws {
        if db != nil {
            return
        }

        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            throw DictionarySQLiteError.resourceNotFound
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX

        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw DictionarySQLiteError.openFailed(msg)
        }

        self.db = handle
        refreshOptionalIndexes()
    }

    private func selectEntries(matching term: String, limit: Int) throws -> [DictionaryEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT e.id,
                             COALESCE((SELECT k_match.text
                                                 FROM kanji k_match
                                                 WHERE k_match.entry_id = e.id
                                                     AND k_match.text = ?1
                                                 LIMIT 1),
                                                (SELECT k.text
                                                 FROM kanji k
                                                 WHERE k.entry_id = e.id
                                                 ORDER BY k.is_common DESC, k.id ASC
                                                 LIMIT 1),
                                                '') AS kanji_text,
               COALESCE((SELECT r.text
                         FROM kana_forms r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS kana_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        WHERE EXISTS (SELECT 1 FROM kanji k2 WHERE k2.entry_id = e.id AND k2.text = ?1)
           OR EXISTS (SELECT 1 FROM kana_forms r2 WHERE r2.entry_id = e.id AND r2.text = ?1)
        LIMIT ?2;
        """

        lastQueryDescription = "selectEntries term='\(term)' limit=\(limit)\n" + sql

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, term, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var rows: [RawDictionaryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            rows.append(RawDictionaryRow(entryID: id, kanji: kanji, gloss: gloss, isCommon: isCommon))
        }

        return try expandRows(rows)
    }

    private func selectEntriesByGloss(matching term: String, limit: Int) throws -> [DictionaryEntry] {
        guard hasGlossesFTS else { return [] }
        guard let db else { return [] }
        guard let ftsQuery = buildFTSQuery(from: term) else { return [] }
        let sql = """
        WITH matched AS (
            SELECT entry_id
            FROM glosses_fts
            WHERE glosses_fts MATCH ?1
            GROUP BY entry_id
            LIMIT ?2
        )
        SELECT e.id,
               COALESCE((SELECT k.text
                         FROM kanji k
                         WHERE k.entry_id = e.id
                         ORDER BY k.is_common DESC, k.id ASC
                         LIMIT 1), '') AS kanji_text,
               COALESCE((SELECT r.text
                         FROM kana_forms r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS kana_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?2;
        """

        lastQueryDescription = "selectEntriesByGloss term='\(term)' fts='\(ftsQuery)' limit=\(limit)\n" + sql

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var rows: [RawDictionaryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            rows.append(RawDictionaryRow(entryID: id, kanji: kanji, gloss: gloss, isCommon: isCommon))
        }
        return try expandRows(rows)
    }

    private func selectEntriesBySurfaceToken(matching term: String, limit: Int) throws -> [DictionaryEntry] {
        guard hasSurfaceIndex else { return [] }
        guard let db else { return [] }
        let sanitized = sanitizeSurfaceToken(term)
        guard !sanitized.isEmpty else { return [] }
        guard sanitized.count <= surfaceTokenMaxLength else { return [] }
        let sql: String
        if surfaceIndexUsesHash {
            sql = """
        WITH matched AS (
            SELECT entry_id
            FROM surface_index
            WHERE token_hash = ?1
            GROUP BY entry_id
            LIMIT ?2
        )
        SELECT e.id,
               COALESCE((SELECT k.text
                         FROM kanji k
                         WHERE k.entry_id = e.id
                         ORDER BY k.is_common DESC, k.id ASC
                         LIMIT 1), '') AS kanji_text,
               COALESCE((SELECT r.text
                         FROM kana_forms r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS kana_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?2;
        """
        } else {
            sql = """
        WITH matched AS (
            SELECT entry_id
            FROM surface_index
            WHERE token = ?1
            GROUP BY entry_id
            LIMIT ?2
        )
        SELECT e.id,
               COALESCE((SELECT k.text
                         FROM kanji k
                         WHERE k.entry_id = e.id
                         ORDER BY k.is_common DESC, k.id ASC
                         LIMIT 1), '') AS kanji_text,
               COALESCE((SELECT r.text
                         FROM kana_forms r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS kana_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?2;
        """
        }

        if surfaceIndexUsesHash {
            lastQueryDescription = "selectEntriesBySurfaceToken term='\(term)' sanitized='\(sanitized)' limit=\(limit) using token_hash\n" + sql
        } else {
            lastQueryDescription = "selectEntriesBySurfaceToken term='\(term)' sanitized='\(sanitized)' limit=\(limit) using token\n" + sql
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if surfaceIndexUsesHash {
            let hash = surfaceTokenHash(sanitized)
            sqlite3_bind_int64(stmt, 1, hash)
        } else {
            sqlite3_bind_text(stmt, 1, sanitized, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var rows: [RawDictionaryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            rows.append(RawDictionaryRow(entryID: id, kanji: kanji, gloss: gloss, isCommon: isCommon))
        }
        return try expandRows(rows)
    }

    /// Debug helper for surfacing the most recent SQL used in lookups.
    func debugLastQueryDescription() async -> String {
        lastQueryDescription
    }

    private func expandRows(_ rows: [RawDictionaryRow]) throws -> [DictionaryEntry] {
        guard rows.isEmpty == false else { return [] }
        let entryIDs = Array(Set(rows.map { $0.entryID }))
        let kanaMap = try fetchKanaVariants(for: entryIDs)
        var expanded: [DictionaryEntry] = []
        expanded.reserveCapacity(rows.count)
        for row in rows {
            let readings = kanaMap[row.entryID] ?? []
            if readings.isEmpty {
                expanded.append(DictionaryEntry(entryID: row.entryID, kanji: row.kanji, kana: nil, gloss: row.gloss, isCommon: row.isCommon))
                continue
            }
            var seen: Set<String> = []
            for reading in readings {
                guard reading.isEmpty == false else { continue }
                if seen.insert(reading).inserted == false { continue }
                expanded.append(DictionaryEntry(entryID: row.entryID, kanji: row.kanji, kana: reading, gloss: row.gloss, isCommon: row.isCommon))
            }
        }
        return expanded
    }

    private func fetchKanaVariants(for entryIDs: [Int64]) throws -> [Int64: [String]] {
        guard let db, entryIDs.isEmpty == false else { return [:] }
        var mappings: [Int64: [String]] = [:]
        let chunkSize = 500
        var offset = 0
        while offset < entryIDs.count {
            let chunk = Array(entryIDs[offset..<min(entryIDs.count, offset + chunkSize)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT entry_id, text
            FROM kana_forms
            WHERE entry_id IN (\(placeholders))
            ORDER BY entry_id ASC, is_common DESC, id ASC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for (index, entryID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), entryID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let entryID = sqlite3_column_int64(stmt, 0)
                guard let textPtr = sqlite3_column_text(stmt, 1) else { continue }
                let reading = String(cString: textPtr)
                guard reading.isEmpty == false else { continue }
                mappings[entryID, default: []].append(reading)
            }
            offset += chunk.count
        }
        return mappings
    }

    private func containsKanjiCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) {
                return true
            }
        }
        return false
    }

    private func buildFTSQuery(from term: String) -> String? {
        let lower = term.lowercased()
        var tokens: [String] = []
        var current = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: false)
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return nil }
        let prefixed = tokens.map { "\($0)*" }
        return prefixed.joined(separator: " AND ")
    }

    private func surfaceTokenHash(_ text: String) -> Int64 {
        let fnvOffset: UInt64 = 0xcbf29ce484222325
        let fnvPrime: UInt64 = 0x100000001b3
        var hash = fnvOffset
        for scalar in text.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= fnvPrime
        }
        return Int64(bitPattern: hash)
    }

    private func refreshOptionalIndexes() {
        guard let db else {
            hasGlossesFTS = false
            hasSurfaceIndex = false
            return
        }
        hasGlossesFTS = tableExists("glosses_fts", in: db)
        hasSurfaceIndex = tableExists("surface_index", in: db)
        if hasSurfaceIndex {
            surfaceIndexUsesHash = tableHasColumn("surface_index", column: "token_hash", in: db)
        } else {
            surfaceIndexUsesHash = false
        }
    }

    private func tableExists(_ name: String, in db: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func tableHasColumn(_ table: String, column: String, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) != SQLITE_OK {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                let name = String(cString: namePtr)
                if name == column {
                    return true
                }
            }
        }
        return false
    }

    private func romanToHiragana(_ input: String) -> String {
        // Normalize
        var s = input.lowercased()
        // Replace macrons with typical IME equivalents
        s = s.replacingOccurrences(of: "ā", with: "aa")
            .replacingOccurrences(of: "ī", with: "ii")
            .replacingOccurrences(of: "ū", with: "uu")
            .replacingOccurrences(of: "ē", with: "ee")
            .replacingOccurrences(of: "ō", with: "ou")
        // Remove spaces and hyphens
        s = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        // Mappings inspired by iOS romaji IME
        let tri: [String: String] = [
            "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
            "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
            "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
            "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
            "ja": "じゃ", "ju": "じゅ", "jo": "じょ",
            "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
            "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
            "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ",
            "cya": "ちゃ", "cyu": "ちゅ", "cyo": "ちょ",
            "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
            "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
            "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
            "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
            "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
            "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
            "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
            "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
            "she": "しぇ", "che": "ちぇ", "je": "じぇ"
        ]
        let di: [String: String] = [
            // Core syllables
            "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
            "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
            "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
            "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
            "ji": "じ",
            "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と",
            "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
            "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
            "ha": "は", "hi": "ひ", "hu": "ふ", "he": "へ", "ho": "ほ",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
            "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
            "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
            "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
            "ya": "や", "yu": "ゆ", "yo": "よ",
            "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
            "wa": "わ", "wo": "を", "we": "うぇ", "wi": "うぃ"
        ]
        let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
        let consonants: Set<Character> = Set("bcdfghjklmnpqrstvwxyz")

        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            // handle n'
            if chars[i] == "n" && i + 1 < chars.count && chars[i + 1] == "'" {
                out += "ん"; i += 2; continue
            }
            // sokuon for double consonants (except n)
            if i + 1 < chars.count {
                let c = chars[i]
                let n = chars[i + 1]
                if c == n && consonants.contains(c) && c != "n" {
                    out += "っ"; i += 1; continue
                }
            }
            // Try tri-graph
            if i + 2 < chars.count {
                let key = String(chars[i...i + 2])
                if let kana = tri[key] {
                    out += kana; i += 3; continue
                }
            }
            // Special handling for standalone 'n'
            if chars[i] == "n" {
                if i + 1 >= chars.count { out += "ん"; i += 1; continue }
                let next = chars[i + 1]
                if next == "n" { out += "ん"; i += 2; continue }
                if !vowels.contains(next) && next != "y" { out += "ん"; i += 1; continue }
                // else fallthrough to digraph handling (na, ni, nya, ...)
            }
            // Try di-graph
            if i + 1 < chars.count {
                let key = String(chars[i...i + 1])
                if let kana = di[key] {
                    out += kana; i += 2; continue
                }
            }
            // Single vowels
            let key1 = String(chars[i])
            switch key1 {
            case "a": out += "あ"
            case "i": out += "い"
            case "u": out += "う"
            case "e": out += "え"
            case "o": out += "お"
            default:
                // pass-through unknown character (e.g., punctuation)
                out += key1
            }
            i += 1
        }
        return out
    }

    private func hiraganaToKatakana(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, false)
        return String(m)
    }

    private func latinToKanaCandidates(for term: String) -> [String] {
        let hira = romanToHiragana(term)
        var result: Set<String> = []
        if !hira.isEmpty { result.insert(hira) }
        let kata = hiraganaToKatakana(hira)
        if !kata.isEmpty { result.insert(kata) }
        return Array(result)
    }

    private func exactMatchCandidates(for term: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ value: String) {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        append(term)
        for variant in normalizedKanaVariants(for: term) {
            append(variant)
        }
        return ordered
    }

    private func normalizedKanaVariants(for term: String) -> [String] {
        let hiragana = katakanaToHiragana(term)
        guard containsOnlyKana(hiragana) else { return [] }

        var bases = Set<String>()

        // Potential/passive (common learner pain points):
        // - Ichidan potential/passive: たべられる → たべる
        // - Godan potential ("e-row" + る): かける → かく, よめる → よむ, ぬぐえる → ぬぐう
        if hiragana.hasSuffix("られる"), hiragana.count > "られる".count {
            let base = String(hiragana.dropLast("られる".count)) + "る"
            bases.insert(base)
        }
        if hiragana.hasSuffix("る"), hiragana.count > 1 {
            let map: [Character: Character] = [
                "え": "う",
                "け": "く",
                "げ": "ぐ",
                "せ": "す",
                "ぜ": "ず",
                "て": "つ",
                "で": "づ",
                "ね": "ぬ",
                "へ": "ふ",
                "べ": "ぶ",
                "ぺ": "ぷ",
                "め": "む",
                "れ": "る"
            ]
            let chars = Array(hiragana)
            let penultimate = chars[chars.count - 2]
            if let replacement = map[penultimate] {
                let prefix = String(chars.dropLast(2))
                let base = prefix + String(replacement)
                if base.isEmpty == false {
                    bases.insert(base)
                }
            }
        }

        let adjectiveSuffixes: [(String, String)] = [
            ("くなかったです", "い"),
            ("くなかった", "い"),
            ("くないです", "い"),
            ("くない", "い"),
            ("かったです", "い"),
            ("かった", "い")
        ]
        for (suffix, replacement) in adjectiveSuffixes {
            if hiragana.hasSuffix(suffix), hiragana.count > suffix.count {
                let base = String(hiragana.dropLast(suffix.count)) + replacement
                bases.insert(base)
            }
        }

        let verbTeForms = ["している", "してます", "していた", "してる"]
        for suffix in verbTeForms {
            if hiragana.hasSuffix(suffix), hiragana.count > suffix.count {
                let base = String(hiragana.dropLast(suffix.count)) + "する"
                bases.insert(base)
            }
        }

        let baseSnapshot = bases
        for base in baseSnapshot where base.hasSuffix("する") {
            let noun = String(base.dropLast(2))
            if noun.isEmpty == false {
                bases.insert(noun)
            }
        }

        guard bases.isEmpty == false else { return [] }

        var variants: [String] = []
        var seen = Set<String>()
        for base in bases {
            if seen.insert(base).inserted { variants.append(base) }
            let kata = hiraganaToKatakana(base)
            if seen.insert(kata).inserted { variants.append(kata) }
        }
        return variants
    }

    private func containsOnlyKana(_ text: String) -> Bool {
        guard text.isEmpty == false else { return false }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F, // Half-width katakana
                 0x30FC,          // Long vowel mark
                 0x3005:          // Iteration mark
                continue
            default:
                return false
            }
        }
        return true
    }

    private func katakanaToHiragana(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)
        return String(m)
    }

    private func normalizeFullWidthASCII(_ text: String) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(text.count)
        var changed = false
        for scalar in text.unicodeScalars {
            if (0xFF01...0xFF5E).contains(scalar.value),
               let converted = UnicodeScalar(scalar.value - 0xFEE0) {
                scalars.append(converted)
                changed = true
            } else {
                scalars.append(scalar)
            }
        }
        if !changed { return text }
        return String(String.UnicodeScalarView(scalars))
    }

    private func sanitizeSurfaceToken(_ term: String) -> String {
        let allowedRanges: [ClosedRange<UInt32>] = [
            0x0030...0x0039, // ASCII digits
            0x0041...0x005A, // ASCII upper
            0x0061...0x007A, // ASCII lower
            0x3040...0x309F, // Hiragana
            0x30A0...0x30FF, // Katakana
            0x3400...0x4DBF, // CJK Ext A
            0x4E00...0x9FFF, // CJK Unified
            0xFF66...0xFF9F  // Half-width katakana
        ]
        var scalars: [UnicodeScalar] = []
        for scalar in term.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "ー" || scalar == "々" {
                scalars.append(scalar)
                continue
            }
            if allowedRanges.contains(where: { $0.contains(scalar.value) }) {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }
}

