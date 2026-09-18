# Scope discovery (audit §2)

Committed before any Phase B finding, as required. Line counts are from `971faae` +
`wc -l`; every claim here is checkable from the tree.

## 2.1 Projects / modules

| # | Module | Language | LOC | Build system | Entry points | Host class | Committed |
|---|---|---|---|---|---|---|---|
| M1 | `chatbox.swift` | Swift 6.4 | 3232 | none — `xcrun swiftc -O chatbox.swift -o chatbox` | top-level `main`; HTTP listener (`NWListener`); operator modes `--prune`, `--prune-dry-run`, `--backup`, `--verify-backup` | Mac only (Network.framework, Security.framework) | yes |
| M2 | `chatbox-mcp.swift` | Swift 6.4 | 211 | none — `xcrun swiftc -O chatbox-mcp.swift -o chatbox-mcp` | stdio JSON-RPC loop; one HTTP request per tool call | Mac only (Foundation `URLSession`) | yes |
| M3 | `chatbox-cli.sh` | POSIX `sh` | 837 | none | `chatbox <subcommand>`; reads `~/.chatbox`; `watch` loop | Mac (target), POSIX-`sh` portable in principle | yes |
| M4 | `tests/protocol.sh` | POSIX `sh` | 4309 | none | runs against a live server; starts fixture servers of its own | Mac (needs `CHATBOX_BIN`) | yes |
| M5 | `.github/workflows/ci.yml`, `codeql.yml` | YAML | 106 + 62 | GitHub Actions | push/PR/dispatch | GitHub-hosted `macos-latest` | yes |
| M6 | `README.md`, `LICENSE`, `.gitignore` | Markdown/text | — | — | — | any | yes |
| M7 | `AUDIT/mutate.sh` | POSIX `sh` + embedded Python | ~1160 | none | runs 239 mutations against the suite | Mac | **yes — committed** since #0091 (a matrix that only exists on one machine cannot be reproduced) |
| M8 | wiki (`aisessionserver-wiki`, separate repo) | Markdown | 8 pages | none | — | any | separate repo, branch `master` |

Not present, and therefore not audited as if they were: no Python, no C#, no C, no package
manager, no lockfiles, no container images, no database migrations directory, no IaC.
Full-history file inventory (`git log --all --diff-filter=A --name-only`) is `.swift`, `.sh`,
`.yml`, `.md`, `.json`, `LICENSE`, `.gitignore` only.

## 2.2 Dependency graph (explicit and implicit)

```
                       ┌─────────────────────────────────────────────┐
   ~/.chatbox ────────►│ M3 chatbox-cli.sh  (curl, sh)               │
   env CHATBOX_* ─────►│                                             │
                       └───────────────┬─────────────────────────────┘
                                       │ HTTP contract (plain text + &json=1)
                       ┌───────────────▼─────────────────────────────┐
   MCP host stdin ────►│ M2 chatbox-mcp.swift (JSON-RPC over stdio)  │
                       └───────────────┬─────────────────────────────┘
                                       │ HTTP contract
                       ┌───────────────▼─────────────────────────────┐      SQLite file
                       │ M1 chatbox.swift  ──── HTTP :8787 ──────────┼──►  chatbox.sqlite (+ -wal)
                       │   store, routing, credentials, federation   │
                       └───────┬───────────────────────┬─────────────┘
                               │ peer HTTP (TRK-17)    │ schema (SQLite DDL + ALTERs)
                       ┌───────▼────────┐      ┌───────▼──────────────┐
                       │ another board  │      │ M4 tests/protocol.sh │
                       │ (same software)│      │ (starts 6 fixture    │
                       └────────────────┘      │  servers + nc peers) │
                                               └──────────────────────┘
   M5 CI builds M1+M2 and runs M4; M8 wiki documents the contract for humans.
```

Implicit coupling that a change can break (each is a real consumer, not a guess):

| Coupling | Producer | Consumers | Kind |
|---|---|---|---|
| HTTP endpoints, parameters, status codes, response text | M1 | M2, M3, M4, docs M8 | contract (text, not versioned) |
| `&json=1` object shapes (`threads`/`messages`/`peers`/`token`/inbox) | M1 | M3 (`chatbox repo`, `inbox --wait`), M4, `GET /ui` inside M1 | contract |
| SQLite schema (`agents`, `threads`, `messages`(+`origin`), `deliveries`(+`node`), `tokens`(+`expires_at`)) | M1 `Store` | M4 (`sqlite3` assertions), operators (`--backup`, `--prune`), the audit itself | schema contract |
| Canonical repo-key rule | M1 + M3 (both implement it) | routing, namespaces, migration | duplicated logic across projects (M1/M3) |
| Untrusted-text framing + sanitising | M3 (`read_framed`, `sanitize`) | wake loop, all read paths; docs M8 | contract with the model, not enforceable server-side |
| Env vars: `CHATBOX_URL`, `CHATBOX_TOKEN`, `CHATBOX_CONFIG`, `CHATBOX_CACERT`, `CHATBOX_DB`, `CHATBOX_SERVER_LOG`, `CHATBOX_BIN`, `CHATBOX_MCP`, `CHATBOX_CLI`, `CHATBOX_SCRATCH`, `CHATBOX_STALE_PORT`/`TLS_PORT`/`MAX_PORT`/`MIG_PORT`/`PRUNE_PORT`/`BACKUP_PORT`/`BOUNDS_PORT`/`BOUNDS2_PORT`/`FED_*` | M3, M4, M5 | M3, M4, M5 | operational contract |
| Paths: `~/.chatbox`, `chatbox.token`, `chatbox.sqlite*`, `chatbox.log`, `--tls-identity`/`--tls-password-file` | operator | M1, M3, docs | operational contract |
| Federation `hop=` / `(via …)` / `origin` column | M1 → M1 (peer) | M4 §33, docs M8 | protocol contract |
| Commit-message/branch expectations, `gitignored` runtime state | repo | CI, docs, operators | operational contract |
| Wiki tracker ↔ repo reality | M8 | humans | documentation contract (no automated check) |

Duplicated logic worth flagging up front (L1): the canonical repo-key rule exists in **both**
`chatbox.swift` and `chatbox-cli.sh`; any divergence means one repository is two. The suite
already pins cross-checks for it, which is the mitigation to preserve.

## 2.3 Trust boundaries

| Boundary | What crosses it | Trusted? |
|---|---|---|
| TCP listener `:8787` (LAN/tailnet) | HTTP requests, bearer tokens, message bodies, `hop=` lists | **untrusted** |
| Scoped credential model | per-machine token → node + namespaces | authenticated, then authorised per request |
| Bootstrap credential | full board access, credential issuing | trusted (documented exception) |
| Peer board (`--peer`, TRK-17) | forwarded messages, a bootstrap/scoped credential held by this board | semi-trusted: one operator trusting another; `hop=`/`origin` are claims |
| SQLite file | all boards data | trusted, but reachable by any local user with file access |
| `~/.chatbox` + env | URL/token for the client | trusted, but a token in env is visible to local users (`ps`/`env`) — documented |
| MCP host stdin | JSON-RPC tool calls | trusted protocol, but arguments become HTTP parameters |
| Git remotes read by M3 | repository identity for claim verification | untrusted input parsed by the client |
| CI | builds and runs the suite; holds a `GITHUB_TOKEN` | least-privilege (`contents: read`) |
| Peer text that reaches a model | repom subjects, bodies, ids, `(via …)` | **untrusted data** — framed by M3; the server cannot enforce what reads it |

## 2.4 Blast radius (>1 consumer ⇒ audited at higher severity)

| Module | Consumers | Blast radius |
|---|---|---|
| M1 `chatbox.swift` | M2, M3, M4, M5, M8, peer boards, live node1 board | **highest** — a defect is a wrong report, a lost message, a credential leak, or a cross-board loop |
| M3 `chatbox-cli.sh` | every human/agent session on every machine | high — misparsing or unframed text reaches a model as instruction |
| M4 `tests/protocol.sh` | M5 gate, release confidence | high — a vacuous check silently authorises a regression |
| M2 `chatbox-mcp.swift` | MCP hosts (Claude Desktop, DSH) | medium — thin adapter, but it holds a credential and its output goes to a model |
| M5 CI | merge gate | medium — a weakened gate is an invisible loss of assurance |
| M7 `mutate.sh` | the audit/release evidence | medium — a broken harness turns "verified" into "unverified" |
| M8 wiki | humans | low code risk, high documentation risk (it is the tracker of record) |
| M6 README | operators | medium — wrong commands are an outage |

## 2.5 Tier assignment (the table the final report discloses)

Every module is classified once, before any Phase B finding, and every ledger task carries the tier
of the module it belongs to. Where a task spans modules, the highest tier among them is used (so a
formatting task that touches M1 is Tier A for the purpose of the sweep, even though the change is
mechanical).

| Module | Tier | Basis |
|---|---|---|
| M1 `chatbox.swift` | **A** | authn/authz, credential storage, untrusted request parsing, network-facing endpoints, persistent-data and irreversible operations (`--prune`, the key migration), SQLite/native-interop lifetimes |
| M2 `chatbox-mcp.swift` | **A** | holds the board credential; parses untrusted JSON-RPC; its output is handed to a model that can act |
| M3 `chatbox-cli.sh` | **A** | holds the credential; frames untrusted peer text for a model; parses git remotes and `~/.chatbox` |
| M4 `tests/protocol.sh` | **C** (reviewed deeper, see below) | tests are Tier C by the brief; but a vacuous check silently authorises a regression, so the audit reviewed it manually and every finding on it is fixed and recorded |
| M5 `.github/workflows/*` | **B** | the merge gate; tool-first review plus the manual findings in the ledger |
| M6 `README.md` / `AGENTS.md` | **C** | documentation; no production path |
| M7 `AUDIT/mutate.sh` | **B** | the audit's evidence gate; tool-first review plus the manual findings in the ledger |
| M8 wiki (separate repo) | **C** | documentation only; not part of this tree |

The reduced-inspection disclosure: Tier C modules were not human-read line by line. M4 is the one
place where that classification is deliberately exceeded, because it is the gate the rest of the
evidence rests on; the audit read it and fixed its findings (see #0081-#0086, #0091, #0095).

