# Audit environment record

Every tool, version, install method and host. Anything installed during the audit must be
re-installable from this file alone. Update this file in the same commit as any install.

Audit branch: `audit/2026-09-15` (base `971faae`). Ledger: [`ledger.md`](ledger.md).

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
| sqlite3 | macOS built-in | — | node1, node2 | schema/row inspection in the suite and audit |
| curl, nc, openssl | macOS/Homebrew | — | node1, node2 | protocol tests, fixtures |

Re-install everything on a fresh Mac (documented in one line, per §1):

```sh
xcode-select --install                                   # Swift 6.4 + SDK
brew install swiftlint shellcheck gitleaks semgrep dash llvm
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
