# Audit ledger

Machine-readable twin: [`ledger.json`](ledger.json) (it wins on conflict). Environment: [`environment.md`](environment.md). Scope: [`inventory.md`](inventory.md). Baseline: [`baseline.md`](baseline.md).

Branch `audit/2026-09-15`, base `971faae`. Standard: 6.4, -swift-version 6, -strict-concurrency=complete, -warnings-as-errors; POSIX sh, sh -n + dash -n + shellcheck.

**Open: 16 | done: 0 | blocked: 0 | total: 16** (S0 0, S1 6, S2 6, S3 4)

Status gates (a status may not advance without the artefact): START = reproduced/statically proven + expected behaviour written down; PROGRESS = the diff; TEST = a check that fails before and passes after, full suite green, no new warnings; AUDIT = cold re-read + lint/analyzer/scanners re-run + no baseline regression; DONE = committed atomically to the audit branch.

| id | sev | module | file:line | title | category | status | host | discovered by |
|---|---|---|---|---|---|---|---|---|
| [0001](#0001) | S1 | M1 | `chatbox.swift (whole file)` | Source does not build under the audit standard (Swift 6 language mode, strict concurrency, warnings-as-errors) | unsafe | **START** | node1 | phase-A baseline |
| [0002](#0002) | S1 | M1 | `chatbox.swift:1062,1070` | Static ISO8601DateFormatter instances are shared mutable state (not Sendable) | unsafe | **START** | node1 | phase-A baseline |
| [0003](#0003) | S1 | M1 | `chatbox.swift:1238` | `Chatbox.publicURL` is a mutable static global | unsafe | **START** | node1 | phase-A baseline |
| [0004](#0004) | S1 | M1 | `chatbox.swift:27,3215,3217,3221` | Top-level configuration `let`s are MainActor-isolated and referenced from nonisolated code | unsafe | **START** | node1 | phase-A baseline |
| [0005](#0005) | S1 | M1 | `chatbox.swift:2464,1155-1180,1700-1745,1600-1660` | Non-Sendable captures and captured-var mutation across @Sendable closures (DispatchWorkItem, URLSession completion, waiters, event poll) | unsafe | **START** | node1 | phase-A baseline |
| [0015](#0015) | S1 | M1 | `chatbox.swift:896,373` | `@unchecked Sendable` on Chatbox and Store suppresses all concurrency checking | unsafe | **START** | node1 | L2 |
| [0006](#0006) | S2 | M5 | `.github/workflows/ci.yml:31,40 ; codeql.yml:44,47,60` | CI actions are pinned to mutable tags, not commit SHAs | deps | **START** | node1 | L0 |
| [0007](#0007) | S2 | M1/M2 | `chatbox.swift (63 sites), chatbox-mcp.swift` | 63 force-unwrapped String.data(using:.utf8)! conversions | unsafe | **START** | node1 | L0 swiftlint baseline |
| [0008](#0008) | S2 | M3 | `chatbox-cli.sh:203` | Variable interpolated into a printf format string (SC2059) | bug | **START** | node1 | L0 shellcheck baseline |
| [0009](#0009) | S2 | M3 | `chatbox-cli.sh:456,463` | A pipeline both reads and writes the same file (SC2094) - truncation/data-loss risk | bug | **START** | node1 | L0 shellcheck baseline |
| [0010](#0010) | S2 | M4 | `tests/protocol.sh:1284,1679,1689,2054,2551,2676,3021,3299,3312,3459,3565,3941` | Shellcheck findings in the suite (SC3057 x3 quoted substring, SC2143 x5, SC2059 x2, SC2034, SC2329) | test | **START** | node1 | L0 shellcheck baseline |
| [0014](#0014) | S2 | M1 | `chatbox.swift:2426` | CodeQL swift/cleartext-transmission (high) on the HTTP listener - waiver or design change | unsafe | **START** | node1 | L0 |
| [0011](#0011) | S3 | M1/M2/M4 | `repository-wide` | Formatter/linter baseline: 3309 swift-format findings, 303 swiftlint findings | style | **START** | node1 | L0 |
| [0012](#0012) | S3 | M6/M1 | `README.md:11, chatbox.swift:6` | Documented toolchain (Swift 6.3.3) contradicts the audit standard (Swift 6.4 + strict concurrency) | docs | **START** | node1 | phase-A |
| [0013](#0013) | S3 | M7 | `tests/.scratch` | Unbounded scratch growth: 1.8 GB / 120414 files from mutation runs and per-cell TLS fixtures | style | **START** | node1 | L0 secret-scan triage |
| [0016](#0016) | S3 | M3 | `chatbox-cli.sh:30` | SC1090: the client sources a non-constant path (~/.chatbox) | style | **START** | node1 | L0 shellcheck baseline |

## Task detail

### 0001

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift (whole file)`
- **Title:** Source does not build under the audit standard (Swift 6 language mode, strict concurrency, warnings-as-errors)
- **Status:** START
- **Evidence (before):** AUDIT/baseline/strict-concurrency.txt: rc=1, 22 errors + 20 warnings. Kinds: 3x non-Sendable static ISO8601DateFormatter/publicURL, 4x main-actor-isolated top-level lets (TRANSIENT, tlsIdentity, peerURL) referenced from nonisolated code, 2x DispatchWorkItem capture, 18x captured-var mutation / non-Sendable capture in @Sendable closures.
- **Fix:** Umbrella task. Sub-tasks 0002-0005 carry the actual diffs; this closes when `xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors` is clean for chatbox.swift and chatbox-mcp.swift and the documented build/README state the same flags.
- **Notes:** Existing `@unchecked Sendable` on Chatbox/Store is the reason the checker is silent today; the brief forbids adding it as a fix. The serial-queue invariant is real, so the fix is to express it (see 0005), not to annotate it away.

### 0002

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:1062,1070`
- **Title:** Static ISO8601DateFormatter instances are shared mutable state (not Sendable)
- **Status:** START
- **Evidence (before):** chatbox.swift:1062:16: error: static property 'iso' is not concurrency-safe because non-'Sendable' type 'ISO8601DateFormatter' may have shared mutable state; same at 1070 for 'isoTiny'.
- **Fix:** Replace the two formatters with `Date.ISO8601FormatStyle` (Sendable) or per-call formatting; keep the fractional-seconds fallback parse. Must not regress the hot path (`nowISO()` is called per write).
- **Notes:** Rejected: `nonisolated(unsafe)` - same escape hatch as @unchecked Sendable, forbidden as a fix.

### 0003

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:1238`
- **Title:** `Chatbox.publicURL` is a mutable static global
- **Status:** START
- **Evidence (before):** chatbox.swift:1238:16: error: static property 'publicURL' is not concurrency-safe because it is nonisolated global shared mutable state.
- **Fix:** Make the public URL an immutable value produced once from configuration and passed into Chatbox (used by usage()/`GET /`), removing the static var.

### 0004

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:27,3215,3217,3221`
- **Title:** Top-level configuration `let`s are MainActor-isolated and referenced from nonisolated code
- **Status:** START
- **Evidence (before):** chatbox.swift:3215:22 error: main actor-isolated var 'peerURL' can not be referenced from a nonisolated context (x2); 3217/3221 'tlsIdentity'; 27:1 'TRANSIENT'.
- **Fix:** Move startup configuration into a `Sendable` struct (or make the file a library with an explicit entry point) so the listener/shutdown code receives immutable config instead of reaching for globals. TRANSIENT (sqlite destructor sentinel) becomes a nonisolated immutable constant.
- **Notes:** Root cause is that top-level code in a single-file executable is implicitly @MainActor under Swift 6 mode.

### 0005

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:2464,1155-1180,1700-1745,1600-1660`
- **Title:** Non-Sendable captures and captured-var mutation across @Sendable closures (DispatchWorkItem, URLSession completion, waiters, event poll)
- **Status:** START
- **Evidence (before):** 20 warnings promoted to errors: capture of 'idle' DispatchWorkItem; 6x mutation of captured var (answer, status, redirectedTo, req, touch, nextKeep); 2x capture of 'waiter'.
- **Fix:** Replace the completion-handler + semaphore shapes with async/await (`URLSession.data(for:)`) or `Synchronization.Mutex`-protected boxes, and stop capturing mutable vars: values cross actor/queue boundaries as immutable results. Keep the documented single-serial-queue invariant expressed in types.
- **Notes:** This is the core of 0001 and the largest single change in the audit.

### 0015

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:896,373`
- **Title:** `@unchecked Sendable` on Chatbox and Store suppresses all concurrency checking
- **Status:** START
- **Evidence (before):** final class Chatbox: @unchecked Sendable; final class Store: @unchecked Sendable. Every cross-thread access in the file relies on this promise; the compiler therefore reports nothing today (the 0001 baseline shows what it would report without it).
- **Fix:** Either express the serial-queue invariant in types the compiler can check (a global actor or an actor per store) or keep the annotation with an explicit, reviewed invariant comment *and* keep all current and future calls on the queue - decision recorded; the brief forbids adding such annotations, so the audit's default is the typed model.
- **Notes:** Overlaps 0001/0005; kept separate because it is the reviewable decision, not the mechanical fix.

### 0006

- **Severity / category / module:** S2 / deps / M5
- **Location:** `.github/workflows/ci.yml:31,40 ; codeql.yml:44,47,60`
- **Title:** CI actions are pinned to mutable tags, not commit SHAs
- **Status:** START
- **Evidence (before):** uses: actions/checkout@v7, github/codeql-action/init@v4, github/codeql-action/analyze@v4
- **Fix:** Pin each action to a full commit SHA with the tag in a comment; record the update procedure.

### 0007

- **Severity / category / module:** S2 / unsafe / M1/M2
- **Location:** `chatbox.swift (63 sites), chatbox-mcp.swift`
- **Title:** 63 force-unwrapped String.data(using:.utf8)! conversions
- **Status:** START
- **Evidence (before):** swiftlint rule non_optional_string_data_conversion x63 (AUDIT/baseline/swiftlint.json)
- **Fix:** Use the non-failable `Data(_:)` initializer (or a tiny helper) so no `!` remains on a conversion that cannot fail.

### 0008

- **Severity / category / module:** S2 / bug / M3
- **Location:** `chatbox-cli.sh:203`
- **Title:** Variable interpolated into a printf format string (SC2059)
- **Status:** START
- **Evidence (before):** SC2059 (info) 'Don't use variables in the printf format string' - a value containing % is reinterpreted as a directive.
- **Fix:** Pass the value as an argument to printf '%s' with a fixed format.
- **Notes:** Also appears twice in tests/protocol.sh.

### 0009

- **Severity / category / module:** S2 / bug / M3
- **Location:** `chatbox-cli.sh:456,463`
- **Title:** A pipeline both reads and writes the same file (SC2094) - truncation/data-loss risk
- **Status:** START
- **Evidence (before):** SC2094 x2 'Make sure not to read and write the same file in the same pipeline'.
- **Fix:** Read into a variable or write to a temporary file and move it into place atomically; never redirect into a file the same pipeline is reading.

### 0010

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:1284,1679,1689,2054,2551,2676,3021,3299,3312,3459,3565,3941`
- **Title:** Shellcheck findings in the suite (SC3057 x3 quoted substring, SC2143 x5, SC2059 x2, SC2034, SC2329)
- **Status:** START
- **Evidence (before):** AUDIT/baseline/shellcheck-suite.txt - 12 findings; SC3057 is a real parsing hazard in parameter expansion.
- **Fix:** Triage each: fix the real ones (SC3057/SC2059) and add targeted directives with justification where the pattern is deliberate.
- **Notes:** A check that silently mis-parses is a vacuous check (the file's own design rule).

### 0014

- **Severity / category / module:** S2 / unsafe / M1
- **Location:** `chatbox.swift:2426`
- **Title:** CodeQL swift/cleartext-transmission (high) on the HTTP listener - waiver or design change
- **Status:** START
- **Evidence (before):** 1 open code-scanning alert #1 swift/cleartext-transmission, severity high, chatbox.swift:2426. TLS is opt-in by documented design (README/Deployment/Architecture), so the alert is accurate rather than a false positive.
- **Fix:** Decision task: (a) keep plaintext support and record a written waiver in the repo (AUDIT/waivers.md) plus a CodeQL dismissal with the same justification, or (b) make TLS mandatory (breaking every client URL and the documented deployment). Recommendation: (a) - the channel is documented for private networks and the client already supports TLS; forcing it is a product decision, not a defect fix.
- **Notes:** Rejected as a fix: silencing CodeQL. The alert stays visible unless a human decision says otherwise.

### 0011

- **Severity / category / module:** S3 / style / M1/M2/M4
- **Location:** `repository-wide`
- **Title:** Formatter/linter baseline: 3309 swift-format findings, 303 swiftlint findings
- **Status:** START
- **Evidence (before):** AUDIT/baseline/swift-format.txt (3309), AUDIT/baseline/swiftlint-counts.txt (303: identifier_name 124, line_length 83, non_optional_string_data_conversion 63, cyclomatic_complexity 8, ...)
- **Fix:** Add a committed formatter config matching the project's real style, apply it in one formatting-only commit, and keep swiftlint's substantive rules on while disabling the ones that fight documented design (file_length for the single-file constraint) with a written reason.
- **Notes:** Formatting must be its own commit, never mixed into a fix (brief S10).

### 0012

- **Severity / category / module:** S3 / docs / M6/M1
- **Location:** `README.md:11, chatbox.swift:6`
- **Title:** Documented toolchain (Swift 6.3.3) contradicts the audit standard (Swift 6.4 + strict concurrency)
- **Status:** START
- **Evidence (before):** chatbox.swift header: 'Swift 6.3.3, Foundation + Network + SQLite3 only'; README build line has no language mode or strictness flags.
- **Fix:** Update the documented build to the flags that are actually required, in the same commit as the code that satisfies them (0001).

### 0013

- **Severity / category / module:** S3 / style / M7
- **Location:** `tests/.scratch`
- **Title:** Unbounded scratch growth: 1.8 GB / 120414 files from mutation runs and per-cell TLS fixtures
- **Status:** START
- **Evidence (before):** du -sh tests/.scratch = 1.8G; find | wc -l = 120414; gitleaks worktree scan took 71s over 1.34 GB and reported 2097 hits, 100% under tests/.scratch (1048 pkcs12-file + 1048 private-key from the TLS fixture, 1 false positive in mut/names.json).
- **Fix:** Have the harness prune per-cell scratch (keep only the failing cell's artefacts) and delete the accumulated directory once no run is active. Command + rollback are logged in the ledger before running.
- **Notes:** Tracked tree and full history are clean (gitleaks: 0 leaks in 42 commits, 0 in git archive HEAD).

### 0016

- **Severity / category / module:** S3 / style / M3
- **Location:** `chatbox-cli.sh:30`
- **Title:** SC1090: the client sources a non-constant path (~/.chatbox)
- **Status:** START
- **Evidence (before):** SC1090 (warning): ShellCheck can't follow non-constant source.
- **Fix:** Add a `# shellcheck source=/dev/null` directive with a comment explaining that the path is the documented config file, and confirm the file is only read (never executed from an untrusted location).
- **Notes:** Sourcing a shell file executes it: check the ownership/permission expectations of ~/.chatbox.

## Destructive or system-changing operations (command + rollback, logged before running)

| Date | Command | Why | Rollback |
|---|---|---|---|
| 2026-09-15 | `brew install dash` | second POSIX shell for `-n` checks (the suite targets `sh`; bash-3.2-in-POSIX-mode is the primary) | `brew uninstall dash-shell` |
| 2026-09-15 | `git checkout -b audit/2026-09-15` (from `971faae`) | the brief requires all audit work on `audit/<date>`, never on main | `git branch -D audit/2026-09-15` while main is untouched |

