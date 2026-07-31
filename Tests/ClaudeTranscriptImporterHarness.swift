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
        let malformed = #"{"timestamp":"bad-json""#
        let line = """
        {"timestamp":"2026-07-31T10:00:00Z","uuid":"evt-1","sessionId":"session-1","message":{"model":"claude-sonnet-4","usage":{"input_tokens":200,"cache_creation_input_tokens":20,"cache_read_input_tokens":10,"output_tokens":30}}}
        """
        try (malformed + "\n" + line + "\n").write(to: transcript, atomically: true, encoding: .utf8)

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

        let fallbackProjects = root.appendingPathComponent(".claude/projects/fallback")
        try FileManager.default.createDirectory(
            at: fallbackProjects,
            withIntermediateDirectories: true)
        let fallbackTranscript = fallbackProjects.appendingPathComponent("fallback.jsonl")
        let fallbackLine = """
        {"timestamp":"2026-07-31T11:00:00Z","uuid":"evt-2","sessionId":"session-2","message":{"model":"claude-sonnet-4","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """
        try (fallbackLine + "\n").write(to: fallbackTranscript, atomically: true, encoding: .utf8)
        let fallbackLedger = try UsageLedger.open(at: root.appendingPathComponent("fallback-usage.sqlite"))
        let fallbackTimeline = try AccountTimelineStore.open(at: root.appendingPathComponent("fallback-timeline.sqlite"))
        let fallbackImporter = ClaudeTranscriptImporter(
            projectsRoot: root.appendingPathComponent(".claude/projects/fallback"),
            ledger: fallbackLedger,
            timeline: fallbackTimeline,
            knownProfileCount: { 1 },
            singleKnownAccountID: { "saved-profile-a" })
        try fallbackImporter.run(now: ISO8601DateFormatter().date(from: "2026-07-31T11:01:00Z")!)
        let fallbackTotals = try fallbackLedger.totals(
            provider: .claude,
            accountID: "saved-profile-a",
            start: ISO8601DateFormatter().date(from: "2026-07-31T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!)
        expect(fallbackTotals.inputTokens == 10, "single-profile fallback should use the saved profile account id")

        print("PASS: claude transcript importer")
    }
}
