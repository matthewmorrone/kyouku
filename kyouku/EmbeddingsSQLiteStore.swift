import Foundation
import SQLite3
import os

/// Concurrent-read store for `embeddings(word TEXT PRIMARY KEY, vec BLOB)`.
///
/// - `vec` is expected to be exactly 300 little-endian float32 values.
/// - Uses a small pool of read-only SQLite connections + prepared statements.
final class EmbeddingsSQLiteStore: @unchecked Sendable {
    static let shared = EmbeddingsSQLiteStore()

    enum EmbeddingsError: Error, CustomStringConvertible {
        case resourceNotFound
        case openFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case stepFailed(String)
        case badBlobSize(expected: Int, actual: Int)

        var description: String {
            switch self {
            case .resourceNotFound:
                return "EmbeddingsError.resourceNotFound"
            case .openFailed(let msg):
                return "EmbeddingsError.openFailed(\(msg))"
            case .prepareFailed(let msg):
                return "EmbeddingsError.prepareFailed(\(msg))"
            case .bindFailed(let msg):
                return "EmbeddingsError.bindFailed(\(msg))"
            case .stepFailed(let msg):
                return "EmbeddingsError.stepFailed(\(msg))"
            case .badBlobSize(let expected, let actual):
                return "EmbeddingsError.badBlobSize(expected: \(expected), actual: \(actual))"
            }
        }
    }

    /// Creates a store reading from the bundled `dictionary.sqlite3`.
    ///
    /// - Parameters:
    ///   - poolSize: Maximum concurrent readers.
    init(poolSize: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)) {
        self.poolSize = max(1, poolSize)
        self.semaphore = DispatchSemaphore(value: self.poolSize)
        self.poolLock = NSLock()
        self.poolState = PoolState()
    }

    /// Returns `nil` if the word is not present.
    func vector(for word: String) throws -> [Float]? {
        semaphore.wait()
        let connection = try checkoutConnection()
        defer {
            checkinConnection(connection)
            semaphore.signal()
        }

        return try connection.vector(for: word)
    }

    // MARK: - Pool

    private struct PoolState {
        var initialized = false
        var connections: [Connection] = []
    }

    private let semaphore: DispatchSemaphore
    private let poolLock: NSLock
    private var poolState: PoolState
    private let poolSize: Int

    private func checkoutConnection() throws -> Connection {
        poolLock.lock()
        defer { poolLock.unlock() }

        if poolState.initialized == false {
            poolState.connections = try Self.makeConnections(count: poolSize)
            poolState.initialized = true
        }
        return poolState.connections.removeLast()
    }

    private func checkinConnection(_ connection: Connection) {
        poolLock.lock()
        poolState.connections.append(connection)
        poolLock.unlock()
    }

    private static func makeConnections(count: Int) throws -> [Connection] {
        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            throw EmbeddingsError.resourceNotFound
        }
        var out: [Connection] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(try Connection(url: url))
        }
        return out
    }

    // MARK: - SQLite connection

    private final class Connection {
        private static let dim = 300
        private static let expectedBytes = dim * MemoryLayout<Float>.size

        private let db: OpaquePointer
        private let stmt: OpaquePointer

        init(url: URL) throws {
            var handle: OpaquePointer?

            // Each connection is only used by one reader at a time (pool checkout),
            // so NOMUTEX avoids internal SQLite mutex overhead.
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            let rcOpen = sqlite3_open_v2(url.path, &handle, flags, nil)
            guard rcOpen == SQLITE_OK, let db = handle else {
                let msg = String(cString: sqlite3_errmsg(handle))
                sqlite3_close(handle)
                throw EmbeddingsSQLiteStore.EmbeddingsError.openFailed(msg)
            }
            self.db = db

            var stmt: OpaquePointer?
            let sql = "SELECT vec FROM embeddings WHERE word = ?1 LIMIT 1;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_close(db)
                throw EmbeddingsSQLiteStore.EmbeddingsError.prepareFailed(msg)
            }
            self.stmt = stmt!
        }

        deinit {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        }

        func vector(for word: String) throws -> [Float]? {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            let rcBind = sqlite3_bind_text(stmt, 1, word, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard rcBind == SQLITE_OK else {
                throw EmbeddingsSQLiteStore.EmbeddingsError.bindFailed(String(cString: sqlite3_errmsg(db)))
            }

            let rcStep = sqlite3_step(stmt)
            switch rcStep {
            case SQLITE_ROW:
                guard let blob = sqlite3_column_blob(stmt, 0) else {
                    return nil
                }
                let bytes = Int(sqlite3_column_bytes(stmt, 0))
                guard bytes == Self.expectedBytes else {
                    throw EmbeddingsSQLiteStore.EmbeddingsError.badBlobSize(expected: Self.expectedBytes, actual: bytes)
                }

                // Zero-copy view of SQLite's memory; Array<Float> returned is the only allocation.
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blob), count: bytes, deallocator: .none)
                return data.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float.self)
                    assert(floats.count == Self.dim)
                    guard floats.count == Self.dim else {
                        // Defensive: should be guaranteed by bytes == expectedBytes.
                        return nil
                    }
                    return Array(floats)
                }

            case SQLITE_DONE:
                return nil

            default:
                throw EmbeddingsSQLiteStore.EmbeddingsError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
