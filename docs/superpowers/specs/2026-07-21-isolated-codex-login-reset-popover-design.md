# Isolated Codex Login and Reset Popover Design

## Goal

Add another Codex account without logging out or replacing the active Codex credential, and expose inactive-account reset details on click.

## Codex login

The settings menu gains **Add OpenAI Codex account**. CCManager launches the installed official `codex login` command with a newly created isolated `CODEX_HOME` under CCManager's private data directory. That directory contains a config forcing file credential storage. The existing `~/.codex/auth.json` is never read, modified, moved, or replaced by this login.

After the browser OAuth flow succeeds, CCManager validates the isolated `auth.json`, copies it with owner-only permissions into the existing saved-profile store, refreshes the account list, and removes the temporary login directory. The current Codex account remains active. Cancelling terminates only the isolated login process and removes its temporary files.

Profile names reuse an existing profile when the account ID matches. New accounts use a filesystem-safe full email address, avoiding collisions between equal email prefixes on different domains.

The existing **Import current OpenAI Codex login** action remains available for users who intentionally authenticated through the normal CLI.

## Reset details

Clicking an inactive account card opens a compact popover with one row per relevant window, including weekly and 5-hour limits. Each row shows remaining percentage plus reset countdown and absolute date/time. When the provider has not supplied a future reset, the row says **Available after using this account** rather than displaying a dash or inventing a timestamp.

Inline reset rows are removed from compact cards to keep the grid dense. Active account rows retain their existing inline reset information.

## Safety and verification

- No new dependency or app-owned network endpoint is added.
- OAuth traffic is performed by the installed official Codex CLI against OpenAI.
- The active Codex credential path is unchanged throughout isolated login.
- Naming, reset copy, and presentation behavior receive regression coverage.
- The release app is rebuilt, installed, launched, and hash-verified.
