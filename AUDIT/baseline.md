# Baseline (audit §3) — the regression yardstick

Captured on **node1** at `971faae` (+ the audit branch's `AUDIT/` directory, which changes no
product code). Raw artefacts are in [`baseline/`](baseline/). No later state may be worse than
this on any metric without an explicit, numbered task.

## Build

| What | Command | Result | Artefact |
|---|---|---|---|
| Documented build, server | `xcrun swiftc -O chatbox.swift -o chatbox` | **rc=0, 0 warnings** | `baseline/build-warnings.txt` |
| Documented build, MCP adapter | `xcrun swiftc -O chatbox-mcp.swift -o chatbox-mcp` | **rc=0, 0 warnings** | `baseline/build-warnings.txt` |
| Audit standard, server | `xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -typecheck chatbox.swift` | **rc=1 — 10 primary errors, 10 primary warnings** (22/20 when continuation lines are counted too; the primary count is the metric used below) | `baseline/strict-concurrency.txt` |
| Audit standard, MCP adapter | same flags, `chatbox-mcp.swift` | rc=0 — 0 errors, 3 warnings (captured-var mutation in the `URLSession` completion) | `baseline/strict-concurrency-mcp.txt` |

Baseline warning count for the *documented* build: **0**. That is the number no change may exceed.
The strict-concurrency build is a new metric with no prior state, so its baseline is "not yet
compliant" and the target is 0/0 (tasks 0001–0005, 0015).

## Tests

| What | Result | Artefact |
|---|---|---|
| `tests/protocol.sh` against a disposable server (CI-equivalent env, `CHATBOX_MCP` set) | **864 passed, 0 failed**, 0 skipped except the documented `sqlite3`/`nc` guards when absent | `../tests/.scratch/manual33/out.txt` (local), CI run 34953230087 |
| Mutation matrix (239 mutations, harness `AUDIT/mutate.sh`) | last full sweep on the pre-audit revision: base GREEN, **226/226 cells red**, relative-path cell GREEN, **0 false passes**. After the audit changed the source, eleven fragments no longer matched and were being skipped (task #0091); they are repaired, the anchor check is now fatal and the harness is committed. The repaired cells were re-verified red individually; a **full 239-cell sweep on the final revision is Phase E work** | `../tests/.scratch/matrix-trk17-run2.log`, `matrix-trk17-final2.log` |
| CI | **success** on `971faae` | https://github.com/Pummelchen/AISessionServer/actions/runs/34953230087 |
| CodeQL | **success** on `971faae`, 1 open alert (`swift/cleartext-transmission`, task 0014) | `baseline/codeql-alerts.txt` |

Coverage: Swift has no built-in coverage without a test harness; the suite drives the server
end-to-end over HTTP, so line coverage is measured with `-profile-generate`/`llvm-cov` against a
disposable server run — see `baseline/coverage.txt` (captured after the heavy baseline slot frees).
There is **no unit-test target**, so coverage is stated for the binary as exercised by the HTTP
suite; a gap in coverage is a gap in end-to-end reachability, not in line-level unit tests.

Baseline `skipped` count: the suite prints `skip` only when an optional tool is missing (`nc`,
`sqlite3`, `CHATBOX_BIN`, `CHATBOX_MCP`); with the CI-equivalent environment all of them run.
**A skip is never allowed to hide an S0/S1 check** — see task 0010 for the shellcheck findings that
could make a check vacuous.

Note on the mid-run toolchain switch: at 16:15 on node1 the CommandLineTools/Xcode 27 SDK landed while the matrix was running, which made four cells fail to *build* (SDK 27 against the 6.3.3 compiler, then an unaccepted Xcode licence). The audit branch records the fix; the four cells were re-run under Swift 6.4 and are red. No cell was left unverified.

## Lint / analyzer / type checker (counts by rule)

| Tool | Command | Findings | Artefact |
|---|---|---|---|
| shellcheck | `shellcheck -s sh chatbox-cli.sh` | **4** (SC1090, SC2059, SC2094 x2) | `baseline/shellcheck-cli.txt` |
| shellcheck | `shellcheck -s sh tests/protocol.sh` | **12** (SC3057 x3, SC2143 x5, SC2059 x2, SC2034, SC2329, SC1090) | `baseline/shellcheck-suite.txt` |
| shellcheck | `shellcheck -s sh AUDIT/mutate.sh` | 0 | `baseline/shellcheck-mutate.txt` |
| swiftlint | `swiftlint lint --reporter json chatbox.swift chatbox-mcp.swift` | **303** across 14 rules (identifier_name 124, line_length 83, non_optional_string_data_conversion 63, cyclomatic_complexity 8, statement_position 5, function_body_length 5, large_tuple 4, …) | `baseline/swiftlint.json`, `baseline/swiftlint-counts.txt` |
| swift-format | `xcrun swift-format lint --strict` | **3309** | `baseline/swift-format.txt` |
| type checker | the strict-concurrency build above | 22 errors | `baseline/strict-concurrency.txt` |
| `sh -n` / `dash -n` | both shell files, both shells | 0 | this file |
| semgrep | `semgrep scan --config p/swift --metrics off` | **0** (Swift rules only; no sh ruleset ran offline) | `baseline/semgrep.json` |
| CodeQL | CI workflow | 1 open alert (task 0014) | `baseline/codeql-alerts.txt` |

## Dependency / CVE scan

**N/A with reason, not skipped.** The repository has no package manager, no lockfile and no
third-party dependency: `chatbox.swift` and `chatbox-mcp.swift` import only `Foundation`,
`Network`, `SQLite3`, `CryptoKit` and `Security` (all OS-provided), and the shell programs call only
`curl`, `openssl`, `sqlite3`, `nc`, `git` and coreutils. There is therefore no dependency tree to
scan; the equivalent control is the CI action pinning finding (task 0006) and the toolchain record
in `environment.md`. `git rev-list --objects --all` shows the largest blob in history is
`tests/protocol.sh` at 247 KB — no vendored archives, no binaries.

## Secret scan

| Scope | Result | Artefact |
|---|---|---|
| **Full history** (`gitleaks git --log-opts=--all`) | **0 leaks in 42 commits**, 537 KB scanned | `baseline/gitleaks-history.txt` |
| **Committed tree** (`git archive HEAD` → `gitleaks dir`) | **0 leaks**, 499 KB | `baseline/gitleaks-tracked.txt` |
| Working tree (includes gitignored runtime state) | 2097 hits, **100 % under `tests/.scratch/`** (1048 `pkcs12-file` + 1048 `private-key` from the per-run TLS fixture, 1 false positive in `mut/names.json`); `tests/.scratch` is 1.8 GB / 120414 files | `baseline/gitleaks-worktree.txt` → task 0013 |

No live-looking credential was found in any committed file or in any commit. The worktree hits are
disposable test fixtures in gitignored state; they are recorded here because the audit must *prove*
that, not assume it — the triage is one command (`git ls-files` for the tracked set, `gitleaks dir`
over `git archive HEAD`).

## Placeholder / facade sweep (§5)

Zero markers in the tracked sources: `chatbox.swift`, `chatbox-mcp.swift`, `chatbox-cli.sh`,
`tests/protocol.sh`, both workflow files and the docs contain no `TODO`, `FIXME`, `HACK`, `XXX`,
`STUB`, `WIP`, `placeholder`, `dummy`, `lorem`, `foo-bar`, `fatalError`, `NotImplemented` or
`not implemented`. The only pattern hits were the words "temporary file" around `mktemp` uses in
`chatbox-cli.sh`. There are no `pass`-style bodies, no always-true validators, no hardcoded success
returns, no simulated work, and no `exit()` used as a stub (the `exit()` calls are the documented
startup refusals and operator modes, each of which prints a reason first).
