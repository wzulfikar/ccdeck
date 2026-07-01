import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite persistence: the account roster and app settings.
/// Kept on the main actor so the non-Sendable `sqlite3` handle never crosses actors.
@MainActor
final class Store {
    nonisolated(unsafe) private var db: OpaquePointer?

    static let dbURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ccdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ccdeck.sqlite")
    }()

    init() {
        sqlite3_open(Self.dbURL.path, &db)
        migrate()
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS accounts (
            email TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            plan  TEXT NOT NULL,
            ord   INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Accounts

    func upsertAccount(_ a: Account) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO accounts(email,label,plan,ord) VALUES(?,?,?,?)
        ON CONFLICT(email) DO UPDATE SET label=excluded.label, plan=excluded.plan;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, a.email, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, a.label, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, a.plan, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(a.order))
        sqlite3_step(stmt)
    }

    func listAccounts() -> [Account] {
        var stmt: OpaquePointer?
        let sql = "SELECT email,label,plan,ord FROM accounts ORDER BY ord ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Account] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Account(
                email: text(stmt, 0),
                label: text(stmt, 1),
                plan: text(stmt, 2),
                order: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return out
    }

    func deleteAccount(email: String) {
        run("DELETE FROM accounts WHERE email=?;", text: email)
    }

    func nextOrder() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ord),-1)+1 FROM accounts;", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Settings

    func setSetting(_ key: String, _ value: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func getSetting(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : nil
    }

    // MARK: - Helpers

    private func run(_ sql: String, text value: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
