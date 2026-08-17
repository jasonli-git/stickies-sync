import Foundation
import SQLite3

/// A thin wrapper over the SQLite that ships with macOS.
///
/// Hand-rolled rather than taken from a library: the schema is four tables and
/// perhaps twenty statements, and the alternative is a dependency the whole
/// project would lean on for the rest of its life. `swift-argument-parser`
/// remains the only third-party package (ARCHITECTURE #10).
///
/// Not thread-safe, and not `Sendable`. One replica, one queue — the watcher in
/// `StickiesStore` serializes onto a single queue before calling in.
public final class Database {
    /// SQLite needs to be told whether a bound string outlives the call. It does
    /// not, so everything is bound as transient and copied.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public enum DatabaseError: Error, CustomStringConvertible {
        case openFailed(path: String, message: String)
        case statementFailed(sql: String, message: String)

        public var description: String {
            switch self {
            case .openFailed(let path, let message): "could not open \(path): \(message)"
            case .statementFailed(let sql, let message): "\(message) — while running: \(sql)"
            }
        }
    }

    /// A value a column can hold. The schema uses no floating-point columns, so
    /// there is no `.double` case to get wrong.
    public enum Value: Hashable, Sendable {
        case text(String)
        case integer(Int)
        case blob(Data)
        case null
    }

    private var handle: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw DatabaseError.openFailed(path: path, message: message)
        }
        self.handle = handle

        // Foreign keys are off by default in SQLite and the schema relies on
        // them to keep history and vectors from outliving their note.
        try execute("PRAGMA foreign_keys = ON")
        // WAL survives a crash mid-write without losing the whole file, which
        // matters for a database written from a background agent.
        try execute("PRAGMA journal_mode = WAL")
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements with no parameters and no results.
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError.statementFailed(sql: sql, message: message)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [Value] = []) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw DatabaseError.statementFailed(sql: sql, message: lastMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    /// Materializes every row up front. The largest query here returns one note's
    /// versions, so streaming would buy nothing and cost a cursor lifetime to
    /// manage.
    public func query(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(Row(statement: statement))
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError.statementFailed(sql: sql, message: lastMessage())
            }
        }
    }

    /// Runs `body` in a transaction, rolling back if it throws. Nested calls are
    /// not supported and the schema never needs them.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(sql: sql, message: lastMessage())
        }

        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 =
                switch parameter {
                case .text(let value):
                    sqlite3_bind_text(statement, index, value, -1, Self.transient)
                case .integer(let value):
                    sqlite3_bind_int64(statement, index, Int64(value))
                case .blob(let value):
                    value.isEmpty
                        ? sqlite3_bind_zeroblob(statement, index, 0)
                        : value.withUnsafeBytes {
                            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient)
                        }
                case .null:
                    sqlite3_bind_null(statement, index)
                }

            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw DatabaseError.statementFailed(sql: sql, message: lastMessage())
            }
        }
        return statement
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

extension Database {
    /// One result row, read by column name so a schema change that reorders
    /// columns cannot silently shift the values.
    public struct Row {
        private var columns: [String: Value]

        init(statement: OpaquePointer?) {
            var columns: [String: Value] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                columns[name] =
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_TEXT:
                        .text(String(cString: sqlite3_column_text(statement, index)))
                    case SQLITE_INTEGER:
                        .integer(Int(sqlite3_column_int64(statement, index)))
                    case SQLITE_BLOB:
                        .blob(
                            sqlite3_column_bytes(statement, index) > 0
                                ? Data(
                                    bytes: sqlite3_column_blob(statement, index),
                                    count: Int(sqlite3_column_bytes(statement, index))
                                )
                                : Data()
                        )
                    default:
                        .null
                    }
            }
            self.columns = columns
        }

        public func text(_ name: String) -> String? {
            if case .text(let value) = columns[name] { value } else { nil }
        }

        public func integer(_ name: String) -> Int? {
            if case .integer(let value) = columns[name] { value } else { nil }
        }

        public func blob(_ name: String) -> Data? {
            if case .blob(let value) = columns[name] { value } else { nil }
        }

        public func bool(_ name: String) -> Bool {
            integer(name) == 1
        }
    }
}
