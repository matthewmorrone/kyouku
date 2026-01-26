import Foundation
import SQLite3

/// Batch reader for embeddings vectors using `WHERE word IN (...)`.
///
/// Keys are bound and queried verbatim (no trimming/normalization).
final class EmbeddingsSQLiteBatchReader: @unchecked Sendable {
    struct Configuration {
        var poolSize: Int
        var maxBatchSize: Int

        init(poolSize: Int = max(1, ProcessInfo.processInfo.activeProcessorCount), maxBatchSize: Int = 200) {
            self.poolSize = max(1, poolSize)
            self.maxBatchSize = max(1, maxBatchSize)
        }
    }

    enum BatchError: Error {
        case resourceNotFound
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case badBlobSize(expected: Int, actual: Int)
    }

    private final class Connection {
        private static let dim = 300
        private static let expectedBytes = dim * MemoryLayout<Float>.size

        private let db: OpaquePointer
        private var stmtCache: [Int: OpaquePointer] = [:]

        init(url: URL) throws {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(handle))
                sqlite3_close(handle)
                throw BatchError.openFailed(msg)
            }
            self.db = handle!
        }

        deinit {
            for (_, stmt) in stmtCache {
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }

        func fetch(keys: [String]) throws -> [String: [Float]] {
            guard keys.isEmpty == false else { return [:] }
            let stmt = try statement(forKeyCount: keys.count)

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            for (i, key) in keys.enumerated() {
                let rc = sqlite3_bind_text(stmt, Int32(i + 1), key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if rc != SQLITE_OK {
                    throw BatchError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
            }

            var out: [String: [Float]] = [:]
            out.reserveCapacity(keys.count)

            while true {
                let rcStep = sqlite3_step(stmt)
                if rcStep == SQLITE_ROW {
                    guard let wordPtr = sqlite3_column_text(stmt, 0) else { continue }
                    let word = String(cString: wordPtr)

                    guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
                    let bytes = Int(sqlite3_column_bytes(stmt, 1))
                    guard bytes == Self.expectedBytes else {
                        throw BatchError.badBlobSize(expected: Self.expectedBytes, actual: bytes)
                    }

                    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blob), count: bytes, deallocator: .none)
                    if let vec: [Float] = data.withUnsafeBytes({ raw in
                        let floats = raw.bindMemory(to: Float.self)
                        assert(floats.count == Self.dim)
                        guard floats.count == Self.dim else { return nil }
                        return Array(floats)
                    }) {
                        out[word] = vec
                    }
                    continue
                }

                if rcStep == SQLITE_DONE {
                    break
                }

                throw BatchError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            return out
        }

        private func statement(forKeyCount n: Int) throws -> OpaquePointer {
            if let existing = stmtCache[n] {
                return existing
            }

            let placeholders = Array(repeating: "?", count: n).enumerated().map { idx, _ in "?\(idx + 1)" }.joined(separator: ",")
            let sql = "SELECT word, vec FROM embeddings WHERE word IN (\(placeholders));"

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw BatchError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }

            let s = stmt!
            stmtCache[n] = s
            return s
        }
    }

    private struct PoolState {
        var initialized = false
        var connections: [Connection] = []
    }

    private let config: Configuration
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var poolState = PoolState()

    init(config: Configuration = Configuration()) {
        self.config = config
        self.semaphore = DispatchSemaphore(value: config.poolSize)
    }

    func fetchVectors(for keys: [String]) throws -> [String: [Float]] {
        guard keys.isEmpty == false else { return [:] }

        var merged: [String: [Float]] = [:]
        merged.reserveCapacity(keys.count)

        for chunk in keys.chunked(into: config.maxBatchSize) {
            semaphore.wait()
            let conn = try checkoutConnection()
            defer {
                checkinConnection(conn)
                semaphore.signal()
            }

            let part = try conn.fetch(keys: chunk)
            for (k, v) in part {
                merged[k] = v
            }
        }

        return merged
    }

    private func checkoutConnection() throws -> Connection {
        lock.lock()
        defer { lock.unlock() }

        if poolState.initialized == false {
            guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
                throw BatchError.resourceNotFound
            }
            poolState.connections = try (0..<config.poolSize).map { _ in
                try Connection(url: url)
            }
            poolState.initialized = true
        }
        return poolState.connections.removeLast()
    }

    private func checkinConnection(_ conn: Connection) {
        lock.lock()
        poolState.connections.append(conn)
        lock.unlock()
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        out.reserveCapacity((count + size - 1) / size)
        var idx = 0
        while idx < count {
            let end = Swift.min(count, idx + size)
            out.append(Array(self[idx..<end]))
            idx = end
        }
        return out
    }
}
