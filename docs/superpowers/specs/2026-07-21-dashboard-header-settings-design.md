# Dashboard Header Settings Design

## Goal

Reduce visual clutter in the menu dashboard by removing the Claude API-equivalent value card and moving persistent account/settings controls into the header.

## Approved layout

The dashboard header keeps the title and last-updated timestamp on the left/centre. Its right edge contains three compact controls in this order:

1. Refresh button.
2. Native macOS settings menu using a gear icon.
3. Quit button.

The settings menu contains:

- Add Anthropic account, including the existing browser choices.
- Import OpenAI Codex login.
- Launch at Login toggle.

The Claude API-equivalent card is removed completely. It is not hidden or moved into settings.

## Transient states

OAuth progress, pasted-code entry, cancellation, and errors remain visible inline only while relevant. They are not buried in the settings menu because users need immediate feedback after starting an account login.

## Scope and safety

This is a presentation-only reorganization. Existing login, import, launch-at-login, refresh, and quit actions retain their current implementations. No network endpoints, authentication storage, account discovery, or usage calculations change.

## Verification

- A structural regression check confirms the value strip is absent.
- A structural regression check confirms the header contains Refresh, Settings, and Quit controls.
- The presentation harness and release build must pass.
- The rebuilt app must be installed, launched, signed, and byte-identical to the packaged binary.
