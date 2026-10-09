import Foundation
import SQLite3

public struct SQLiteError: LocalizedError {
    public let message: String
    public var errorDescription: String? { "Database: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Not thread-safe by itself; `MailStore` serializes access.
final class SQLiteDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw SQLiteError(message: "cannot open \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(handle) }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw lastError() }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError() }
            rows.append(Row(statement: statement!))
        }
        return rows
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case nil: sqlite3_bind_null(statement, index)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as UInt32: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Bool: sqlite3_bind_int64(statement, index, value ? 1 : 0)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Date: sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
            default:
                sqlite3_finalize(statement)
                throw SQLiteError(message: "unsupported parameter \(String(describing: param))")
            }
        }
        return statement
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
    }
}

struct Row {
    private var values: [String: Any] = [:]

    init(statement: OpaquePointer) {
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: values[name] = sqlite3_column_int64(statement, column)
            case SQLITE_FLOAT: values[name] = sqlite3_column_double(statement, column)
            case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(statement, column))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                if let pointer = sqlite3_column_blob(statement, column) {
                    values[name] = Data(bytes: pointer, count: count)
                }
            default: break
            }
        }
    }

    func string(_ key: String) -> String? { values[key] as? String }
    func int(_ key: String) -> Int64? { values[key] as? Int64 }
    func bool(_ key: String) -> Bool { (values[key] as? Int64 ?? 0) != 0 }
    func double(_ key: String) -> Double? { values[key] as? Double ?? (values[key] as? Int64).map(Double.init) }
}
