# AI Meter

A private, local-first macOS menu-bar dashboard for Claude and OpenAI Codex subscription limits.

This is a redesigned fork of [everyai-com/notch-limits](https://github.com/everyai-com/notch-limits). It replaces the original floating notch overlay with a compact native-glass menu panel organized by provider.

## Features

- Separate **Claude** and **Codex** sections.
- Green marker beside the account currently active in each CLI.
- 5-hour, weekly, and model-specific limit bars showing capacity remaining.
- Reset countdowns and absolute reset times; click an inactive card for details.
- Compact three-column layout for additional accounts.
- Menu-bar A/C readout showing the active accounts' short-window capacity.
- Add multiple Claude accounts through browser OAuth without changing the Claude CLI login.
- Add multiple Codex accounts through an isolated official `codex login` flow without logging out or replacing the active Codex credential.
- One-click Codex switching with automatic credential backups.
- Native macOS glass using a non-interactive `NSVisualEffectView`.

## Install from source

Requires macOS 14+ and Xcode or the Swift toolchain.

```bash
git clone https://github.com/AlchemistChaos/ai-usage-meter.git
cd ai-usage-meter
./build-app.sh release --install
```

The app is installed at `/Applications/AI Meter.app`. It has no Dock icon; open it from the A/C gauge in the macOS menu bar.

## Adding accounts

Open the settings cog in the dashboard.

### Claude

Choose **Add Anthropic account**, select a browser, and complete the OAuth flow. Stored profiles are polled independently, so inactive Claude accounts can still show fresh usage.

### Codex

Choose **Add OpenAI Codex account** and sign in through the browser. AI Meter launches the installed official Codex CLI with a temporary isolated `CODEX_HOME`, forces file-based credential storage there, imports the completed login, and removes the temporary directory. Your active `~/.codex/auth.json` is not changed.

**Import OpenAI Codex login** remains available for saving whichever account is already active in the normal Codex CLI.

Inactive Codex limits come from the last local reading captured for that account. Switch to it and use Codex once to record fresh limits.

## Privacy and network behavior

There is no telemetry, analytics, hosted backend, or project-owned server.

- Claude usage and profile requests go directly to official Anthropic endpoints in `ClaudeProvider.swift` and `ClaudeOAuth.swift`.
- Adding a Codex account runs the installed official Codex CLI, which performs its login directly with OpenAI inside an isolated local state directory.
- Codex usage is read locally from `~/.codex/logs_2.sqlite`; AI Meter does not call a Codex usage endpoint.
- The OAuth callback listener binds only to localhost.
- Saved credentials live under `~/.ccmanager/profiles/` with owner-only `0600` permissions.
- Codex switching backs up the active credential before replacing it and writes atomically.
- The app does not send prompts, source code, transcripts, filenames, or usage data to any server operated by this project.

Inspect the relevant implementation directly:

- [`ClaudeOAuth.swift`](Sources/AIMeter/ClaudeOAuth.swift)
- [`ClaudeProvider.swift`](Sources/AIMeter/ClaudeProvider.swift)
- [`CodexLogin.swift`](Sources/AIMeter/CodexLogin.swift)
- [`CodexProvider.swift`](Sources/AIMeter/CodexProvider.swift)
- [`ProfileStore.swift`](Sources/AIMeter/ProfileStore.swift)

To print the local credential/data sources detected by the app:

```bash
/Applications/AI Meter.app/Contents/MacOS/AIMeter --diagnose
```

## How usage is obtained

**Claude:** the app polls Anthropic's OAuth usage endpoint for each stored profile at most once every five minutes.

**Codex:** the official CLI records rate-limit headers in its local SQLite log. The app reads the most recent matching record and caches it per account. If an inactive account has no fresh reset timestamp, the UI says it becomes available after using that account instead of inventing a date.

## Build and verify

```bash
swift build -c release
bash Tests/DashboardStructureHarness.sh
bash Tests/NativeGlassStructureHarness.sh
bash Tests/AppBrandingHarness.sh
swiftc Sources/AIMeter/Models.swift \
  Sources/AIMeter/AccountPresentation.swift \
  Tests/AccountPresentationHarness.swift \
  -o /tmp/notch-limits-presentation-tests
/tmp/notch-limits-presentation-tests
swiftc Sources/AIMeter/CodexLogin.swift \
  Tests/CodexLoginHarness.swift \
  -o /tmp/notch-limits-codex-login-tests
/tmp/notch-limits-codex-login-tests
```

`./build-app.sh release` creates an ad-hoc signed local bundle by default. Set `AIMETER_SIGN_IDENTITY` to a Developer ID identity for distribution builds.

## Project layout

| File | Responsibility |
|---|---|
| `App.swift` / `GlassDashboardView.swift` | Menu-bar scene and provider-first dashboard |
| `NativeGlassBackground.swift` | Clear native glass background that cannot intercept input |
| `AccountManager.swift` | Refresh loop, account actions, and login coordination |
| `MenuBarPreferences.swift` | Persistent menu-bar metric selections and compact defaults |
| `ClaudeProvider.swift` / `ClaudeOAuth.swift` | Claude profiles, OAuth, and live limits |
| `CodexProvider.swift` / `CodexLogin.swift` | Local Codex limits and isolated account login |
| `ProfileStore.swift` | Owner-only profile storage, backups, and atomic switching |

## Limitations

- Claude CLI switching is deliberately unsupported because it would require modifying Claude's own credential state.
- Codex can only show data previously recorded while that account was active and used.
- The compact default shows Claude's 5-hour and Codex's weekly capacity. Use Settings → Menu bar to toggle Claude 5-hour, Claude weekly, and Codex weekly independently.
- A selected menu-bar value displays `—` when that exact provider window is unavailable; it never substitutes a different window.
- Locally built/ad-hoc signed apps are intended for your own Mac; public downloads should be Developer ID signed and notarized.

## Attribution and license

Based on [everyai-com/notch-limits](https://github.com/everyai-com/notch-limits). The upstream copyright notice is preserved.

MIT — see [LICENSE](LICENSE).
