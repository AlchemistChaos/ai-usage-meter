# Per-Account Token Metering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track Claude and Codex token usage per account across hourly, daily, weekly, monthly, and yearly views, show it in the dashboard/history UI, and keep ambiguous historical usage out of named account totals.

**Architecture:** Add a small local SQLite usage ledger plus a provider-agnostic active-account timeline. Claude transcript rows and Codex SSE usage rows are imported incrementally into the ledger, then attributed to accounts by stable account ID plus observed active-account time spans. A history query layer builds hourly and calendar-based aggregates from that ledger so the UI can show `today`, `24h`, `7d`, `30d`, `month`, `year`, and longer trends without scanning raw events on every refresh. When a row cannot be attributed confidently, store it as unattributed instead of guessing.

**Tech Stack:** Swift 5.9, macOS 14, Foundation, SQLite3, existing manual harness tests, existing menu-bar SwiftUI app.

## Global Constraints

- macOS floor stays `macOS 14` as declared in `Package.swift`.
- Keep the app local-first: no hosted backend, no telemetry, no third-party analytics.
- Do not add any new provider network client for Codex usage; Codex token usage must come from local `~/.codex/logs_2.sqlite`.
- Keep Claude usage/account requests direct to Anthropic only; token metering must come from local Claude transcripts.
- Never invent account attribution. If a usage row cannot be tied to exactly one account, persist it as unattributed and exclude it from named account totals.
- Preserve current live limit behavior: Claude limit polling stays per stored OAuth profile; Codex limit polling stays via app-server with SQLite fallback.
- Support `hourly`, `daily`, `weekly`, `monthly`, and `yearly` token history from the first shipped version of this feature.
- Support both rolling windows (`24h`, `7d`, `30d`, `365d`) and calendar windows (`today`, `this week`, `this month`, `this year`).
- Keep long-range history queries fast enough for menu refreshes by adding persisted rollups or cached aggregates; do not full-scan all raw events on every UI refresh.
- Keep secrets on disk owner-only (`0600`) where new files are created.
- Follow the repository’s existing verification style: `swift build`, shell structure harnesses, and ad hoc `swiftc` harness binaries.

---

## File Structure

- Create: `Sources/AIMeter/AttributedTokenStats.swift`
  Responsibility: per-account token totals and attribution confidence metadata used by the UI.
- Create: `Sources/AIMeter/UsageLedger.swift`
  Responsibility: local SQLite schema, event upsert, window queries, checkpoints.
- Create: `Sources/AIMeter/AccountTimelineStore.swift`
  Responsibility: observed active-account spans per provider, plus timestamp-based account lookup.
- Create: `Sources/AIMeter/ClaudeTranscriptImporter.swift`
  Responsibility: incremental import of Claude transcript usage rows into the ledger.
- Create: `Sources/AIMeter/CodexUsageImporter.swift`
  Responsibility: incremental import of Codex local SSE `response.usage` rows into the ledger.
- Create: `Sources/AIMeter/UsageHistoryQuery.swift`
  Responsibility: hourly and calendar-window aggregate queries over attributed and unattributed usage.
- Modify: `Sources/AIMeter/Models.swift`
  Responsibility: extend `Account` with token totals, history summaries, and attribution status.
- Modify: `Sources/AIMeter/AccountManager.swift`
  Responsibility: observe active account changes, run importers, query per-account token totals and history.
- Modify: `Sources/AIMeter/GlassDashboardView.swift`
  Responsibility: surface per-account token totals, quick time-range chips, and unattributed-state copy.
- Create: `Sources/AIMeter/UsageHistoryView.swift`
  Responsibility: dedicated history drill-down with hourly/daily/weekly/monthly/yearly sections.
- Modify: `Sources/AIMeter/Diagnostics.swift`
  Responsibility: print per-account and unattributed token totals for verification across short and long windows.
- Modify: `README.md`
  Responsibility: document forward-only attribution behavior and verification commands.
- Create: `Tests/UsageLedgerHarness.swift`
  Responsibility: schema/query/checkpoint regression coverage.
- Create: `Tests/ClaudeTranscriptImporterHarness.swift`
  Responsibility: transcript parsing, attribution, and unattributed fallback coverage.
- Create: `Tests/CodexUsageImporterHarness.swift`
  Responsibility: SSE usage parsing, timestamp attribution, and duplicate suppression coverage.
- Create: `Tests/UsageHistoryHarness.swift`
  Responsibility: hourly buckets, calendar windows, rolling windows, and unattributed totals coverage.
- Modify: `Tests/DashboardStructureHarness.sh`
  Responsibility: assert the new token summary/history copy appears and legacy machine-wide wording is removed.

### Product Rule

The first build with this feature will not retroactively “fix” old mixed-account usage. Historical rows that predate the app’s observed account timeline remain unattributed unless there is a safe single-profile attribution case. Named per-account hourly/daily/weekly/monthly/yearly totals are forward-accurate from the first run after upgrade.

### Task 1: Add Shared Token-Ledger Models And Storage

**Files:**
- Create: `Sources/AIMeter/AttributedTokenStats.swift`
- Create: `Sources/AIMeter/UsageLedger.swift`
- Test: `Tests/UsageLedgerHarness.swift`

**Interfaces:**
- Consumes: `ProviderKind` from `Sources/AIMeter/Models.swift`
- Produces: `AttributedTokenStats`, `UsageLedger`, `UsageLedger.WindowTotals`, `UsageLedger.ImportCheckpoint`

- [ ] **Step 1: Write the failing harness for event upsert, duplicate suppression, and window queries**

```swift
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
enum UsageLedgerHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-usage-ledger-\(UUID().uuidString)")
        let ledger = try UsageLedger.open(at: root.appendingPathComponent("usage.sqlite"))

        try ledger.upsert(event: .init(
            externalID: "claude:session-1:event-1",
            provider: .claude,
            accountID: "claude-account-a",
            timestamp: Date(timeIntervalSince1970: 1_785_000_000),
            inputTokens: 100,
            outputTokens: 25,
            cacheWriteTokens: 10,
            cacheReadTokens: 5,
            totalTokens: 140,
            source: "claude-transcript",
            attribution: .observedActiveSpan))
        try ledger.upsert(event: .init(
            externalID: "claude:session-1:event-1",
            provider: .claude,
            accountID: "claude-account-a",
            timestamp: Date(timeIntervalSince1970: 1_785_000_000),
            inputTokens: 100,
            outputTokens: 25,
            cacheWriteTokens: 10,
            cacheReadTokens: 5,
            totalTokens: 140,
            source: "claude-transcript",
            attribution: .observedActiveSpan))

        let totals = try ledger.totals(
            provider: .claude,
            accountID: "claude-account-a",
            start: Date(timeIntervalSince1970: 1_784_999_000),
            end: Date(timeIntervalSince1970: 1_785_001_000))
        expect(totals.inputTokens == 100, "duplicate events should be ignored")
        expect(totals.outputTokens == 25, "output tokens should be summed")
        expect(totals.cacheWriteTokens == 10, "cache write tokens should be retained")
        expect(totals.cacheReadTokens == 5, "cache read tokens should be retained")
        expect(totals.totalTokens == 140, "total tokens should be retained")

        try ledger.saveCheckpoint(source: "claude-transcript", cursor: "file.jsonl:128")
        expect(
            try ledger.checkpoint(source: "claude-transcript")?.cursor == "file.jsonl:128",
            "checkpoint cursor should round-trip")

        print("PASS: usage ledger")
    }
}
```

- [ ] **Step 2: Run the harness to verify it fails because the ledger types do not exist yet**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Tests/UsageLedgerHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-ledger-tests
```

Expected: compile failure mentioning missing `AttributedTokenStats` or `UsageLedger`.

- [ ] **Step 3: Add the shared token stats type and SQLite ledger implementation**

```swift
import Foundation

enum TokenAttribution: String, Codable {
    case observedActiveSpan
    case singleProfileFallback
    case unattributed
}

struct AttributedTokenStats: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var totalTokens = 0
    var attribution: TokenAttribution = .unattributed

    var isEmpty: Bool { totalTokens == 0 }
}
```

```swift
import Foundation
import SQLite3

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

    struct ImportCheckpoint: Equatable {
        let source: String
        let cursor: String
    }

    static func open(at url: URL) throws -> SQLiteStore { ... }
}
```

```sql
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
);

CREATE INDEX IF NOT EXISTS idx_usage_events_window
ON usage_events(provider, account_id, ts);

CREATE TABLE IF NOT EXISTS import_checkpoints (
  source TEXT PRIMARY KEY,
  cursor TEXT NOT NULL,
  updated_at REAL NOT NULL
);
```

- [ ] **Step 4: Run the harness to verify the ledger passes**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Tests/UsageLedgerHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-ledger-tests
/tmp/notch-limits-usage-ledger-tests
```

Expected:

```text
PASS: usage ledger
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Tests/UsageLedgerHarness.swift
git commit -m "feat: add local usage ledger"
```

### Task 2: Persist Observed Active-Account Timelines

**Files:**
- Create: `Sources/AIMeter/AccountTimelineStore.swift`
- Modify: `Sources/AIMeter/AccountManager.swift`
- Test: `Tests/UsageLedgerHarness.swift`

**Interfaces:**
- Consumes: `ProviderKind`, `UsageLedger`
- Produces: `AccountTimelineStore.observe(provider:accountID:at:)`, `AccountTimelineStore.accountID(for:timestamp:)`

- [ ] **Step 1: Extend the harness to prove span rollover and lookup behavior**

```swift
let timeline = try AccountTimelineStore.open(
    at: root.appendingPathComponent("timeline.sqlite"))
let t0 = Date(timeIntervalSince1970: 1_785_100_000)
let t1 = t0.addingTimeInterval(60)
let t2 = t1.addingTimeInterval(60)

try timeline.observe(provider: .claude, accountID: "a", at: t0)
try timeline.observe(provider: .claude, accountID: "a", at: t1)
try timeline.observe(provider: .claude, accountID: "b", at: t2)

expect(
    try timeline.accountID(for: .claude, timestamp: t0.addingTimeInterval(30)) == "a",
    "lookup inside the first span should return account a")
expect(
    try timeline.accountID(for: .claude, timestamp: t2.addingTimeInterval(1)) == "b",
    "lookup after rollover should return account b")
```

- [ ] **Step 2: Run the harness to verify it fails because the timeline store does not exist**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Tests/UsageLedgerHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-ledger-tests
```

Expected: compile failure mentioning missing `AccountTimelineStore`.

- [ ] **Step 3: Add timeline persistence and observe active accounts from `AccountManager.refresh()`**

```swift
import Foundation
import SQLite3

enum AccountTimelineStore {
    static func open(at url: URL) throws -> SQLiteStore { ... }

    func observe(
        provider: ProviderKind,
        accountID: String,
        at date: Date = Date()
    ) throws { ... }

    func accountID(
        for provider: ProviderKind,
        timestamp: Date
    ) throws -> String? { ... }
}
```

```sql
CREATE TABLE IF NOT EXISTS account_spans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider TEXT NOT NULL,
  account_id TEXT NOT NULL,
  started_at REAL NOT NULL,
  ended_at REAL
);

CREATE INDEX IF NOT EXISTS idx_account_spans_lookup
ON account_spans(provider, started_at, ended_at);
```

```swift
private func observeActiveAccounts() {
    if let claude = ClaudeProvider.identity()?.accountUuid {
        try? timeline.observe(provider: .claude, accountID: claude, at: Date())
    }
    if let codex = CodexProvider.activeAccountIdentity(
        desktopAccountID: CodexProvider.desktopAccountIdentity(),
        cliAccountID: CodexProvider.identity(
            at: ProfileStore.activeCredentialPath(.codex))?.accountID) {
        try? timeline.observe(provider: .codex, accountID: codex, at: Date())
    }
}
```

- [ ] **Step 4: Re-run the harness and verify span lookup passes**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Tests/UsageLedgerHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-ledger-tests
/tmp/notch-limits-usage-ledger-tests
```

Expected:

```text
PASS: usage ledger
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/AccountManager.swift \
  Tests/UsageLedgerHarness.swift
git commit -m "feat: persist active account timelines"
```

### Task 3: Import Claude Transcript Usage Per Account

**Files:**
- Create: `Sources/AIMeter/ClaudeTranscriptImporter.swift`
- Modify: `Sources/AIMeter/AccountManager.swift`
- Create: `Tests/ClaudeTranscriptImporterHarness.swift`

**Interfaces:**
- Consumes: `UsageLedger`, `AccountTimelineStore`, `ClaudeProvider`
- Produces: `ClaudeTranscriptImporter.run(now:)`, imported `usage_events` rows with Claude attribution

- [ ] **Step 1: Write the failing harness for transcript parsing and unattributed fallback**

```swift
import Foundation

@main
enum ClaudeTranscriptImporterHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-claude-import-\(UUID().uuidString)")
        let projects = root.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

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
```

- [ ] **Step 2: Run the harness to verify it fails because the importer does not exist**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/ClaudeTranscriptImporter.swift \
  Tests/ClaudeTranscriptImporterHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-claude-import-tests
```

Expected: compile failure mentioning missing `ClaudeTranscriptImporter`.

- [ ] **Step 3: Implement incremental transcript import with explicit attribution rules**

```swift
import Foundation

struct ClaudeTranscriptImporter {
    let projectsRoot: URL
    let ledger: UsageLedger.SQLiteStore
    let timeline: AccountTimelineStore.SQLiteStore
    let knownProfileCount: () -> Int

    func run(now: Date = Date()) throws {
        for transcript in transcriptFiles() {
            try importTranscript(transcript)
        }
    }

    private func attributedAccountID(for timestamp: Date) throws -> (String?, TokenAttribution) {
        if let accountID = try timeline.accountID(for: .claude, timestamp: timestamp) {
            return (accountID, .observedActiveSpan)
        }
        if knownProfileCount() == 1 {
            return (ClaudeProvider.identity()?.accountUuid, .singleProfileFallback)
        }
        return (nil, .unattributed)
    }
}
```

```swift
private func importLine(_ data: Data) throws {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let uuid = obj["uuid"] as? String,
          let ts = obj["timestamp"] as? String,
          let date = ISO8601DateFormatter().date(from: ts),
          let message = obj["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any]
    else { return }

    let sessionID = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) ?? "unknown"
    let input = (usage["input_tokens"] as? Int) ?? 0
    let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
    let output = (usage["output_tokens"] as? Int) ?? 0
    let total = input + cacheWrite + cacheRead + output
    guard total > 0 else { return }

    let (accountID, attribution) = try attributedAccountID(for: date)
    try ledger.upsert(event: .init(
        externalID: "claude:\(sessionID):\(uuid)",
        provider: .claude,
        accountID: accountID,
        timestamp: date,
        inputTokens: input,
        outputTokens: output,
        cacheWriteTokens: cacheWrite,
        cacheReadTokens: cacheRead,
        totalTokens: total,
        source: "claude-transcript",
        attribution: attribution))
}
```

- [ ] **Step 4: Re-run the harness and verify transcript attribution works**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/ClaudeTranscriptImporter.swift \
  Tests/ClaudeTranscriptImporterHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-claude-import-tests
/tmp/notch-limits-claude-import-tests
```

Expected:

```text
PASS: claude transcript importer
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/ClaudeTranscriptImporter.swift \
  Sources/AIMeter/AccountManager.swift \
  Tests/ClaudeTranscriptImporterHarness.swift
git commit -m "feat: import claude transcript usage by account"
```

### Task 4: Import Codex Local SSE Usage Per Account

**Files:**
- Create: `Sources/AIMeter/CodexUsageImporter.swift`
- Modify: `Sources/AIMeter/CodexProvider.swift`
- Modify: `Sources/AIMeter/AccountManager.swift`
- Create: `Tests/CodexUsageImporterHarness.swift`

**Interfaces:**
- Consumes: `~/.codex/logs_2.sqlite`, `UsageLedger`, `AccountTimelineStore`, `CodexProvider`
- Produces: `CodexUsageImporter.run()`, exact `response.usage` imports per Codex account

- [ ] **Step 1: Write the failing harness for SSE usage extraction and duplicate suppression**

```swift
import Foundation

@main
enum CodexUsageImporterHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-codex-import-\(UUID().uuidString)")
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
```

- [ ] **Step 2: Run the harness to verify it fails because the importer does not exist**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/CodexUsageImporter.swift \
  Tests/CodexUsageImporterHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-codex-usage-tests
```

Expected: compile failure mentioning missing `CodexUsageImporter`.

- [ ] **Step 3: Implement exact SSE usage parsing and timestamp attribution**

```swift
import Foundation
import SQLite3

struct CodexUsageImporter {
    let logsDB: URL
    let ledger: UsageLedger.SQLiteStore
    let timeline: AccountTimelineStore.SQLiteStore

    func run() throws {
        let since = try ledger.checkpoint(source: "codex-sse")?.cursor.flatMap(Int64.init) ?? 0
        for row in try usageRows(afterID: since) {
            let (accountID, attribution) = try attributedAccountID(for: row.timestamp)
            try ledger.upsert(event: .init(
                externalID: "codex:\(row.responseID)",
                provider: .codex,
                accountID: accountID,
                timestamp: row.timestamp,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheWriteTokens: row.cacheWriteTokens,
                cacheReadTokens: row.cacheReadTokens,
                totalTokens: row.totalTokens,
                source: "codex-sse",
                attribution: attribution))
            try ledger.saveCheckpoint(source: "codex-sse", cursor: String(row.logID))
        }
    }

    private func attributedAccountID(for timestamp: Date) throws -> (String?, TokenAttribution) {
        if let accountID = try timeline.accountID(for: .codex, timestamp: timestamp) {
            return (accountID, .observedActiveSpan)
        }
        return (nil, .unattributed)
    }
}
```

```swift
private func decodeUsage(from body: String) throws -> UsageRow? {
    guard body.hasPrefix("SSE event: ") else { return nil }
    let json = String(body.dropFirst("SSE event: ".count))
    guard let data = json.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = root["response"] as? [String: Any],
          let usage = response["usage"] as? [String: Any],
          let responseID = response["id"] as? String
    else { return nil }

    return UsageRow(
        responseID: responseID,
        inputTokens: (usage["input_tokens"] as? Int) ?? 0,
        outputTokens: (usage["output_tokens"] as? Int) ?? 0,
        cacheWriteTokens: ((usage["input_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int) ?? 0,
        cacheReadTokens: ((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0,
        totalTokens: (usage["total_tokens"] as? Int) ?? 0)
}
```

- [ ] **Step 4: Re-run the harness and verify exact Codex usage imports pass**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/CodexUsageImporter.swift \
  Tests/CodexUsageImporterHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-codex-usage-tests
/tmp/notch-limits-codex-usage-tests
```

Expected:

```text
PASS: codex usage importer
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/CodexUsageImporter.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/AccountManager.swift \
  Tests/CodexUsageImporterHarness.swift
git commit -m "feat: import codex local usage by account"
```

### Task 5: Add History Queries For Hourly, Daily, Weekly, Monthly, And Yearly Windows

**Files:**
- Create: `Sources/AIMeter/UsageHistoryQuery.swift`
- Create: `Tests/UsageHistoryHarness.swift`
- Modify: `Sources/AIMeter/UsageLedger.swift`

**Interfaces:**
- Consumes: `UsageLedger`, `AttributedTokenStats`
- Produces: `UsageHistoryQuery`, `UsageHistoryQuery.RangePreset`, `UsageHistoryQuery.SeriesPoint`, `UsageHistoryQuery.HistorySnapshot`

- [ ] **Step 1: Write the failing harness for hourly buckets and long-range windows**

```swift
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
enum UsageHistoryHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-history-\(UUID().uuidString)")
        let ledger = try UsageLedger.open(at: root.appendingPathComponent("usage.sqlite"))

        let start = ISO8601DateFormatter().date(from: "2026-07-31T08:00:00Z")!
        try ledger.upsert(event: .init(
            externalID: "codex:r1",
            provider: .codex,
            accountID: "codex-a",
            timestamp: start,
            inputTokens: 100,
            outputTokens: 20,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 120,
            source: "codex-sse",
            attribution: .observedActiveSpan))
        try ledger.upsert(event: .init(
            externalID: "codex:r2",
            provider: .codex,
            accountID: "codex-a",
            timestamp: start.addingTimeInterval(3600),
            inputTokens: 50,
            outputTokens: 10,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 60,
            source: "codex-sse",
            attribution: .observedActiveSpan))

        let query = UsageHistoryQuery(ledger: ledger)
        let hourly = try query.series(
            provider: .codex,
            accountID: "codex-a",
            preset: .last24Hours,
            now: ISO8601DateFormatter().date(from: "2026-07-31T12:00:00Z")!)
        expect(hourly.points.count == 24, "24h preset should emit 24 hourly buckets")
        expect(hourly.points.contains(where: { $0.inputTokens == 100 }), "hourly series should include first bucket")
        expect(hourly.points.contains(where: { $0.inputTokens == 50 }), "hourly series should include second bucket")

        let monthly = try query.snapshot(
            provider: .codex,
            accountID: "codex-a",
            now: ISO8601DateFormatter().date(from: "2026-07-31T12:00:00Z")!)
        expect(monthly.today.inputTokens == 150, "today total should sum both rows")
        expect(monthly.last24Hours.inputTokens == 150, "24h total should sum both rows")

        print("PASS: usage history query")
    }
}
```

- [ ] **Step 2: Run the harness to verify it fails because the history query layer does not exist**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/UsageHistoryQuery.swift \
  Tests/UsageHistoryHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-history-tests
```

Expected: compile failure mentioning missing `UsageHistoryQuery`.

- [ ] **Step 3: Implement history presets and aggregate series queries**

```swift
import Foundation

struct UsageHistoryQuery {
    enum RangePreset: CaseIterable {
        case today
        case last24Hours
        case last7Days
        case last30Days
        case thisMonth
        case thisYear
    }

    struct SeriesPoint: Equatable {
        let bucketStart: Date
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
    }

    struct Series: Equatable {
        let preset: RangePreset
        let points: [SeriesPoint]
    }

    struct HistorySnapshot: Equatable {
        let today: AttributedTokenStats
        let last24Hours: AttributedTokenStats
        let last7Days: AttributedTokenStats
        let last30Days: AttributedTokenStats
        let thisMonth: AttributedTokenStats
        let thisYear: AttributedTokenStats
    }

    let ledger: UsageLedger.SQLiteStore

    func snapshot(provider: ProviderKind, accountID: String?, now: Date = Date()) throws -> HistorySnapshot { ... }
    func series(provider: ProviderKind, accountID: String?, preset: RangePreset, now: Date = Date()) throws -> Series { ... }
}
```

```swift
private func dateBounds(for preset: RangePreset, now: Date) -> (start: Date, end: Date, bucket: BucketKind) {
    let cal = Calendar(identifier: .gregorian)
    switch preset {
    case .today:
        return (cal.startOfDay(for: now), now, .hour)
    case .last24Hours:
        return (now.addingTimeInterval(-24 * 3600), now, .hour)
    case .last7Days:
        return (now.addingTimeInterval(-7 * 86_400), now, .day)
    case .last30Days:
        return (now.addingTimeInterval(-30 * 86_400), now, .day)
    case .thisMonth:
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        return (start, now, .day)
    case .thisYear:
        let start = cal.date(from: cal.dateComponents([.year], from: now))!
        return (start, now, .month)
    }
}
```

- [ ] **Step 4: Re-run the harness and verify hourly and long-range queries pass**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/UsageHistoryQuery.swift \
  Tests/UsageHistoryHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-history-tests
/tmp/notch-limits-usage-history-tests
```

Expected:

```text
PASS: usage history query
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/UsageHistoryQuery.swift \
  Sources/AIMeter/UsageLedger.swift \
  Tests/UsageHistoryHarness.swift
git commit -m "feat: add hourly and long-range usage history queries"
```

### Task 6: Wire Per-Account Totals Into Accounts, Diagnostics, And Dashboard

**Files:**
- Modify: `Sources/AIMeter/Models.swift`
- Modify: `Sources/AIMeter/AccountManager.swift`
- Modify: `Sources/AIMeter/GlassDashboardView.swift`
- Modify: `Sources/AIMeter/Diagnostics.swift`
- Modify: `Tests/DashboardStructureHarness.sh`

**Interfaces:**
- Consumes: `UsageLedger`, `UsageHistoryQuery`, `ClaudeTranscriptImporter`, `CodexUsageImporter`
- Produces: `Account.todayTokens`, `Account.last24HoursTokens`, `Account.last7DaysTokens`, `Account.thisMonthTokens`, `Account.thisYearTokens`, `Account.tokenAttribution`, dashboard token summary

- [ ] **Step 1: Add a failing structure assertion for per-account token copy**

```bash
rg -q 'Today tokens' Sources/AIMeter/GlassDashboardView.swift || {
  echo "FAIL: per-account token summary is missing" >&2
  exit 1
}

if rg -q 'Tokens today] in:' Sources/AIMeter/GlassDashboardView.swift; then
  echo "FAIL: machine-wide diagnostics copy leaked into the dashboard" >&2
  exit 1
fi
```

- [ ] **Step 2: Run the structure harness to verify it fails before UI wiring**

Run:

```bash
cd /Users/chaos/Github/notch-limits
bash Tests/DashboardStructureHarness.sh
```

Expected: failure mentioning missing per-account token summary.

- [ ] **Step 3: Extend account models, run importers from `AccountManager`, and render token totals**

```swift
struct Account: Identifiable {
    ...
    let todayTokens: AttributedTokenStats
    let last24HoursTokens: AttributedTokenStats
    let last7DaysTokens: AttributedTokenStats
    let thisMonthTokens: AttributedTokenStats
    let thisYearTokens: AttributedTokenStats

    var hasAttributedTokens: Bool {
        !todayTokens.isEmpty
            || !last24HoursTokens.isEmpty
            || !last7DaysTokens.isEmpty
            || !thisMonthTokens.isEmpty
            || !thisYearTokens.isEmpty
    }
}
```

```swift
private let ledger = try? UsageLedger.open(
    at: ProfileStore.root.appending(path: "usage.sqlite"))
private let timeline = try? AccountTimelineStore.open(
    at: ProfileStore.root.appending(path: "timeline.sqlite"))

private func refreshUsageImportsIfStale() {
    observeActiveAccounts()
    try? ClaudeTranscriptImporter(
        projectsRoot: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
        ledger: ledger,
        timeline: timeline,
        knownProfileCount: { ClaudeProvider.listProfiles().count }
    ).run()
    try? CodexUsageImporter(
        logsDB: CodexProvider.logsDB,
        ledger: ledger,
        timeline: timeline
    ).run()
}
```

```swift
private struct TokenSummaryRow: View {
    let title: String
    let stats: AttributedTokenStats

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("in \(TokenStats.formatCount(stats.inputTokens))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
            Text("out \(TokenStats.formatCount(stats.outputTokens))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
    }
}
```

```swift
let history = try UsageHistoryQuery(ledger: ledger).snapshot(
    provider: account.provider,
    accountID: accountID,
    now: Date())
let today = history.today
let last24Hours = history.last24Hours
let last7Days = history.last7Days
let thisMonth = history.thisMonth
let thisYear = history.thisYear
```

```swift
VStack(alignment: .leading, spacing: 4) {
    TokenSummaryRow(title: "Today", stats: account.todayTokens)
    TokenSummaryRow(title: "24h", stats: account.last24HoursTokens)
    TokenSummaryRow(title: "7d", stats: account.last7DaysTokens)
    TokenSummaryRow(title: "Month", stats: account.thisMonthTokens)
    TokenSummaryRow(title: "Year", stats: account.thisYearTokens)
}
```

- [ ] **Step 4: Run build plus structure harnesses to verify the integration passes**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swift build -c release
bash Tests/DashboardStructureHarness.sh
```

Expected:

```text
Build complete!
PASS: dashboard header structure
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AccountManager.swift \
  Sources/AIMeter/GlassDashboardView.swift \
  Sources/AIMeter/Diagnostics.swift \
  Tests/DashboardStructureHarness.sh
git commit -m "feat: show per-account token totals"
```

### Task 7: Add Dedicated History Drill-Down For Hourly And Daily Trends

**Files:**
- Create: `Sources/AIMeter/UsageHistoryView.swift`
- Modify: `Sources/AIMeter/GlassDashboardView.swift`
- Modify: `Sources/AIMeter/AccountManager.swift`
- Modify: `Tests/DashboardStructureHarness.sh`

**Interfaces:**
- Consumes: `UsageHistoryQuery`, `Account`
- Produces: history sheet/popover entry point and per-account drill-down for hourly/daily/monthly/yearly trends

- [ ] **Step 1: Add a failing structure assertion for the history entry point**

```bash
rg -q 'History' Sources/AIMeter/GlassDashboardView.swift || {
  echo "FAIL: history entry point is missing" >&2
  exit 1
}
rg -q 'UsageHistoryView' Sources/AIMeter/GlassDashboardView.swift || {
  echo "FAIL: history drill-down view is not wired" >&2
  exit 1
}
```

- [ ] **Step 2: Run the structure harness to verify it fails before the history UI exists**

Run:

```bash
cd /Users/chaos/Github/notch-limits
bash Tests/DashboardStructureHarness.sh
```

Expected: failure mentioning missing history entry point.

- [ ] **Step 3: Implement a drill-down history view with hourly and longer-range sections**

```swift
import SwiftUI

struct UsageHistoryView: View {
    let account: Account
    let hourlySeries: UsageHistoryQuery.Series
    let dailySeries: UsageHistoryQuery.Series
    let monthlySeries: UsageHistoryQuery.Series

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(account.label)
                    .font(.system(size: 12, weight: .semibold))
                HistorySection(title: "Last 24 hours", series: hourlySeries)
                HistorySection(title: "Last 30 days", series: dailySeries)
                HistorySection(title: "This year", series: monthlySeries)
            }
            .padding(14)
        }
        .frame(width: 520, height: 540)
    }
}
```

```swift
Button("History") {
    selectedHistoryAccount = account
}
.sheet(item: $selectedHistoryAccount) { selected in
    UsageHistoryView(
        account: selected,
        hourlySeries: manager.historySeries(for: selected, preset: .last24Hours),
        dailySeries: manager.historySeries(for: selected, preset: .last30Days),
        monthlySeries: manager.historySeries(for: selected, preset: .thisYear))
}
```

- [ ] **Step 4: Re-run the structure harness and verify the history UI wiring passes**

Run:

```bash
cd /Users/chaos/Github/notch-limits
bash Tests/DashboardStructureHarness.sh
```

Expected:

```text
PASS: dashboard header structure
```

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add \
  Sources/AIMeter/UsageHistoryView.swift \
  Sources/AIMeter/GlassDashboardView.swift \
  Sources/AIMeter/AccountManager.swift \
  Tests/DashboardStructureHarness.sh
git commit -m "feat: add usage history drill-down"
```

### Task 8: Document Forward-Only Attribution And Full Verification

**Files:**
- Modify: `README.md`
- Modify: `Sources/AIMeter/Diagnostics.swift`

**Interfaces:**
- Consumes: final importer and ledger behavior
- Produces: clear operator docs and terminal diagnostics for account-attribution debugging

- [ ] **Step 1: Add failing documentation expectations to the final verification checklist**

```bash
rg -q 'Per-account token totals are forward-attributed' README.md || {
  echo "FAIL: README is missing forward-attribution documentation" >&2
  exit 1
}
rg -q 'unattributed' README.md || {
  echo "FAIL: README is missing unattributed usage behavior" >&2
  exit 1
}
```

- [ ] **Step 2: Run the checks to verify the docs are not updated yet**

Run:

```bash
cd /Users/chaos/Github/notch-limits
rg -q 'Per-account token totals are forward-attributed' README.md
```

Expected: non-zero exit status.

- [ ] **Step 3: Update README and diagnostics output**

```markdown
## Token metering

- Per-account token totals are forward-attributed from the first AI Meter run that observes each provider account.
- Claude token totals come from local transcript `usage` rows.
- Codex token totals come from local SSE `response.usage` rows in `~/.codex/logs_2.sqlite`.
- Rows that cannot be tied to exactly one observed account are stored as unattributed and excluded from named account totals.
```

```swift
print("\n[Claude account tokens]")
for account in claudeAccounts {
    print("  \(account.label): today in \(TokenStats.formatCount(account.todayTokens.inputTokens)) out \(TokenStats.formatCount(account.todayTokens.outputTokens))")
    print("    24h in \(TokenStats.formatCount(account.last24HoursTokens.inputTokens)) 7d in \(TokenStats.formatCount(account.last7DaysTokens.inputTokens)) month in \(TokenStats.formatCount(account.thisMonthTokens.inputTokens)) year in \(TokenStats.formatCount(account.thisYearTokens.inputTokens))")
}
print("\n[Codex account tokens]")
for account in codexAccounts {
    print("  \(account.label): today in \(TokenStats.formatCount(account.todayTokens.inputTokens)) out \(TokenStats.formatCount(account.todayTokens.outputTokens))")
    print("    24h in \(TokenStats.formatCount(account.last24HoursTokens.inputTokens)) 7d in \(TokenStats.formatCount(account.last7DaysTokens.inputTokens)) month in \(TokenStats.formatCount(account.thisMonthTokens.inputTokens)) year in \(TokenStats.formatCount(account.thisYearTokens.inputTokens))")
}
print("\n[Unattributed tokens]")
print("  Claude: \(TokenStats.formatCount(unattributedClaude.inputTokens)) / \(TokenStats.formatCount(unattributedClaude.outputTokens))")
print("  Codex: \(TokenStats.formatCount(unattributedCodex.inputTokens)) / \(TokenStats.formatCount(unattributedCodex.outputTokens))")
```

- [ ] **Step 4: Run the full repo verification sequence**

Run:

```bash
cd /Users/chaos/Github/notch-limits
swift build -c release
bash Tests/DashboardStructureHarness.sh
bash Tests/NativeGlassStructureHarness.sh
bash Tests/AppBrandingHarness.sh
swiftc -parse-as-library Sources/AIMeter/StatusItemLifecycle.swift \
  Tests/StatusItemLifecycleHarness.swift \
  -o /tmp/notch-limits-status-item-tests
/tmp/notch-limits-status-item-tests
swiftc -parse-as-library Sources/AIMeter/PopoverPlacement.swift \
  Tests/PopoverPlacementHarness.swift \
  -o /tmp/notch-limits-popover-placement-tests
/tmp/notch-limits-popover-placement-tests
bash Tests/StatusItemStructureHarness.sh
bash Tests/CodexLivePollingStructureHarness.sh
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/UsageHistoryQuery.swift \
  Tests/UsageHistoryHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-history-tests
/tmp/notch-limits-usage-history-tests
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Tests/UsageLedgerHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-usage-ledger-tests
/tmp/notch-limits-usage-ledger-tests
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/ClaudeTranscriptImporter.swift \
  Tests/ClaudeTranscriptImporterHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-claude-import-tests
/tmp/notch-limits-claude-import-tests
swiftc -parse-as-library \
  Sources/AIMeter/Models.swift \
  Sources/AIMeter/AttributedTokenStats.swift \
  Sources/AIMeter/UsageLedger.swift \
  Sources/AIMeter/AccountTimelineStore.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/CodexUsageImporter.swift \
  Tests/CodexUsageImporterHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-codex-usage-tests
/tmp/notch-limits-codex-usage-tests
./build-app.sh release
AIMETER_APP_PATH="AI Meter.app" bash Tests/InstalledStatusItemHarness.sh
```

Expected: every harness prints `PASS: ...`, `swift build -c release` succeeds, and `./build-app.sh release` produces `AI Meter.app`.

- [ ] **Step 5: Commit**

```bash
cd /Users/chaos/Github/notch-limits
git add README.md Sources/AIMeter/Diagnostics.swift
git commit -m "docs: document per-account token attribution"
```

## Coverage Check

- Claude per-account token totals: covered by Tasks 2, 3, 5, 6, 7, 8.
- Codex per-account token totals: covered by Tasks 2, 4, 5, 6, 7, 8.
- Hourly history: covered by Tasks 5, 7, 8.
- Daily/weekly/monthly/yearly history: covered by Tasks 5, 6, 7, 8.
- No-guess attribution rule: covered by Tasks 1, 2, 3, 4, 8.
- UI visibility: covered by Tasks 6 and 7.
- Diagnostics and operator docs: covered by Task 8.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-31-per-account-token-metering.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
