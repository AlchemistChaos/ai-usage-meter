# AI Meter Status Item Lifecycle

## Problem

AI Meter's SwiftUI `MenuBarExtra` can stop appearing while the process remains
healthy. Relaunching the process restores the gauge, which shows that provider
collection and dashboard rendering are not the failure point. The missing
piece is deterministic ownership and recovery of the macOS status item.

## Design

Replace the `MenuBarExtra` scene with an AppKit-owned status item controller.
The application delegate creates one `NSStatusItem`, retains it for the
application lifetime, and assigns a stable `autosaveName`. Its button always
contains the gauge icon and may append the existing user-selected Claude and
Codex metrics.

Clicking the button toggles a transient `NSPopover` whose content is the
existing SwiftUI `MenuView` hosted through `NSHostingController`. The popover
closes when the user clicks elsewhere and is reused rather than recreated on
every click.

The controller exposes an idempotent `ensureStatusItem()` operation. The app
invokes it at launch, on application reactivation, after wake, and after screen
configuration changes. If the retained item is absent or marked invisible,
the controller restores visibility or recreates the item. Recovery must never
create duplicate gauges.

## Data Flow

`AccountManager` remains the source of usage data. The status item controller
observes account changes and menu-bar preference changes, then updates only the
button title. All provider polling, account switching, dashboard content, and
stored preferences remain unchanged.

## Space Constraints

macOS may temporarily hide any status item when the menu bar lacks space. The
gauge icon remains mandatory and metric text remains optional/configurable.
The lifecycle recovery code handles a missing item, but does not fight the
system's temporary space management or create repeated items.

## Testing

- Add a focused lifecycle harness proving repeated recovery creates one item.
- Prove an invisible retained item is made visible.
- Prove a missing item is recreated.
- Keep the existing presentation, dashboard structure, branding, and Codex
  login harnesses green.
- Build the release app, install it, and verify that launch registers the gauge,
  clicking opens the dashboard, closing and reopening works, and a process
  restart restores exactly one gauge.

## Non-goals

- No provider, authentication, account, or token-statistics changes.
- No Dock icon or conventional application window.
- No redesign of the dashboard or menu-bar metric preferences.
