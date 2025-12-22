//
//  DictionaryEntry.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation
import SQLite3

struct DictionaryEntry: Identifiable, Hashable {
    let id: Int64
    let kanji: String
    let reading: String
    let gloss: String
    let isCommon: Bool
}



actor DictionarySQLiteStore {
    static let shared = DictionarySQLiteStore()

    private var db: OpaquePointer?
    private let surfaceTokenMaxLength = 10
    private var hasGlossesFTS = false
    private var hasSurfaceIndex = false
    private var surfaceIndexUsesHash = false

    private init() {
        self.db = nil
    }

    // Keep the core implementation synchronous inside the actor.
    // We'll expose an async wrapper for call sites.
    private func lookupSync(term: String, limit: Int = 30) throws -> [DictionaryEntry] {
        try ensureOpen()

        guard db != nil else {
            return []
        }

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let normalized = normalizeFullWidthASCII(trimmed)

        // 1) Exact match on kanji/readings + simple conjugation fallbacks
        var results = try queryExactMatches(for: normalized, limit: limit)
        if !results.isEmpty { return results }

        // 2) If input looks like Latin (romaji), try converting to kana and match readings
        let allowedLatin = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz '-")
        if normalized.rangeOfCharacter(from: allowedLatin.inverted) == nil {
            let kanaCandidates = latinToKanaCandidates(for: normalized)
            for cand in kanaCandidates where !cand.isEmpty {
                results = try queryExactMatches(for: cand, limit: limit)
                if !results.isEmpty { return results }
            }
        }

        // 2b) Surface substring match via indexed tokens if no hits yet
        results = try selectEntriesBySurfaceToken(matching: normalized, limit: limit)
        if !results.isEmpty { return results }

        // 3) English gloss search via FTS
        results = try selectEntriesByGloss(matching: normalized, limit: limit)
        return results
    }

    /// Public async API used by the rest of the app.
    /// This matches the existing `try await DictionarySQLiteStore.shared.lookup(...)` call sites.
    func lookup(term: String, limit: Int = 30) async throws -> [DictionaryEntry] {
        // Actor isolation ensures safe access to `db`, but the SQL work can still be heavy.
        // We keep the work inside the actor; since callers are often on @MainActor,
        // the `await` prevents blocking UI.
        try lookupSync(term: term, limit: limit)
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
        SELECT text FROM readings;
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
               COALESCE((SELECT k.text
                         FROM kanji k
                         WHERE k.entry_id = e.id
                         ORDER BY k.is_common DESC, k.id ASC
                         LIMIT 1), '') AS kanji_text,
               COALESCE((SELECT r.text
                         FROM readings r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS reading_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM readings r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        WHERE EXISTS (SELECT 1 FROM kanji k2 WHERE k2.entry_id = e.id AND k2.text = ?1)
           OR EXISTS (SELECT 1 FROM readings r2 WHERE r2.entry_id = e.id AND r2.text = ?1)
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, term, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var rows: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let reading = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            rows.append(DictionaryEntry(id: id, kanji: kanji, reading: reading, gloss: gloss, isCommon: isCommon))
        }

        if containsKanjiCharacters(term) {
            rows = rows.filter { $0.kanji == term }
        }

        return rows
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
                         FROM readings r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS reading_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM readings r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var rows: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let reading = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            rows.append(DictionaryEntry(id: id, kanji: kanji, reading: reading, gloss: gloss, isCommon: isCommon))
        }
        return rows
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
                         FROM readings r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS reading_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM readings r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
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
                         FROM readings r
                         WHERE r.entry_id = e.id
                         ORDER BY r.is_common DESC, r.id ASC
                         LIMIT 1), '') AS reading_text,
               COALESCE((SELECT GROUP_CONCAT(g.text, '; ')
                         FROM senses s
                         JOIN glosses g ON g.sense_id = s.id
                         WHERE s.entry_id = e.id), '') AS gloss_text,
               CASE
                 WHEN EXISTS (SELECT 1 FROM kanji k3 WHERE k3.entry_id = e.id AND k3.is_common = 1)
                   OR EXISTS (SELECT 1 FROM readings r3 WHERE r3.entry_id = e.id AND r3.is_common = 1)
               THEN 1 ELSE 0 END AS is_common_flag
        FROM entries e
        JOIN matched m ON m.entry_id = e.id
        LIMIT ?2;
        """
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

        var rows: [DictionaryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let reading = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))
            let isCommon = sqlite3_column_int(stmt, 4) != 0
            rows.append(DictionaryEntry(id: id, kanji: kanji, reading: reading, gloss: gloss, isCommon: isCommon))
        }
        return rows
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

