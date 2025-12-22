//
//  DictionarySQLiteError.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/21/25.
//


import Foundation
import SQLite3

enum DictionarySQLiteError: Error, CustomStringConvertible {
    case resourceNotFound
    case openFailed(String)
    case prepareFailed(String)

    var description: String {
        switch self {
        case .resourceNotFound:
            return "dictionary.sqlite3 not found in app bundle."
        case .openFailed(let msg):
            return "Failed to open SQLite DB: \(msg)"
        case .prepareFailed(let msg):
            return "Failed to prepare SQLite statement: \(msg)"
        }
    }
}