import Foundation
import SQLite3

enum SQLPlaygroundError: LocalizedError {
    case databaseNotFound
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case readOnlyOnly

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "dictionary.sqlite3 not found in app bundle."
        case .openFailed(let message):
            return "Failed to open dictionary.sqlite3: \(message)"
        case .prepareFailed(let message):
            return "Failed to prepare statement: \(message)"
        case .stepFailed(let message):
            return "Failed while stepping statement: \(message)"
        case .readOnlyOnly:
            return "SQL Playground is read-only. Only SELECT / PRAGMA / WITH queries are allowed."
        }
    }
}

actor SQLPlaygroundExecutor {
    static let shared = SQLPlaygroundExecutor()

    private var db: OpaquePointer?

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func execute(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "(empty input)" }

        // Support multiple statements separated by semicolons. This is
        // intentionally simple and does not attempt to handle semicolons
        // inside string literals; it's meant for quick diagnostics.
        let rawStatements = trimmed.split(separator: ";")
        var outputs: [String] = []

        for (index, raw) in rawStatements.enumerated() {
            let statement = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard statement.isEmpty == false else { continue }

            if statement.hasPrefix(".") {
                let result = try handleMetaCommand(statement)
                outputs.append(result)
                continue
            }

            let lower = statement.lowercased()
            if !(lower.hasPrefix("select") || lower.hasPrefix("pragma") || lower.hasPrefix("with")) {
                throw SQLPlaygroundError.readOnlyOnly
            }

            let label = rawStatements.count > 1 ? "-- statement \(index + 1) --\n" : ""
            let result = try runSQL(statement)
            outputs.append(label + result)
        }

        return outputs.isEmpty ? "(empty input)" : outputs.joined(separator: "\n\n")
    }

    // MARK: - Schema helpers (read-only)

    func userTableNames() throws -> [String] {
        try listUserTables()
    }

    func columnNames(forTableNamed tableName: String) throws -> [String] {
        try listColumnNames(forTableNamed: tableName)
    }

    private func handleMetaCommand(_ command: String) throws -> String {
        let token = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let head = parts.first ?? token

        switch head {
        case ".tables":
            return try listTables()
        case ".pragma":
            // Convenience meta-command wrapper.
            // Examples:
            //   .pragma fks
            //   .pragma foreign_keys
            //   .pragma foreign_key_list entries
            if parts.count <= 1 {
                return "Usage:\n  .pragma fks\n  .pragma foreign_keys\n  .pragma foreign_key_list <table>\n\n(You can also run raw PRAGMA statements directly, e.g. PRAGMA foreign_key_list('entries');)"
            }
            let sub = parts[1].lowercased()
            if sub == "fks" || sub == "foreign_keys" {
                return try listAllForeignKeys()
            }
            if sub == "foreign_key_list" {
                guard parts.count >= 3 else {
                    return "Usage: .pragma foreign_key_list <table>\nExample: .pragma foreign_key_list entries"
                }
                let table = parts[2]
                return try describeForeignKeys(forTableNamed: table)
            }
            return "Unrecognized .pragma command: \(parts.dropFirst().joined(separator: " "))\nTry: .pragma fks"
        case ".diagram", ".relationships", ".rels":
            return try relationshipDiagram()
        default:
            if token.hasPrefix("."), token.count > 1 {
                let tableName = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard tableName.isEmpty == false else {
                    return "Meta-command requires a table name after '.'. Example: .entries"
                }
                return try describeColumns(forTableNamed: tableName)
            }
            return "Unrecognized meta-command: \(token)\nSupported commands:\n  .tables\n  .[table_name]  (columns for a table, e.g. .entries)\n  .pragma fks\n  .pragma foreign_key_list <table>\n  .diagram"
        }
    }

    private func listTables() throws -> String {
        return try runSQL("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;")
    }

    private func describeColumns(forTableNamed tableName: String) throws -> String {
        let escapedName = tableName.replacingOccurrences(of: "'", with: "''")
        let sql = "PRAGMA table_info('\(escapedName)');"
        let result = try runSQL(sql)
        if result.hasPrefix("(no rows)") {
            return "No columns found for table '\(tableName)'. Does it exist?\n\n" + result
        }
        return "Columns for '\(tableName)':\n\n" + result
    }

    private func listColumnNames(forTableNamed tableName: String) throws -> [String] {
        try openIfNeeded()
        guard let db else { throw SQLPlaygroundError.openFailed("Database handle is nil") }

        let escapedName = tableName.replacingOccurrences(of: "'", with: "''")
        let sql = "PRAGMA table_info('\(escapedName)');"

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw SQLPlaygroundError.prepareFailed(message)
        }
        guard let statement else {
            throw SQLPlaygroundError.prepareFailed("sqlite3_prepare_v2 returned nil statement")
        }
        defer { sqlite3_finalize(statement) }

        // PRAGMA table_info columns:
        // cid, name, type, notnull, dflt_value, pk
        var out: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                if let ptr = sqlite3_column_text(statement, 1) {
                    out.append(String(cString: ptr))
                }
            case SQLITE_DONE:
                return out
            default:
                let message = String(cString: sqlite3_errmsg(db))
                throw SQLPlaygroundError.stepFailed(message)
            }
        }
    }

    // MARK: - Foreign keys

    private struct ForeignKeyEdge: Hashable {
        let fromTable: String
        let fromColumn: String
        let toTable: String
        let toColumn: String
        let onUpdate: String
        let onDelete: String
    }

    private func listAllForeignKeys() throws -> String {
        try openIfNeeded()
        let tables = try listUserTables()
        guard tables.isEmpty == false else { return "(no tables)" }

        var edges: [ForeignKeyEdge] = []
        edges.reserveCapacity(64)

        for table in tables {
            edges.append(contentsOf: try foreignKeys(forTableNamed: table))
        }

        guard edges.isEmpty == false else {
            return "(no foreign keys found)"
        }

        // Stable ordering: group by fromTable then toTable then columns.
        edges.sort {
            if $0.fromTable != $1.fromTable { return $0.fromTable < $1.fromTable }
            if $0.toTable != $1.toTable { return $0.toTable < $1.toTable }
            if $0.fromColumn != $1.fromColumn { return $0.fromColumn < $1.fromColumn }
            return $0.toColumn < $1.toColumn
        }

        var lines: [String] = []
        lines.reserveCapacity(edges.count + 4)
        lines.append("Foreign key constraints (\(edges.count)):\n")
        for e in edges {
            var rule = ""
            if e.onUpdate.isEmpty == false || e.onDelete.isEmpty == false {
                rule = "  [onUpdate=\(e.onUpdate.isEmpty ? "(default)" : e.onUpdate), onDelete=\(e.onDelete.isEmpty ? "(default)" : e.onDelete)]"
            }
            lines.append("\(e.fromTable).\(e.fromColumn) -> \(e.toTable).\(e.toColumn)\(rule)")
        }
        return lines.joined(separator: "\n")
    }

    private func relationshipDiagram() throws -> String {
        try openIfNeeded()
        let tables = try listUserTables()
        guard tables.isEmpty == false else { return "(no tables)" }

        var byFromTable: [String: [ForeignKeyEdge]] = [:]
        for table in tables {
            let fks = try foreignKeys(forTableNamed: table)
            if fks.isEmpty == false {
                byFromTable[table, default: []].append(contentsOf: fks)
            }
        }

        guard byFromTable.isEmpty == false else {
            return "(no foreign keys found)"
        }

        var lines: [String] = []
        let orderedTables = byFromTable.keys.sorted()
        for table in orderedTables {
            lines.append("\(table)")
            let edges = (byFromTable[table] ?? []).sorted {
                if $0.toTable != $1.toTable { return $0.toTable < $1.toTable }
                if $0.fromColumn != $1.fromColumn { return $0.fromColumn < $1.fromColumn }
                return $0.toColumn < $1.toColumn
            }
            for e in edges {
                lines.append("  ├─ \(e.fromColumn) -> \(e.toTable).\(e.toColumn)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describeForeignKeys(forTableNamed tableName: String) throws -> String {
        let table = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard table.isEmpty == false else { return "(empty table name)" }
        let fks = try foreignKeys(forTableNamed: table)
        guard fks.isEmpty == false else {
            return "(no foreign keys for '\(table)')"
        }
        var lines: [String] = []
        lines.append("Foreign keys for '\(table)':")
        for e in fks {
            var rule = ""
            if e.onUpdate.isEmpty == false || e.onDelete.isEmpty == false {
                rule = "  [onUpdate=\(e.onUpdate.isEmpty ? "(default)" : e.onUpdate), onDelete=\(e.onDelete.isEmpty ? "(default)" : e.onDelete)]"
            }
            lines.append("\(e.fromColumn) -> \(e.toTable).\(e.toColumn)\(rule)")
        }
        return lines.joined(separator: "\n")
    }

    private func listUserTables() throws -> [String] {
        // Pull table names using sqlite_master.
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        return try runSQLRowsSingleColumn(sql)
    }

    private func foreignKeys(forTableNamed tableName: String) throws -> [ForeignKeyEdge] {
        try openIfNeeded()
        guard let db else { throw SQLPlaygroundError.openFailed("Database handle is nil") }

        let escapedName = tableName.replacingOccurrences(of: "'", with: "''")
        let sql = "PRAGMA foreign_key_list('\(escapedName)');"

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw SQLPlaygroundError.prepareFailed(message)
        }
        guard let statement else {
            throw SQLPlaygroundError.prepareFailed("sqlite3_prepare_v2 returned nil statement")
        }
        defer { sqlite3_finalize(statement) }

        func text(_ column: Int32) -> String {
            guard let ptr = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: ptr)
        }

        // PRAGMA foreign_key_list columns:
        // id, seq, table, from, to, on_update, on_delete, match
        var out: [ForeignKeyEdge] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                let toTable = text(2)
                let fromColumn = text(3)
                let toColumn = text(4)
                let onUpdate = text(5)
                let onDelete = text(6)
                out.append(
                    ForeignKeyEdge(
                        fromTable: tableName,
                        fromColumn: fromColumn,
                        toTable: toTable,
                        toColumn: toColumn,
                        onUpdate: onUpdate,
                        onDelete: onDelete
                    )
                )
            case SQLITE_DONE:
                return out
            default:
                let message = String(cString: sqlite3_errmsg(db))
                throw SQLPlaygroundError.stepFailed(message)
            }
        }
    }

    private func runSQLRowsSingleColumn(_ sql: String) throws -> [String] {
        try openIfNeeded()
        guard let db else { throw SQLPlaygroundError.openFailed("Database handle is nil") }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw SQLPlaygroundError.prepareFailed(message)
        }
        guard let statement else {
            throw SQLPlaygroundError.prepareFailed("sqlite3_prepare_v2 returned nil statement")
        }
        defer { sqlite3_finalize(statement) }

        var out: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                if let ptr = sqlite3_column_text(statement, 0) {
                    out.append(String(cString: ptr))
                } else {
                    out.append("")
                }
            case SQLITE_DONE:
                return out
            default:
                let message = String(cString: sqlite3_errmsg(db))
                throw SQLPlaygroundError.stepFailed(message)
            }
        }
    }

    private func openIfNeeded() throws {
        if db != nil { return }

        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            throw SQLPlaygroundError.databaseNotFound
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown error (code \(rc))"
            if let handle { sqlite3_close(handle) }
            throw SQLPlaygroundError.openFailed(message)
        }

        db = handle
    }

    private func runSQL(_ sql: String) throws -> String {
        try openIfNeeded()
        guard let db else { throw SQLPlaygroundError.openFailed("Database handle is nil") }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw SQLPlaygroundError.prepareFailed(message)
        }
        guard let statement else {
            throw SQLPlaygroundError.prepareFailed("sqlite3_prepare_v2 returned nil statement")
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))

        if columnCount == 0 {
            var rowCount = 0
            rowLoop: while true {
                let stepResult = sqlite3_step(statement)
                switch stepResult {
                case SQLITE_ROW:
                    rowCount += 1
                case SQLITE_DONE:
                    break rowLoop
                default:
                    let message = String(cString: sqlite3_errmsg(db))
                    throw SQLPlaygroundError.stepFailed(message)
                }
            }
            return rowCount == 0 ? "(no rows)\nSQL: \(sql)" : "(\(rowCount) row(s) affected)\nSQL: \(sql)"
        }

        var headerColumns: [String] = []
        for index in 0..<columnCount {
            if let namePointer = sqlite3_column_name(statement, Int32(index)) {
                headerColumns.append(String(cString: namePointer))
            } else {
                headerColumns.append("col\(index + 1)")
            }
        }

        var rows: [[String]] = []

        rowLoop: while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                var values: [String] = []
                for index in 0..<columnCount {
                    let columnType = sqlite3_column_type(statement, Int32(index))
                    switch columnType {
                    case SQLITE_NULL:
                        values.append("NULL")
                    case SQLITE_INTEGER:
                        let intValue = sqlite3_column_int64(statement, Int32(index))
                        values.append(String(intValue))
                    case SQLITE_FLOAT:
                        let doubleValue = sqlite3_column_double(statement, Int32(index))
                        values.append(String(doubleValue))
                    case SQLITE_TEXT:
                        if let textPointer = sqlite3_column_text(statement, Int32(index)) {
                            values.append(String(cString: textPointer))
                        } else {
                            values.append("")
                        }
                    default:
                        values.append("(blob)")
                    }
                }
                rows.append(values)
            case SQLITE_DONE:
                break rowLoop
            default:
                let message = String(cString: sqlite3_errmsg(db))
                throw SQLPlaygroundError.stepFailed(message)
            }
        }

        if rows.isEmpty {
            return "(no rows)\nSQL: \(sql)"
        }

        var columnWidths = Array(repeating: 0, count: columnCount)
        for (index, name) in headerColumns.enumerated() {
            columnWidths[index] = max(columnWidths[index], name.count)
        }
        for row in rows {
            for (index, value) in row.enumerated() {
                columnWidths[index] = max(columnWidths[index], value.count)
            }
        }

        func padded(_ string: String, to width: Int) -> String {
            if string.count >= width { return string }
            return string + String(repeating: " ", count: width - string.count)
        }

        var lines: [String] = []
        let headerLine = zip(headerColumns, columnWidths).map { padded($0, to: $1) }.joined(separator: " | ")
        lines.append(headerLine)

        let separatorLine = columnWidths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")
        lines.append(separatorLine)

        for row in rows {
            let line = zip(row, columnWidths).map { padded($0, to: $1) }.joined(separator: " | ")
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
