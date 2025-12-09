//
//  DictionaryStore.swift
//  kyouku
//
//  Deprecated: JSON-based dictionary loader removed in favor of SQLite-backed DictionarySQLiteStore.
//  This placeholder remains to avoid build errors from missing files.
//
//  If you need a JSON loader in the future, create a new implementation that
//  does not conflict with the SQLite-backed models.
//

import Foundation
import Combine

@available(*, deprecated, message: "Use DictionarySQLiteStore instead.")
final class DictionaryStore: ObservableObject {
    // No-op: kept for source compatibility. Use DictionarySQLiteStore for lookups.
    @Published var entries: [String: [Any]] = [:]

    init() {}

    func lookup(_ key: String) -> [Any] { [] }
}
