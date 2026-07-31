import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum ClaudeTranscriptImporterHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-claude-import-\(UUID().uuidString)")
        let projects = root.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(
            at: projects,
            withIntermediateDirectories: true)

        let transcript = projects.appendingPathComponent("session.jsonl")
        let line = """
        {"timestamp":"2026-07-31T10:00:00Z","uuid":"evt-1","sessionId":"session-1","message":{"model":"claude-sonnet-4","usage":{"input_tokens":200,"cache_creation_input_tokens":20,"cache_read_input_tokens":10,"output_tokens":30}}}
        """
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let ledger = try UsageLedger.open(at: root.appendingPathComponent("usage.sqlite"))
        let timeline = try AccountTimelineStore.open(at: root.appendingPathComponent("timeline.sqlite"))
        try timeline.observe(
            provider: .claude,
            accountID: "claude-account-a",
            at: ISO8601DateFormatter().date(from: "2026-07-31T09:59:00Z")!)

        let importer = ClaudeTranscriptImporter(
            projectsRoot: root.appendingPathComponent(".claude/projects"),
            ledger: ledger,
            timeline: timeline,
            knownProfileCount: { 2 })
        try importer.run(now: ISO8601DateFormatter().date(from: "2026-07-31T10:01:00Z")!)

        let totals = try ledger.totals(
            provider: .claude,
            accountID: "claude-account-a",
            start: ISO8601DateFormatter().date(from: "2026-07-31T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!)
        expect(totals.inputTokens == 200, "Claude input tokens should import")
        expect(totals.outputTokens == 30, "Claude output tokens should import")
        expect(totals.cacheWriteTokens == 20, "Claude cache write tokens should import")
        expect(totals.cacheReadTokens == 10, "Claude cache read tokens should import")

        print("PASS: claude transcript importer")
    }
}
