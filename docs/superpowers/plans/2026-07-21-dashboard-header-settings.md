# Dashboard Header Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Claude value strip and consolidate persistent controls into a native settings menu beside Refresh and Quit.

**Architecture:** Keep all UI changes inside `GlassDashboardView.swift`. The header owns persistent controls; the footer is reduced to transient OAuth/error feedback. Existing `AccountManager` methods and `SMAppService` bindings remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, ServiceManagement, macOS 14+

## Global Constraints

- Remove the Claude API-equivalent card completely.
- Header control order is Refresh, Settings, Quit.
- Settings contains Add Anthropic, Import OpenAI Codex, and Launch at Login.
- Preserve existing authentication, import, storage, and network behavior.

---

### Task 1: Restructure dashboard controls

**Files:**
- Create: `Tests/DashboardStructureHarness.sh`
- Modify: `Sources/CCManager/GlassDashboardView.swift`

**Interfaces:**
- Consumes: `AccountManager.beginClaudeLogin`, `importCurrentCodex`, `cancelClaudeLogin`; `SMAppService.mainApp`.
- Produces: Native SwiftUI header `Menu` and transient-only status view.

- [ ] **Step 1: Write the failing structural regression test**

Check that `GlassValueStrip` is absent, the header contains `Settings`, `Quit`, and Refresh, and the settings menu contains the three approved controls.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash Tests/DashboardStructureHarness.sh`
Expected: FAIL because `GlassValueStrip` and footer controls still exist.

- [ ] **Step 3: Implement the minimal UI change**

Delete `GlassValueStrip`; add a gear `Menu` and Quit button to the header; replace `GlassDashboardFooter` with transient OAuth/error feedback only.

- [ ] **Step 4: Verify and install**

Run the structural harness, presentation harness, `swift build -c release`, and `./build-app.sh release --install`. Verify the installed signature, process, and binary hash.

- [ ] **Step 5: Commit**

Commit the harness, view changes, and this plan with message `Move dashboard controls into header settings`.
