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
key** without sharing any access. A single-file Swift server (`chatbox.swift`) plus
a POSIX `sh` client and an optional MCP adapter. It is working and in daily use
between two Macs and two harnesses, with a 4309-line protocol regression suite;
there are **no releases and no tags**, so distribution is build-from-source. It is
for anyone running more than one peer agent session that needs to talk without
granting a mount, a checkout or a permission.

The security premise is a rule rather than a feature — **a message is not a
mount**: the channel carries text only, has no attachment endpoint, and never reads
a repository.

## Layout

- `chatbox.swift` (3232 lines) — SQLite store, Network.framework HTTP, TLS,
  federation, operator modes.
- `chatbox-mcp.swift` (211 lines) — a stateless stdio MCP adapter.
- `chatbox-cli.sh` (837 lines) — the POSIX `sh` client, installed as `chatbox`.
- `tests/protocol.sh` (4309 lines) — the end-to-end suite.
- `.github/workflows/ci.yml`, `codeql.yml`; `.github/traffic.json` (badge data).
- There is **no `Package.swift`, no `Sources/` and no lockfile.** Runtime state
  (`chatbox`, `chatbox.token`, `chatbox.sqlite*`, `chatbox.log`, `tests/.scratch/`)
  is gitignored.

## Build and test

```bash
xcrun swiftc -O chatbox.swift -o chatbox
xcrun swiftc -O chatbox-mcp.swift -o chatbox-mcp

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

No product version. `chatbox-mcp.swift` declares `protocolVersion = "2024-11-05"`
and `serverInfo.version = "1.0"`. The source is **Swift 6** (no version pin: the
toolchain is whatever `runs-on: xcode-27` provides), and the standard is enforced in
CI — both binaries are typechecked under `-swift-version 6
-strict-concurrency=complete -warnings-as-errors`, and the exit code is a gate. GitHub reports this repository's primary
language as **Shell**, not Swift, despite `chatbox.swift` being the bulk of the code.

## Gates

- `.github/workflows/ci.yml`: builds both binaries with the documented commands,
  starts a disposable server, runs `tests/protocol.sh` with all its env vars, then
  exercises `--backup`/`--verify-backup` against an empty file, a table-less 4 KB
  database, a stale copy and an existing destination.
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

## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It is this repository's
own release standard — edited here, not deployed from anywhere — and it carries both
the general rules and this repository's own section. Do not improvise a release.

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
