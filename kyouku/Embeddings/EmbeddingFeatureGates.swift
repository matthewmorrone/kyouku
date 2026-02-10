import Foundation
import SQLite3

enum EmbeddingFeature: String, CaseIterable {
    case semanticSearch
    case similarWords
    case flashcardAdaptation
    case tokenBoundaryResolution
}

/// Lightweight runtime guards around embedding availability.
final class EmbeddingFeatureGates: @unchecked Sendable {
    static let shared = EmbeddingFeatureGates()

    struct GateState {
        var enabled: Bool
        var reason: String?
    }

    private struct State {
        var metadataChecked: Bool = false
        var metadataOK: Bool = false
        var metadataFailureReason: String?

        var featureStates: [EmbeddingFeature: GateState] = {
            var dict: [EmbeddingFeature: GateState] = [:]
            for f in EmbeddingFeature.allCases {
                dict[f] = GateState(enabled: true, reason: nil)
            }
            return dict
        }()
    }

    private let lock = NSLock()
    private var state = State()

    func isEnabled(_ feature: EmbeddingFeature) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (state.featureStates[feature]?.enabled ?? false) && state.metadataOK
    }

    func metadataStatus() -> GateState {
        lock.lock()
        defer { lock.unlock() }
        return GateState(enabled: state.metadataOK, reason: state.metadataFailureReason)
    }

    /// Performs a one-time, lightweight metadata check against the bundled DB.
    ///
    /// If this fails, all embedding-backed features should be considered disabled.
    func ensureMetadataChecked() {
        lock.lock()
        if state.metadataChecked {
            lock.unlock()
            return
        }
        state.metadataChecked = true
        lock.unlock()

        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "dictionary.sqlite3 not found in bundle"
            lock.unlock()
            return
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "Failed to open DB: \(msg)"
            lock.unlock()
            return
        }

        guard let db = handle else {
            sqlite3_close(handle)
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "Failed to open DB: null handle"
            lock.unlock()
            return
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*), MIN(length(vec)), MAX(length(vec)) FROM embeddings;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "Prepare failed: \(msg)"
            lock.unlock()
            return
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) != SQLITE_ROW {
            let msg = String(cString: sqlite3_errmsg(db))
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "Step failed: \(msg)"
            lock.unlock()
            return
        }

        let rowCount = Int(sqlite3_column_int64(stmt, 0))
        let minLen = Int(sqlite3_column_int64(stmt, 1))
        let maxLen = Int(sqlite3_column_int64(stmt, 2))

        if rowCount != 30000 {
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "Unexpected embeddings row count: \(rowCount)"
            lock.unlock()
            return
        }

        if minLen != 1200 || maxLen != 1200 {
            lock.lock()
            state.metadataOK = false
            state.metadataFailureReason = "Unexpected vec length range: min=\(minLen) max=\(maxLen)"
            lock.unlock()
            return
        }

        lock.lock()
        state.metadataOK = true
        state.metadataFailureReason = nil
        lock.unlock()
    }
}
