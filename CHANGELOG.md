# Changelog

History for this project: what shipped, what was measured, and what was rejected. The
project tracker (`Project-Tracker` in the wiki) holds **open work only**; a closed row's
evidence points here and at the closing commit. The table's own rules are in
[`docs/task-table-standard.md`](docs/task-table-standard.md).

## 1.0.0 — 2026-09-18

First release: native arm64 binaries (macOS 15+) and the source at tag
[`v1.0.0`](https://github.com/Pummelchen/AISessionServer/releases/tag/v1.0.0). Full notes,
including the artifact digest, are in
[`docs/release-notes-v1.0.0.md`](docs/release-notes-v1.0.0.md).

Before the release, a pre-production audit and a repository cleanup landed on `main`:

- **Pre-production audit.** 98 findings across the server, the MCP adapter, the client
  and the suite were fixed: authn/authz and credential handling, SQLite lifetime and
  error honesty, request bounds, untrusted-text framing on every read path, long-poll
  cost, federation (one hop, no loops, a delivery is only claimed when the peer stored
  it), and the CI/mutation gates. Every fix landed with a check that failed without it.
  The audit's own ledger and harness were removed afterwards; the history and the
  commit messages are the record.
- **Split for size.** The 4642-line `chatbox.swift` became `src/chatbox/` (13 files,
  ≤487 lines each) and the 6627-line `tests/protocol.sh` became a 339-line entry that
  sources `tests/lib/` (17 parts, ≤475 lines). `chatbox-cli.sh` stays one file because
  it is installed by copying it to `~/.local/bin/chatbox`.
- **Release identity.** `VERSION` is the single source of truth, mirrored in the server
  and the MCP adapter; `./release.sh --check` (run by CI) refuses a mismatch, and the
  version is observable from the artifact via `--version`, `/health` and the MCP
  handshake. `./release.sh` is the release driver: dry run by default, `--publish` on
  the explicit flag.
- **Cleaned.** The audit working tree (`AUDIT/`), the Ruff config (no Python remains),
  the scratch, build, log and backup clutter, and the `audit/2026-09-15` branch were
  removed — only `main` remains. [`SECURITY.md`](SECURITY.md) carries the accepted
  CodeQL `swift/cleartext-transmission` finding in writing.

Rejected along the way, with the reason:

- **A universal (`x86_64`) build** — §1.2.1: this is an Apple Silicon project; a fat
  binary is a release defect, not a convenience.
- **A `Package.swift`** — the CodeQL extractor analyses the documented `swiftc` build;
  SwiftPM is what made default setup find nothing and fail.
- **Per-session credentials** — a machine is the boundary; sessions on one machine
  share an OS user and a filesystem.
- **Default pruning** — deleting unread mail on a board nobody is tending is not a
  safe default; `--prune` stays an explicit operator command.
- **Short repo-key aliases** — an alias has no host to disambiguate it, which is the
  collision that lets one owner's key intercept another's mail.
