# Audit report

Generated from [`ledger.json`](ledger.json) on 2026-09-18 (the ledger is the single source of truth; this file is output).

Branch `audit/2026-09-15`, base `971faae`.
Standard: 6.4, -swift-version 6, -strict-concurrency=complete, -warnings-as-errors; POSIX sh, sh -n + dash -n + shellcheck.

## Counts

- Total tasks: **98**
- DONE: **98**
- BLOCKED: **0** (terminal, each with a named owner below)
- Open: **0**
- By severity: S0 7, S1 31, S2 51, S3 9
- By tier: A 77, B 4, C 17

## Phase E — independent verification

- Host: node2 (Mac mini M2, 8 GB, macOS 27.0, Swift 6.4, Xcode 27); revision `d47eda1`; fresh `git clone --branch audit/2026-09-15` from origin
- Build: xcrun swiftc -O: 0 diagnostics for both binaries; `lipo -archs` = arm64
- Strict typecheck: 0 errors / 0 warnings for both binaries
- Gates: swift-format lint --strict 0; swiftlint lint --strict 0; sh -n + dash -n + shellcheck 0 on all three scripts; ruff check + format --check 0
- Scanners: gitleaks full history no leaks; semgrep p/swift 0; CodeQL green in CI; one accepted alert waived in AUDIT/waivers.md W-01
- Suite: tests/protocol.sh 1163 passed / 0 failed
- Coverage: llvm-cov over the suite: 84.89% regions, 92.30% lines, 72.15% functions
- Placeholders: 0 production placeholders (the 5 marker matches are mktemp XXXXXX templates)
- Ledger open: 0
- **Result: PASSED end to end in one clean run**

## Decisions

| id | question | decision |
|---|---|---|
| DEC-01 | Tracker of record: the wiki page as the source of truth, or GitHub Issues with the wiki as the dashboard? | GitHub Issues is the queue for work in flight; the wiki Tracker is the map (open work only, in tables); the in-repo AUDIT ledger is the record of evidence and history. |
| DEC-02 | Repo key form: canonical host/owner/repo, or short aliases such as libfoo? | Canonical `host/owner/repo` only. No short aliases. |
| DEC-03 | Message transport: keep bodies in the URL query string, or move to the POST body? | The POST body is the transport for message fields; the documented query-string form stays for GETs and for compatibility. |
| DEC-05 | Retention default: never prune, or prune acknowledged mail after 90 days? | Never prune automatically. `--prune <days>` stays an explicit operator command with a dry run, and stale sessions are reported, never evicted. |

## Evidence

See [`ledger.md`](ledger.md) for every task's before/after evidence and commit, [`baseline.md`](baseline.md) for the yardstick, [`tool-coverage.md`](tool-coverage.md) for the language-standard and tool-coverage proofs, and [`waivers.md`](waivers.md) for the one accepted scanner finding.

