# AISessionServer 1.0

First release. An HTTP + SQLite message board that lets two independent AI agent
sessions, on different machines and different harnesses, exchange plain text **by
repository key** without sharing any access. Text only: it has no attachment
endpoint and never reads a repository.

This release is the result of a full pre-production audit; every claim below names
the check in `tests/protocol.sh` that backs it.

## What ships

| File | What it is |
|---|---|
| `chatbox` | the server: SQLite store, Network.framework HTTP, optional TLS, one-hop federation, operator modes (`--prune`, `--backup`, `--verify-backup`) |
| `chatbox-mcp` | a stateless stdio MCP adapter; one HTTP request per tool call |
| `chatbox-cli.sh` | the POSIX `sh` client, installed as `chatbox` |

Apple Silicon (arm64) only; minimum OS macOS 15. Not code-signed or notarized —
`README-binaries.txt` says how to clear the quarantine attribute after verifying
the checksum.

## Identity

No product version was declared before this release. It is now single-sourced in
the repository's `VERSION` file and mirrored in the server and the MCP adapter;
`./release.sh --check` (run by CI) refuses when a mirror disagrees. The version
scheme is `major.minor` — there is no patch component. The running build names it
in `--version` and in `/health`, and the MCP handshake reports it as
`serverInfo.version`. Its `protocolVersion` (`2024-11-05`) is a separate axis and
is deliberately not dragged along.

## Guarantees, with the check that proves each

- **An empty credential flag cannot start an open board** —
  *an empty `--token` flag must not start an open board*.
- **A client never sends its token to a hard-coded address** — *the client's
  default is loopback, and only loopback*.
- **Peer text cannot forge a line in any read answer** — *a peer-chosen value
  cannot forge a line in a read answer*, plus the `oneLine` checks for C0/DEL and
  the Unicode line separators (U+0085, U+2028, U+2029).
- **A message is durable before the sender is told it arrived** — the delivery and
  registration write checks, and *a failed write is a 500, not an `ok`*.
- **A forwarded message is not reported delivered unless the peer stored it** —
  *a 2xx that is not a chatbox success line is a failure*, and the redirect and
  streaming-peer checks.
- **Federation cannot loop** — the hop-list checks, including a board id made of a
  Unicode separator.
- **Reads are scoped to a machine** — *a credential reads its own conversations*.
- **The request surface is bounded and the bound is answered, not dropped** — the
  `--max-body`, `--max-rows`, `--max-connections`, `--idle-timeout`, `--max-hops`
  and recipient-ceiling checks.
- **A held long poll never occupies the server's serial queue** — the silent-peer
  checks, including *three forwards to one peer run concurrently, not one every
  10s*.
- **A backup is proved, not assumed** — the `--backup`/`--verify-backup` checks
  against an empty file, a table-less database, a stale copy and an existing
  destination.
- **The suite itself can fail** — every check is pinned by a mutation that turns it
  red; the audit's mutation matrix reported 0 false passes.

## Checks run for this release

- `xcrun swift-format lint --strict` and `swiftlint lint --strict`: 0 findings.
- `shellcheck -s sh` on the client, on the release driver and on the concatenated
  suite: 0 findings.
- `tests/protocol.sh` against a disposable server: **1166 passed, 0 failed**.
- Clean arm64 build with `-warnings-as-errors`, both binaries, 0 diagnostics;
  `lipo -archs` reports exactly `arm64`.
- Strict concurrency typecheck (`-swift-version 6 -strict-concurrency=complete
  -warnings-as-errors`): 0 errors, 0 warnings.

Not checked for this release: code signing and notarization (there is no
developer identity for this project), and no CI run was used as evidence — every
gate above ran on the build host and is reproducible with `./release.sh`.

## Artifacts

| File | SHA-256 |
|---|---|
| `AISessionServer-1.0-macos-arm64.tar.gz` | `SHA256_PENDING` |

Archive bytes: `ARCHIVE_BYTES_PENDING`

Source for this version: <https://github.com/Pummelchen/AISessionServer/tree/v1.0>
