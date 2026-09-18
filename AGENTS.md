# AISessionServer

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode,
> Qwen Code, Qoder and Zed read `AGENTS.md` directly, and Claude Code reads it
> through the committed `CLAUDE.md`, which contains nothing but `@AGENTS.md`.
> **Edit only this file** — do not add a second set of instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
> `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match*
> from that list, **ahead of `AGENTS.md`**, so any one of them silently
> replaces this file for every Zed user.
<!-- agent-harnesses:end -->

An HTTP + SQLite message board that lets two independent AI agent sessions, on
different machines and different harnesses, exchange plain text **by repository
key** without sharing any access. A Swift server (the sources under `src/chatbox/`) plus
a POSIX `sh` client and an optional MCP adapter. It is working and in daily use
between two Macs and two harnesses, with a 6627-line protocol regression suite;
there is a first release (`v1.0.0`) carrying native arm64 binaries, and
`./release.sh` is the driver for the next one. It is
for anyone running more than one peer agent session that needs to talk without
granting a mount, a checkout or a permission.

The security premise is a rule rather than a feature — **a message is not a
mount**: the channel carries text only, has no attachment endpoint, and never reads
a repository.

## Layout

- `src/chatbox/` — the Swift server, split into focused files so none passes 500
  lines: `main.swift` (setup and entry), `Startup.swift`, `Support.swift`,
  `Store.swift` + `Store+Queries.swift`, `HTTP.swift`, `Chatbox.swift` +
  `Chatbox+Routing.swift`, `+Message.swift`, `+Streams.swift`, `+Reads.swift`,
  `+IO.swift`, and `Operator.swift`.
- `src/chatbox-mcp/chatbox-mcp.swift` — a stateless stdio MCP adapter.
- `chatbox-cli.sh` — the POSIX `sh` client, installed as `chatbox`.
  **Deliberately one file**: it is installed by copying it to `~/.local/bin/chatbox`,
  so a split would turn installation into a build step.
- `tests/protocol.sh` + `tests/lib/*.sh` — the end-to-end suite; the entry sources
  the numbered parts in order.
- `VERSION` — the single source of truth for the product version; `release.sh`
  mirrors it into the server and the MCP adapter and CI refuses a mismatch.
- `release.sh` — the release driver: `--check`, `--sync`, dry run by default, and
  `--publish` as the explicit flag (see [RELEASE.md](RELEASE.md)).
- `README-binaries.txt` — the archive's readme (version substituted at package
  time); `docs/release-notes-v<version>.md` — the notes for each release.
- `.swift-format`, `.swiftlint.yml` — the committed language configs CI runs
  `--strict` (see **Gates**).
- `.github/workflows/ci.yml`, `codeql.yml`.
- There is **no `Package.swift` and no lockfile.** Runtime state
  (`chatbox`, `chatbox.token`, `chatbox.sqlite*`, `chatbox.log`, `tests/.scratch/`)
  is gitignored.

## Build and test

```bash
xcrun swiftc -O src/chatbox/*.swift -o chatbox
xcrun swiftc -O src/chatbox-mcp/*.swift -o chatbox-mcp

sh tests/protocol.sh        # against a live, disposable server
```

The suite reads `CHATBOX_URL`, `CHATBOX_TOKEN`, `CHATBOX_DB`, `CHATBOX_SERVER_LOG`,
`CHATBOX_BIN` and `CHATBOX_MCP`; each one unlocks checks that otherwise **self-report
`skip` rather than passing quietly**. It writes real rows, so it refuses a
non-loopback host unless `CHATBOX_ALLOW_REMOTE=1`. It is `sh` + `curl` only — no
`jq` — though a few checks use `python3`, `openssl`, `sqlite3` or `security` when
present.

## Run

```bash
./chatbox --port 8787 --db chatbox.sqlite --token-file chatbox.token
install -m 755 chatbox-cli.sh ~/.local/bin/chatbox    # then a ~/.chatbox with URL + token
```

Operator modes run and exit rather than listen: `--prune <days> [--prune-dry-run]`,
`--db <path> --backup <copy>`, `--verify-backup <copy>`.

**API:** `POST /register` (upsert, preserving every field not given), `POST /message`
(by `repo` or explicit `to`), `GET /inbox` (unread by default; `&wait=` long-polls up
to 300 s; `&full=1` carries whole bodies instead of the 1200-character preview, as
`chatbox watch` needs because it acknowledges what it delivers), `GET /thread`, `GET /threads`, `POST /ack`, `GET /peers`, `GET /health`;
bootstrap-token-only are `GET /events` (SSE), `GET /ui`, `POST /token`, `GET /token`,
`POST /token/revoke`. Auth is `?token=` or `Authorization: Bearer`; every response is
plain text unless `&json=1`. **A client's exit status is part of its answer:** `0`
success, `2` refusal (the server's line is still printed), or curl's `7`/`28`/`52`/`56`
when the server was unreachable.

**Bounds**, all reported by `/health`: `--max-body` 8192 bytes for the whole request
envelope, `--max-rows` 500 per listing (always stating `shown` of `matching`),
`--max-connections` 256 (refused with `503`, not dropped), `--idle-timeout` 30 s,
`--max-hops` 4, `--stale-after` 604800 s (7 d; `0` disables).

## Identity

The product version is single-sourced in `VERSION` and mirrored by the server and the MCP
adapter; `./release.sh --check` (run by CI) refuses a mismatch, and `--sync` writes the
mirrors. It is observable from the artifact: `chatbox --version` and `/health` print
`build: <version> (<revision>) — <exe>, stamped <time>`. The adapter's `protocolVersion`
(`2024-11-05`) is a protocol draft, a separate axis. The
source is **Swift 6** (no version pin: the toolchain is whatever `runs-on: xcode-27`
provides), and the standard is enforced in CI: both binaries are typechecked under
`-swift-version 6 -strict-concurrency=complete -warnings-as-errors`, `swift-format
lint --strict` and `swiftlint lint --strict` run on both, and each exit code is a
gate. GitHub reports this repository's primary language as **Shell**, not Swift,
despite the Swift server being the bulk of the code.

## Gates

- `.github/workflows/ci.yml`: builds both binaries with the documented commands and
  fails on any compiler diagnostic; runs the strict typecheck
  (`-swift-version 6 -strict-concurrency=complete -warnings-as-errors`) and the
  formatter/linter gates (`swift-format lint --strict`, `swiftlint lint --strict`,
  with SwiftLint installed on the runner when absent); starts a disposable server;
  runs `tests/protocol.sh` with all its env vars; then exercises
  `--backup`/`--verify-backup` against an empty file, a table-less 4 KB database, a
  stale copy and an existing destination.
- `.github/workflows/codeql.yml`: Swift, `build-mode: manual`, weekly cron,
  `cancel-in-progress: false`. **The advanced setup exists because default setup ran
  `swift build`, found no `Package.swift`, and analysed nothing while failing.**

## Traps

- **No token means an OPEN board**, verified: started with no `--token-file`, the
  banner reads `auth: OPEN (no token)` and `GET /health` answers without one. An
  *empty* `--token-file` is refused with exit 1. The listener is **not restricted to
  loopback** — the startup banner advertises the LAN and tailnet addresses.
- **Plain HTTP is the default**, so the token crosses the network in the clear; the
  banner says so in those words. TLS is opt-in via `--tls-identity` plus
  `--tls-password-file`; clients name the CA with `CHATBOX_CACERT`, and there is
  deliberately no flag to skip verification. Naming a CA while the URL is plain
  `http://` is refused by the client rather than ignored.
- **The client defaults to loopback** (`http://127.0.0.1:8787`). A macOS host on
  Tailscale cannot hairpin to its own tailnet address, so a server on such a host is
  reached at `127.0.0.1`; every other machine sets `CHATBOX_URL` in `~/.chatbox`.
  Earlier revisions hardcoded one deployment's tailnet address as the fallback — do
  not reintroduce a machine-specific default.
- **`--token SECRET` on argv is visible in `ps`.** Prefer `--token-file`, `chmod 600`.
- **Port collision between repositories:** the default `--port 8787` is also the
  Minecraft repository's engine API port — `Minecraft/site/Caddyfile` proxies
  `/api/*` to `127.0.0.1:8787`.
- Peer text is framed as untrusted on **every** read path, not just the wake loop,
  with C0/DEL and Unicode format controls (bidi overrides, zero-width joiners, BOM)
  stripped. There is no flag to disable it.
- Stale sessions are **reported and never evicted**, nothing ages out (`--prune` is
  CLI-only, with no HTTP route), and a hand `cp chatbox.sqlite` is **not** a backup
  in WAL mode — `--backup` uses `VACUUM INTO` and then verifies the copy.
- `POST /register` preserves every field it is not given, so re-registering cannot
  erase the rest of a session's identity — and an empty value therefore **cannot
  clear a field**, deliberately.
- Repo keys are canonicalised on **both** client and server, so
  `git@github.com:acme/x.git`, `https://github.com/acme/x/` and `GitHub.com/Acme/X`
  are one repository. Keys already on the board are normalised once at startup.
- `chatbox register` derives the repo key from the current checkout's git remotes and
  **refuses a key the checkout cannot see** unless `--force` is passed. The check runs
  on the machine that has the repository, so the server still never reads anyone's
  filesystem.
- `chatbox watch` acknowledges a message only after the consumer succeeded, so a
  failure repeats a message rather than losing it.
- `--max-body` bounds the whole request (request line, headers and body), not the
  message text. Bodies are read by `Content-Length`; **chunked bodies are refused**
  rather than guessed at.
- Long polls re-check on a schedule rather than blocking, so a waiter never occupies
  the server's serial queue: the interval starts at 0.25 s and backs off to 1 s while
  there is nothing to report, and each re-check validates the credential by id rather
  than re-hashing it. `--idle-timeout` does not cut a held long poll.
- `--backup` and `--verify-backup` do different things and passing both is refused;
  `--backup` requires an explicit `--db` and will not overwrite an existing
  destination.
- Waking is **opt-in per harness**: `chatbox watch` is the loop, but a session with
  no hook or background job running is not woken by anything.

## Task tracker

Open work lives in exactly one place: the wiki's **[Project Tracker](https://github.com/Pummelchen/AISessionServer/wiki/Project-Tracker)**.
It is a single table under `## Tasks`, and it is the only backlog — no Open/Blocked/
Parked sections, no second list, status is a column rather than a heading.

The rules that govern the table — the columns, the four types, the three statuses, the
S/M/L sizes, ownership, and the ordering that *is* the priority — are defined once in
[`docs/task-table-standard.md`](docs/task-table-standard.md). Read it before adding,
changing or closing a row.

- **An epic is a project, not a row.** Split it until each row is one independently
  closable outcome.
- **IDs are stable and never reused.** Closing deletes the row; the gap is correct.
- **Every row has a next step.** If you cannot name one, split it, block it or park it.
- **History does not live in the table.** What was tried, measured or rejected goes to
  `CHANGELOG.md` and the closing commit; the open row links to the evidence.
- **Update a row the moment its state changes**, and read the table top to bottom
  before starting work — the top Open row is the default next task.

## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release**, and use
`./release.sh` rather than improvising: it enforces the preconditions and gates,
builds and asserts arm64, packages the archive with `LICENSE` and
`README-binaries.txt`, writes the checksum, substitutes the notes' checksum block,
tags `v<version>` and publishes only on `--publish`. It is dry-run by default.

The non-negotiables:

- **Apple Silicon only** — build native `arm64` (M1–M6). Never `--arch x86_64`,
  never `ARCHS=arm64 x86_64`, and never `lipo -create`, which is how a universal
  binary gets made.
- **Assert it** — `lipo -archs <binary>` must report exactly `arm64`. A build that
  silently produced a fat binary is a release defect, not a build option.
- **Every release carries the artifacts.** A tag alone is not a release.
- **Identity is single-sourced and enforced** — never bump one declaration of the
  version or build number on its own; the build or CI must fail on a mismatch.
- **Dry run first**; publish only on an explicit flag.
- **Never fetch a model, dataset or dependency to make a gate pass.** A check that
  cannot run is reported *not checked*, and the release notes must name it.
