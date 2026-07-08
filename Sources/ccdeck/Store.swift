import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite persistence: the account roster and app settings.
/// Kept on the main actor so the non-Sendable `sqlite3` handle never crosses actors.
@MainActor
final class Store {
    nonisolated(unsafe) private var db: OpaquePointer?

    static let dbURL: URL = {
        // "ccdeck" in production, "ccdeck-dev" in the dev variant — a dev build
        // gets its own roster/settings database.
        let dirName = (Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false)
            ? "ccdeck-dev" : "ccdeck"
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dirName, isDirectory: true)
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
        CREATE TABLE IF NOT EXISTS hourly_usage (
            hour_epoch   INTEGER NOT NULL,   -- unix ts floored to the hour (UTC)
            model        TEXT    NOT NULL,   -- message.model, e.g. "claude-opus-4-8"
            input        INTEGER NOT NULL DEFAULT 0,
            output       INTEGER NOT NULL DEFAULT 0,
            cache_create INTEGER NOT NULL DEFAULT 0,
            cache_read   INTEGER NOT NULL DEFAULT 0,
            messages     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (hour_epoch, model)
        );
        """)
    }

    // MARK: - Hourly usage history

    /// Overwrite every row at or after `fromEpoch` with `rows`. Used each scan to replace
    /// today's buckets with the freshly-computed running total — idempotent across app
    /// restarts (a restart re-scans today from scratch, so a plain additive upsert would
    /// double-count). Older rows (backfilled) are left untouched.
    func replaceHours(fromEpoch: Int, rows: [HourlyRow]) {
        exec("BEGIN;")
        run("DELETE FROM hourly_usage WHERE hour_epoch >= ?;", int: fromEpoch)
        insertRows(rows)
        exec("COMMIT;")
    }

    /// Seed rows for hours that may not exist yet (history backfill). Existing rows for the
    /// same (hour, model) are replaced, so re-running a backfill is safe.
    func insertHours(_ rows: [HourlyRow]) {
        exec("BEGIN;")
        insertRows(rows)
        exec("COMMIT;")
    }

    private func insertRows(_ rows: [HourlyRow]) {
        let sql = """
        INSERT INTO hourly_usage(hour_epoch,model,input,output,cache_create,cache_read,messages)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(hour_epoch,model) DO UPDATE SET
            input=excluded.input, output=excluded.output,
            cache_create=excluded.cache_create, cache_read=excluded.cache_read,
            messages=excluded.messages;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for r in rows {
            sqlite3_bind_int64(stmt, 1, Int64(r.hourEpoch))
            sqlite3_bind_text(stmt, 2, r.model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(r.tokens.input))
            sqlite3_bind_int64(stmt, 4, Int64(r.tokens.output))
            sqlite3_bind_int64(stmt, 5, Int64(r.tokens.cacheCreate))
            sqlite3_bind_int64(stmt, 6, Int64(r.tokens.cacheRead))
            sqlite3_bind_int64(stmt, 7, Int64(r.tokens.messages ?? 0))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    /// Drop history older than `beforeEpoch` (called on each write to cap the table at
    /// ~60 days — enough to compare the current 30-day window against the prior one).
    func pruneHours(beforeEpoch: Int) {
        run("DELETE FROM hourly_usage WHERE hour_epoch < ?;", int: beforeEpoch)
    }

    /// Oldest hour recorded, or nil when the table is empty. Lets the caller tell whether a
    /// baseline window is fully covered by history before showing a delta against it.
    func earliestHourEpoch() -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(hour_epoch) FROM hourly_usage;", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// All rows in `[fromEpoch, toEpoch)`. The caller buckets them into local hours/days
    /// and prices them per model.
    func hourlyRows(fromEpoch: Int, toEpoch: Int) -> [HourlyRow] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT hour_epoch,model,input,output,cache_create,cache_read,messages
        FROM hourly_usage WHERE hour_epoch >= ? AND hour_epoch < ? ORDER BY hour_epoch ASC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(fromEpoch))
        sqlite3_bind_int64(stmt, 2, Int64(toEpoch))
        var out: [HourlyRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HourlyRow(
                hourEpoch: Int(sqlite3_column_int64(stmt, 0)),
                model: text(stmt, 1),
                tokens: ModelTokens(
                    input: Int(sqlite3_column_int64(stmt, 2)),
                    output: Int(sqlite3_column_int64(stmt, 3)),
                    cacheCreate: Int(sqlite3_column_int64(stmt, 4)),
                    cacheRead: Int(sqlite3_column_int64(stmt, 5)),
                    messages: Int(sqlite3_column_int64(stmt, 6))
                )
            ))
        }
        return out
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

    private func run(_ sql: String, int value: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(value))
        sqlite3_step(stmt)
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
