# All-Account Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show fresh subscription-limit usage for every enrolled Claude and Codex account simultaneously without profile collisions or changes to the active Claude Code login.

**Architecture:** Store Claude profiles by Anthropic account UUID in a dedicated `ClaudeProfileStore`, with explicit credential provenance separating AI Meter-owned OAuth chains from Claude Code-owned credentials. Poll every saved Claude token directly and every saved Codex credential through an isolated official `codex app-server`, then deduplicate presentation by provider account ID.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, Foundation `URLSession`, Security framework, official Codex app-server JSON-RPC, shell and standalone Swift test harnesses.

## Global Constraints

- Modify only `AlchemistChaos/ai-usage-meter`; do not modify the old fork or upstream Notch Limits.
- Preserve macOS 14 as the minimum supported version and bundle identifier `com.alchemistchaos.aimeter`.
- Claude is view-only: never import, activate, overwrite, or refresh Claude Code-owned credentials.
- New Claude profiles are keyed by Anthropic account UUID; full email is display metadata only.
- Credential files use `0600`; credential directories use `0700`; writes and migrations are atomic and backed up.
- Poll at most once per minute per account with bounded concurrency and account-scoped errors.
- Keep existing Codex explicit switching and backups, but do not require switching for background polling.

---

### Task 1: UUID-Keyed Claude Profile Store and Migration

**Files:**
- Create: `Sources/AIMeter/ClaudeProfileStore.swift`
- Create: `Tests/ClaudeProfileStoreHarness.swift`
- Modify: `Sources/AIMeter/ClaudeProvider.swift:254-331`
- Modify: `Sources/AIMeter/ClaudeOAuth.swift:209-231`

**Interfaces:**
- Produces `ClaudeProfileStore.Record`, `list(root:)`, `record(accountUUID:root:)`, `credentialURL(accountUUID:root:)`, `saveCredential(_:identity:origin:root:)`, and `migrateLegacyProfiles(root:)`.
- `ClaudeAuthOrigin` has exact raw values `appOAuth` and `legacy`.
- `ClaudeProvider` and `ClaudeOAuth` consume these APIs; no caller constructs a profile path from email.

- [ ] **Step 1: Write the failing profile-store harness**

Create fixtures for `river@ultima.inc`/UUID `account-a` and `river@gmail.com`/UUID `account-b`. Assert their URLs differ, re-saving `account-a` leaves exactly two records, permissions are `0600`, and migration of two legacy folders with the same UUID is idempotent and creates backups.

```swift
let first = try ClaudeProfileStore.saveCredential(
    credential("account-a", "river@ultima.inc", expiresAt: 100),
    identity: .init(accountUUID: "account-a", email: "river@ultima.inc", plan: "max"),
    origin: .appOAuth,
    root: root)
let second = try ClaudeProfileStore.saveCredential(
    credential("account-b", "river@gmail.com", expiresAt: 200),
    identity: .init(accountUUID: "account-b", email: "river@gmail.com", plan: "max"),
    origin: .appOAuth,
    root: root)
expect(first != second, "UUIDs, not email prefixes, must define profile paths")
expect(ClaudeProfileStore.list(root: root).map(\.identity.email).sorted()
       == ["river@gmail.com", "river@ultima.inc"],
       "same-prefix emails must remain visible together")
```

- [ ] **Step 2: Run the harness and verify RED**

Run:

```bash
swiftc -parse-as-library Sources/AIMeter/ClaudeProfileStore.swift \
  Tests/ClaudeProfileStoreHarness.swift -o /tmp/ai-meter-claude-profile-tests
```

Expected: compilation fails because `ClaudeProfileStore` and `ClaudeAuthOrigin` do not exist.

- [ ] **Step 3: Implement the minimal UUID store and migration**

Use these exact public shapes:

```swift
enum ClaudeAuthOrigin: String { case appOAuth, legacy }

enum ClaudeProfileStore {
    struct Identity: Equatable {
        let accountUUID: String
        let email: String?
        let plan: String?
    }
    struct Record {
        let identity: Identity
        let origin: ClaudeAuthOrigin
        let credentialURL: URL
        let expiresAt: Date?
    }

    static func credentialURL(accountUUID: String, root: URL = ProfileStore.root) -> URL
    static func list(root: URL = ProfileStore.root) -> [Record]
    static func record(accountUUID: String, root: URL = ProfileStore.root) -> Record?
    static func saveCredential(
        _ data: Data, identity: Identity, origin: ClaudeAuthOrigin,
        root: URL = ProfileStore.root
    ) throws -> URL
    static func migrateLegacyProfiles(root: URL = ProfileStore.root) throws
}
```

`saveCredential` must parse the JSON object, set `_ccmanagerIdentity`, set `_ccmanagerAuth` to `origin/schemaVersion`, write a same-directory temporary file, chmod it to `0600`, then replace the destination. Migration backs up before moving and retains the later `claudeAiOauth.expiresAt` when duplicate UUIDs exist.

- [ ] **Step 4: Route existing Claude profile access through the new store**

Replace `ClaudeProvider.profileFile/listProfiles/storedProfile` path logic with `ClaudeProfileStore.list()`. Change `ClaudeOAuth.saveProfile` to serialize the OAuth payload and call:

```swift
try ClaudeProfileStore.saveCredential(
    out,
    identity: .init(
        accountUUID: profile.accountUuid,
        email: profile.email,
        plan: profile.plan),
    origin: .appOAuth)
```

Run migration once from `AccountManager.init()` before `refresh()`.

- [ ] **Step 5: Run tests and commit**

Run the new harness twice, then `swift build -c debug` and existing `Tests/ClaudeProviderHarness.swift`. Expected: all pass and the second migration run makes no changes.

```bash
git add Sources/AIMeter/ClaudeProfileStore.swift Sources/AIMeter/ClaudeProvider.swift \
  Sources/AIMeter/ClaudeOAuth.swift Sources/AIMeter/AccountManager.swift \
  Tests/ClaudeProfileStoreHarness.swift
git commit -m "fix: key Claude profiles by account UUID"
```

### Task 2: Refresh Only AI Meter-Owned Claude OAuth Chains

**Files:**
- Modify: `Sources/AIMeter/ClaudeOAuth.swift:114-159`
- Modify: `Sources/AIMeter/ClaudeProvider.swift:288-384`
- Modify: `Tests/ClaudeProviderHarness.swift`
- Modify: `Tests/NoTokenRotationHarness.sh`
- Modify: `Tests/ClaudeAuthStructureHarness.sh`

**Interfaces:**
- Produces `ClaudeOAuth.refreshRequest(refreshToken:)`, `decodeRefreshResponse(data:statusCode:existing:)`, and `ClaudeProvider.usableToken(for:) async`.
- Consumes `ClaudeProfileStore.Record.origin`; only `.appOAuth` may call the refresh grant.

- [ ] **Step 1: Add failing refresh and provenance tests**

Add pure tests that an expired `.appOAuth` record creates a POST to `https://api.anthropic.com/v1/oauth/token`, rotated token JSON retains identity/origin, and an expired `.legacy` record throws authentication-required without producing a refresh request.

```swift
let request = try ClaudeOAuth.refreshRequest(refreshToken: "refresh-one")
expect(request.url?.absoluteString == "https://api.anthropic.com/v1/oauth/token",
       "app-owned refresh must use Anthropic's API token endpoint")
expect(String(data: request.httpBody!, encoding: .utf8)!.contains("refresh_token"),
       "refresh request must carry the app-owned refresh grant")
```

- [ ] **Step 2: Run tests and verify RED**

Run the Claude provider harness. Expected: compilation fails because the refresh helpers do not exist. Run `Tests/NoTokenRotationHarness.sh`; it should fail after its new provenance assertions are added because no guarded refresh path exists.

- [ ] **Step 3: Implement guarded refresh**

Move refresh request construction and response decoding into `ClaudeOAuth`. In `ClaudeProvider.usableToken(for:)`, return an unexpired token; for an expired `.legacy` token, throw `.userAuthenticationRequired`; for an expired `.appOAuth` token, perform one refresh, atomically persist the rotated response through `ClaudeProfileStore.saveCredential`, then return the persisted token.

The production guard must be structurally explicit:

```swift
guard record.origin == .appOAuth else {
    throw URLError(.userAuthenticationRequired)
}
let refreshed = try await ClaudeOAuth.refresh(tokens: token)
try ClaudeProfileStore.saveCredential(
    refreshed.credentialData,
    identity: record.identity,
    origin: .appOAuth)
```

The active Claude Code path continues calling only `freshClaudeCodeToken()` and never invokes this function.

- [ ] **Step 4: Update the safety harness**

Replace the blanket prohibition on `grant_type=refresh_token` with assertions that the grant exists only in `ClaudeOAuth.swift`, every invocation is behind `record.origin == .appOAuth`, and no Claude import/activate/write-to-Keychain path exists.

- [ ] **Step 5: Run tests and commit**

Run both Claude Swift harnesses, both auth structure harnesses, and `swift build -c debug`. Expected: all pass.

```bash
git add Sources/AIMeter/ClaudeOAuth.swift Sources/AIMeter/ClaudeProvider.swift \
  Tests/ClaudeProviderHarness.swift Tests/NoTokenRotationHarness.sh \
  Tests/ClaudeAuthStructureHarness.sh
git commit -m "fix: refresh only meter-owned Claude profiles"
```

### Task 3: Poll and Present Every Claude Account Independently

**Files:**
- Modify: `Sources/AIMeter/AccountManager.swift:210-390,410-465`
- Modify: `Sources/AIMeter/GlassDashboardView.swift`
- Modify: `Tests/AccountPresentationHarness.swift`
- Create: `Tests/AllClaudeAccountsStructureHarness.sh`

**Interfaces:**
- Consumes UUID-keyed `ClaudeProfileStore.Record` values and async `ClaudeProvider.usableToken(for:)`.
- Produces one `Account` per UUID, `pendingClaudeReconnectUUID`, and `beginClaudeReconnect(accountUUID:browser:)`.

- [ ] **Step 1: Add failing account aggregation and reconnect tests**

Add presentation fixtures for two inactive same-prefix emails and one active UUID matching a stored profile. Assert two total cards remain, the matching active UUID deduplicates, and an error on one UUID leaves the other account usable. Add a structure harness requiring reconnect to compare returned UUID before saving.

- [ ] **Step 2: Run tests and verify RED**

Run `Tests/AccountPresentationHarness.swift` and the new shell harness. Expected: the aggregation fixture fails because existing profile names are path labels and reconnect has no UUID target.

- [ ] **Step 3: Implement UUID aggregation and account-scoped polling**

Build Claude accounts from a `[String: Account]` dictionary keyed by UUID. Merge the active Claude Code identity into its matching stored record instead of appending a second card. Poll saved records with a task group limited to four concurrent tasks and apply each result/error by UUID; never clear the entire Claude array because one task fails.

```swift
var byUUID: [String: Account] = [:]
for record in ClaudeProfileStore.list() {
    byUUID[record.identity.accountUUID] = claudeAccount(record: record, isActive: false)
}
if let active = ClaudeProvider.identity() {
    byUUID[active.accountUuid] = claudeAccount(
        record: ClaudeProfileStore.record(accountUUID: active.accountUuid),
        activeIdentity: active,
        isActive: true)
}
```

- [ ] **Step 4: Implement targeted reconnect UI**

Retain the selected UUID when reconnect begins. After OAuth profile lookup, require equality before calling `saveCredential`; otherwise show `Authenticated <email>, expected <email>. Retry with the intended account.` and leave both files untouched. Add a Reconnect button only to `.reconnectRequired` Claude cards.

- [ ] **Step 5: Run tests and commit**

Run AccountPresentation, ClaudeProvider, the new structure harness, dashboard structure tests, and `swift build -c debug`. Expected: all pass.

```bash
git add Sources/AIMeter/AccountManager.swift Sources/AIMeter/GlassDashboardView.swift \
  Tests/AccountPresentationHarness.swift Tests/AllClaudeAccountsStructureHarness.sh
git commit -m "feat: show all Claude account limits together"
```

### Task 4: Poll Every Saved Codex Profile Through Isolated App Servers

**Files:**
- Modify: `Sources/AIMeter/CodexRateLimitClient.swift:1-222`
- Modify: `Sources/AIMeter/AccountManager.swift:54-210`
- Modify: `Tests/CodexRateLimitClientHarness.swift`
- Create: `Tests/AllCodexAccountsHarness.swift`

**Interfaces:**
- Produces `CodexRateLimitClient.Result { accountID, snapshot }` and `fetchResult(codexHome:expectedAccountID:timeout:)`.
- Consumes each saved profile directory as isolated `CODEX_HOME`; rejects identity mismatches.

- [ ] **Step 1: Add failing isolated-environment and identity tests**

Assert a prepared process receives `CODEX_HOME` and `CODEX_SQLITE_HOME` equal to the selected profile directory, request payload includes `account/read` and `account/rateLimits/read`, a matching account ID returns a result, and a mismatched account ID throws `identityMismatch`.

- [ ] **Step 2: Run tests and verify RED**

Run the Codex rate-limit harness. Expected: compilation fails because `Result`, isolated home arguments, and identity validation do not exist.

- [ ] **Step 3: Extend the app-server exchange**

Send three JSON-RPC requests after initialize: `account/read` and `account/rateLimits/read`. Decode the account response's `account.id`, retain the rate-limit response, and return only after both exist. Add:

```swift
struct Result { let accountID: String; let snapshot: CodexProvider.Snapshot }
static func fetchResult(
    codexHome: URL?, expectedAccountID: String?, timeout: TimeInterval = 10
) async throws -> Result
```

When `codexHome` is non-nil, set both environment variables on the child process. Before launch, copy no credentials and modify no live files.

- [ ] **Step 4: Poll all saved Codex records**

In `AccountManager`, start one bounded background poll per distinct saved account ID, using the parent directory of that profile's `auth.json` as `CODEX_HOME`. Cache successful snapshots by returned account ID. Keep existing live-active polling and explicit switching, deduplicating by account ID.

- [ ] **Step 5: Run tests and commit**

Run CodexRateLimitClient, CodexLogin, the new all-accounts harness, existing live polling structure tests, and `swift build -c debug`. Expected: all pass and the live `~/.codex/auth.json` hash remains unchanged.

```bash
git add Sources/AIMeter/CodexRateLimitClient.swift Sources/AIMeter/AccountManager.swift \
  Tests/CodexRateLimitClientHarness.swift Tests/AllCodexAccountsHarness.swift
git commit -m "feat: poll all Codex profiles without switching"
```

### Task 5: Diagnostics, Documentation, Release Build, and Installation

**Files:**
- Modify: `Sources/AIMeter/Diagnostics.swift:1-120`
- Modify: `README.md`
- Modify: `Tests/InstalledStatusItemHarness.sh`
- Modify: `docs/superpowers/specs/2026-08-30-all-account-usage-design.md` only if implementation reveals an approved deviation

**Interfaces:**
- Diagnostics print account labels, UUID prefixes, origins, freshness, and errors; never tokens or auth codes.
- The installed app is produced by `./build-app.sh release --install`.

- [ ] **Step 1: Add failing diagnostic/privacy assertions**

Extend structure tests to require UUID-prefix/origin/freshness diagnostics and prohibit `accessToken`, `refreshToken`, Authorization headers, and full UUIDs in diagnostic output.

- [ ] **Step 2: Run tests and verify RED**

Run the diagnostics/privacy harnesses. Expected: fail because profile origin and all-account freshness are not yet printed.

- [ ] **Step 3: Update diagnostics and README**

Document UUID-keyed Claude enrollment, live all-account Codex polling, reconnect semantics, migration, and the Claude Code read-only boundary. Diagnostics print one line per profile using only `String(uuid.prefix(8)) + "…"`.

- [ ] **Step 4: Run the complete verification suite**

Run every command listed in README's Build and Verify section plus the new harnesses, then:

```bash
swift build -c release
./build-app.sh release
AIMETER_APP_PATH="AI Meter.app" bash Tests/InstalledStatusItemHarness.sh
git diff --check
```

Expected: all commands exit zero with no compiler warnings or test failures.

- [ ] **Step 5: Install and smoke-test without altering credentials**

Record SHA-256 hashes of `~/.claude/.credentials.json` when present, the `Claude Code-credentials` Keychain item's modification metadata, and `~/.codex/auth.json`. Run `./build-app.sh release --install`, launch AI Meter, execute `AIMeter --diagnose`, and confirm the recorded live credential hashes/metadata are unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/AIMeter/Diagnostics.swift README.md Tests/InstalledStatusItemHarness.sh
git commit -m "docs: verify all-account usage installation"
```

Do not push commits or create a release unless the user explicitly requests it.
