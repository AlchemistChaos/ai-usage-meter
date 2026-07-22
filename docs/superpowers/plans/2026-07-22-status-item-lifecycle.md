# AI Meter Status Item Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stale-prone SwiftUI menu-bar scene with an explicitly retained and recoverable AppKit status item while preserving the existing dashboard and metric preferences.

**Architecture:** A pure generic lifecycle object owns the create/reuse/restore decision and is tested without AppKit. `StatusItemController` adapts that lifecycle to `NSStatusItem`, hosts the existing `MenuView` in a transient `NSPopover`, and refreshes the button label from `AccountManager` and `UserDefaults`. An AppKit application delegate owns the controller and calls recovery at launch, activation, wake, and screen changes.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Combine, shell and `swiftc` harnesses.

## Global Constraints

- Keep the app menu-bar-only with `LSUIElement=true`; do not add a Dock icon or ordinary window.
- Preserve provider polling, authentication, account storage, dashboard content, and metric preferences.
- Recovery is idempotent and must never create duplicate gauges.
- Respect macOS temporary hiding when menu-bar space is insufficient.

---

### Task 1: Testable status-item lifecycle

**Files:**
- Create: `Sources/AIMeter/StatusItemLifecycle.swift`
- Create: `Tests/StatusItemLifecycleHarness.swift`

**Interfaces:**
- Produces: `StatusItemRepresenting`, `StatusItemLifecycle<Item>`, and `ensureItem() -> (item: Item, created: Bool)`.

- [ ] Write a harness with a fake item that asserts the first ensure creates one item, repeated ensure reuses it, invisibility is repaired, and detachment creates exactly one replacement.
- [ ] Compile the harness before implementation and confirm failure because the lifecycle types do not exist.
- [ ] Implement the minimal generic lifecycle and attachment/visibility protocol.
- [ ] Recompile and run the harness; expect `PASS: status item lifecycle`.

### Task 2: AppKit status item and popover

**Files:**
- Create: `Sources/AIMeter/StatusItemController.swift`
- Modify: `Sources/AIMeter/App.swift`
- Modify: `Tests/DashboardStructureHarness.sh`

**Interfaces:**
- Consumes: `StatusItemLifecycle<NSStatusItem>` and `AccountManager.shared`.
- Produces: `StatusItemController.ensureStatusItem()` and an app delegate that invokes it for lifecycle events.

- [ ] Extend the structural harness to require an AppKit-owned `NSStatusItem`, retained controller, stable autosave name, transient `NSPopover`, target-action click, and launch/activation/wake/screen recovery hooks; require that `MenuBarExtra` is absent.
- [ ] Run the structural harness and confirm it fails on the missing AppKit controller.
- [ ] Implement `StatusItemController`: create a variable-length item, set `autosaveName`, icon, target/action, transient popover with `MenuView`, Combine account observation, preference notification observation, label refresh, and idempotent recovery.
- [ ] Replace the SwiftUI `App` scene with an AppKit application entry point and delegate that retains the controller and registers/removes wake and screen observers.
- [ ] Run the lifecycle and structural harnesses; expect both to pass.

### Task 3: Documentation and full verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the new lifecycle harness and AppKit app entry point.

- [ ] Add the lifecycle harness command to the documented verification recipe and update the project-layout description.
- [ ] Run all shell and Swift harnesses, then `swift build -c release`.
- [ ] Run `./build-app.sh release --install` to replace and relaunch only `/Applications/AI Meter.app`.
- [ ] Verify one `AIMeter` process exists and compare Control Centre menu-bar windows with the app stopped versus running to confirm exactly one status item is registered.
- [ ] Exercise click/close/reopen through Computer Use if the status item is exposed; otherwise report the programmatic lifecycle evidence precisely.
- [ ] Inspect `git diff --check` and `git status`, then commit the implementation.
