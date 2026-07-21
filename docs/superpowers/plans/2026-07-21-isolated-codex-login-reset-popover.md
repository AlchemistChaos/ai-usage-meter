# Isolated Codex Login and Reset Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add non-destructive multi-account Codex login and click-to-open inactive reset details.

**Architecture:** A focused `CodexLogin` helper owns isolated process and filesystem staging. `AccountManager` coordinates UI state and imports validated credentials through `ProfileStore`. Presentation helpers provide deterministic profile naming and reset-detail copy; SwiftUI displays login progress and a card popover.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Process`, ServiceManagement, macOS 14+

## Global Constraints

- Never modify `~/.codex/auth.json` while adding an isolated account.
- Use the installed official Codex CLI with an isolated, pre-created `CODEX_HOME`.
- Force `cli_auth_credentials_store = "file"` in the isolated home.
- Remove temporary credentials after import or cancellation.
- Show real reset timestamps when available and explicit unavailable copy otherwise.

---

### Task 1: Presentation and naming behavior

**Files:**
- Modify: `Sources/CCManager/AccountPresentation.swift`
- Modify: `Tests/AccountPresentationHarness.swift`

- [ ] Add failing assertions for collision-safe full-email profile names and unavailable reset copy.
- [ ] Run the harness and confirm the new APIs are missing.
- [ ] Implement the minimal pure helpers and make the harness pass.

### Task 2: Isolated Codex login

**Files:**
- Create: `Sources/CCManager/CodexLogin.swift`
- Modify: `Sources/CCManager/ProfileStore.swift`
- Modify: `Sources/CCManager/AccountManager.swift`

- [ ] Add a filesystem harness that proves isolated setup does not alter the active credential fixture.
- [ ] Implement executable discovery, isolated home creation, process launch/cancel, validated external credential import, unique naming, cleanup, and published pending state.
- [ ] Run the harness and presentation tests.

### Task 3: Settings and reset popover UI

**Files:**
- Modify: `Sources/CCManager/GlassDashboardView.swift`
- Modify: `Tests/DashboardStructureHarness.sh`

- [ ] Extend the structural test for Add Codex, pending login feedback, card popover, both reset windows, and removal of compact inline reset rows.
- [ ] Implement the settings action, transient status, clickable card popover, and compact reset detail rows.
- [ ] Run all harnesses and the release build.

### Task 4: Package and verify

- [ ] Commit the implementation.
- [ ] Install and relaunch `/Applications/CCManager.app`.
- [ ] Verify signature, running process, installed binary hash, clean tree, and unchanged declared app network endpoints.
