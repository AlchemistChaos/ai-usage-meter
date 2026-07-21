# Glass Menu Dashboard Design

## Objective

Replace the ambiguous account list with a provider-first glass dashboard that is easy to scan from the macOS menu bar. Remove the top-center desktop overlay entirely.

## Scope

- Keep Notch Limits as a menu-bar-only app.
- Stop creating `NotchController` and its floating center-screen panel at launch.
- Redesign `MenuView` as the primary dashboard.
- Preserve all existing account collection, OAuth, local-log parsing, profile switching, refresh cadence, and privacy behavior.
- Do not add dependencies, telemetry, network destinations, or background services.

## Information Architecture

The dashboard uses provider as the top-level grouping:

1. **Anthropic · Claude** — labelled `Live usage`.
2. **OpenAI · Codex** — labelled `Local logs`.

Each provider receives a distinct glass section with its own mark and restrained tint. The global “Best account active” recommendation is removed because Claude and Codex accounts are not interchangeable.

The menu-bar label also avoids a single cross-provider percentage. It shows the stable gauge icon followed by compact remaining-capacity readings for each provider with active data, formatted as `A 75 · C 45`. A provider without data is omitted.

## Account Hierarchy

Within each provider section:

- The active CLI account appears first as a full-width detailed card.
- A small glowing green dot is the only active-account marker. Its accessibility label and tooltip say `Active CLI account`.
- Every usage window remains visible on the active card, including reset time and data freshness.
- Inactive accounts appear below in a fixed three-column grid.
- Five inactive accounts therefore occupy no more than two rows.
- Long identities truncate to one line and reveal the full value in a tooltip.
- Inactive Codex accounts retain a compact `Switch` action on hover/focus. Claude cards are informational because the app does not switch Claude CLI credentials.

## Compact Inactive Cards

Each inactive card contains:

- Account identity and plan.
- The weekly remaining allowance as a large, explicit `NN% weekly left` value and horizontal bar. If no weekly window exists, the longest available window becomes primary and its label is written out.
- A compact `5h` remaining-capacity bar with its own percentage when a distinct short window exists.
- Data age when the reading is not current.

Cards use compact 6–9 point internal spacing and six-point grid gaps. They do not use radial, semicircular, speedometer, or ring gauges.

## Meter Semantics

All visual meters represent **remaining capacity**, never consumed capacity:

- Text always includes `left` where ambiguity is possible.
- Bar fill equals `UsageWindow.remainingPercent`.
- Healthy remaining capacity uses the neutral provider tint.
- Low capacity becomes amber, then red.
- Existing `usedPercent` values remain unchanged in the data model; conversion happens only in presentation helpers.

## Glass Visual System

- Dashboard width: 500 points.
- Dark translucent base using SwiftUI `ultraThinMaterial` behind the dashboard content.
- Provider sections use low-opacity gradients, one-pixel white hairlines, subtle inner highlights, and restrained shadows.
- Anthropic uses a warm clay accent; Codex uses a cool blue accent.
- Typography remains native San Francisco with a minimum practical reading size of 10 points for metadata and 11 points for account labels.
- Motion is limited to refresh transitions, hover affordances, and numeric changes. No decorative continuous animation.

## Value and Footer Content

- The API-equivalent strip remains, but is explicitly labelled `Claude API equivalent` and `Claude estimate only`.
- Add-account actions remain provider-labelled.
- Refresh, last-updated time, launch-at-login, errors, and quit remain available.
- Empty and error states sit inside the relevant provider section rather than becoming unlabeled global rows.

## Data Flow

No data-path changes are required:

- `AccountManager.accounts` remains the source of account state.
- Views group accounts by `ProviderKind` and partition them by `isActive`.
- Claude inactive accounts continue receiving live usage from the existing Anthropic polling flow.
- Codex inactive accounts continue displaying cached snapshots from local Codex logs.
- No view initiates new provider requests.

## Accessibility and Interaction

- Provider names and vendors are written out; identification does not rely on color or symbols.
- Active state has an accessibility label in addition to the visual dot.
- Remaining percentages are available as text, not only as bar length or color.
- Compact cards are keyboard-focusable when they expose the Codex switch action.
- Reduced-motion settings disable nonessential transitions.

## Verification

- Add focused tests for provider grouping, active/inactive partitioning, remaining-capacity presentation, and compact-card summary selection.
- Build the release configuration with no third-party dependencies.
- Render the menu with fake data containing at least one active and five inactive accounts under a provider.
- Verify five inactive cards occupy two rows at the target width.
- Verify Claude and Codex headings, active dots, `% left` labels, Claude-only value disclaimer, and Codex switch affordances.
- Launch the installed app and confirm no center-screen overlay window is created.
- Re-run the outbound-domain audit to confirm the redesign introduces no network destinations.
