//
//  DictionaryEntry.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//


import Foundation
import SQLite3

// SQLite3 module in Swift doesn't export SQLITE_TRANSIENT; define it here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DictionaryEntry: Identifiable, Hashable {
    let id: Int64
    let kanji: String
    let reading: String
    let gloss: String
}

// MARK: - Dictionary Entry Model

//struct DictionaryEntry: Identifiable, Codable {
//    let id: String                     // Usually the ent_seq
//    let kanji: [String]?
//    let reading: [String]
//    let meanings: [String]
//}


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

    func lookup(term: String, limit: Int = 30) throws -> [DictionaryEntry] {
        try ensureOpen()

        guard let db else {
            return []
        }

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        }

        let sql = """
        SELECT id, COALESCE(kanji, ''), COALESCE(reading, ''), COALESCE(gloss, '')
        FROM entries
        WHERE kanji = ?1 OR reading = ?1
        LIMIT ?2;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DictionarySQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var results: [DictionaryEntry] = []
        results.reserveCapacity(min(limit, 30))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)

            let kanji = String(cString: sqlite3_column_text(stmt, 1))
            let reading = String(cString: sqlite3_column_text(stmt, 2))
            let gloss = String(cString: sqlite3_column_text(stmt, 3))

            results.append(DictionaryEntry(
                id: id,
                kanji: kanji,
                reading: reading,
                gloss: gloss
            ))
        }

        return results
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }
}
