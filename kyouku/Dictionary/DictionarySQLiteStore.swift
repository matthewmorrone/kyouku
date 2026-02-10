import Foundation
import SQLite3

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
    private var hasSentencePairs = false
    private var hasPitchAccents = false
    private var lastQueryDescription: String = ""

    private init() {
        self.db = nil
    }

    // Keep an exact-only variant for contexts like the Details sheet where we
    // do NOT want substring/token fallback results.
    private func lookupExactSync(term: String, limit: Int = 30, mode: DictionarySearchMode) throws -> [DictionaryEntry] {
        try ensureOpen()

        guard db != nil else {
            return []
        }

        // IMPORTANT: `term` must already be normalized by `DictionaryKeyPolicy.lookupKey`.
        guard term.isEmpty == false else {
            return []
        }

        let normalized = term

        if case .english = mode {
            return try selectEntriesByGloss(matching: normalized, limit: limit)
        }

        // 1) Exact match on kanji/kana_forms + kana normalization fallbacks.
        var results = try queryExactMatches(for: normalized, limit: limit)
        if !results.isEmpty { return results }

        // 2) If the query is Latin, try converting to kana and exact-matching.
        if looksLikeLatinQuery(normalized) {
            let kanaCandidates = latinToKanaCandidates(for: normalized)
            for cand in kanaCandidates where !cand.isEmpty {
                results = try queryExactMatches(for: cand, limit: limit)
                if !results.isEmpty { return results }
            }
        }

        return []
    }

    // Keep the core implementation synchronous inside the actor.
    // We'll expose async wrappers for call sites.
    private func lookupSync(term: String, limit: Int = 30, mode: DictionarySearchMode) throws -> [DictionaryEntry] {
        try ensureOpen()

        guard db != nil else {
            return []
        }

        // IMPORTANT: `term` must already be normalized by `DictionaryKeyPolicy.lookupKey`.
        // No trimming/folding/normalization is performed here.
        guard term.isEmpty == false else {
            return []
        }

        let normalized = term

        // When English is explicitly requested, prioritize gloss search.
        if case .english = mode {
            let englishResults = try selectEntriesByGloss(matching: normalized, limit: limit)
            if englishResults.isEmpty == false {
                return englishResults
            }
            // User might have typed Japanese while EN is selected; fall back to the JP pipeline.
            return try lookupSync(term: normalized, limit: limit, mode: .japanese)
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

            // For JP mode we stop here so English words don't fall through to gloss hits.
            return []
        }

        // 2b) Surface substring match via indexed tokens if no hits yet
        results = try selectEntriesBySurfaceToken(matching: normalized, limit: limit)
        if !results.isEmpty { return results }

        // 3) English gloss search is reserved for explicit EN queries, so JP lookups end here.
        return []
    }

    private func looksLikeLatinQuery(_ text: String) -> Bool {
        // Input is expected to already be a normalized lookup key (trimmed upstream).
        guard text.isEmpty == false else { return false }
        guard containsJapaneseScript(text) == false else { return false }

        var hasLatinLetter = false
        for scalar in text.unicodeScalars {
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
        try lookupSync(term: term, limit: limit, mode: .japanese)
    }

    /// Variant that allows callers to influence how the query is interpreted
    /// (e.g., prefer English gloss matches for Latin input).
    func lookup(term: String, limit: Int = 30, mode: DictionarySearchMode) async throws -> [DictionaryEntry] {
        try lookupSync(term: term, limit: limit, mode: mode)
    }

    /// Exact-only lookup (no substring/token fallback). Useful for Details views
    /// where we only want the selected surface and its lemma, not component hits.
    func lookupExact(term: String, limit: Int = 30, mode: DictionarySearchMode = .japanese) async throws -> [DictionaryEntry] {
        try lookupExactSync(term: term, limit: limit, mode: mode)
    }

    func fetchEntryDetails(for entryIDs: [Int64]) async throws -> [DictionaryEntryDetail] {
        try fetchEntryDetailsSync(for: entryIDs)
    }

    /// Returns a best-effort priority score for each entry based on JMdict tags.
    /// Lower scores indicate higher priority (more common/important forms).
    ///
    /// This helps produce Jisho-like ordering when many entries share the same
    /// reading/surface (e.g. こと → 事/言/琴…).
    func fetchEntryPriorityScores(for entryIDs: [Int64]) async throws -> [Int64: Int] {
        try fetchEntryPriorityScoresSync(for: entryIDs)
    }

    /// Best-effort example sentence lookup.
    ///
    /// Notes:
    /// - The DB currently does not map JMdict entry IDs to sentences.
    /// - We therefore do a substring match over `sentence_pairs.jp_text`.
    /// - If the bundled DB lacks the optional `sentence_pairs` table, this returns [].
    func fetchExampleSentences(containing terms: [String], limit: Int = 8) async throws -> [ExampleSentence] {
        try fetchExampleSentencesSync(containing: terms, limit: limit)
    }

    /// Returns pitch accent rows keyed by (surface, reading) if the bundled DB includes
    /// the optional `pitch_accents` table.
    func fetchPitchAccents(surface: String, reading: String) async throws -> [PitchAccent] {
        try fetchPitchAccentsSync(surface: surface, reading: reading)
    }

    /// Returns whether the bundled DB includes the optional `pitch_accents` table.
    ///
    /// Non-throwing: returns false if the DB cannot be opened.
    func supportsPitchAccents() async -> Bool {
        do {
            try ensureOpen()
            return hasPitchAccents
        } catch {
            return false
        }
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

    /// Returns surface forms that are explicitly allowed to end with small っ/ッ.
    ///
    /// This is used by Stage 1 segmentation to enforce the hard constraint that
    /// normal lexical tokens must not terminate on sokuon. We only allow it for
    /// entries that JMdict classifies as interjections or onomatopoeic/mimetic forms.
    ///
    /// IMPORTANT: Callers must treat this as bootstrap-only data and cache it in memory.
    func listSokuonTerminalAllowedSurfaceForms() async throws -> [String] {
        try ensureOpen()
        guard let db else { return [] }
        let sql = """
        WITH allowed_entries AS (
            SELECT DISTINCT entry_id
            FROM senses
            WHERE COALESCE(pos, '') LIKE '%int%'
               OR COALESCE(misc, '') LIKE '%on-mim%'
               OR COALESCE(misc, '') LIKE '%on-mat%'
        )
        SELECT DISTINCT k.text
        FROM kana_forms k
        JOIN allowed_entries a ON a.entry_id = k.entry_id
        WHERE k.text LIKE '%っ' OR k.text LIKE '%ッ'
        UNION
        SELECT DISTINCT k.text
        FROM kanji k
        JOIN allowed_entries a ON a.entry_id = k.entry_id
        WHERE k.text LIKE '%っ' OR k.text LIKE '%ッ';
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            let raw = String(cString: ptr)
            let normalized = raw.precomposedStringWithCanonicalMapping
            if normalized.isEmpty == false {
                out.append(normalized)
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
                             COALESCE((SELECT GROUP_CONCAT(t.text, '; ')
                                                 FROM (
                                                         SELECT g.text AS text
                                                         FROM senses s
                                                         JOIN glosses g ON g.sense_id = s.id
                                                         WHERE s.entry_id = e.id
                                                         ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
                                                 ) t), '') AS gloss_text,
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

        var out: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let kanaText = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            let trimmedKana = kanaText.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                DictionaryEntry(
                    entryID: id,
                    kanji: kanji,
                    kana: trimmedKana.isEmpty ? nil : trimmedKana,
                    gloss: gloss,
                    isCommon: isCommon
                )
            )
        }

        return out
    }

    private func selectEntriesByGloss(matching term: String, limit: Int) throws -> [DictionaryEntry] {
        guard let db else { return [] }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        if hasGlossesFTS, let ftsQuery = buildFTSQuery(from: trimmed) {
        let rankedSQL = """
        WITH matched AS (
            SELECT entry_id, MIN(bm25(glosses_fts)) AS score
            FROM glosses_fts
            WHERE glosses_fts MATCH ?1
            GROUP BY entry_id
            ORDER BY score ASC
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
                             COALESCE((SELECT GROUP_CONCAT(t.text, '; ')
                                                 FROM (
                                                         SELECT g.text AS text
                                                         FROM senses s
                                                         JOIN glosses g ON g.sense_id = s.id
                                                         WHERE s.entry_id = e.id
                                                         ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
                                                 ) t), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag,
               m.score
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        ORDER BY m.score ASC, is_common_flag DESC, e.id ASC
        LIMIT ?2;
        """

        let fallbackSQL = """
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
                             COALESCE((SELECT GROUP_CONCAT(t.text, '; ')
                                                 FROM (
                                                         SELECT g.text AS text
                                                         FROM senses s
                                                         JOIN glosses g ON g.sense_id = s.id
                                                         WHERE s.entry_id = e.id
                                                         ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
                                                 ) t), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        var sqlUsed = rankedSQL
        if sqlite3_prepare_v2(db, rankedSQL, -1, &stmt, nil) != SQLITE_OK {
            // Some SQLite builds/FTS schemas may not support bm25(); fall back to a basic query.
            sqlUsed = fallbackSQL
            if sqlite3_prepare_v2(db, fallbackSQL, -1, &stmt, nil) != SQLITE_OK {
                throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        defer { sqlite3_finalize(stmt) }

        lastQueryDescription = "selectEntriesByGloss term='\(trimmed)' fts='\(ftsQuery)' limit=\(limit)\n" + sqlUsed

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var out: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let kanaText = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            let trimmedKana = kanaText.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                DictionaryEntry(
                    entryID: id,
                    kanji: kanji,
                    kana: trimmedKana.isEmpty ? nil : trimmedKana,
                    gloss: gloss,
                    isCommon: isCommon
                )
            )
        }
            if out.isEmpty == false {
                return out
            }
        }

        // Fallback when the bundled DB lacks the optional gloss FTS table (or it wasn't detected).
        // This is slower than FTS but keeps EN search functional.
        let lower = trimmed.lowercased()
        var tokens: [String] = []
        var current = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if current.isEmpty == false {
                tokens.append(current)
                current.removeAll(keepingCapacity: false)
            }
        }
        if current.isEmpty == false { tokens.append(current) }
        guard tokens.isEmpty == false else { return [] }

        let likeClauses = tokens.enumerated().map { idx, _ in
            "lower(g.text) LIKE '%' || ?\(idx + 1) || '%'"
        }.joined(separator: " AND ")

        let sql = """
        WITH matched AS (
            SELECT s.entry_id
            FROM glosses g
            JOIN senses s ON s.id = g.sense_id
            WHERE (g.lang = 'eng' OR g.lang IS NULL OR g.lang = '')
              AND \(likeClauses)
            GROUP BY s.entry_id
            LIMIT ?\(tokens.count + 1)
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
               COALESCE((SELECT GROUP_CONCAT(g2.text, '; ')
                         FROM senses s2
                         JOIN glosses g2 ON g2.sense_id = s2.id
                         WHERE s2.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM kana_forms r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?\(tokens.count + 1);
        """

        lastQueryDescription = "selectEntriesByGlossFallback term='\(trimmed)' tokens='\(tokens.joined(separator: " "))' limit=\(limit)\n" + sql

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, token) in tokens.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int(stmt, Int32(tokens.count + 1), Int32(max(1, limit)))

        var out: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let kanaText = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            let trimmedKana = kanaText.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                DictionaryEntry(
                    entryID: id,
                    kanji: kanji,
                    kana: trimmedKana.isEmpty ? nil : trimmedKana,
                    gloss: gloss,
                    isCommon: isCommon
                )
            )
        }
        return out
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
                             COALESCE((SELECT GROUP_CONCAT(t.text, '; ')
                                                 FROM (
                                                         SELECT g.text AS text
                                                         FROM senses s
                                                         JOIN glosses g ON g.sense_id = s.id
                                                         WHERE s.entry_id = e.id
                                                         ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
                                                 ) t), '') AS gloss_text,
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
                             COALESCE((SELECT GROUP_CONCAT(t.text, '; ')
                                                 FROM (
                                                         SELECT g.text AS text
                                                         FROM senses s
                                                         JOIN glosses g ON g.sense_id = s.id
                                                         WHERE s.entry_id = e.id
                                                         ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
                                                 ) t), '') AS gloss_text,
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

        var out: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let kanaText = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            let trimmedKana = kanaText.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                DictionaryEntry(
                    entryID: id,
                    kanji: kanji,
                    kana: trimmedKana.isEmpty ? nil : trimmedKana,
                    gloss: gloss,
                    isCommon: isCommon
                )
            )
        }
        return out
    }

    /// Debug helper for surfacing the most recent SQL used in lookups.
    func debugLastQueryDescription() async -> String {
        lastQueryDescription
    }

    // NOTE: We intentionally no longer expand a single JMdict entry into multiple
    // `DictionaryEntry` results per kana variant. Alternate readings are handled
    // as a property of the entry (via `fetchEntryDetailsSync(for:)`).

    private func fetchEntryDetailsSync(for entryIDs: [Int64]) throws -> [DictionaryEntryDetail] {
        let ordered = orderedUniqueEntryIDs(entryIDs)
        guard ordered.isEmpty == false else { return [] }
        try ensureOpen()
        guard db != nil else { return [] }

        let metadata = try fetchEntryMetadata(for: ordered)
        guard metadata.isEmpty == false else { return [] }

        let kanjiMap = try fetchFormMap(table: "kanji", entryIDs: ordered)
        let kanaMap = try fetchFormMap(table: "kana_forms", entryIDs: ordered)
        let sensesMap = try fetchSensesMap(for: ordered)

        var details: [DictionaryEntryDetail] = []
        details.reserveCapacity(ordered.count)
        for entryID in ordered {
            guard let isCommon = metadata[entryID] else { continue }
            let detail = DictionaryEntryDetail(
                entryID: entryID,
                isCommon: isCommon,
                kanjiForms: kanjiMap[entryID] ?? [],
                kanaForms: kanaMap[entryID] ?? [],
                senses: sensesMap[entryID] ?? []
            )
            details.append(detail)
        }
        return details
    }

    private func fetchEntryPriorityScoresSync(for entryIDs: [Int64]) throws -> [Int64: Int] {
        let ordered = orderedUniqueEntryIDs(entryIDs)
        guard ordered.isEmpty == false else { return [:] }
        try ensureOpen()
        guard let db else { return [:] }

        func tagPriority(_ tag: String) -> Int? {
            let t = tag.lowercased()
            switch t {
            case "ichi1": return 0
            case "news1": return 1
            case "spec1": return 2
            case "gai1": return 3
            case "ichi2": return 10
            case "news2": return 11
            case "spec2": return 12
            case "gai2": return 13
            default:
                break
            }

            // JMdict frequency tags sometimes appear as nf01..nf48 (lower is more frequent).
            if t.hasPrefix("nf"), t.count == 4 {
                let digits = t.suffix(2)
                if let v = Int(digits) {
                    return 20 + v
                }
            }

            // Optional JLPT-like tags if present.
            if t.hasPrefix("jlpt"), let last = t.last, let n = Int(String(last)) {
                return 80 + n
            }

            return nil
        }

        func bestTagScore(from tags: [String]) -> Int {
            var best = Int.max
            for tag in tags {
                if let p = tagPriority(tag) {
                    best = min(best, p)
                }
            }
            return best == Int.max ? 200 : best
        }

        // Defaults to a high score; we lower it when we find better tags/common forms.
        var bestByEntry: [Int64: Int] = [:]

        for chunk in chunkedEntryIDs(ordered) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT entry_id, is_common, tags
            FROM kanji
            WHERE entry_id IN (\(placeholders))
            UNION ALL
            SELECT entry_id, is_common, tags
            FROM kana_forms
            WHERE entry_id IN (\(placeholders));
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            // Bind the chunk twice (for the UNION ALL).
            for (index, entryID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), entryID)
            }
            for (index, entryID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(chunk.count + index + 1), entryID)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let entryID = sqlite3_column_int64(stmt, 0)
                let isCommon = sqlite3_column_int(stmt, 1) != 0
                let rawTags = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
                let tags = decodeTags(rawTags)

                // Common forms should generally win when everything else ties.
                let commonPenalty = isCommon ? 0 : 50
                let tagScore = bestTagScore(from: tags)
                let score = commonPenalty + tagScore

                if let existing = bestByEntry[entryID] {
                    if score < existing {
                        bestByEntry[entryID] = score
                    }
                } else {
                    bestByEntry[entryID] = score
                }
            }
        }

        return bestByEntry
    }

    private func fetchEntryMetadata(for entryIDs: [Int64]) throws -> [Int64: Bool] {
        guard let db, entryIDs.isEmpty == false else { return [:] }
        var metadata: [Int64: Bool] = [:]
        for chunk in chunkedEntryIDs(entryIDs) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id, is_common FROM entries WHERE id IN (\(placeholders));"
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
                let isCommon = sqlite3_column_int(stmt, 1) != 0
                metadata[entryID] = isCommon
            }
        }
        return metadata
    }

    private func fetchFormMap(table: String, entryIDs: [Int64]) throws -> [Int64: [DictionaryEntryForm]] {
        guard let db, entryIDs.isEmpty == false else { return [:] }
        var map: [Int64: [DictionaryEntryForm]] = [:]
        for chunk in chunkedEntryIDs(entryIDs) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id, entry_id, text, is_common, tags FROM \(table) WHERE entry_id IN (\(placeholders)) ORDER BY entry_id ASC, is_common DESC, id ASC;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for (index, entryID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), entryID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let formID = sqlite3_column_int64(stmt, 0)
                let entryID = sqlite3_column_int64(stmt, 1)
                guard let textPtr = sqlite3_column_text(stmt, 2) else { continue }
                let text = String(cString: textPtr)
                guard text.isEmpty == false else { continue }
                let isCommon = sqlite3_column_int(stmt, 3) != 0
                let tagsValue = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
                let form = DictionaryEntryForm(id: formID, text: text, isCommon: isCommon, tags: decodeTags(tagsValue))
                map[entryID, default: []].append(form)
            }
        }
        return map
    }

    private func fetchSensesMap(for entryIDs: [Int64]) throws -> [Int64: [DictionaryEntrySense]] {
        guard let db, entryIDs.isEmpty == false else { return [:] }
        var builders: [Int64: DictionaryEntrySenseBuilder] = [:]
        var entrySenseIDs: [Int64: [Int64]] = [:]

        for chunk in chunkedEntryIDs(entryIDs) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id, entry_id, order_index, pos, misc, field, dialect FROM senses WHERE entry_id IN (\(placeholders)) ORDER BY entry_id ASC, order_index ASC;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for (index, entryID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), entryID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let senseID = sqlite3_column_int64(stmt, 0)
                let entryID = sqlite3_column_int64(stmt, 1)
                let orderIndex = Int(sqlite3_column_int(stmt, 2))
                let pos = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) }
                let misc = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
                let field = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
                let dialect = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) }
                let builder = DictionaryEntrySenseBuilder(
                    senseID: senseID,
                    entryID: entryID,
                    orderIndex: orderIndex,
                    partsOfSpeech: decodeTags(pos),
                    miscellaneous: decodeTags(misc),
                    fields: decodeTags(field),
                    dialects: decodeTags(dialect)
                )
                builders[senseID] = builder
                entrySenseIDs[entryID, default: []].append(senseID)
            }
        }

        let senseIDs = Array(builders.keys)
        guard senseIDs.isEmpty == false else { return [:] }

        for chunk in chunkedEntryIDs(senseIDs) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id, sense_id, entry_id, order_index, lang, text FROM glosses WHERE sense_id IN (\(placeholders)) ORDER BY sense_id ASC, order_index ASC;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for (index, senseID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), senseID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let glossID = sqlite3_column_int64(stmt, 0)
                let senseID = sqlite3_column_int64(stmt, 1)
                let orderIndex = Int(sqlite3_column_int(stmt, 3))
                guard let langPtr = sqlite3_column_text(stmt, 4) else { continue }
                let rawLanguage = String(cString: langPtr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                // Some generators leave English as an empty lang; treat that as English.
                // Also accept "en".
                let isEnglish = rawLanguage.isEmpty || rawLanguage == "eng" || rawLanguage == "en"
                guard isEnglish else { continue }
                guard let textPtr = sqlite3_column_text(stmt, 5) else { continue }
                let text = String(cString: textPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { continue }
                guard let builder = builders[senseID] else { continue }
                let gloss = DictionarySenseGloss(id: glossID, text: text, language: "eng", orderIndex: orderIndex)
                builder.glosses.append(gloss)
            }
        }

        var map: [Int64: [DictionaryEntrySense]] = [:]
        for (entryID, senseIDsForEntry) in entrySenseIDs {
            var senses: [DictionaryEntrySense] = []
            senses.reserveCapacity(senseIDsForEntry.count)
            for senseID in senseIDsForEntry {
                guard let builder = builders[senseID] else { continue }
                let sense = builder.makeSense()
                guard sense.glosses.isEmpty == false else { continue }
                senses.append(sense)
            }
            if senses.isEmpty == false {
                map[entryID] = senses
            }
        }
        return map
    }

    private func orderedUniqueEntryIDs(_ ids: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        var ordered: [Int64] = []
        ordered.reserveCapacity(ids.count)
        for id in ids {
            if seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    private func chunkedEntryIDs(_ ids: [Int64], chunkSize: Int = 400) -> [[Int64]] {
        guard ids.isEmpty == false else { return [] }
        var result: [[Int64]] = []
        result.reserveCapacity(max(1, ids.count / chunkSize))
        var offset = 0
        while offset < ids.count {
            let end = min(ids.count, offset + chunkSize)
            result.append(Array(ids[offset..<end]))
            offset = end
        }
        return result
    }

    private func decodeTags(_ raw: String?) -> [String] {
        guard let raw = raw, raw.isEmpty == false else { return [] }
        return raw
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private final class DictionaryEntrySenseBuilder {
        let senseID: Int64
        let entryID: Int64
        let orderIndex: Int
        let partsOfSpeech: [String]
        let miscellaneous: [String]
        let fields: [String]
        let dialects: [String]
        var glosses: [DictionarySenseGloss]

        init(senseID: Int64, entryID: Int64, orderIndex: Int, partsOfSpeech: [String], miscellaneous: [String], fields: [String], dialects: [String]) {
            self.senseID = senseID
            self.entryID = entryID
            self.orderIndex = orderIndex
            self.partsOfSpeech = partsOfSpeech
            self.miscellaneous = miscellaneous
            self.fields = fields
            self.dialects = dialects
            self.glosses = []
        }

        func makeSense() -> DictionaryEntrySense {
            let orderedGlosses = glosses.sorted { lhs, rhs in
                if lhs.orderIndex == rhs.orderIndex {
                    return lhs.id < rhs.id
                }
                return lhs.orderIndex < rhs.orderIndex
            }
            return DictionaryEntrySense(
                id: senseID,
                orderIndex: orderIndex,
                partsOfSpeech: partsOfSpeech,
                miscellaneous: miscellaneous,
                fields: fields,
                dialects: dialects,
                glosses: orderedGlosses
            )
        }
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
            hasSentencePairs = false
            hasPitchAccents = false
            return
        }
        hasGlossesFTS = tableExists("glosses_fts", in: db)
        hasSurfaceIndex = tableExists("surface_index", in: db)
        hasSentencePairs = tableExists("sentence_pairs", in: db)
        hasPitchAccents = tableExists("pitch_accents", in: db)
        if hasSurfaceIndex {
            surfaceIndexUsesHash = tableHasColumn("surface_index", column: "token_hash", in: db)
        } else {
            surfaceIndexUsesHash = false
        }
    }

    private func fetchPitchAccentsSync(surface: String, reading: String) throws -> [PitchAccent] {
        try ensureOpen()
        guard let db else { return [] }
        guard hasPitchAccents else { return [] }

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let r = reading.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard s.isEmpty == false, r.isEmpty == false else { return [] }

        let sql = """
        SELECT surface, reading, accent, morae, kind, reading_marked
        FROM pitch_accents
        WHERE surface = ?1 AND reading = ?2
        ORDER BY accent ASC, morae ASC;
        """

        lastQueryDescription = "fetchPitchAccents surface='\(s)' reading='\(r)'\n" + sql

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, s, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, r, -1, SQLITE_TRANSIENT)

        var out: [PitchAccent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let surfacePtr = sqlite3_column_text(stmt, 0), let readingPtr = sqlite3_column_text(stmt, 1) else { continue }
            let surfaceText = String(cString: surfacePtr)
            let readingText = String(cString: readingPtr)
            let accent = Int(sqlite3_column_int(stmt, 2))
            let morae = Int(sqlite3_column_int(stmt, 3))
            let kind: String? = {
                guard let ptr = sqlite3_column_text(stmt, 4) else { return nil }
                let v = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }()
            let readingMarked: String? = {
                guard let ptr = sqlite3_column_text(stmt, 5) else { return nil }
                let v = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }()

            out.append(
                PitchAccent(
                    surface: surfaceText,
                    reading: readingText,
                    accent: accent,
                    morae: morae,
                    kind: kind,
                    readingMarked: readingMarked
                )
            )
        }
        return out
    }

    private func fetchExampleSentencesSync(containing terms: [String], limit: Int) throws -> [ExampleSentence] {
        try ensureOpen()
        guard let db else { return [] }
        guard hasSentencePairs else { return [] }

        let normalizedTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard normalizedTerms.isEmpty == false else { return [] }

        func escapeLike(_ value: String) -> String {
            // Escape LIKE wildcards and the escape character itself.
            // We use ESCAPE '\\' in SQL.
            var out = ""
            out.reserveCapacity(value.count)
            for ch in value {
                if ch == "\\" || ch == "%" || ch == "_" {
                    out.append("\\")
                }
                out.append(ch)
            }
            return out
        }

        func isShortAndBroad(_ value: String) -> Bool {
            // Avoid pathological matches for 1-char kana / particles.
            // Still allow 1-char kanji queries.
            if value.count >= 2 { return false }
            return containsKanjiCharacters(value) == false
        }

        let perTermLimit = max(8, min(50, limit * 4))
        let overallLimit = max(1, limit)

        var seen: Set<String> = []
        var out: [ExampleSentence] = []
        out.reserveCapacity(min(16, overallLimit))

        let sql = "SELECT jp_id, en_id, jp_text, en_text FROM sentence_pairs WHERE jp_text LIKE ?1 ESCAPE '\\' ORDER BY jp_id ASC LIMIT ?2;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for rawTerm in normalizedTerms {
            if out.count >= overallLimit { break }
            if isShortAndBroad(rawTerm) { continue }

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            let pattern = "%\(escapeLike(rawTerm))%"
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(perTermLimit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let jpID = sqlite3_column_int64(stmt, 0)
                let enID = sqlite3_column_int64(stmt, 1)
                guard let jpPtr = sqlite3_column_text(stmt, 2), let enPtr = sqlite3_column_text(stmt, 3) else {
                    continue
                }

                let jpText = String(cString: jpPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                let enText = String(cString: enPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard jpText.isEmpty == false, enText.isEmpty == false else { continue }

                let key = "\(jpID)#\(enID)"
                if seen.insert(key).inserted {
                    out.append(ExampleSentence(jpID: jpID, enID: enID, jpText: jpText, enText: enText))
                    if out.count >= overallLimit { break }
                }
            }
        }

        return out
    }

}

