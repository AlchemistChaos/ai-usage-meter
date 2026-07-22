# Live Codex Rate Limits

## Goal

Restore accurate Codex usage in AI Meter after Codex stopped reliably logging
the legacy `x-codex-*` response headers. The menu-bar summary and dashboard
must show the current active account's rate limit without removing the existing
cached readings used for inactive accounts.

## Chosen approach

AI Meter will periodically start the installed `codex app-server` over stdio,
initialize a JSON-RPC session, request `account/rateLimits/read`, parse the
returned primary and secondary windows, and then exit the helper process. This
uses Codex's own authenticated rate-limit client and avoids duplicating private
HTTP authentication inside AI Meter.

A persistent app-server connection was rejected because it adds lifecycle,
reconnection, and notification-merging complexity that is unnecessary for a
five-minute usage poll. Calling Codex's private HTTP endpoint directly was
rejected because its authentication and request contract are more fragile than
the app-server protocol bundled with the installed CLI.

## Components and data flow

`CodexProvider` will own an asynchronous live-snapshot function. A small,
injectable process runner will make its JSON-RPC output testable without
launching Codex in unit tests. The provider will:

1. Resolve the installed `codex` executable.
2. Launch `codex app-server --listen stdio://`.
3. Send `initialize` followed by `account/rateLimits/read`.
4. Ignore unrelated notifications and match the rate-limit response by request
   identifier.
5. Convert each returned window into the existing `UsageWindow` model and stamp
   the snapshot with the current time.

`AccountManager` will poll this live source at most once every five minutes and
store a successful result in `SnapshotCache` under the active Codex account ID.
It will then rebuild the account rows, which updates both the dashboard and the
menu-bar `C` value. Existing SQLite header harvesting remains as a fallback and
continues to supply historical readings for inactive accounts.

## Failure handling

The helper process will have a finite timeout and will be terminated after the
response or timeout. Missing executables, malformed JSON, protocol errors,
authentication failures, and timeouts will leave the newest cached snapshot in
place and expose a concise Codex error through the manager's existing error
surface. A failed live poll must not overwrite a newer cached snapshot with the
older SQLite fallback.

Only the active Codex credential is polled. Switching accounts causes the next
refresh to poll the newly active account rather than attributing a response to
the previous one.

## Testing and verification

Parser tests will cover a current `account/rateLimits/read` response, unrelated
JSON-RPC messages, absent secondary windows, and malformed/error responses. A
manager/provider test will verify that a live snapshot takes precedence over a
legacy cached reading for the matching account.

Verification will include the full Swift test suite, a release build, and a
live diagnostic query showing that AI Meter reads the same percentage as the
installed Codex app-server. The installed application will only be replaced or
relaunched after those checks pass.
