import Foundation
import SQLite3

struct CodexUsageImporter {
    let logsDB: URL
    let ledger: UsageLedger.SQLiteStore
    let timeline: AccountTimelineStore.SQLiteStore

    func run() throws {
        guard FileManager.default.fileExists(atPath: logsDB.path()) else { return }
        let since = try ledger.checkpoint(source: "codex-sse")
            .flatMap { Int64($0.cursor) } ?? 0
        for row in try usageRows(afterID: since) {
            let attributed = try attributedAccount(for: row.timestamp)
            try ledger.upsert(event: .init(
                externalID: "codex:\(row.responseID)",
                provider: .codex,
                accountID: attributed.accountID,
                timestamp: row.timestamp,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheWriteTokens: row.cacheWriteTokens,
                cacheReadTokens: row.cacheReadTokens,
                totalTokens: row.totalTokens,
                source: "codex-sse",
                attribution: attributed.attribution))
            try ledger.saveCheckpoint(source: "codex-sse", cursor: String(row.logID))
        }
    }

    private func attributedAccount(for timestamp: Date) throws -> (
        accountID: String?, attribution: TokenAttribution
    ) {
        if let accountID = try timeline.accountID(for: .codex, timestamp: timestamp) {
            return (accountID, .observedActiveSpan)
        }
        return (nil, .unattributed)
    }

    private struct UsageRow {
        let logID: Int64
        let timestamp: Date
        let responseID: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
    }

    private func usageRows(afterID since: Int64) throws -> [UsageRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(logsDB.path(), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "CodexUsageImporter", code: 1)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, ts, feedback_log_body
            FROM logs
            WHERE id > ?
              AND target = 'codex_api::sse::responses'
            ORDER BY id ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexUsageImporter", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)

        var rows: [UsageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let logID = sqlite3_column_int64(stmt, 0)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
            guard let bodyText = sqlite3_column_text(stmt, 2) else { continue }
            if let row = try decodeUsage(
                from: String(cString: bodyText),
                logID: logID,
                timestamp: timestamp
            ) {
                rows.append(row)
            }
        }
        return rows
    }

    private func decodeUsage(
        from body: String,
        logID: Int64,
        timestamp: Date
    ) throws -> UsageRow? {
        guard body.hasPrefix("SSE event: ") else { return nil }
        let json = String(body.dropFirst("SSE event: ".count))
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any],
              let responseID = response["id"] as? String
        else { return nil }

        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        return UsageRow(
            logID: logID,
            timestamp: timestamp,
            responseID: responseID,
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            cacheWriteTokens: (inputDetails?["cache_write_tokens"] as? Int) ?? 0,
            cacheReadTokens: (inputDetails?["cached_tokens"] as? Int) ?? 0,
            totalTokens: (usage["total_tokens"] as? Int) ?? 0)
    }
}
