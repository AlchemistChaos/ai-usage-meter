# Live Codex Rate Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AI Meter's Codex dashboard and menu-bar percentage track the installed Codex client's current `account/rateLimits/read` response.

**Architecture:** Add a focused stdio JSON-RPC client that launches the installed Codex app-server for each bounded poll and converts its response into the existing `CodexProvider.Snapshot`. `AccountManager` polls that client for the active account every five minutes, caches successful snapshots, and keeps the current SQLite reader as a non-destructive fallback.

**Tech Stack:** Swift 5.9, Foundation `Process`/`Pipe`, Codex app-server JSON-RPC v2, SQLite fallback, shell and Swift harness tests.

## Global Constraints

- Support macOS 14 and the repository's existing Swift 5.9 package.
- Poll only the active Codex account and never mutate Codex credentials.
- Time out and terminate helper processes; never block the main actor.
- Preserve cached inactive-account snapshots and the legacy SQLite fallback.
- A stale or failed result must never overwrite a newer cached snapshot.

---

## File structure

- Create `Sources/AIMeter/CodexRateLimitClient.swift`: app-server request construction, response decoding, timeout-bounded process transport.
- Create `Tests/CodexRateLimitClientHarness.swift`: pure request/response regression coverage.
- Create `Tests/CodexLivePollingStructureHarness.sh`: verifies manager wiring, throttling, account checks, and fallback retention.
- Modify `Sources/AIMeter/AccountManager.swift`: active-account live polling and cache/UI refresh.
- Modify `Sources/AIMeter/Diagnostics.swift`: report the live Codex source separately from the fallback.
- Modify `README.md`: document the live source, fallback, and verification commands.

### Task 1: Decode current Codex app-server rate limits

**Files:**
- Create: `Tests/CodexRateLimitClientHarness.swift`
- Create: `Sources/AIMeter/CodexRateLimitClient.swift`

**Interfaces:**
- Consumes: `CodexProvider.Snapshot`, `UsageWindow`, and the existing window-label conventions.
- Produces: `CodexRateLimitClient.decodeSnapshot(from:capturedAt:) throws -> CodexProvider.Snapshot?` and `CodexRateLimitClient.requestPayload() -> Data`.

- [ ] **Step 1: Write the failing parser/request harness**

Create a harness with a real v2 response fixture. It must assert that request payload lines contain `initialize` request ID `1` and `account/rateLimits/read` request ID `2`; a response with ID `2`, `usedPercent: 76`, `windowDurationMins: 10080`, and `planType: "pro"` becomes one `Weekly` window with 24 percent remaining; a notification and response ID `1` return `nil`; malformed JSON and JSON-RPC `error` objects throw.

```swift
let snapshot = try CodexRateLimitClient.decodeSnapshot(
    from: Data(response.utf8), capturedAt: capturedAt)
expect(snapshot?.windows.first?.label == "Weekly", "10,080 minutes is weekly")
expect(snapshot?.windows.first?.remainingPercent == 24, "live response is authoritative")
expect(snapshot?.plan == "pro", "plan type should be retained")
```

- [ ] **Step 2: Run the harness and verify RED**

Run:

```bash
swiftc Sources/AIMeter/Models.swift Sources/AIMeter/CodexProvider.swift \
  Tests/CodexRateLimitClientHarness.swift -lsqlite3 \
  -o /tmp/notch-limits-codex-rate-limit-tests
```

Expected: compilation fails because `CodexRateLimitClient` does not exist.

- [ ] **Step 3: Implement the minimal decoder and request payload**

Define Codable envelopes matching the current protocol and accept only response ID `2`:

```swift
enum CodexRateLimitClient {
    static let rateLimitRequestID = 2

    static func requestPayload() -> Data {
        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-meter","version":"0.1"}}}"#
        let limits = #"{"id":2,"method":"account/rateLimits/read","params":null}"#
        return Data("\(initialize)\n\(limits)\n".utf8)
    }

    static func decodeSnapshot(
        from data: Data,
        capturedAt: Date
    ) throws -> CodexProvider.Snapshot? {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.id == rateLimitRequestID else { return nil }
        if let error = response.error {
            throw ClientError.protocolError(error.message)
        }
        guard let limits = response.result?.rateLimits else {
            throw ClientError.invalidResponse
        }
        let windows = [limits.primary, limits.secondary].compactMap { window in
            guard let window, let minutes = window.windowDurationMins,
                  minutes > 0 else { return nil }
            return UsageWindow(
                label: label(for: minutes),
                usedPercent: Double(window.usedPercent),
                windowMinutes: minutes,
                resetsAt: window.resetsAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                })
        }
        guard !windows.isEmpty else { throw ClientError.invalidResponse }
        return CodexProvider.Snapshot(
            windows: windows,
            plan: limits.planType,
            capturedAt: capturedAt)
    }
}
```

Use the existing labels (`5h`, `Daily`, `Weekly`, or duration-derived labels), convert Unix `resetsAt` seconds to `Date`, omit null/zero-duration windows, and throw a localized protocol error for a matching JSON-RPC error or missing `rateLimits` result.

- [ ] **Step 4: Run the harness and verify GREEN**

Run the compile command above, followed by:

```bash
/tmp/notch-limits-codex-rate-limit-tests
```

Expected: `PASS: Codex app-server rate-limit parsing`.

- [ ] **Step 5: Commit the parser**

```bash
git add Sources/AIMeter/CodexRateLimitClient.swift Tests/CodexRateLimitClientHarness.swift
git commit -m "feat: parse live Codex rate limits"
```

### Task 2: Fetch a snapshot through a bounded app-server process

**Files:**
- Modify: `Sources/AIMeter/CodexRateLimitClient.swift`
- Modify: `Tests/CodexRateLimitClientHarness.swift`

**Interfaces:**
- Consumes: `CodexLogin.executableURL() -> URL?`, `requestPayload()`, and `decodeSnapshot(from:capturedAt:)`.
- Produces: `CodexRateLimitClient.fetchSnapshot(timeout:) async throws -> CodexProvider.Snapshot`.

- [ ] **Step 1: Extend the harness with executable and transport-boundary behavior**

Add assertions that the client exposes arguments exactly equal to `['app-server', '--listen', 'stdio://']`, and that a stream containing initialization output, an unrelated notification, and then response ID `2` selects the rate-limit response. This keeps protocol framing testable independently of a real network request.

- [ ] **Step 2: Run the harness and verify RED**

Compile with `Sources/AIMeter/CodexLogin.swift` added. Expected: failure because `appServerArguments` and stream decoding are absent.

- [ ] **Step 3: Implement the timeout-bounded transport**

Add:

```swift
static let appServerArguments = ["app-server", "--listen", "stdio://"]

static func fetchSnapshot(
    timeout: TimeInterval = 10
) async throws -> CodexProvider.Snapshot
```

Run blocking process I/O on a utility dispatch queue. Launch the URL returned by `CodexLogin.executableURL()`, write the two JSON-RPC lines while keeping stdin open, use `poll(2)` against stdout until the deadline, decode complete newline-delimited messages, and return response ID `2`. In every exit path, close stdin, clear pipes, and terminate a still-running process. Include bounded stderr text in errors without logging credentials or complete environment state.

- [ ] **Step 4: Run parser harness and a live client probe**

Expected harness output: `PASS: Codex app-server rate-limit parsing`.

Add a temporary diagnostic entry point through `Diagnostics.run()` only in Task 4; for this task, verify the package compiles:

```bash
swift build
```

Expected: `Build complete!` with exit code 0.

- [ ] **Step 5: Commit the transport**

```bash
git add Sources/AIMeter/CodexRateLimitClient.swift Tests/CodexRateLimitClientHarness.swift
git commit -m "feat: fetch Codex limits from app server"
```

### Task 3: Poll live limits for the active account

**Files:**
- Create: `Tests/CodexLivePollingStructureHarness.sh`
- Modify: `Sources/AIMeter/AccountManager.swift`

**Interfaces:**
- Consumes: `CodexRateLimitClient.fetchSnapshot(timeout:)` and `SnapshotCache.put(accountID:snapshot:)`.
- Produces: a five-minute live poll that republishes `accounts` after caching a successful current-account snapshot.

- [ ] **Step 1: Write the failing manager-wiring harness**

The shell harness must verify that `AccountManager` has `lastCodexPoll`, `lastCodexPollAccountID`, and `codexPollInFlightAccountID`; calls `pollCodexUsageIfStale()` from `refresh()`; invokes `CodexRateLimitClient.fetchSnapshot`; confirms the active account ID still matches before caching; and leaves the existing `CodexProvider.latestSnapshot()` fallback in `codexAccounts()`.

- [ ] **Step 2: Run the structure harness and verify RED**

Run:

```bash
bash Tests/CodexLivePollingStructureHarness.sh
```

Expected: failure naming the first missing live-polling field or call.

- [ ] **Step 3: Implement account-aware polling**

Add poll state and call it after the first synchronous account rebuild:

```swift
private var lastCodexPoll: Date?
private var lastCodexPollAccountID: String?
private var codexPollInFlightAccountID: String?
```

The poll starts immediately for a new account or after five minutes for the same account. Capture the requested account ID before fetching; if the active credential changes before completion, discard the result. On success, cache the live snapshot and rebuild the account rows so `StatusItemController` receives the published change. On failure, retain cached values, throttle retries for that account, and publish a concise provider error. Ensure Claude success cannot erase a current Codex error by combining provider-specific error strings.

- [ ] **Step 4: Run the structure harness, Swift harnesses, and debug build**

Run:

```bash
bash Tests/CodexLivePollingStructureHarness.sh
/tmp/notch-limits-codex-rate-limit-tests
swift build
```

Expected: both harnesses print `PASS` and the build exits 0.

- [ ] **Step 5: Commit manager integration**

```bash
git add Sources/AIMeter/AccountManager.swift Tests/CodexLivePollingStructureHarness.sh
git commit -m "fix: refresh active Codex usage live"
```

### Task 4: Diagnostics and documentation

**Files:**
- Modify: `Sources/AIMeter/Diagnostics.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `CodexRateLimitClient.fetchSnapshot(timeout:)`.
- Produces: `--diagnose` output that distinguishes live app-server data from SQLite fallback data.

- [ ] **Step 1: Add failing structural assertions**

Extend `Tests/CodexLivePollingStructureHarness.sh` to require diagnostic labels `live app-server usage` and `SQLite fallback usage`, and require the README to mention `account/rateLimits/read`.

- [ ] **Step 2: Run the harness and verify RED**

Expected: failure because diagnostics and documentation still describe SQLite as the only Codex source.

- [ ] **Step 3: Update diagnostics and README**

Make diagnostics asynchronous before the AppKit run loop starts, print the live snapshot when available, print a concise live error otherwise, and always print the legacy fallback separately. Update the usage and limitations sections and add the new harness command to the verification block.

- [ ] **Step 4: Run diagnostics against the installed Codex client**

Run:

```bash
swift run AIMeter --diagnose
```

Expected: live Codex output reports the same weekly `usedPercent` as a direct `account/rateLimits/read` query, and the fallback is clearly timestamped separately.

- [ ] **Step 5: Commit diagnostics and docs**

```bash
git add Sources/AIMeter/Diagnostics.swift README.md Tests/CodexLivePollingStructureHarness.sh
git commit -m "docs: describe live Codex usage source"
```

### Task 5: Full verification and local installation

**Files:**
- Modify only if verification exposes a defect in the preceding scoped changes.

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: a verified and locally installed AI Meter bundle whose menu label tracks live Codex quota.

- [ ] **Step 1: Run the repository's complete verification suite**

Run every command in README's build-and-verify section, including the new Codex live polling harness, then run `git diff --check` and `swift build -c release`.

- [ ] **Step 2: Build the application bundle without installing**

Run:

```bash
./build-app.sh release
```

Expected: `Built AI Meter.app`, a valid ad-hoc signature, and exit code 0.

- [ ] **Step 3: Verify live behavior from the built bundle**

Run:

```bash
"AI Meter.app/Contents/MacOS/AIMeter" --diagnose
```

Expected: live app-server usage has a current timestamp and the current Codex weekly percentage.

- [ ] **Step 4: Install and relaunch only after safety checks**

Run the desktop-app safety checklist, then:

```bash
./build-app.sh release --install
```

Confirm the installed status-item harness passes and inspect the menu label after the first live poll. It must show the current remaining percentage rather than the old cached 66.

- [ ] **Step 5: Commit any verification-only corrections**

If verification required scoped corrections, commit only those files with a message describing the corrected behavior. Otherwise leave the task commits unchanged.
