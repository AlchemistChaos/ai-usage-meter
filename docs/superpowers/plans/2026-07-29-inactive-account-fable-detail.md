# Inactive Account Fable Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Include Fable and other model-specific usage windows in the clicked inactive-account detail popover without changing compact cards.

**Architecture:** Add one pure presentation helper that orders primary, short, and remaining windows without duplication. Wire the existing SwiftUI reset-detail popover to that helper; the live Claude provider already supplies Fable.

**Tech Stack:** Swift 6, SwiftUI, Foundation, shell structure harnesses.

## Global Constraints

- Change only the standalone AI Meter macOS app.
- Do not change compact account-card contents or layout.
- Do not change Claude polling, authentication, profiles, or cached usage.
- Keep clicked detail order as primary long window, short window, then remaining provider windows.
- Do not duplicate any window.
- Preserve existing reset and empty-state copy.
- Add no dependency.

---

### Task 1: Include all windows in clicked account detail

**Files:**
- Modify: `Tests/AccountPresentationHarness.swift`
- Modify: `Tests/DashboardStructureHarness.sh`
- Modify: `Sources/AIMeter/AccountPresentation.swift`
- Modify: `Sources/AIMeter/GlassDashboardView.swift`

**Interfaces:**
- Produces: `AccountPresentation.detailWindows(for account: Account) -> [UsageWindow]`
- Consumes: existing `primaryWindow(for:)`, `shortWindow(for:excluding:)`, and `Account.windows`.

- [ ] **Step 1: Write the failing presentation assertion**

Add this case after the existing primary/short assertions in `Tests/AccountPresentationHarness.swift`:

```swift
let fable = window("Fable wk", minutes: 10_080, used: 64)
let claudeWithFable = account(
    .claude, "claude-fable", active: false,
    windows: [fiveHour, weekly, fable])
expect(
    AccountPresentation.detailWindows(for: claudeWithFable).map(\.label)
        == ["Weekly", "5h", "Fable wk"],
    "clicked account detail should include model-specific windows")
```

- [ ] **Step 2: Require the detail popover to use the helper**

Add this assertion before the final PASS line in `Tests/DashboardStructureHarness.sh`:

```bash
rg -Fq 'let windows = AccountPresentation.detailWindows(for: account)' "$view" || {
  echo "FAIL: inactive account detail should include every provider window" >&2
  exit 1
}
```

- [ ] **Step 3: Run both tests and verify RED**

Run:

```bash
swiftc Sources/AIMeter/Models.swift \
  Sources/AIMeter/MenuBarPreferences.swift \
  Sources/AIMeter/AccountPresentation.swift \
  Tests/AccountPresentationHarness.swift \
  -o /tmp/notch-limits-fable-presentation-tests
bash Tests/DashboardStructureHarness.sh
```

Expected: the Swift harness fails to compile because `detailWindows(for:)` is missing, and the structure harness fails because the popover does not call it.

- [ ] **Step 4: Implement ordered, deduplicated detail windows**

Add this method after `shortWindow(for:excluding:)` in `AccountPresentation.swift`:

```swift
static func detailWindows(for account: Account) -> [UsageWindow] {
    let primary = primaryWindow(for: account)
    let short = shortWindow(for: account, excluding: primary)
    var windows = [primary, short].compactMap { $0 }
    let featuredIDs = Set(windows.map(\.id))
    windows.append(contentsOf: account.windows.filter {
        !featuredIDs.contains($0.id)
    })
    return windows
}
```

- [ ] **Step 5: Wire the SwiftUI detail popover**

Replace the local primary/short/window construction at the start of `ResetDetailsPopover.body` with:

```swift
let windows = AccountPresentation.detailWindows(for: account)
```

Do not change `CompactAccountCard`.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
swiftc Sources/AIMeter/Models.swift \
  Sources/AIMeter/MenuBarPreferences.swift \
  Sources/AIMeter/AccountPresentation.swift \
  Tests/AccountPresentationHarness.swift \
  -o /tmp/notch-limits-fable-presentation-tests
/tmp/notch-limits-fable-presentation-tests
bash Tests/DashboardStructureHarness.sh
swift build
```

Expected: presentation and structure harnesses print PASS, and the debug build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/AIMeter/AccountPresentation.swift \
  Sources/AIMeter/GlassDashboardView.swift \
  Tests/AccountPresentationHarness.swift \
  Tests/DashboardStructureHarness.sh
git diff --cached --check
git commit -m "fix: show Fable in inactive account details"
```

### Task 2: Verify the standalone desktop app

**Files:**
- No source changes expected.

- [ ] **Step 1: Run the complete documented harness set**

Run the build and verification commands from `README.md`, excluding installation and launch.

- [ ] **Step 2: Build the release app bundle**

Run:

```bash
./build-app.sh release
```

Expected: `AI Meter.app` is produced successfully in this isolated worktree.

- [ ] **Step 3: Inspect the final diff**

Confirm the implementation changes only presentation ordering, the detail-popover call, and focused tests. Do not install or relaunch the app unless the user explicitly asks.
