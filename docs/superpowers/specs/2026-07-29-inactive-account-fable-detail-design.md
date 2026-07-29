# Inactive Account Fable Detail Design

## Goal

Show every relevant Claude usage window, including Fable, when a user clicks an inactive account card in the standalone AI Meter macOS app.

## Behavior

The compact account card remains unchanged: it shows the account identity, plan, overall weekly capacity, and short-window capacity.

The clicked reset-detail popover shows:

1. The primary long window, normally Weekly.
2. The short window, normally 5h.
3. Every remaining provider window in its original order, including model-specific limits such as Fable.

Each detail row keeps the existing remaining-percentage and reset-time presentation. Accounts with no windows keep the existing unavailable message.

## Architecture

`ClaudeProvider` already parses model-scoped limits from Anthropic's live response, so the provider layer does not change.

Add a pure `AccountPresentation.detailWindows(for:)` helper that orders the existing account windows without duplicating the primary or short window. `ResetDetailsPopover` consumes that helper instead of rebuilding a two-window array.

## Verification

- Extend `AccountPresentationHarness` with a Weekly, 5h, and Fable account and assert the clicked-detail order.
- Extend `DashboardStructureHarness` to require `ResetDetailsPopover` to use the shared detail-window helper.
- Run the presentation harness, dashboard structure harness, debug build, and release build.
