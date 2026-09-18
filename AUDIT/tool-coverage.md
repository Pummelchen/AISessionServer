# Tool coverage and language-standard proofs (audit §1)

A check handed to a tool is only covered if the tool is **configured to catch it and demonstrably
does**. Every proof below was run on node1 on 2026-09-18 with the tool versions in
[`environment.md`](environment.md); the violating snippet and the tool's own words are recorded.
A tool that stays silent is not coverage: the human check would have to come back or the config
would have to be fixed.

## Language-standard proof (the build must fail on a violation)

The standard is only in force if the build actually fails without it. Each language that exists in
the repository has one proof of a violation the standard rejects.

### Swift — non-Sendable capture across a `@Sendable` boundary (hard error)

```swift
final class NotSendable { var x = 0 }
func take(_ f: @Sendable () -> Void) { f() }
func f() {
    let n = NotSendable()
    take { n.x += 1 }
}
```

```console
$ xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -typecheck sendable4.swift
sendable4.swift:5:12: error: capture of 'n' with non-Sendable type 'NotSendable' in a '@Sendable' closure [#SendableClosureCaptures]
exit=1
```

`-warnings-as-errors` is what makes the diagnostic fatal; without `-swift-version 6
-strict-concurrency=complete` the same code compiles. (A capture across `DispatchQueue.async` or a
`Task` stays a *warning* even with `-warnings-as-errors`, because those APIs are `@preconcurrency`;
`environment.md` records that and the audit treats a non-empty diagnostic list as a failure even
when the exit code is 0. The explicit `@Sendable` form above is the hard-error case.)

### Swift — a force-unwrap must fail SwiftLint `--strict`

```swift
let x: Int? = 1
print(x!)
```

```console
$ swiftlint lint --strict --quiet --config .swiftlint.yml force.swift
force.swift:2:8: error: Force Unwrapping Violation: Force unwrapping should be avoided (force_unwrapping)
```

`force_unwrapping` is an opt-in rule and is enabled in the committed `.swiftlint.yml`; the source is
clean under it (18 existing force-unwraps removed in task #0011).

### Swift — a formatting violation must fail swift-format `--strict`

```swift
func f( ) {let x=1;print(x)}
```

```console
$ xcrun swift-format lint --strict --configuration .swift-format fmt.swift
fmt.swift:1:8: error: [Spacing] remove 1 space
fmt.swift:1:12: error: [Spacing] add 1 space
...
```

### C — N/A with reason, not skipped

There is no C in the repository or its history (`git log --all --diff-filter=A --name-only` is
`.swift`, `.sh`, `.yml`, `.md`, `.json`, LICENSE, `.gitignore` only). There is nothing to compile
under `-std=c99 -pedantic-errors` and no native module for ASan/UBSan to run over.

### Python — Ruff, with the pitfalls the standard names

The only committed Python is `AUDIT/gen-ledger.py`, so the standard is Ruff format + lint with the
families that catch the listed pitfalls, configured in the committed `ruff.toml`.

| Pitfall | Rule that catches it | Proof |
|---|---|---|
| bare `except:` | E722 | `ruff check --select E722 bare.py` → `E722 Do not use bare 'except'` |
| mutable default argument | B006 | `ruff check --config ruff.toml b006.py` → `B006 Do not use mutable data structures for argument defaults` |
| `assert` used for validation | S101 | `ruff check --config ruff.toml s101.py` → `S101 Use of 'assert' detected` |
| `is` compared to a literal, unused loop var, etc. | B | enabled (`select = [..., "B", ...]`) |
| test-shape mistakes | PT | enabled (no test module exists, so the rules are configured and idle) |
| `subprocess` without `check=True` | **no Ruff rule catches it** | recorded honestly: the committed Python uses no `subprocess`, so there is no instance to delegate; if one is added, the check is a human one. |

`ruff check AUDIT/gen-ledger.py` and `ruff format --check AUDIT/gen-ledger.py` are clean under
`ruff.toml`, and `python3 -m compileall AUDIT/gen-ledger.py` succeeds.

### POSIX sh — shellcheck

```sh
#!/bin/sh
foo="bar"
printf "$foo\n"
```

```console
$ shellcheck -s sh sc.sh
In sc.sh line 3:
printf "$foo\n"
       ^------^ SC2059 (info): Don't use variables in the printf format string. Use printf '..%s..' "$foo".
```

The same shellcheck (`-s sh`, 0 findings) is clean on `chatbox-cli.sh`, `tests/protocol.sh` and
`AUDIT/mutate.sh`, and all three parse under both `/bin/sh` and `dash -n`.

## Tool coverage for delegated checks

| Check | Tool + config | Deliberate violation | Tool's answer |
|---|---|---|---|
| Swift concurrency safety | `swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors` (CI step) | non-Sendable capture in a `@Sendable` closure | hard error, exit 1 (above) |
| Swift style | `.swiftlint.yml`, `--strict` | `print(x!)` | `force_unwrapping` error (above) |
| Swift formatting | `.swift-format`, `lint --strict` | `func f( ) {let x=1;...}` | `[Spacing]` errors (above) |
| sh static analysis | `shellcheck -s sh` | `printf "$foo"` | SC2059 (above) |
| Python lint/format | `ruff.toml` | bare `except:`; `def f(x=[])`; `assert` | E722 / B006 / S101 (above) |
| Secrets, full history | `gitleaks git --log-opts=--all` | a generated GitHub PAT in a scratch file | `gitleaks dir` reports `leaks found: 1`; the real history and tracked tree report `no leaks found` |
| Swift SAST | CodeQL Swift (`build-mode: manual`, both binaries) + `semgrep --config p/swift` | — (scanners run in CI and locally; 1 accepted alert is waived in [`waivers.md`](waivers.md)) | semgrep: 0 findings; CodeQL: pinned in CI |
| Mutation anchors | `AUDIT/mutate.sh` `frag_pattern` | a fragment whose *tokens* are gone aborts the run before any cell executes | the harness prints `ANCHOR PROBLEMS` and exits 1; verified against the formatted and the pre-format source (`prepared 305 mutations` both ways) |

## Dead-symbol sweep (§6.2) — periphery is not runnable here, so say so

`periphery` 3.8.0 is installed, but it cannot scan this repository's layout: it needs an Xcode
project or a `Package.swift`, and the repository deliberately has neither. A temporary SPM wrapper
was built to try (two executable targets, Swift 6 language mode, macOS 15) and it compiles both
sources, but this SwiftPM produces no index store for periphery to read, so periphery exits 1 with
`index store path does not exist`. Recorded as **not checked by periphery**, not as clean.

The sweep was done instead by reference count: every `func` name declared in the two Swift files and
the shell client, counted across its own file; a name that occurs only at its declaration is dead.

| File | Declarations | Never referenced |
|---|---|---|
| `chatbox.swift` | 137 | 0 |
| `chatbox-mcp.swift` | 18 | 0 |
| `chatbox-cli.sh` | 25 | 0 |

The three symbols an earlier pass removed (`HTTPOutcome`, `countOrNil`, `Store.lastSeen(of:)`) have
0 textual occurrences, and a commented-out-code sweep of the production sources found only prose
comments (`// for the secret`, `// while the lock is held`), no disabled code.

## Sanitizers

* **C:** N/A — no C (see above).
* **Swift:** `swift test --sanitize=thread` is N/A: there is no `Package.swift` and no test target.
  The concurrency-sensitive paths are exercised by the HTTP suite under the strict-concurrency
  build, and TSan on a Network.framework HTTP server without a SwiftPM test target would require
  inventing a harness that does not exist here. Recorded as not-checked rather than claimed.
