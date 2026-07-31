import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self)

enum UsageLedger {
    struct UsageEvent {
        let externalID: String
        let provider: ProviderKind
        let accountID: String?
        let timestamp: Date
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
        let source: String
        let attribution: TokenAttribution
    }

    struct WindowTotals: Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
    }

    struct EventRow: Equatable {
        let timestamp: Date
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
    }

    struct ImportCheckpoint: Equatable {
        let source: String
        let cursor: String
    }

    enum LedgerError: LocalizedError {
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

        func upsert(event: UsageEvent) throws {
            let sql = """
                INSERT INTO usage_events (
                    external_id, provider, account_id, ts,
                    input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
                    total_tokens, source, attribution
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(external_id) DO UPDATE SET
                    provider = excluded.provider,
                    account_id = excluded.account_id,
                    ts = excluded.ts,
                    input_tokens = excluded.input_tokens,
                    output_tokens = excluded.output_tokens,
                    cache_write_tokens = excluded.cache_write_tokens,
                    cache_read_tokens = excluded.cache_read_tokens,
                    total_tokens = excluded.total_tokens,
                    source = excluded.source,
                    attribution = excluded.attribution
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, event.externalID, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, event.provider.rawValue, -1, sqliteTransient)
            bindNullableText(event.accountID, to: stmt, index: 3)
            sqlite3_bind_double(stmt, 4, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 5, Int64(event.inputTokens))
            sqlite3_bind_int64(stmt, 6, Int64(event.outputTokens))
            sqlite3_bind_int64(stmt, 7, Int64(event.cacheWriteTokens))
            sqlite3_bind_int64(stmt, 8, Int64(event.cacheReadTokens))
            sqlite3_bind_int64(stmt, 9, Int64(event.totalTokens))
            sqlite3_bind_text(stmt, 10, event.source, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 11, event.attribution.rawValue, -1, sqliteTransient)

            try stepDone(stmt)
        }

        func totals(
            provider: ProviderKind,
            accountID: String?,
            start: Date,
            end: Date
        ) throws -> WindowTotals {
            let accountClause = accountID == nil ? "account_id IS NULL" : "account_id = ?"
            let sql = """
                SELECT
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cache_write_tokens), 0),
                    COALESCE(SUM(cache_read_tokens), 0),
                    COALESCE(SUM(total_tokens), 0)
                FROM usage_events
                WHERE provider = ?
                  AND \(accountClause)
                  AND ts >= ?
                  AND ts < ?
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            var nextIndex: Int32 = 2
            if let accountID {
                sqlite3_bind_text(stmt, nextIndex, accountID, -1, sqliteTransient)
                nextIndex += 1
            }
            sqlite3_bind_double(stmt, nextIndex, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, nextIndex + 1, end.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw error("failed to read usage totals")
            }

            return WindowTotals(
                inputTokens: Int(sqlite3_column_int64(stmt, 0)),
                outputTokens: Int(sqlite3_column_int64(stmt, 1)),
                cacheWriteTokens: Int(sqlite3_column_int64(stmt, 2)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 3)),
                totalTokens: Int(sqlite3_column_int64(stmt, 4)))
        }

        func saveCheckpoint(source: String, cursor: String) throws {
            let sql = """
                INSERT INTO import_checkpoints (source, cursor, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET
                    cursor = excluded.cursor,
                    updated_at = excluded.updated_at
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, source, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, cursor, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)

            try stepDone(stmt)
        }

        func checkpoint(source: String) throws -> ImportCheckpoint? {
            let sql = "SELECT source, cursor FROM import_checkpoints WHERE source = ?"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, source, -1, sqliteTransient)
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else {
                throw error("failed to read import checkpoint")
            }
            guard let sourceText = sqlite3_column_text(stmt, 0),
                  let cursorText = sqlite3_column_text(stmt, 1) else {
                throw error("checkpoint row was incomplete")
            }
            return ImportCheckpoint(
                source: String(cString: sourceText),
                cursor: String(cString: cursorText))
        }

        func events(
            provider: ProviderKind,
            accountID: String?,
            start: Date,
            end: Date
        ) throws -> [EventRow] {
            let accountClause = accountID == nil ? "account_id IS NULL" : "account_id = ?"
            let sql = """
                SELECT
                    ts,
                    input_tokens,
                    output_tokens,
                    cache_write_tokens,
                    cache_read_tokens,
                    total_tokens
                FROM usage_events
                WHERE provider = ?
                  AND \(accountClause)
                  AND ts >= ?
                  AND ts < ?
                ORDER BY ts ASC
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            var nextIndex: Int32 = 2
            if let accountID {
                sqlite3_bind_text(stmt, nextIndex, accountID, -1, sqliteTransient)
                nextIndex += 1
            }
            sqlite3_bind_double(stmt, nextIndex, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, nextIndex + 1, end.timeIntervalSince1970)

            var rows: [EventRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(EventRow(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    cacheWriteTokens: Int(sqlite3_column_int64(stmt, 3)),
                    cacheReadTokens: Int(sqlite3_column_int64(stmt, 4)),
                    totalTokens: Int(sqlite3_column_int64(stmt, 5))))
            }
            return rows
        }

        private func prepare(_ sql: String) throws -> OpaquePointer? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw error("failed to prepare statement")
            }
            return stmt
        }

        private func bindNullableText(_ value: String?, to stmt: OpaquePointer?, index: Int32) {
            if let value {
                sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, index)
            }
        }

        private func stepDone(_ stmt: OpaquePointer?) throws {
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw error("statement did not finish cleanly")
            }
        }

        private func error(_ message: String) -> LedgerError {
            let dbMessage = String(cString: sqlite3_errmsg(db))
            return .sqlite("\(message): \(dbMessage)")
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
            throw LedgerError.sqlite("failed to open usage ledger: \(message)")
        }

        let store = SQLiteStore(db: db)
        try store.bootstrap()
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path())
        return store
    }
}

private extension UsageLedger.SQLiteStore {
    func bootstrap() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS usage_events (
              external_id TEXT PRIMARY KEY,
              provider TEXT NOT NULL,
              account_id TEXT,
              ts REAL NOT NULL,
              input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cache_write_tokens INTEGER NOT NULL,
              cache_read_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL,
              source TEXT NOT NULL,
              attribution TEXT NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_usage_events_window
            ON usage_events(provider, account_id, ts)
            """,
            """
            CREATE TABLE IF NOT EXISTS import_checkpoints (
              source TEXT PRIMARY KEY,
              cursor TEXT NOT NULL,
              updated_at REAL NOT NULL
            )
            """
        ]

        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw error("failed to bootstrap usage ledger")
            }
        }
    }
}
