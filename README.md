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

Choose **Add Anthropic account**, select a browser, and complete the OAuth flow for each account you want to monitor. Profiles are keyed by Anthropic account UUID rather than email prefix, so accounts with similar addresses cannot overwrite each other. Stored profiles are polled independently, while Claude Code's active login remains untouched.

### Codex

Choose **Add OpenAI Codex account** and sign in through the browser. AI Meter launches the installed official Codex CLI with a temporary isolated `CODEX_HOME`, forces file-based credential storage there, imports the completed login, and removes the temporary directory. Your active `~/.codex/auth.json` is not changed.

**Import OpenAI Codex login** remains available for saving whichever account is already active in the normal Codex CLI.

Every saved Codex profile is polled through its own isolated official Codex app-server state. Switching is optional and no longer required merely to refresh an inactive account's limits.

## Privacy and network behavior

There is no telemetry, analytics, hosted backend, or project-owned server.

- Claude usage and profile requests go directly to Anthropic-hosted OAuth endpoints in `ClaudeProvider.swift` and `ClaudeOAuth.swift`.
- Adding a Codex account runs the installed official Codex CLI, which performs its login directly with OpenAI inside an isolated local state directory.
- Codex limits come from the installed Codex client's `account/rateLimits/read` method. Saved accounts use isolated `CODEX_HOME` directories; rate-limit headers in `~/.codex/logs_2.sqlite` remain a last-known fallback.
- The OAuth callback listener binds only to localhost.
- Saved credentials live under `~/.ccmanager/profiles/` with owner-only `0600` permissions.
- Codex switching backs up the active credential before replacing it and writes atomically.
- The app does not read Claude transcripts or import token-event history.
- The app does not send prompts, source code, filenames, or usage data to any server operated by this project.

Inspect the relevant implementation directly:

- [`ClaudeOAuth.swift`](Sources/AIMeter/ClaudeOAuth.swift)
- [`ClaudeProvider.swift`](Sources/AIMeter/ClaudeProvider.swift)
- [`ClaudeProfileStore.swift`](Sources/AIMeter/ClaudeProfileStore.swift)
- [`CodexLogin.swift`](Sources/AIMeter/CodexLogin.swift)
- [`CodexProvider.swift`](Sources/AIMeter/CodexProvider.swift)
- [`ProfileStore.swift`](Sources/AIMeter/ProfileStore.swift)

To print the local credential/data sources detected by the app:

```bash
/Applications/AI Meter.app/Contents/MacOS/AIMeter --diagnose
```

## How usage is obtained

**Claude:** for the active Claude Code account, the app first reads Claude Code statusline `rate_limits` captured in `~/.ccmanager/claude-statusline/latest.json`, then tries Claude Code's current unexpired OAuth credential. Every account added in AI Meter has a separate UUID-keyed OAuth profile. AI Meter refreshes only those app-owned chains and never rotates or writes Claude Code's credential.

**Codex:** the app asks the installed official Codex client for `account/rateLimits/read` at most once per minute per account. Saved profiles launch app-server with that profile directory as isolated `CODEX_HOME`; the active `~/.codex/auth.json` is never replaced during background polling. Legacy local rate-limit headers remain a fallback for the active account.

## Build and verify

```bash
swift build -c release
bash Tests/DashboardStructureHarness.sh
bash Tests/NativeGlassStructureHarness.sh
bash Tests/AppBrandingHarness.sh
swiftc -parse-as-library Sources/AIMeter/StatusItemLifecycle.swift \
  Tests/StatusItemLifecycleHarness.swift \
  -o /tmp/notch-limits-status-item-tests
/tmp/notch-limits-status-item-tests
swiftc Sources/AIMeter/MenuAgentLauncher.swift \
  Tests/MenuAgentLauncherHarness.swift \
  -o /tmp/notch-limits-menu-agent-tests
/tmp/notch-limits-menu-agent-tests
swiftc -parse-as-library Sources/AIMeter/PopoverPlacement.swift \
  Tests/PopoverPlacementHarness.swift \
  -o /tmp/notch-limits-popover-placement-tests
/tmp/notch-limits-popover-placement-tests
bash Tests/StatusItemStructureHarness.sh
bash Tests/CodexLivePollingStructureHarness.sh
bash Tests/NoAnalyticsStructureHarness.sh
bash Tests/ClaudeAuthStructureHarness.sh
bash Tests/NoTokenRotationHarness.sh
bash Tests/AllClaudeAccountsStructureHarness.sh
swiftc -parse-as-library Sources/AIMeter/Models.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/CodexLogin.swift \
  Sources/AIMeter/ProfileStore.swift \
  Sources/AIMeter/SnapshotCache.swift \
  Sources/AIMeter/ClaudeProfileStore.swift \
  Sources/AIMeter/ClaudeProvider.swift \
  Sources/AIMeter/ClaudeOAuth.swift \
  Tests/ClaudeProviderHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-claude-provider-tests
/tmp/notch-limits-claude-provider-tests
./build-app.sh release
AIMETER_APP_PATH="AI Meter.app" bash Tests/InstalledStatusItemHarness.sh
swiftc Sources/AIMeter/Models.swift \
  Sources/AIMeter/MenuBarPreferences.swift \
  Sources/AIMeter/AccountPresentation.swift \
  Tests/AccountPresentationHarness.swift \
  -o /tmp/notch-limits-presentation-tests
/tmp/notch-limits-presentation-tests
swiftc -parse-as-library Sources/AIMeter/Models.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/CodexLogin.swift \
  Sources/AIMeter/ProfileStore.swift \
  Sources/AIMeter/SnapshotCache.swift \
  Sources/AIMeter/ClaudeProfileStore.swift \
  Sources/AIMeter/ClaudeOAuth.swift \
  Sources/AIMeter/ClaudeProvider.swift \
  Tests/SnapshotCacheHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-snapshot-cache-tests
/tmp/notch-limits-snapshot-cache-tests
swiftc Sources/AIMeter/CodexLogin.swift \
  Tests/CodexLoginHarness.swift \
  -o /tmp/notch-limits-codex-login-tests
/tmp/notch-limits-codex-login-tests
swiftc -parse-as-library Sources/AIMeter/Models.swift \
  Sources/AIMeter/CodexProvider.swift \
  Sources/AIMeter/CodexLogin.swift \
  Sources/AIMeter/CodexRateLimitClient.swift \
  Tests/CodexRateLimitClientHarness.swift \
  -lsqlite3 -o /tmp/notch-limits-codex-rate-limit-tests
/tmp/notch-limits-codex-rate-limit-tests
```

`./build-app.sh release` creates an ad-hoc signed local bundle by default. Set `AIMETER_SIGN_IDENTITY` to a Developer ID identity for distribution builds.

## Project layout

| File | Responsibility |
|---|---|
| `App.swift` / `MenuAgentLauncher.swift` / `StatusItemController.swift` | App lifecycle, macOS 26 menu-agent relay, retained gauge, and dashboard popover |
| `AppPreferences.swift` / `LaunchAtLoginBridge.swift` | Shared menu preferences and bundled launch-at-login commands |
| `StatusItemLifecycle.swift` | Idempotent creation and visibility recovery for the gauge |
| `PopoverPlacement.swift` | Keeps the dashboard below the menu bar as its content resizes |
| `GlassDashboardView.swift` | Provider-first dashboard |
| `NativeGlassBackground.swift` | Clear native glass background that cannot intercept input |
| `AccountManager.swift` | Refresh loop, account actions, and login coordination |
| `MenuBarPreferences.swift` | Persistent menu-bar metric selections and compact defaults |
| `ClaudeProfileStore.swift` | UUID-keyed Claude profile storage, migration, provenance, and atomic writes |
| `ClaudeProvider.swift` / `ClaudeOAuth.swift` | Claude OAuth, guarded app-owned refresh, and live limits |
| `CodexProvider.swift` / `CodexLogin.swift` | Local Codex limits and isolated account login |
| `ProfileStore.swift` | Owner-only profile storage, backups, and atomic switching |

## Limitations

- Claude CLI switching is deliberately unsupported because it would require modifying Claude's own credential state.
- All saved Codex accounts are polled live through isolated official app-server processes.
- The compact default shows Claude's 5-hour and Codex's weekly capacity. Use Settings → Menu bar to toggle Claude 5-hour, Claude weekly, Claude Fable, and Codex weekly independently.
- A selected menu-bar value displays `—` when that exact provider window is unavailable; it never substitutes a different window.
- Locally built/ad-hoc signed apps are intended for your own Mac; public downloads should be Developer ID signed and notarized.

## Attribution and license

Based on [everyai-com/notch-limits](https://github.com/everyai-com/notch-limits). The upstream copyright notice is preserved.

MIT — see [LICENSE](LICENSE).
