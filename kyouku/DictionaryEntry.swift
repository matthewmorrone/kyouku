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

enum DictionarySQLiteError: Error, CustomStringConvertible {
    case resourceNotFound
    case openFailed(String)
    case prepareFailed(String)

    var description: String {
        switch self {
        case .resourceNotFound:
            return "jmdict.sqlite3 not found in app bundle."
        case .openFailed(let msg):
            return "Failed to open SQLite DB: \(msg)"
        case .prepareFailed(let msg):
            return "Failed to prepare SQLite statement: \(msg)"
        }
    }
}

actor DictionarySQLiteStore {
    static let shared = DictionarySQLiteStore()

    private var db: OpaquePointer?

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
        if trimmed.isEmpty {
            return []
        }

        // 1) Exact match on kanji/readings
        var results = try selectEntries(matching: trimmed, limit: limit)
        if !results.isEmpty { return results }

        // 2) If input looks like Latin (romaji), try converting to kana and match readings
        let latinSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz '-").inverted
        if trimmed.rangeOfCharacter(from: latinSet) == nil {
            let kanaCandidates = latinToKanaCandidates(for: trimmed)
            for cand in kanaCandidates where !cand.isEmpty {
                results = try selectEntries(matching: cand, limit: limit)
                if !results.isEmpty { return results }
            }
        }

        // 2b) Fuzzy kana/kanji match (substring) if no hits yet
        if results.isEmpty {
            results = try selectEntriesFuzzy(matching: trimmed, limit: limit)
            if !results.isEmpty { return results }
        }

        // 3) English gloss search (case-insensitive substring)
        results = try selectEntriesByGloss(containing: trimmed, limit: limit)
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

    private func ensureOpen() throws {
        if db != nil {
            return
        }

        guard let url = Bundle.main.url(forResource: "jmdict", withExtension: "sqlite3") else {
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
        return rows
    }

    private func selectEntriesByGloss(containing term: String, limit: Int) throws -> [DictionaryEntry] {
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
        WHERE EXISTS (
            SELECT 1
            FROM senses s2
            JOIN glosses g2 ON g2.sense_id = s2.id
            WHERE s2.entry_id = e.id
              AND g2.text LIKE ?1 COLLATE NOCASE
        )
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%" + term + "%"
        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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

    private func selectEntriesFuzzy(matching term: String, limit: Int) throws -> [DictionaryEntry] {
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
        WHERE EXISTS (SELECT 1 FROM kanji k2 WHERE k2.entry_id = e.id AND k2.text LIKE ?1)
           OR EXISTS (SELECT 1 FROM readings r2 WHERE r2.entry_id = e.id AND r2.text LIKE ?1)
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%" + term + "%"
        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }
}

