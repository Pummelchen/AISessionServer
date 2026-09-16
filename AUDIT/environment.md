# Audit environment record

Every tool, version, install method and host. Anything installed during the audit must be
re-installable from this file alone. Update this file in the same commit as any install.

Audit branch: `audit/2026-09-15` (base `971faae`). Ledger: [`ledger.md`](ledger.md).

**The branch was reconciled with `main` on 2026-09-16.** `main` moved nine commits while the audit
ran (`971faae` → `a4bc3ec`), including its own fix for the same S0 as #0017 — a **loopback** client
default (PR #6) rather than this audit's refusal-to-guess — plus a CI runner-label change
(`xcode-27`), the workflow updates, and `AGENTS.md`/`CLAUDE.md`/`RELEASE.md`. `origin/main` was
merged into the audit branch (a merge commit; nothing already pushed was rewritten), the one conflict
(`chatbox-cli.sh`) was resolved in favour of the shipped loopback default with the audit's reasoning
kept in the comment, and section 35's checks were re-pinned to what that design has to guarantee: the
default is loopback, it is never a machine-specific address, and no such address is written into the
client at all. Task #0093 records it. Everything after that merge was re-verified on the merged tree
(base cell GREEN 1027/0, relative-path cell GREEN, 0 false passes, both binaries strict-typecheck 0/0),
and CI (`35131154108`) and CodeQL (`35131157602`) were dispatched from the merged revision
(`8e0f52d`). **Both stayed queued for 30 minutes without starting** (polled every 45s from 00:57 to 01:25; GitHub never picked them up), so monitoring stopped as instructed. The ids remain for collection: CI `35131154108`, CodeQL `35131157602`. The last *completed* runs on this branch are the pre-merge CI `35017564533` (success) and CodeQL `34992397530` (success); the merged workflows differ from them only by main's `runs-on: xcode-27` label.

## Scope honesty note (read first)

The audit brief describes a monorepo of 20+ interdependent projects with Python, C# and C
components. **This repository is not that.** It is a single Swift project plus POSIX `sh`
programs:

| Language | Present | Standard applied |
|---|---|---|
| Swift (6.4) | yes — `chatbox.swift`, `chatbox-mcp.swift` | strict concurrency, warnings-as-errors |
| POSIX `sh` | yes — `chatbox-cli.sh`, `tests/protocol.sh` | `sh -n`, `shellcheck` |
| Python 3.14 | **no** (only throwaway local helpers, never committed) | n/a |
| C# / .NET | **no** | n/a |
| C | **no** | n/a (no sanitizer/C-tooling tasks) |
| Build system / package manager | **none by design** — `xcrun swiftc` invocations | n/a (no lockfiles) |

So the Python/C#/C-specific parts of §1 (type checkers, sanitizer builds, .NET analysers) are
**N/A**, not skipped: there is no code of those languages in the repository or its history
(`git log --diff-filter=A --name-only` shows only `.swift`, `.sh`, `.md`, `.yml`). The
per-language tooling matrix below records that explicitly rather than inventing work.

## Fleet

| Host | Role | Hardware | OS | Swift | Notes |
|---|---|---|---|---|---|
| node1 (`Node1.local`) | development + audit host | Mac mini M2, 8 cores, 8 GB | macOS 27.0 (26A428) | 6.4 (swiftlang-6.4.0.34.1), SDK MacOSX27 | this session; Docker available |
| node2 (`Node2.local`) | independent verification host | Mac mini M2, 8 GB | macOS 26.6.2 | 6.4 (swiftlang-6.4.0.34.1) | SSH key auth from node1 (`ssh node2@node2`) |
| node3, node4 | Mac fleet | Mac mini M2, 8 GB | (not touched this session) | — | listed for the record; nothing installed |
| Debian 13 (Trixie) Intel VPS | Linux/x86 work | — | — | — | **not used**: there is no Linux/x86 work in this repository (no C/.NET/Python), and the brief requires asking before provisioning. Proposed use is recorded in the ledger as a deferred item if a Linux POSIX-`sh` run is wanted. |

Per-host state after this session: **nothing installed on node2/3/4.** Everything below is on
node1 (already installed before this audit, verified by `command -v`), except where the
"installed during audit" column says otherwise.

## Toolchain

| Tool | Version | Install method | Host | Purpose |
|---|---|---|---|---|
| swiftc / swift-driver | 1.168.6, Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) | Xcode CommandLineTools (`xcode-select -p` = `/Library/Developer/CommandLineTools`) | node1 | build, type check, strict concurrency |
| macOS SDK | MacOSX27.sdk (target `arm64-apple-macosx27.0.0`) | bundled with CLT | node1 | build |
| swiftlint | 0.65.1 | `brew install swiftlint` (pre-existing) | node1 | Swift linter |
| swift-format | Apple swift-format (bundled with CLT 6.4) | `xcrun swift-format` | node1 | Swift formatter/linter |
| shellcheck | 0.11.0 | `brew install shellcheck` (pre-existing) | node1 | POSIX `sh` static analysis |
| sh (POSIX) | `/bin/sh` = bash 3.2 in POSIX mode | macOS built-in | node1 | the shell the client and suite are written for |
| dash | (installed during audit — see below) | `brew install dash` | node1 | second POSIX shell for `-n` checks |
| gitleaks | 8.30.1 | `brew install gitleaks` (pre-existing) | node1 | secret scan, **full history** |
| semgrep | 1.1xx (see `baseline/tool-versions.txt`) | `brew install semgrep` (pre-existing) | node1 | SAST (secondary; CodeQL is the primary) |
| CodeQL | GitHub Actions `codeql.yml` (Swift, build-mode manual) | GitHub-hosted | CI | primary SAST |
| Docker | 29.8.0 (build 88096ef005) | Docker Desktop (pre-existing) | node1 | disposable Linux toolchains (unused so far: no Linux work) |
| llvm-cov | Homebrew LLVM 23.1.1 | `brew install llvm` (pre-existing) | node1 | Swift coverage |
| actionlint | 1.7.12 | `brew install actionlint` (installed during the audit) | node1 | GitHub Actions workflow linter |
| sqlite3 | macOS built-in | — | node1, node2 | schema/row inspection in the suite and audit |
| curl, nc, openssl | macOS/Homebrew | — | node1, node2 | protocol tests, fixtures |

Re-install everything on a fresh Mac (documented in one line, per §1):

```sh
xcode-select --install                                   # Swift 6.4 + SDK
brew install swiftlint shellcheck gitleaks semgrep dash llvm actionlint
```

`swift-format` needs no install: it ships with the 6.4 CommandLineTools (`xcrun swift-format`).

## Version policy vs. the repository's documented constraint

`chatbox.swift`'s header declares "Swift 6.3.3, Foundation + Network + SQLite3 only, no external
packages, one file, no build system" and the README documents `xcrun swiftc -O chatbox.swift -o
chatbox`. The audit standard is now **Swift 6.4 with strict concurrency and warnings-as-errors**.

That is a genuine change of contract, not a formality: the 6.4 compiler defaults to the Swift 5
language mode unless asked otherwise, so the standard means building with at least
`-swift-version 6 -strict-concurrency=complete -warnings-as-errors`. Whether the source satisfies
that is a baseline measurement (`baseline/strict-concurrency.txt`) and its findings are ledger
tasks — a build flag that the code does not survive is not "done" by dropping the flag.

Rejected alternative, recorded because it is the tempting shortcut: pinning the README to Swift
6.3.3 and leaving the compiler at its default mode. Rejected because the brief's non-negotiable is
"do not lower compiler strictness", and because the same code must keep building on the CI image
(`macos-latest`), which now ships 6.4.

## What the standard's flags do, and do not, catch

The flag set is the brief's, and it is worth stating plainly that it is not a complete data-race
checker. Measured on swiftlang-6.4.0.34.1:

- A non-Sendable capture in a `@Sendable` closure is a **hard error**
  (`-swift-version 6 -strict-concurrency=complete -warnings-as-errors`, exit 1). That is the class of
  defect tasks #0002-#0005 were about, and it is why the strict build is the yardstick for them.
- A diagnostic Swift downgrades because the API it crosses is `@preconcurrency` stays a **warning even
  with `-warnings-as-errors`** and does not fail the command. Measured with
  `DispatchQueue.async { captured += 1 }`: exit 0 with one `[#SendableClosureCaptures]` warning.

The repository has no such warning today (the strict build and the documented build are both 0
diagnostics), but the flags alone would not stop one from landing. So the audit treats a *non-empty
diagnostic list* as a failure even when the exit code is 0: the build output is read, not just the
status. The CI step added for task #0092 enforces the exit code; reading the log is what covers the
rest, and Phase E records the diagnostic count rather than only "green".

## The mutation matrix

`AUDIT/mutate.sh` is the harness that proves the suite catches the bugs it claims to. It is committed,
because a matrix that lives only in one machine's uncommitted scratch directory cannot be reproduced
and — as task #0091 records — eleven of its cells went stale and were silently skipped before it was
moved here.

```sh
sh AUDIT/mutate.sh                    # every cell, plus the base and relative-path cells
ONLY=name,name sh AUDIT/mutate.sh      # those cells (base and relative always run)
```

How it works and the rules it enforces:

- It freezes `chatbox.swift`, `chatbox-cli.sh`, `chatbox-mcp.swift` and `tests/protocol.sh` into
  `tests/.scratch/frozen/`, so an edit made while a long run is in flight cannot change what the
  surviving cells were measured against.
- Each mutation names an exact fragment of the frozen source. **A fragment that no longer matches
  aborts the run before any cell executes** (no results table, exit 1). Repair the fragment or delete
  the cell in a commit that says why; never leave it stale, because a skipped cell looks exactly like
  a clean one.
- The base cell must be green, every mutation cell must be red, and both the base being red and a
  mutant failing to build are counted with the false passes. The run exits non-zero if there are any.
- The last cell re-runs the suite the way CI does (`sh tests/protocol.sh` from the repository root,
  relative paths, no `CHATBOX_CLI`/`CHATBOX_SCRATCH`).
- One run at a time: the harness refuses to start if another is live, because two runs share the
  scratch directory and the port range.
- Scratch state stays under `tests/.scratch/` (gitignored); the harness writes nothing else.
- Cost: each cell runs the whole suite, so a full matrix is hours. `ONLY=` is what makes re-checking
  one fix affordable.

