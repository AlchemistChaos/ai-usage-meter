import Foundation
import SQLite3

private let sqliteTransientTimeline = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self)

enum AccountTimelineStore {
    enum TimelineError: LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): return message
            }
        }
    }

    final class SQLiteStore {
        private let db: OpaquePointer

        fileprivate init(db: OpaquePointer) {
            self.db = db
        }

        deinit {
            sqlite3_close(db)
        }

        func observe(
            provider: ProviderKind,
            accountID: String,
            at date: Date = Date()
        ) throws {
            let current = try latestSpan(for: provider)
            if let current, current.accountID == accountID, current.endedAt == nil {
                let update = try prepare(
                    "UPDATE account_spans SET last_confirmed_at = ? WHERE id = ?")
                defer { sqlite3_finalize(update) }
                sqlite3_bind_double(update, 1, date.timeIntervalSince1970)
                sqlite3_bind_int64(update, 2, current.id)
                try stepDone(update)
                return
            }

            if let current, current.endedAt == nil {
                let update = try prepare(
                    "UPDATE account_spans SET ended_at = ? WHERE id = ?")
                defer { sqlite3_finalize(update) }
                sqlite3_bind_double(update, 1, current.lastConfirmedAt.timeIntervalSince1970)
                sqlite3_bind_int64(update, 2, current.id)
                try stepDone(update)
            }

            let insert = try prepare(
                """
                INSERT INTO account_spans (
                    provider, account_id, started_at, last_confirmed_at, ended_at
                ) VALUES (?, ?, ?, ?, NULL)
                """)
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_text(insert, 1, provider.rawValue, -1, sqliteTransientTimeline)
            sqlite3_bind_text(insert, 2, accountID, -1, sqliteTransientTimeline)
            sqlite3_bind_double(insert, 3, date.timeIntervalSince1970)
            sqlite3_bind_double(insert, 4, date.timeIntervalSince1970)
            try stepDone(insert)
        }

        func accountID(
            for provider: ProviderKind,
            timestamp: Date
        ) throws -> String? {
            let stmt = try prepare(
                """
                SELECT account_id
                FROM account_spans
                WHERE provider = ?
                  AND started_at <= ?
                  AND (ended_at IS NULL OR ended_at > ?)
                ORDER BY started_at DESC
                LIMIT 1
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransientTimeline)
            sqlite3_bind_double(stmt, 2, timestamp.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, timestamp.timeIntervalSince1970)

            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW,
                  let text = sqlite3_column_text(stmt, 0) else {
                throw error("failed to read timeline span")
            }
            return String(cString: text)
        }

        private struct Span {
            let id: Int64
            let accountID: String
            let lastConfirmedAt: Date
            let endedAt: Date?
        }

        private func latestSpan(for provider: ProviderKind) throws -> Span? {
            let stmt = try prepare(
                """
                SELECT id, account_id, last_confirmed_at, ended_at
                FROM account_spans
                WHERE provider = ?
                ORDER BY started_at DESC, id DESC
                LIMIT 1
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransientTimeline)

            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW,
                  let accountText = sqlite3_column_text(stmt, 1) else {
                throw error("failed to read latest timeline span")
            }
            let endedAt: Date?
            if sqlite3_column_type(stmt, 3) == SQLITE_NULL {
                endedAt = nil
            } else {
                endedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            }
            return Span(
                id: sqlite3_column_int64(stmt, 0),
                accountID: String(cString: accountText),
                lastConfirmedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: endedAt)
        }

        private func prepare(_ sql: String) throws -> OpaquePointer? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw error("failed to prepare timeline statement")
            }
            return stmt
        }

        private func stepDone(_ stmt: OpaquePointer?) throws {
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw error("timeline statement did not finish cleanly")
            }
        }

        private func error(_ message: String) -> TimelineError {
            .sqlite("\(message): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    static func open(at url: URL) throws -> SQLiteStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path(),
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let db { sqlite3_close(db) }
            throw TimelineError.sqlite("failed to open account timeline: \(message)")
        }

        let store = SQLiteStore(db: db)
        try store.bootstrap()
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path())
        return store
    }
}

private extension AccountTimelineStore.SQLiteStore {
    func bootstrap() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS account_spans (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              provider TEXT NOT NULL,
              account_id TEXT NOT NULL,
              started_at REAL NOT NULL,
              last_confirmed_at REAL NOT NULL DEFAULT 0,
              ended_at REAL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_account_spans_lookup
            ON account_spans(provider, started_at, ended_at)
            """
        ]
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw error("failed to bootstrap account timeline")
            }
        }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE account_spans ADD COLUMN last_confirmed_at REAL NOT NULL DEFAULT 0",
            nil,
            nil,
            nil)
        guard sqlite3_exec(
            db,
            """
            UPDATE account_spans
            SET last_confirmed_at = started_at
            WHERE last_confirmed_at = 0
            """,
            nil,
            nil,
            nil) == SQLITE_OK else {
            throw error("failed to backfill account timeline confirmations")
        }
    }
}
