import Foundation
import SQLite3

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private enum CodexUsageImporterHarnessData {
    static func create(db url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path(), &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CodexUsageImporterHarness", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            ts_nanos INTEGER NOT NULL,
            level TEXT NOT NULL,
            target TEXT NOT NULL,
            feedback_log_body TEXT,
            module_path TEXT,
            file TEXT,
            line INTEGER,
            thread_id TEXT,
            process_uuid TEXT,
            estimated_bytes INTEGER NOT NULL DEFAULT 0
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexUsageImporterHarness", code: 2)
        }

        let row = """
        INSERT INTO logs (
            ts, ts_nanos, level, target, feedback_log_body,
            module_path, file, line, thread_id, process_uuid, estimated_bytes
        ) VALUES (
            1785100030, 0, 'INFO', 'codex_api::sse::responses',
            'SSE event: {"type":"response.completed","response":{"id":"resp-1","usage":{"input_tokens":300,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":40,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":340}}}',
            'mod', 'file', 1, 'thread-1', 'proc-1', 0
        );
        """
        guard sqlite3_exec(db, row, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexUsageImporterHarness", code: 3)
        }
    }
}

@main
enum CodexUsageImporterHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-codex-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let db = root.appendingPathComponent("logs.sqlite")
        let ledger = try UsageLedger.open(at: root.appendingPathComponent("usage.sqlite"))
        let timeline = try AccountTimelineStore.open(at: root.appendingPathComponent("timeline.sqlite"))

        try timeline.observe(
            provider: .codex,
            accountID: "codex-account-a",
            at: Date(timeIntervalSince1970: 1_785_100_000))

        try CodexUsageImporterHarnessData.create(db: db)
        let importer = CodexUsageImporter(logsDB: db, ledger: ledger, timeline: timeline)
        try importer.run()
        try importer.run()

        let totals = try ledger.totals(
            provider: .codex,
            accountID: "codex-account-a",
            start: Date(timeIntervalSince1970: 1_785_100_000),
            end: Date(timeIntervalSince1970: 1_785_101_000))
        expect(totals.inputTokens == 300, "Codex input tokens should import once")
        expect(totals.outputTokens == 40, "Codex output tokens should import once")
        expect(totals.totalTokens == 340, "Codex total tokens should import once")

        print("PASS: codex usage importer")
    }
}
