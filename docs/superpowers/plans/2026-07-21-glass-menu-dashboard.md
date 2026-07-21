# Glass Menu Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating notch overlay and ambiguous mixed account list with a menu-bar-only, provider-first glass dashboard using compact weekly and 5-hour remaining-capacity bars.

**Architecture:** Keep provider I/O and credential storage unchanged. Add a pure presentation helper that groups accounts and selects primary/secondary windows, then render those results in a new glass dashboard hosted by `MenuView`. Remove `NotchController` creation from the app shell so no center-screen panel exists.

**Tech Stack:** Swift 5.9 package, SwiftUI, AppKit, ServiceManagement, XCTest, macOS 14+

## Global Constraints

- Dashboard width is 500 points.
- Provider order is Anthropic · Claude, then OpenAI · Codex.
- All bars show remaining capacity, never consumed capacity.
- The active account uses a small green dot with accessibility text.
- Five inactive accounts fit in no more than two rows through a fixed three-column grid.
- Weekly is the compact card's primary value; a distinct 5-hour window gets a second bar and percentage.
- No radial, ring, dial, semicircular, or automotive gauges.
- Do not change account collection, OAuth, credential storage, refresh cadence, or network destinations.
- Do not add package dependencies.

---

### Task 1: Add testable account presentation helpers

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CCManager/AccountPresentation.swift`
- Create: `Tests/CCManagerTests/AccountPresentationTests.swift`

**Interfaces:**
- Consumes: `[Account]`, `ProviderKind`, `UsageWindow`
- Produces: `ProviderAccountGroup`, `AccountPresentation.groups(_:)`, `AccountPresentation.primaryWindow(for:)`, `AccountPresentation.shortWindow(for:excluding:)`, and `AccountPresentation.activeRemaining(for:in:)`

- [ ] **Step 1: Add an XCTest target**

Update `Package.swift` targets to:

```swift
targets: [
    .executableTarget(
        name: "CCManager",
        path: "Sources/CCManager",
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
        name: "CCManagerTests",
        dependencies: ["CCManager"],
        path: "Tests/CCManagerTests"
    ),
]
```

- [ ] **Step 2: Write failing presentation tests**

Create `Tests/CCManagerTests/AccountPresentationTests.swift`:

```swift
import XCTest
@testable import CCManager

final class AccountPresentationTests: XCTestCase {
    private func window(_ label: String, minutes: Int, used: Double) -> UsageWindow {
        UsageWindow(label: label, usedPercent: used,
                    windowMinutes: minutes, resetsAt: nil)
    }

    private func account(
        _ provider: ProviderKind, _ name: String, active: Bool,
        windows: [UsageWindow]
    ) -> Account {
        Account(provider: provider, profileName: name,
                email: "\(name)@example.com", plan: "pro",
                isActive: active, windows: windows,
                status: .live(Date(timeIntervalSince1970: 1)))
    }

    func testGroupsAccountsProviderFirstAndPartitionsActive() {
        let accounts = [
            account(.codex, "codex-active", active: true, windows: []),
            account(.claude, "claude-other", active: false, windows: []),
            account(.claude, "claude-active", active: true, windows: []),
        ]

        let groups = AccountPresentation.groups(accounts)

        XCTAssertEqual(groups.map(\.provider), [.claude, .codex])
        XCTAssertEqual(groups[0].active?.profileName, "claude-active")
        XCTAssertEqual(groups[0].inactive.map(\.profileName), ["claude-other"])
        XCTAssertEqual(groups[1].active?.profileName, "codex-active")
    }

    func testWeeklyIsPrimaryAndFiveHourIsSecondary() {
        let fiveHour = window("5h", minutes: 300, used: 25)
        let weekly = window("Weekly", minutes: 10_080, used: 49)
        let value = account(.claude, "active", active: true,
                            windows: [fiveHour, weekly])

        let primary = AccountPresentation.primaryWindow(for: value)
        let short = AccountPresentation.shortWindow(for: value, excluding: primary)

        XCTAssertEqual(primary?.label, "Weekly")
        XCTAssertEqual(primary?.remainingPercent, 51)
        XCTAssertEqual(short?.label, "5h")
        XCTAssertEqual(short?.remainingPercent, 75)
    }

    func testSingleWindowDoesNotRenderDuplicateSecondary() {
        let fiveHour = window("5h", minutes: 300, used: 25)
        let value = account(.codex, "active", active: true, windows: [fiveHour])
        let primary = AccountPresentation.primaryWindow(for: value)

        XCTAssertEqual(primary?.label, "5h")
        XCTAssertNil(AccountPresentation.shortWindow(for: value, excluding: primary))
    }

    func testMenuReadingUsesTightestWindowFromActiveAccountOnly() {
        let active = account(.claude, "active", active: true, windows: [
            window("5h", minutes: 300, used: 25),
            window("Weekly", minutes: 10_080, used: 49),
        ])
        let inactive = account(.claude, "inactive", active: false, windows: [
            window("Weekly", minutes: 10_080, used: 99),
        ])

        XCTAssertEqual(
            AccountPresentation.activeRemaining(for: .claude, in: [active, inactive]),
            51
        )
    }
}
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `swift test --filter AccountPresentationTests`

Expected: compilation fails because `AccountPresentation` and `ProviderAccountGroup` do not exist.

- [ ] **Step 4: Implement the minimal presentation helper**

Create `Sources/CCManager/AccountPresentation.swift`:

```swift
import Foundation

struct ProviderAccountGroup: Identifiable {
    var id: ProviderKind { provider }
    let provider: ProviderKind
    let active: Account?
    let inactive: [Account]
}

enum AccountPresentation {
    static func groups(_ accounts: [Account]) -> [ProviderAccountGroup] {
        [ProviderKind.claude, ProviderKind.codex].map { provider in
            let matching = accounts.filter { $0.provider == provider }
            return ProviderAccountGroup(
                provider: provider,
                active: matching.first(where: \.isActive),
                inactive: matching.filter { !$0.isActive }
            )
        }
    }

    static func primaryWindow(for account: Account) -> UsageWindow? {
        account.longWindow ?? account.shortWindow ?? account.windows.first
    }

    static func shortWindow(
        for account: Account, excluding primary: UsageWindow?
    ) -> UsageWindow? {
        guard let short = account.shortWindow,
              short.id != primary?.id else { return nil }
        return short
    }

    static func activeRemaining(
        for provider: ProviderKind, in accounts: [Account]
    ) -> Int? {
        guard let active = accounts.first(where: {
            $0.provider == provider && $0.isActive
        }) else { return nil }
        let remaining = active.windows.map(\.remainingPercent).min()
        return remaining.map { Int($0.rounded()) }
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter AccountPresentationTests`

Expected: four tests pass.

```bash
git add Package.swift Sources/CCManager/AccountPresentation.swift Tests/CCManagerTests/AccountPresentationTests.swift
git commit -m "Add provider account presentation helpers"
```

---

### Task 2: Build the provider-first glass dashboard

**Files:**
- Create: `Sources/CCManager/GlassDashboardView.swift`
- Modify: `Sources/CCManager/MenuView.swift`
- Test: `Tests/CCManagerTests/AccountPresentationTests.swift`

**Interfaces:**
- Consumes: `ProviderAccountGroup` and `AccountPresentation` from Task 1, plus existing `AccountManager` actions
- Produces: `GlassDashboardView`, `ProviderGlassSection`, `ActiveAccountCard`, `CompactAccountCard`, and `RemainingBar`

- [ ] **Step 1: Extend tests for compact-card fallback semantics**

Add to `AccountPresentationTests`:

```swift
func testPrimaryFallsBackToLongestAvailableWindow() {
    let daily = window("Daily", minutes: 1_440, used: 40)
    let fiveHour = window("5h", minutes: 300, used: 10)
    let value = account(.codex, "active", active: true,
                        windows: [fiveHour, daily])

    XCTAssertEqual(AccountPresentation.primaryWindow(for: value)?.label, "Daily")
}
```

- [ ] **Step 2: Run the focused test and verify expected failure**

Run: `swift test --filter AccountPresentationTests/testPrimaryFallsBackToLongestAvailableWindow`

Expected: FAIL because `longWindow` excludes exactly-24-hour windows and the helper selects `5h`.

- [ ] **Step 3: Fix longest-window fallback**

Replace `primaryWindow(for:)` with:

```swift
static func primaryWindow(for account: Account) -> UsageWindow? {
    account.longWindow
        ?? account.windows.max(by: { $0.windowMinutes < $1.windowMinutes })
}
```

- [ ] **Step 4: Create the glass dashboard components**

Create `Sources/CCManager/GlassDashboardView.swift` with:

```swift
import SwiftUI

struct GlassDashboardView: View {
    @ObservedObject var manager: AccountManager
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(AccountPresentation.groups(manager.accounts)) { group in
                    ProviderGlassSection(group: group, manager: manager, columns: columns)
                }
                GlassValueStrip(manager: manager)
                GlassDashboardFooter(manager: manager)
            }
            .padding(13)
        }
        .frame(width: 500, maxHeight: 720)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.system(size: 16, weight: .semibold))
            Spacer()
            if let date = manager.lastRefresh {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh")
        }
    }
}
```

Implement the remaining types in the same file with these exact responsibilities:

```swift
struct ProviderGlassSection: View {
    let group: ProviderAccountGroup
    @ObservedObject var manager: AccountManager
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProviderHeader(provider: group.provider)
            if let active = group.active {
                ActiveAccountCard(account: active)
            }
            if !group.inactive.isEmpty {
                HStack {
                    Text("OTHER ACCOUNTS")
                    Spacer()
                    Text("\(group.inactive.count)")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(group.inactive) { account in
                        CompactAccountCard(account: account) {
                            if account.provider == .codex { manager.switchTo(account) }
                        }
                    }
                }
            }
            if group.active == nil && group.inactive.isEmpty {
                Text("No \(group.provider.displayName) accounts yet")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(providerBackground)
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var providerBackground: some ShapeStyle {
        let tint: Color = group.provider == .claude
            ? Color(red: 0.84, green: 0.42, blue: 0.25)
            : Color(red: 0.31, green: 0.47, blue: 0.95)
        return LinearGradient(colors: [tint.opacity(0.16), .white.opacity(0.035)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
```

`ProviderHeader` must write the vendor and product names explicitly:

```swift
private var title: String {
    provider == .claude ? "Anthropic · Claude" : "OpenAI · Codex"
}
private var source: String {
    provider == .claude ? "Live usage" : "Local logs"
}
```

`ActiveAccountCard` renders every `account.windows` row using `remainingPercent`, the label, percentage text `NN% left`, and reset description. Its green dot has `.accessibilityLabel("Active CLI account")` and `.help("Active CLI account")`.

`CompactAccountCard` uses `AccountPresentation.primaryWindow(for:)` for the large `NN% weekly left` value and primary horizontal `RemainingBar`. It uses `AccountPresentation.shortWindow(for:excluding:)` for a second row containing `5h`, a second `RemainingBar`, and `NN%`. It uses seven-point internal padding and exposes a hover-only `Switch` button only for Codex.

`RemainingBar` accepts `remaining: Double` and fills its capsule to `remaining / 100`. Its tint is blue for values above 40, amber for 15 through 40, and red below 15.

`GlassValueStrip` reproduces the existing API-equivalent calculation but labels it `Claude API equivalent` and `Claude estimate only · this week`.

`GlassDashboardFooter` preserves add-Claude, import-Codex, launch-at-login, error, and quit controls from the existing `MenuView.footer`.

- [ ] **Step 5: Replace the old menu content**

Replace `MenuView.body` with:

```swift
var body: some View {
    GlassDashboardView(manager: manager)
}
```

Remove now-unused `RecommendationBanner`, `AccountRow`, and `UsageBar` from `MenuView.swift`; keep only `MenuView` if all footer logic moved to `GlassDashboardView.swift`.

- [ ] **Step 6: Run tests and build**

Run: `swift test && swift build -c release`

Expected: all presentation tests pass and the release build completes.

- [ ] **Step 7: Commit**

```bash
git add Sources/CCManager/GlassDashboardView.swift Sources/CCManager/MenuView.swift Sources/CCManager/AccountPresentation.swift Tests/CCManagerTests/AccountPresentationTests.swift
git commit -m "Redesign account dashboard with provider glass sections"
```

---

### Task 3: Remove the desktop overlay and clarify the menu-bar label

**Files:**
- Modify: `Sources/CCManager/App.swift`
- Test: `Tests/CCManagerTests/AccountPresentationTests.swift`

**Interfaces:**
- Consumes: `AccountPresentation.activeRemaining(for:in:)`
- Produces: a menu-bar-only app with explicit `A NN · C NN` active-provider readings

- [ ] **Step 1: Add a failing menu-label test**

Add to `AccountPresentationTests`:

```swift
func testMenuLabelIncludesBothProviderReadings() {
    let claude = account(.claude, "claude", active: true, windows: [
        window("Weekly", minutes: 10_080, used: 49),
    ])
    let codex = account(.codex, "codex", active: true, windows: [
        window("Weekly", minutes: 10_080, used: 55),
    ])

    XCTAssertEqual(AccountPresentation.menuLabel(for: [claude, codex]), "A 51 · C 45")
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter AccountPresentationTests/testMenuLabelIncludesBothProviderReadings`

Expected: compilation fails because `menuLabel(for:)` does not exist.

- [ ] **Step 3: Implement the menu-label helper**

Add to `AccountPresentation`:

```swift
static func menuLabel(for accounts: [Account]) -> String? {
    var parts: [String] = []
    if let value = activeRemaining(for: .claude, in: accounts) {
        parts.append("A \(value)")
    }
    if let value = activeRemaining(for: .codex, in: accounts) {
        parts.append("C \(value)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
```

- [ ] **Step 4: Remove `NotchController` creation and use the dual-provider label**

Replace `Sources/CCManager/App.swift` with an app entry point that does not define or instantiate `AppDelegate`/`NotchController`, while preserving `--diagnose` and `--selftest` handling. Use this menu-bar label:

```swift
MenuBarExtra {
    MenuView(manager: manager)
} label: {
    Image(systemName: "gauge.with.dots.needle.33percent")
    if let label = AccountPresentation.menuLabel(for: manager.accounts) {
        Text(label).monospacedDigit()
    }
}
.menuBarExtraStyle(.window)
```

- [ ] **Step 5: Run tests and build**

Run: `swift test && ./build-app.sh release`

Expected: tests pass, the app bundle builds, and no source reference in `App.swift` mentions `NotchController`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CCManager/App.swift Sources/CCManager/AccountPresentation.swift Tests/CCManagerTests/AccountPresentationTests.swift
git commit -m "Make Notch Limits menu-bar only"
```

---

### Task 4: Install and verify the redesigned app

**Files:**
- Verify: `/Applications/CCManager.app`

**Interfaces:**
- Consumes: the release bundle from Tasks 1–3
- Produces: a running locally built app with no floating desktop panel

- [ ] **Step 1: Run the full verification suite**

Run:

```bash
swift test
swift build -c release
git diff --check
```

Expected: all tests pass, release build succeeds, and `git diff --check` prints nothing.

- [ ] **Step 2: Re-run the static outbound-domain audit**

Run:

```bash
rg -n -i '(https?://|URLSession|URLRequest|NWListener|telemetry|analytics|sentry|posthog)' Sources Package.swift
```

Expected: only the existing Anthropic OAuth/usage URLs, localhost callback, the local JWT claim string, and existing networking types appear. No new domain appears.

- [ ] **Step 3: Install and launch**

Run: `./build-app.sh release --install`

Expected: `/Applications/CCManager.app` is replaced by the local build and `CCManager` is running.

- [ ] **Step 4: Verify installed binary and process state**

Run:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/CCManager.app
shasum -a 256 CCManager.app/Contents/MacOS/CCManager /Applications/CCManager.app/Contents/MacOS/CCManager
pgrep -fl '^.*CCManager$'
```

Expected: bundle verification succeeds, both hashes match, and exactly one installed process is running.

- [ ] **Step 5: Verify overlay removal and menu behavior manually**

Open the menu-bar item and confirm:

- Anthropic · Claude and OpenAI · Codex appear as separate glass sections.
- Active accounts have a green dot.
- Five inactive cards render in two rows.
- Compact cards show one weekly percentage/bar and one 5-hour percentage/bar.
- No center-screen notch panel appears.
- No global “Best account” banner appears.

- [ ] **Step 6: Commit any verification-only documentation changes**

If no documentation changed, do not create an empty commit. Otherwise:

```bash
git add docs
git commit -m "Document glass dashboard verification"
```
