# Remove Token Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove transcript and token-history analytics while preserving provider-reported Claude and Codex limit tracking on a 60-second cadence.

**Architecture:** `AccountManager` remains the single refresh coordinator but owns only account discovery, provider limit polling, cached snapshots, and login/account actions. Delete the analytics storage/import/query stack and remove its model and dashboard consumers. Retain the Codex SQLite rate-limit-header fallback because it reads provider limit metadata rather than token history.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation, SQLite3 only where retained by the Codex rate-limit fallback, shell structure harnesses

## Global Constraints

- Keep the macOS floor at macOS 14.
- Keep Claude OAuth limit polling, Codex app-server limit polling, Codex rate-limit-header fallback, account profiles, switching, reset projection, and snapshot caching.
- Remove all reads beneath `~/.claude/projects`.
- Remove token-event imports from `~/.codex/logs_2.sqlite` while retaining rate-limit-header fallback reads.
- Refresh provider limit data at most once per provider/account per 60 seconds, with existing in-flight guards preventing overlap.
- Preserve unrelated working-tree changes in shared UI and documentation files.
- Do not automatically delete old analytics databases from users' disks.

---

### Task 1: Add The No-Analytics Regression Guard

**Files:**
- Create: `Tests/NoAnalyticsStructureHarness.sh`

**Interfaces:**
- Consumes: production source files under `Sources/AIMeter`
- Produces: a shell test that fails when removed analytics symbols or Claude transcript paths return

- [ ] **Step 1: Write the failing structure harness**

Create an executable shell harness that rejects `ClaudeTranscriptImporter`, `CodexUsageImporter`, `UsageLedger`, `AccountTimelineStore`, `UsageHistoryQuery`, `UsageHistoryView`, `TokenStats`, `AttributedTokenStats`, `.claude/projects`, `todayTokens`, `weekTokens`, and `weeklyPlanSpend` anywhere in production Swift sources.

- [ ] **Step 2: Run the harness to verify it fails**

Run: `bash Tests/NoAnalyticsStructureHarness.sh`

Expected: non-zero exit naming at least one analytics reference.

- [ ] **Step 3: Leave the failing guard in place for Task 2**

Do not weaken the rejected symbol set. Task 2 removes the production references that make this test fail.

### Task 2: Remove Analytics Runtime, Models, And UI

**Files:**
- Modify: `Sources/AIMeter/AccountManager.swift`
- Modify: `Sources/AIMeter/Models.swift`
- Modify: `Sources/AIMeter/GlassDashboardView.swift`
- Modify: `Sources/AIMeter/Diagnostics.swift`
- Delete: `Sources/AIMeter/AccountTimelineStore.swift`
- Delete: `Sources/AIMeter/AttributedTokenStats.swift`
- Delete: `Sources/AIMeter/ClaudeTranscriptImporter.swift`
- Delete: `Sources/AIMeter/CodexUsageImporter.swift`
- Delete: `Sources/AIMeter/TokenStats.swift`
- Delete: `Sources/AIMeter/UsageHistoryQuery.swift`
- Delete: `Sources/AIMeter/UsageHistoryView.swift`
- Delete: `Sources/AIMeter/UsageLedger.swift`
- Delete: `Tests/AccountTimelineStoreHarness.swift` if present
- Delete: `Tests/ClaudeTranscriptImporterHarness.swift`
- Delete: `Tests/CodexUsageImporterHarness.swift`
- Delete: `Tests/UsageHistoryHarness.swift`
- Delete: `Tests/UsageLedgerHarness.swift`
- Modify: `Tests/DashboardStructureHarness.sh`
- Test: `Tests/NoAnalyticsStructureHarness.sh`

**Interfaces:**
- Consumes: `ClaudeProvider.fetchUsage(token:)`, `CodexRateLimitClient.fetchSnapshot()`, `CodexProvider.latestSnapshot()`, and `SnapshotCache`
- Produces: provider-only `AccountManager.refresh()` and analytics-free `Account` and dashboard views

- [ ] **Step 1: Remove analytics orchestration from `AccountManager`**

Delete analytics stores, import/scan timestamps, in-flight flags, published token totals, `weeklyPlanSpend`, `applyTokenStats`, `usageSnapshot`, `historySeries`, `importUsageIfStale`, `scanTokensIfStale`, and `observeActiveAccounts`. Make the repeating timer 60 seconds. Change Claude and Codex freshness comparisons from 300 seconds to 60 seconds while retaining the existing in-flight guards and account-change bypass.

- [ ] **Step 2: Remove analytics fields from `Account`**

Delete `usageAccountID`, all attributed-token fields, their initializer parameters and assignments, relabel-copy forwarding, and `hasAttributedTokens`. Keep provider, identity, plan, active state, windows, status, headroom, and demo relabeling.

- [ ] **Step 3: Remove analytics UI and diagnostics**

Delete the dashboard History state, sheet, callbacks, button, token summary rows, and history series calls. Remove analytics-only diagnostic output while retaining provider/profile/snapshot diagnostics. Update `DashboardStructureHarness.sh` so it no longer requires history UI and explicitly rejects it.

- [ ] **Step 4: Delete analytics implementation and harness files**

Delete the files listed above. Do not delete `CodexProvider.swift`, `SnapshotCache.swift`, or their tests because they implement limit readings.

- [ ] **Step 5: Run focused tests**

Run:

```bash
bash Tests/NoAnalyticsStructureHarness.sh
bash Tests/DashboardStructureHarness.sh
bash Tests/CodexLivePollingStructureHarness.sh
```

Expected: all three print `PASS` and exit zero.

### Task 3: Align Documentation And Verify The Product

**Files:**
- Modify: `README.md`
- Delete: `docs/superpowers/plans/2026-07-31-per-account-token-metering.md`
- Test: all retained harnesses and release build

**Interfaces:**
- Consumes: the provider-only implementation from Task 2
- Produces: accurate product documentation and a verified release binary

- [ ] **Step 1: Remove analytics documentation**

Remove token-history, transcript analytics, API-equivalent dollar, usage-ledger, and history-view claims. Document that Claude limits use the app's OAuth login and Anthropic-hosted usage endpoint, while live Codex limits require an installed Codex executable and retain the local rate-limit-header fallback.

- [ ] **Step 2: Run every retained harness**

Run the build-and-test commands documented in `README.md`, plus `bash Tests/NoAnalyticsStructureHarness.sh`.

Expected: every command exits zero and each harness prints `PASS`.

- [ ] **Step 3: Build the release app**

Run: `./build-app.sh`

Expected: release compilation succeeds and produces an `AI Meter.app` bundle without any deleted analytics source.

- [ ] **Step 4: Verify the source and built binary contain no analytics paths**

Run:

```bash
rg -n '\.claude/projects|ClaudeTranscriptImporter|UsageHistoryView|UsageLedger' Sources/AIMeter Tests/NoAnalyticsStructureHarness.sh
strings .build/release/AIMeter | rg '\.claude/projects|ClaudeTranscriptImporter|UsageHistoryView|UsageLedger'
```

Expected: the source search matches only the negative-test patterns, and the binary search has no matches.

- [ ] **Step 5: Inspect the final diff**

Confirm the diff contains only analytics removal, the 60-second polling change, aligned tests/docs, and pre-existing user changes preserved in shared files.

