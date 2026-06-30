import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite persistence: the account roster + a rolling history of usage snapshots.
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
        CREATE TABLE IF NOT EXISTS snapshots (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            email       TEXT NOT NULL,
            ts          REAL NOT NULL,
            five_pct    REAL NOT NULL,
            seven_pct   REAL NOT NULL,
            five_reset  REAL,
            seven_reset REAL
        );
        CREATE INDEX IF NOT EXISTS idx_snap_email_ts ON snapshots(email, ts);
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
        run("DELETE FROM snapshots WHERE email=?;", text: email)
    }

    func nextOrder() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ord),-1)+1 FROM accounts;", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Snapshots

    func insertSnapshot(email: String, usage: Usage) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO snapshots(email,ts,five_pct,seven_pct,five_reset,seven_reset) VALUES(?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, email, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, usage.fetchedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, usage.fiveHourPct)
        sqlite3_bind_double(stmt, 4, usage.sevenDayPct)
        bindOptionalDate(stmt, 5, usage.fiveHourResets)
        bindOptionalDate(stmt, 6, usage.sevenDayResets)
        sqlite3_step(stmt)
    }

    /// Peak utilization over the last `seconds` for an account.
    func summary(email: String, lastSeconds: TimeInterval) -> UsageSummary {
        var stmt: OpaquePointer?
        let sql = """
        SELECT COALESCE(MAX(five_pct),0), COALESCE(MAX(seven_pct),0), COUNT(*)
        FROM snapshots WHERE email=? AND ts>=?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return UsageSummary(peakFiveHour: 0, peakSevenDay: 0, samples: 0)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, email, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, Date().addingTimeInterval(-lastSeconds).timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return UsageSummary(peakFiveHour: 0, peakSevenDay: 0, samples: 0)
        }
        return UsageSummary(
            peakFiveHour: sqlite3_column_double(stmt, 0),
            peakSevenDay: sqlite3_column_double(stmt, 1),
            samples: Int(sqlite3_column_int(stmt, 2))
        )
    }

    /// Drop snapshots older than `days` to keep the file small.
    func pruneSnapshots(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM snapshots WHERE ts<?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
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

    private func bindOptionalDate(_ stmt: OpaquePointer?, _ idx: Int32, _ date: Date?) {
        if let date { sqlite3_bind_double(stmt, idx, date.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, idx) }
    }
}
