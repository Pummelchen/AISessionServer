# Audit ledger

Machine-readable twin: [`ledger.json`](ledger.json) (it wins on conflict). Environment: [`environment.md`](environment.md). Scope: [`inventory.md`](inventory.md). Baseline: [`baseline.md`](baseline.md).

Branch `audit/2026-09-15`, base `971faae`. Standard: 6.4, -swift-version 6, -strict-concurrency=complete, -warnings-as-errors; POSIX sh, sh -n + dash -n + shellcheck.

**Open: 82 | done: 7 | blocked: 0 | total: 89** (S0 7, S1 31, S2 44, S3 7)

Status gates (a status may not advance without the artefact): START = reproduced/statically proven + expected behaviour written down; PROGRESS = the diff; TEST = a check that fails before and passes after, full suite green, no new warnings; AUDIT = cold re-read + lint/analyzer/scanners re-run + no baseline regression; DONE = committed atomically to the audit branch.

| id | sev | module | file:line | title | category | status | host | discovered by |
|---|---|---|---|---|---|---|---|---|
| [0017](#0017) | S0 | M3 | `chatbox-cli.sh:33` | Client ships a hard-coded third-party URL and silently sends the token there when CHATBOX_URL is unset [also: a trailing slash in CHATBOX_URL breaks every route; Shipped client defaults to a hard-coded third-party host, so an unset CHATBOX_URL sends the token there; Client default endpoint is the author's fixed tailnet host, not loopback] | unsafe | **DONE** | node1 | phase-B/L1-architecture,L7-ops,M2-mcp-and-placeholders,M3-client |
| [0018](#0018) | S0 | M3 | `chatbox-cli.sh:820` | watch acknowledges with all=1, losing messages it never delivered | bug | **DONE** | node1 | phase-B/M3-client |
| [0019](#0019) | S0 | M2 | `chatbox-mcp.swift:49` | MCP adapter silently corrupts every argument containing '+' because the server decodes '+' as space [also: CHATBOX_URL with a trailing slash yields //path and 404s every tool call] | bug | **DONE** | node1 | phase-B/M2-mcp-and-placeholders |
| [0020](#0020) | S0 | M1 | `chatbox.swift:1550` | Delivery rows are written with an unchecked run(), so a failed delivery is announced as delivered and the message is unreachable | bug | **DONE** | node1 | phase-B/L1-architecture |
| [0021](#0021) | S0 | M1 | `chatbox.swift:1826` | GET /ui builds 'path + ?token=' and always gets 401, so the read-only view shows an empty board [also: GET /ui concatenates window.location.search onto paths that already contain a query, so its own credential is swallowed and every fetch is unauthenticated] | bug | **DONE** | node1 | phase-B/L1-architecture,L2-server-http |
| [0022](#0022) | S0 | M1 | `chatbox.swift:2300` | Revocation is reported successful without checking whether the UPDATE ran [also: Credential issue and revoke ignore the write result and report success] | unsafe | **DONE** | node1 | phase-B/L2-server-core,L3-line-level |
| [0023](#0023) | S0 | M1 | `chatbox.swift:2830` | --token "" silently starts a fully open board [also: An explicitly empty --token silently starts an open board (fails open, unlike --token-file); `--token ""` (an unset variable) starts an unauthenticated board; --token beats --token-file although the code says the file is preferred] | incomplete | **DONE** | node1 | phase-B/L1-architecture,L3-line-level,L4-security,L7-ops |
| [0001](#0001) | S1 | M1 | `chatbox.swift (whole file)` | Source does not build under the audit standard (Swift 6 language mode, strict concurrency, warnings-as-errors) | unsafe | **START** | node1 | phase-A baseline |
| [0002](#0002) | S1 | M1 | `chatbox.swift:1062,1070` | Static ISO8601DateFormatter instances are shared mutable state (not Sendable) | unsafe | **START** | node1 | phase-A baseline |
| [0003](#0003) | S1 | M1 | `chatbox.swift:1238` | `Chatbox.publicURL` is a mutable static global | unsafe | **START** | node1 | phase-A baseline |
| [0004](#0004) | S1 | M1 | `chatbox.swift:27,3215,3217,3221` | Top-level configuration `let`s are MainActor-isolated and referenced from nonisolated code | unsafe | **START** | node1 | phase-A baseline |
| [0005](#0005) | S1 | M1 | `chatbox.swift:2464,1155-1180,1700-1745,1600-1660` | Non-Sendable captures and captured-var mutation across @Sendable closures (DispatchWorkItem, URLSession completion, waiters, event poll) | unsafe | **START** | node1 | phase-A baseline |
| [0015](#0015) | S1 | M1 | `chatbox.swift:896,373` | `@unchecked Sendable` on Chatbox and Store suppresses all concurrency checking | unsafe | **START** | node1 | L2 |
| [0024](#0024) | S1 | M3 | `chatbox-cli.sh:817` | a failed --exec or print spins the wake loop with no backoff | bug | **START** | node1 | phase-B/M3-client |
| [0025](#0025) | S1 | M2 | `chatbox-mcp.swift:138` | MCP adapter feeds raw peer text to the model with no untrusted frame [also: MCP adapter returns peer text to the model with no untrusted frame] | unsafe | **START** | node1 | phase-B/L1-architecture,L4-security |
| [0026](#0026) | S1 | M2 | `chatbox-mcp.swift:191` | JSON-RPC notifications receive responses (initialize, ping, tools/list, tools/call reply unconditionally) | bug | **START** | node1 | phase-B/M2-mcp-and-placeholders |
| [0027](#0027) | S1 | M2 | `chatbox-mcp.swift:47` | MCP adapter corrupts any message text containing '+' [also: MCP adapter corrupts every + in a parameter value (query built with URLQueryItem)] | bug | **START** | node1 | phase-B/L1-architecture,L3-line-level |
| [0028](#0028) | S1 | M2 | `chatbox-mcp.swift:54` | inbox wait advertised up to 300s but the adapter's HTTP client gives up at 60s [also: MCP HTTP timeout (60/70 s) is shorter than the inbox wait it advertises (max 300 s)] | bug | **START** | node1 | phase-B/L3-line-level,M2-mcp-and-placeholders |
| [0029](#0029) | S1 | M1 | `chatbox.swift:1279` | /health answers 200 with empty counters when the store cannot be read, and omits uptime/build/db state | bug | **START** | node1 | phase-B/L7-ops |
| [0030](#0030) | S1 | M1 | `chatbox.swift:1358` | register and token issuance report success when the store write failed [also: Registration reports success without checking its write] | bug | **START** | node1 | phase-B/L1-architecture,L2-server-core |
| [0031](#0031) | S1 | M1 | `chatbox.swift:1509` | Reply resolution loads every message of the thread, bodies included, with no bound | perf | **START** | node1 | phase-B/L5-performance |
| [0032](#0032) | S1 | M1 | `chatbox.swift:1551` | Delivery rows are inserted unchecked; the answer still claims delivered_to [also: Delivery inserts are unchecked, so a stored message can be reported as delivered without any delivery row] | bug | **START** | node1 | phase-B/L2-server-core,L3-line-level |
| [0033](#0033) | S1 | M1 | `chatbox.swift:1902` | SSE 'bye' frame is built with a doubled backslash, so the documented bye event is never delivered [also: SSE deadline frame uses literal backslash-n, so the bye event is never terminated] | bug | **START** | node1 | phase-B/L2-server-http,L3-line-level |
| [0034](#0034) | S1 | M1 | `chatbox.swift:2095` | Scoped credential's /threads count is board-wide, breaking read scoping [also: Scoped GET /threads?json=1 reports the board-wide thread count; GET /threads?json=1 leaks the board-wide thread count to a scoped credential; GET /threads JSON 'matching' counts the whole board, not the scoped caller's visible set] | unsafe | **START** | node1 | phase-B/L1-architecture,L2-server-core,L2-server-http,L4-security |
| [0035](#0035) | S1 | M1 | `chatbox.swift:2107` | /threads hardcodes LIMIT 100 and its text answer hides the truncation [also: GET /threads is permanently capped at the newest 100 with no offset or cursor; ORDER BY threads.last_at has no index; every /threads call scans and sorts the whole threads table; GET /threads silently truncates at a hard-coded 100, ignores --max-rows, and the text form omits the count; GET /threads text form truncates at a hardcoded 100 and never states the matching count] | bug | **START** | node1 | phase-B/L1-architecture,L2-server-http,L3-line-level,L5-performance |
| [0036](#0036) | S1 | M1 | `chatbox.swift:2135` | Ack reports acknowledgements that did not happen, from an unchecked UPDATE | bug | **START** | node1 | phase-B/L2-server-core |
| [0037](#0037) | S1 | M1 | `chatbox.swift:2138` | ack reports sqlite3_changes() even when the UPDATE failed, so a failed ack answers 'ok acked N' | bug | **START** | node1 | phase-B/L3-line-level |
| [0038](#0038) | S1 | M1 | `chatbox.swift:2232` | A credential's secret is returned even when the token INSERT did not store it | bug | **START** | node1 | phase-B/L2-server-core |
| [0039](#0039) | S1 | M1 | `chatbox.swift:2406` | Request log records no time, peer, principal or route context; credential issue/revoke unaudited [also: Request target control bytes are echoed into logs and the 404 body (log injection)] | bug | **START** | node1 | phase-B/L3-line-level,L7-ops |
| [0040](#0040) | S1 | M1 | `chatbox.swift:2431` | Connections refused at the ceiling get no idle deadline and are not counted, so stalled TLS handshakes accumulate without bound | unsafe | **START** | node1 | phase-B/L2-server-http |
| [0041](#0041) | S1 | M1 | `chatbox.swift:2810` | `--port` and `--stale-after` silently fall back to their defaults on an unparseable value [also: --port and --stale-after silently substitute the default for an unusable value] | logic | **START** | node1 | phase-B/L1-architecture,L3-line-level,L7-ops |
| [0042](#0042) | S1 | M1 | `chatbox.swift:2939` | `--prune`/`--prune-dry-run` on a mistyped `--db` creates a new board and reports success [also: --prune opens (and creates) a database before validating it, so a wrong --db path yields success on a brand-new board; Operator modes: Store is opened before --prune validation, a mistyped --db creates a board and reports 'pruned: 0', and conflicting modes silently win; --prune-dry-run can create or rewrite the database it promises not to touch] | bug | **START** | node1 | phase-B/L1-architecture,L2-server-core,L3-line-level,L7-ops |
| [0043](#0043) | S1 | M1 | `chatbox.swift:298` | Agent ids may contain ',', but recipients are stored comma-joined and re-split, so a reply can be delivered to an unintended session | bug | **START** | node1 | phase-B/L2-server-http |
| [0044](#0044) | S1 | M1 | `chatbox.swift:3232` | No SIGTERM/SIGINT/SIGHUP handling: no drain, no WAL checkpoint, no log reopen | bug | **START** | node1 | phase-B/L7-ops |
| [0045](#0045) | S1 | M1 | `chatbox.swift:484` | Store.rows treats every non-ROW step result as end-of-data, returning partial results as complete | incomplete | **START** | node1 | phase-B/L3-line-level |
| [0046](#0046) | S1 | M1 | `chatbox.swift:827` | Scoped visibility checks full-scan deliveries and messages; no index on deliveries(node) or messages(sender) | perf | **START** | node1 | phase-B/L5-performance |
| [0047](#0047) | S1 | M4 | `tests/protocol.sh:1505` | --port and --stale-after silently fall back to defaults on an unusable value; no check | test | **START** | node1 | phase-B/L6-tests |
| [0048](#0048) | S1 | M4 | `tests/protocol.sh:3442` | No startup-boundary test for --idle-timeout, --max-connections or --max-rows | test | **START** | node1 | phase-B/L6-tests |
| [0006](#0006) | S2 | M5 | `.github/workflows/ci.yml:31,40 ; codeql.yml:44,47,60` | CI actions are pinned to mutable tags, not commit SHAs | deps | **START** | node1 | L0 |
| [0007](#0007) | S2 | M1/M2 | `chatbox.swift (63 sites), chatbox-mcp.swift` | 63 force-unwrapped String.data(using:.utf8)! conversions | unsafe | **START** | node1 | L0 swiftlint baseline |
| [0008](#0008) | S2 | M3 | `chatbox-cli.sh:203` | Variable interpolated into a printf format string (SC2059) | bug | **START** | node1 | L0 shellcheck baseline |
| [0009](#0009) | S2 | M3 | `chatbox-cli.sh:456,463` | A pipeline both reads and writes the same file (SC2094) - truncation/data-loss risk | bug | **START** | node1 | L0 shellcheck baseline |
| [0010](#0010) | S2 | M4 | `tests/protocol.sh:1284,1679,1689,2054,2551,2676,3021,3299,3312,3459,3565,3941` | Shellcheck findings in the suite (SC3057 x3 quoted substring, SC2143 x5, SC2059 x2, SC2034, SC2329) | test | **START** | node1 | L0 shellcheck baseline |
| [0014](#0014) | S2 | M1 | `chatbox.swift:2426` | CodeQL swift/cleartext-transmission (high) on the HTTP listener - waiver or design change | unsafe | **START** | node1 | L0 |
| [0049](#0049) | S2 | repo | `.github/workflows/codeql.yml:57` | CodeQL extraction build never compiles chatbox-mcp.swift, so the MCP adapter is unscanned | test | **START** | node1 | phase-B/M2-mcp-and-placeholders |
| [0050](#0050) | S2 | repo | `aisessionserver-wiki/Deployment.md:92` | Local test runbook starts the disposable server on the suite's own staleness port | docs | **START** | node1 | phase-B/L7-ops |
| [0051](#0051) | S2 | repo | `aisessionserver-wiki/Quick-Start.md:255` | Documented local test command silently skips checks and cannot print the promised result | docs | **START** | node1 | phase-B/L7-ops |
| [0052](#0052) | S2 | M3 | `chatbox-cli.sh:150` | Client puts the credential in curl argv, exposing it to every local user via ps | unsafe | **START** | node1 | phase-B/L4-security |
| [0053](#0053) | S2 | M3 | `chatbox-cli.sh:29` | ~/.chatbox overrides the environment instead of defaulting to it | logic | **START** | node1 | phase-B/M3-client |
| [0054](#0054) | S2 | M3 | `chatbox-cli.sh:355` | canon_repo accepts Unicode Cf/C1 controls that chatbox.swift refuses [also: Repo-key rule duplicated in client and server diverges on Unicode format controls] | logic | **START** | node1 | phase-B/L1-architecture,M3-client |
| [0055](#0055) | S2 | M3 | `chatbox-cli.sh:686` | GET query strings are concatenated unencoded, so ids with a space or & break the request | bug | **START** | node1 | phase-B/M3-client |
| [0056](#0056) | S2 | M3 | `chatbox-cli.sh:703` | ack silently drops --all, then the server error names the flag the caller passed | logic | **START** | node1 | phase-B/M3-client |
| [0057](#0057) | S2 | M3 | `chatbox-cli.sh:775` | watch delivers the 1200-character inbox preview and then acks it | incomplete | **START** | node1 | phase-B/M3-client |
| [0058](#0058) | S2 | M2 | `chatbox-mcp.swift:177` | Well-formed non-object JSON is reported as -32700 parse error instead of -32600 Invalid Request | bug | **START** | node1 | phase-B/M2-mcp-and-placeholders |
| [0059](#0059) | S2 | M2 | `chatbox-mcp.swift:197` | notifications/cancelled is a no-op that can never be observed while a call blocks the read loop | incomplete | **START** | node1 | phase-B/M2-mcp-and-placeholders |
| [0060](#0060) | S2 | M2 | `chatbox-mcp.swift:91` | Tool schema declares additionalProperties:false but undeclared arguments are forwarded to the server | bug | **START** | node1 | phase-B/M2-mcp-and-placeholders |
| [0061](#0061) | S2 | M1 | `chatbox.swift:1553` | Per-recipient N+1 queries on the send path; recipient count is bounded only by --max-body | perf | **START** | node1 | phase-B/L5-performance |
| [0062](#0062) | S2 | M1 | `chatbox.swift:1654` | Boolean parameters are true for any non-empty value: all=0 includes read mail and json=0 emits JSON | logic | **START** | node1 | phase-B/L2-server-http |
| [0063](#0063) | S2 | M1 | `chatbox.swift:1748` | Serial forward queue plus a 12 s semaphore wait holds one connection per queued federation forward | perf | **START** | node1 | phase-B/L5-performance |
| [0064](#0064) | S2 | M1 | `chatbox.swift:1752` | Federation forward buffers the peer's entire response body with no size cap | unsafe | **START** | node1 | phase-B/L2-server-http |
| [0065](#0065) | S2 | M1 | `chatbox.swift:1773` | Any 2xx from the peer is reported as a delivery without checking the peer is a chatbox board | bug | **START** | node1 | phase-B/L2-server-http |
| [0066](#0066) | S2 | M1 | `chatbox.swift:1934` | SSE ticks run three board-wide COUNT(*) queries on the shared serial queue every 0.5 s per stream | perf | **START** | node1 | phase-B/L5-performance |
| [0067](#0067) | S2 | M1 | `chatbox.swift:2017` | Each long-poll waiter re-authorizes and re-queries every 0.25 s for up to 300 s | perf | **START** | node1 | phase-B/L5-performance |
| [0068](#0068) | S2 | M1 | `chatbox.swift:2179` | Read paths echo peer-controlled harness/ip/session/agent/node unescaped while escaping repos in the same loop | bug | **START** | node1 | phase-B/L2-server-http |
| [0069](#0069) | S2 | M1 | `chatbox.swift:2598` | No --version, no --help and no build identifier: a rollback cannot be verified | incomplete | **START** | node1 | phase-B/L7-ops |
| [0070](#0070) | S2 | M1 | `chatbox.swift:2776` | --verify-backup compares only row counts, so a stale copy can verify as current | logic | **START** | node1 | phase-B/L2-server-core |
| [0071](#0071) | S2 | M1 | `chatbox.swift:3093` | --peer-token exists only on the command line, so the federation credential is visible in ps | unsafe | **START** | node1 | phase-B/L4-security |
| [0072](#0072) | S2 | M1 | `chatbox.swift:387` | Server-created database, WAL and backups are world-readable (0644) | unsafe | **START** | node1 | phase-B/L4-security |
| [0073](#0073) | S2 | M1 | `chatbox.swift:449` | Store.exec ignores every SQLite error, and the db-open refusal drops the cause | incomplete | **START** | node1 | phase-B/L7-ops |
| [0074](#0074) | S2 | M1 | `chatbox.swift:460` | Stored text is silently truncated at an embedded NUL byte | bug | **START** | node1 | phase-B/L2-server-core |
| [0075](#0075) | S2 | M1 | `chatbox.swift:499` | Store.scalar returns an arbitrary column via Dictionary.values.first | logic | **START** | node1 | phase-B/L3-line-level |
| [0076](#0076) | S2 | M1 | `chatbox.swift:50` | nowISO() allocates a fresh ISO8601DateFormatter on every call, including once per recipient | perf | **START** | node1 | phase-B/L5-performance |
| [0077](#0077) | S2 | M1 | `chatbox.swift:610` | Repo-key migration ignores BEGIN/COMMIT failures | bug | **START** | node1 | phase-B/L2-server-core |
| [0078](#0078) | S2 | M1 | `chatbox.swift:611` | Startup key migration re-reads all four tables and rewrites every non-canonical row on every start | perf | **START** | node1 | phase-B/L5-performance |
| [0079](#0079) | S2 | M1 | `chatbox.swift:716` | prune() clears reply_to with one full-table-scan UPDATE per pruned message (O(messages x pruned)) | perf | **START** | node1 | phase-B/L5-performance |
| [0080](#0080) | S2 | M1 | `chatbox.swift:799` | Inbox listing sorts the whole matching backlog in a temp b-tree to return 200 rows | perf | **START** | node1 | phase-B/L5-performance |
| [0081](#0081) | S2 | M4 | `tests/protocol.sh:1478` | Aux-server readiness accepts any answering server, not the one just started | test | **START** | node1 | phase-B/L6-tests |
| [0082](#0082) | S2 | M4 | `tests/protocol.sh:3254` | Fixed 'bulk' and 'exact' literals break the suite's per-run namespace on re-runs | test | **START** | node1 | phase-B/L6-tests |
| [0083](#0083) | S2 | M4 | `tests/protocol.sh:3576` | Expiry issuance asserted with 'expires: 20' and no 1/36500 boundaries | test | **START** | node1 | phase-B/L6-tests |
| [0084](#0084) | S2 | M4 | `tests/protocol.sh:3748` | The /events max= ceiling is never exercised | test | **START** | node1 | phase-B/L6-tests |
| [0085](#0085) | S2 | M4 | `tests/protocol.sh:395` | /token?json=1 secret check is vacuous: the JSON form is never asserted | test | **START** | node1 | phase-B/L6-tests |
| [0086](#0086) | S2 | M4 | `tests/protocol.sh:3967` | fed_refuse decides "refused" with a fixed sleep and never checks the exit status | test | **START** | node1 | phase-B/L6-tests |
| [0011](#0011) | S3 | M1/M2/M4 | `repository-wide` | Formatter/linter baseline: 3309 swift-format findings, 303 swiftlint findings | style | **START** | node1 | L0 |
| [0012](#0012) | S3 | M6/M1 | `README.md:11, chatbox.swift:6` | Documented toolchain (Swift 6.3.3) contradicts the audit standard (Swift 6.4 + strict concurrency) | docs | **START** | node1 | phase-A |
| [0013](#0013) | S3 | M7 | `tests/.scratch` | Unbounded scratch growth: 1.8 GB / 120414 files from mutation runs and per-cell TLS fixtures | style | **START** | node1 | L0 secret-scan triage |
| [0016](#0016) | S3 | M3 | `chatbox-cli.sh:30` | SC1090: the client sources a non-constant path (~/.chatbox) | style | **START** | node1 | L0 shellcheck baseline |
| [0087](#0087) | S3 | repo | `.github/traffic.json:4` | Canned view count served as the live 'Views (14d)' README badge | placeholder | **START** | node1 | phase-B/M2-mcp-and-placeholders |
| [0088](#0088) | S3 | M1 | `chatbox.swift:1617` | Local `who` shadows the Principal parameter in message() | style | **START** | node1 | phase-B/L3-line-level |
| [0089](#0089) | S3 | M1 | `chatbox.swift:260` | The '?' element of the repo-key character check is unreachable | dead | **START** | node1 | phase-B/L3-line-level |

## Task detail

### 0017

- **Severity / category / module:** S0 / unsafe / M3
- **Location:** `chatbox-cli.sh:33`
- **Title:** Client ships a hard-coded third-party URL and silently sends the token there when CHATBOX_URL is unset [also: a trailing slash in CHATBOX_URL breaks every route; Shipped client defaults to a hard-coded third-party host, so an unset CHATBOX_URL sends the token there; Client default endpoint is the author's fixed tailnet host, not loopback]
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (static): the line reads URL="${CHATBOX_URL:-http://100.66.125.48:8787}"; 100.66.125.48 is neither loopback nor the user's host on any other machine.

`URL="${CHATBOX_URL:-http://100.66.125.48:8787}"` — the author's Tailscale address — is the fallback when CHATBOX_URL is unset, and nothing verifies that CHATBOX_URL was set. `chatbox register/say/ack/token` then POSTs with `token=$TOKEN` to that host. README.md:107-111 and wiki Quick-Start.md:44 tell the operator to create ~/.chatbox, but a missing, unreadable or typo'd config, or a shell without the profile, sends the bootstrap secret to an address the operator never chose. | chatbox-cli.sh:33 keeps URL verbatim and 151/159 concatenate `${URL}${1}`, so `CHATBOX_URL=http://host:8787/` requests `//inbox`. Verified with a local nc capture: curl sends `GET //inbox?id=x`. The server routes on exact path equality (`req.path == "/inbox"`, chatbox.swift:1226) and falls through to a 404 at 1234; nothing normalises duplicate slashes. | 33: `URL="${CHATBOX_URL:-http://100.66.125.48:8787}"` - a specific tailnet address of the author's machine - while chatbox-mcp.swift:16 defaults to http://127.0.0.1:8787 and README:110 has the operator set CHATBOX_URL. With no ~/.chatbox (or a typo in it) the client sends CHATBOX_TOKEN in the query string to that hard-coded address. | URL="${CHATBOX_URL:-http://100.66.125.48:8787}" (line 33) hard-codes one deployment address, and the header example repeats it (line 7); the comment at lines 27-29 calls it 'the tailnet IP'. A user who exports CHATBOX_TOKEN but does not export CHATBOX_URL sends the token and every message to that host with no warning.

WHY IT MATTERS: A fresh install or an unconfigured shell ships the board's root credential to a hard-coded private address instead of failing; at best it times out, at worst the credential reaches a host that answers. | A trailing slash is a normal way to write a base URL and the client accepts it silently, so a correct-looking config makes every command - reads and writes - answer 404 'not found: GET //inbox'. The cause is a doubled slash buried in the echoed path, not a reachability problem. | A shipped client must not default to a third-party host: the shared or scoped secret is transmitted to whoever answers that address, and the two shipped clients disagree on the default. It is also a deployment trap for anyone following the README. | A wrong-by-default endpoint can leak the shared credential and message contents to a machine the operator does not own. Every other client/adapter defaults to loopback (chatbox-mcp.swift:16), so this default is both surprising and dangerous.

GRADED UP BY THE AUDITOR: A shipped client that sends a token to a hard-coded third-party address when one variable is unset is a credential leak, not a style issue.

CONFIDENCE: high
- **Fix:** Remove the client's built-in server address (CHATBOX_URL now defaults to empty) and refuse with exit 2 and a diagnostic inside curl_tls — the one choke point for every request — when no server is configured. `help` and `repo` need no server and still work; the usage banner prints `server: not configured`.
- **Evidence (after):** TEST (gate), network-free so no live board is ever contacted: the pre-fix client run with CHATBOX_URL and CHATBOX_TOKEN unset and CHATBOX_CACERT set (its own guard fires before curl) answers `chatbox: CHATBOX_CACERT is set but CHATBOX_URL is not https:// (http://100.66.125.48:8787)` - exit 2, but the diagnostic names the built-in third-party default and never says the server is unconfigured, so the new checks FAIL. The fixed client answers `chatbox: no server configured — set CHATBOX_URL, or write it to /nonexistent` - the checks PASS. Full suite after the fix: protocol.sh 878 passed, 0 failed (872 + 6 new checks in section 35, which also prove `help` still works with no server and that the diagnostic never names the old address).
AUDIT (gate): re-read cold. The guard sits in curl_tls, the single function every request path goes through, so a future subcommand cannot bypass it; `repo` (git remotes only) and `help` do not call it and still work unconfigured; the CACERT case now has an explicit empty-URL branch so a CACERT without a URL gets the true diagnostic instead of a confusing one. No check weakened: section 35 is new, and the only changed existing behaviour is that a misconfigured client refuses instead of guessing. Baseline comparison: suite 864 -> 878 passed, documented build and all scanner counts unchanged.
Mutation (gate, after correcting a first attempt whose replacement lost a newline and produced a syntax-error client - that red was discarded, not recorded): the mutant passes `sh -n`, and the harness reports it red with exactly the three section-35 checks failing (875 passed / 3 failed: exit code, 'no server configured', 'deliberately no default') while base stays green at 878.
- **Commit:** `a5a658b`
- **Notes:** Rejected alternatives: (a) defaulting to http://127.0.0.1:8787 like the MCP adapter does — a loopback board is a *different* board, so the token would still be sent somewhere the operator did not name; (b) keeping a default and warning — a warning on every invocation is noise and does not stop the leak; (c) reading the URL from a checkout-specific file — that is what ~/.chatbox already is.

### 0018

- **Severity / category / module:** S0 / bug / M3
- **Location:** `chatbox-cli.sh:820`
- **Title:** watch acknowledges with all=1, losing messages it never delivered
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (static): the watch loop fetches `/inbox?id=$ID&wait=$_wait` — unread only, and the server caps the listing at 200 while saying how many older ones it is not showing — then, after printing the framed body, acknowledges with `all=1` (chatbox-cli.sh:820). With more than 200 unread, the messages the page did NOT contain are marked read and are never delivered: silent loss of mail on the normal path.

START GATE — expected behaviour written down, and the obvious fix rejected: the loop must acknowledge *exactly* the messages it delivered. Acking ids parsed out of the framed text does NOT achieve that and would be worse than the bug: the client prefixes every line of the server's body uniformly with `| `, so a peer's message body containing a line `| [42] UNREAD thread 1 ...` is byte-identical to a real header line, and message ids are small sequential integers an attacker can guess. Parsing ids from that text would let a sender cause the client to mark a *different* unread message of the same agent as read without delivering it. The safe source is the structural one: `GET /inbox?id=…&json=1`, where the server escapes quotes, so a body cannot close a string and inject a field.

PLAN (not yet implemented): render the wake loop's page from the JSON representation (one structural source for both what is printed and what is acked), keep every field going through sanitize/framing, and ack with `message=<id>` for exactly the ids in that page. Needs: a minimal JSON id/field extractor in POSIX sh (the client already parses the hook payload, so extend that), and checks for (a) >200 unread leaves the tail unread rather than acked, (b) a forged `| [id]` line in a body does not cause an ack, (c) a failure to deliver acks nothing.
- **Fix:** The inbox names the messages it rendered in an `X-Chatbox-Unread-Ids` response header (built from the same rows as the body, on both the immediate and the long-poll answer path), and `chatbox watch` acknowledges those ids one by one with `message=<id>`. A server that sends no header leaves the mail unread and says so.
- **Evidence (after):** TEST (gate), the property measured directly on a live board (3 unread, the wake loop delivering with `--exec 'sleep 2'`, and a 4th message arriving during that delivery). BEFORE (client that acks `all=1`): unread after the wake = 0 and the late message is present-but-read — it was acknowledged without ever being delivered, so no later wake will show it and nothing re-queues it: lost. AFTER (client that acks the header's ids): unread after the wake = 1, i.e. the late message is still unread and the next wake delivers it; the three the page held are acknowledged. DEGRADATION: the new client against a server that sends no header leaves everything unread and says so on stderr (`the server did not say which messages it sent; leaving them unread`) — a repeat rather than a loss. Suite base cell green at 902 passed / 0 failed (3 new checks, section 38); mutations 238-audit0018-ackall (the client reverts to `all=1`) and 239-audit0018-noheader (the server stops sending the header) each red on exactly the pinned check; relative cell green; 0 false passes.
AUDIT (gate): re-read cold. The ids come from a response header, which is structural — a peer's message body cannot add an id to it, which is why parsing ids out of the framed text was rejected (recorded above). The header is built from the same `rows` the body rendered, in the same order; the client accepts only all-digit ids; the long-poll answer path sends the same header; the empty-inbox, `json=1` and refusal paths are unchanged; the loop cleans up its header file on every exit path and its trap. No check weakened: the 3 new checks are additive and the existing wake-loop checks (output shape included) still pass untouched. Baseline: suite 899 -> 902; build and scanners unchanged.
- **Commit:** `35bc4e3`
- **Notes:** Rejected alternatives: (a) parsing the ids out of the framed text - the client prefixes every line uniformly, so a peer's body line is byte-identical to a real header and ids are guessable, which would let a sender hide another of the agent's messages (recorded in this task before the fix); (b) re-rendering the page from `/inbox?json=1` - correct in principle but it would change the printed shape every integration and test depends on; (c) acking `thread=` per thread - it cannot be exact, since a thread may hold messages the page did not show; (d) acking the header ids but falling back to `all=1` when it is missing - that reintroduces the loss against an older server, so the fallback leaves them unread instead.

### 0019

- **Severity / category / module:** S0 / bug / M2
- **Location:** `chatbox-mcp.swift:49`
- **Title:** MCP adapter silently corrupts every argument containing '+' because the server decodes '+' as space [also: CHATBOX_URL with a trailing slash yields //path and 404s every tool call]
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (mechanism reproduced): `URLComponents.queryItems` renders body "a+b c&d=e" as `body=a+b%20c%26d%3De` - `&` and `=` are escaped, `+` is not - and the server's percentDecode replaces `+` with a space.

call() builds the query with URLComponents(string: configURL + path) and queryItems (lines 47-50), which leaves '+' literal. Ran a Swift snippet: body 'C++ a&b=c d+e%f' produced URL 'body=C++%20a%26b%3Dc%20d+e%25f'. The server's percentDecode (chatbox.swift:910) does replacingOccurrences(of: "+", with: " ") before percent-decoding, so the stored body becomes 'C  a&b=c d e%f'. chatbox.swift:927 defines formEncode for exactly this reason and chatbox-cli.sh uses curl --data-urlencode. | The URL is built by string concatenation, URLComponents(string: configURL + path) (line 49). Verified with a Swift snippet: configURL 'http://127.0.0.1:8787/' + '/register' yields path '//register'. The server parses the request target verbatim (chatbox.swift:2385-2390) and routes on exact matches such as case ("POST", "/register") (chatbox.swift:1224), with default -> 404 (chatbox.swift:1233). The server strips trailing slashes from its own --peer URL before use.

WHY IT MATTERS: Any message body, subject or token containing '+' (C++, diffs, base64, emails) is stored and delivered with '+' turned into spaces, silently and permanently. A '+' in CHATBOX_TOKEN breaks every authenticated call. This is data corruption on the adapter's normal send path. | An operator who copies the URL from a browser or the startup banner (both end in /) gets an adapter whose every tool call returns the 404/usage text, while the same URL works with chatbox-cli.sh, which appends the path itself.

CONFIDENCE: high
- **Fix:** Add queryEncode(_:) to the adapter and build the query string by hand instead of through URLComponents.queryItems, so `+` (and every other reserved character) is percent-encoded.
- **Evidence (after):** TEST (gate). BEFORE: the pre-fix adapter, asked to say `c++ plus+plus a+b`, stored `c   plus plus a b` (read back through the API) — every `+` in every argument became a space, silently. AFTER: the same call stores `c++ plus+plus a+b` byte-for-byte. Reproduced mechanism: `URLComponents.queryItems` renders the body `a+b c&d=e` as `a+b%20c%26d%3De` — `&` and `=` are escaped, `+` is not — and the server's percentDecode maps `+` to a space. Suite: base cell green at 883 passed / 0 failed (1 new check in section 31, which reads the stored body back through the API, not through the adapter); mutation 233-audit0019-mcpplus (queryEncode allows 0x2B through) red with exactly that check failing.
AUDIT (gate): re-read cold. queryEncode escapes everything outside the RFC 3986 unreserved set, so the query is now built the way the server's own forward path builds its body; values are escaped, the key/value separators are added after escaping, and `URL(string:)` leaves the %XX sequences alone; an empty parameter set produces no '?' at all. No check weakened: the new check is additive. Baseline: suite 881 -> 883 passed; build and scanner counts unchanged.
- **Commit:** `842e588`
- **Notes:** Rejected alternatives: (a) sending the parameters as a form-encoded body — correct, but it would make every GET tool a GET-with-body for no gain here; (b) escaping only `+` before handing the value to URLQueryItem — the initializer re-encodes and the result is not controllable; (c) fixing the server to stop treating `+` as a space — that would break curl's --data-urlencode and the documented form encoding.

### 0020

- **Severity / category / module:** S0 / bug / M1
- **Location:** `chatbox.swift:1550`
- **Title:** Delivery rows are written with an unchecked run(), so a failed delivery is announced as delivered and the message is unreachable
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (static): each `store.run("INSERT OR IGNORE INTO deliveries ...")` result is discarded, `run` returns -1 on a failed prepare/step, and the 200 body's `delivered_to` is built from the in-memory recipient list.

1550-1554 inserts one row per recipient with `store.run("INSERT OR IGNORE INTO deliveries ...")` and ignores the result, then answers `delivered_to:` at 1642. Fault-injected an ABORT trigger on deliveries in a probe board: POST /message returned 200 `delivered_to: node-b-claude`, the message row persisted, and the recipient's /inbox never contained it. The message insert two lines above (1529-1545) already checks rc/changes.

WHY IT MATTERS: Durable acknowledged delivery is the product's core promise ('Nothing is lost'). On SQLITE_FULL/IOERR/SQLITE_BUSY the report is stored but no session is delivered it, while the sender is told it was - silent data loss on the normal send path.

CONFIDENCE: high
- **Fix:** Wrap the send in one BEGIN IMMEDIATE/COMMIT with every statement checked, roll back and answer 500 on any failure, build `delivered_to` from the delivery rows that exist, and check the register upsert's write. The reply's validation and authorisation happen before the transaction opens.
- **Evidence (after):** TEST (gate), with the store forced to refuse by triggers on a live board. BEFORE: with a BEFORE INSERT trigger on deliveries, POST /message answered `ok posted` while `messages=1, deliveries=0` — the message was stored, the sender was told `delivered_to`, no delivery row existed, and `--prune` never removes a message with no deliveries, so it was unreachable mail announced as a delivery. A refused agent INSERT was answered 200 `ok registered` with 0 rows for that id. AFTER: the send answers 500 `error: the message could not be delivered to bob — nothing was written` with `messages=0` (whole send rolled back); the registration answers 500 and stores nothing; both work again once the trigger is dropped. Suite base cell green at 899 passed / 0 failed (8 new checks); mutation 236-audit0020-deliveryguard red on 2 checks, 237-audit0020-registerguard red on 1, relative cell green, 0 false passes.
PHASE-D NOTE (a defect my own first attempt introduced, caught by the base cell before any commit): the first version opened BEGIN IMMEDIATE before the reply's validation, so a 400 (`thread=abc`) or a 403 (a join refusal) returned with the transaction still open. The very next send then failed with `cannot start a transaction within a transaction` — the base cell went RED, 61 checks failing. Fixed by resolving and authorising the reply target *before* BEGIN (every refusal in that block writes nothing, so it needs no rollback), and the whole cell was re-run: base GREEN, mutations red.
AUDIT (gate): re-read cold. One write covers thread creation, the message row, the sender's liveness, every delivery row, the thread stamp and the commit; every statement in it is checked with runReporting and every failure rolls back and answers 500 (never 200); `delivered_to` is now built from the rows that exist (`recipientsWithDelivery`) rather than from the list the route intended, and the stale/warning set is computed over those same rows; the 404-when-the-thread-vanished path still rolls back and still answers 404; the register route checks its INSERT/UPDATE. No check weakened: all 8 are additive and the previous suite is unchanged. Baseline: suite 891 -> 899; build and scanners unchanged.
- **Commit:** `b54abc9`
- **Notes:** Rejected alternatives: (a) deleting the message and its deliveries by hand on a failure - a rollback is the same thing without a second way to leave partial state; (b) reporting only the recipients that were written and answering 200 - a half-delivered report the sender cannot tell from a whole one; (c) keeping the thread creation outside the transaction - a refused send would then leave an empty thread behind on every failure. The first attempt's regression is recorded above as required by Phase D.

### 0021

- **Severity / category / module:** S0 / bug / M1
- **Location:** `chatbox.swift:1826`
- **Title:** GET /ui builds 'path + ?token=' and always gets 401, so the read-only view shows an empty board [also: GET /ui concatenates window.location.search onto paths that already contain a query, so its own credential is swallowed and every fetch is unauthenticated]
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (reproduced): the page serves `const query = window.location.search;` and `fetch(path + query)` with `get('/threads?json=1')`; the URL it builds, `/threads?json=1?token=tok`, answers 401, while `/threads?json=1&token=tok` answers 200.

1823 sets `const query = window.location.search` and 1826 fetches `path + query`, but the paths already carry a query (1831 '/thread?id=', 1834 '/threads?json=1'), so the page requests `/threads?json=1?token=...`. Ran the built server: that exact URL returned 401; `/threads?json=1&token=...` returned 200. refresh() then renders 'No conversations yet.' on a board with 110 threads. protocol.sh:3856-3873 only greps the HTML, never fetches the URLs it builds. | uiPage() serves `const query = window.location.search;` (1823) and `fetch(path + query)` (1826), called as get('/threads?json=1') (1834) and get('/thread?id=' + id) (1831). Opened the documented way, /ui?token=X, search is '?token=X', so the request becomes /threads?json=1?token=X: parse() splits at the first '?', giving params {json:'1?token=X'} and no token param, so authorize() answers 401. refresh() (1833-1852) swallows that failure (JSON.parse throws) and renders '<p class="empty">No conversations yet.</p>'.

WHY IT MATTERS: GET /ui is documented (README:208) as the read-only view of the conversations a credential may read. On every token-protected board it loads no data and displays an empty board - a wrong answer, not an error - and the credential never reaches the server. | On any token-protected board the read-only view always reports an empty board and thread clicks never load, while the underlying API is fine. The suite only greps the static HTML (tests/protocol.sh:3868) and never exercises the fetch, so it passes green over a page that cannot work.

CONFIDENCE: high
- **Fix:** Add a pure withQuery(path, search) helper to the page and route every request through it, so a path that already carries a query gains '&' instead of a second '?'.
- **Evidence (after):** TEST (gate). BEFORE: the pre-fix build's /ui serves no withQuery and its code builds `path + window.location.search`; for '/threads?json=1' with '?token=tok' that URL answers 401 (measured: `curl '/threads?json=1?token=tok'` -> 401, the correct `&token=` form -> 200). AFTER: the shipped function returns '/threads?json=1&token=tok' and that URL answers 200; suite 881 passed / 0 failed (3 new checks, section 36, which extracts withQuery from the served page, runs it under node against five path/search pairs, then calls the live server with the URL it builds); mutation 232-audit0021-uiquery red with exactly that one check failing, base green.
AUDIT (gate): re-read cold. withQuery is pure and total (empty search returns the path unchanged, a path with no query gains '?', a path with one gains '&', a leading '?' is stripped once); every path the page requests now goes through it, so a future call site cannot reintroduce the join. No check weakened: section 36 is new. Baseline: suite 878 -> 881 passed; build and scanners unchanged.
- **Commit:** `47f414f`
- **Notes:** Rejected alternatives: (a) stripping the existing query from the paths ('/threads' + '?json=1&token=…') - works but silently drops json=1 if the parameter order ever changes; (b) putting the token in a cookie or header - the page is credential-free by design and the server accepts ?token= only; (c) testing the JS by source inspection - the shipped function is executed under node instead, so the check fails for the real reason.

### 0022

- **Severity / category / module:** S0 / unsafe / M1
- **Location:** `chatbox.swift:2300`
- **Title:** Revocation is reported successful without checking whether the UPDATE ran [also: Credential issue and revoke ignore the write result and report success]
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (static): `store.revokeToken(id, at: nowISO())` result discarded, then 200 "ok revoked <id> / Every request presenting it is rejected from now on."

revokeToken() (2287-2306) reads revoked_at, calls store.revokeToken(id, at:) at 2300, then returns 200 "ok revoked ... Every request presenting it is rejected from now on". Store.revokeToken (557-559) is run("UPDATE tokens SET revoked_at=? WHERE id=? AND (revoked_at IS NULL OR revoked_at='')"); Store.run (468-477) returns -1 on prepare/step failure and the caller ignores it. authorize() (1121) rejects only a row whose revoked_at is non-empty, so after a failed write (write lock past busy_timeout=5000, disk full, read-only file) the credential keeps authenticating. | Line 2300 `store.revokeToken(id, at: nowISO())` discards the result of `run("UPDATE tokens SET revoked_at=?...")` (Store.run returns -1 on failure, 557-559) and then tells the operator 'Every request presenting it is rejected from now on'. Line 2232 `store.addToken(...)` (which calls run at 549-550) is equally unchecked, and the response prints the secret.

WHY IT MATTERS: The operator believes a leaked credential is dead while it continues to work. A silently-failing security control reported as applied is an S0 security hole, not merely missing error handling. | A failed revoke leaves a live credential in the tokens table while the operator believes it is dead -- a security-relevant false success. A failed addToken hands out a secret that was never stored, so every later request with it is 401 'unknown token'.

CONFIDENCE: high
- **Fix:** Make Store.addToken/revokeToken report the statement result, check it in both routes, answer 500 when the write did not happen, print no secret before the row exists, and resolve a concurrent revoke as the existing 'already revoked' success.
- **Evidence (after):** TEST (gate), with the store forced to refuse by triggers on a live board (the same technique the backup section already uses). BEFORE: with a BEFORE INSERT trigger on tokens, `POST /token` answered 200 and printed `secret:` for a credential that was never stored; with a BEFORE UPDATE trigger, `POST /token/revoke` answered `ok revoked tk-...` while the row was still live (`revoked_at` NULL) — so the operator was told a live credential was dead. AFTER: the issuance is 500 `error: the credential was not stored — nothing was issued (blocked)` with no secret printed; the revocation is 500 `error: the revocation did not run — tk-... is still valid (blocked)`; both work again once the trigger is dropped. Suite base cell green at 891 passed / 0 failed (8 new checks); mutations 234-audit0022-issueguard (3 checks fail) and 235-audit0022-revokeguard (2 checks fail) red, relative cell green, 0 false passes.
AUDIT (gate): re-read cold. Both store methods use runReporting and return (rc, changes); a DONE with changes == 0 on revoke is resolved by re-reading the row (a concurrent revoke is a success, not a false failure); the issuance route checks the write before printing the one and only copy of the secret; the existing 'already revoked' 200 path is unchanged; a prepare failure (rc != DONE) is still a 500 and now carries the store's own reason. No check weakened: all 8 are additive. Baseline: suite 883 -> 891; build and scanners unchanged.
- **Commit:** `599a87d`
- **Notes:** Rejected alternatives: (a) checking only `tokenExists` before the UPDATE (it cannot see a refused UPDATE); (b) printing the secret and warning if the insert failed - the operator would hold a credential that can never work, and the only copy of the secret would be in a response about a failure; (c) treating changes == 0 as 'already revoked' unconditionally - that hides a real refusal, so the row is re-read instead.

### 0023

- **Severity / category / module:** S0 / incomplete / M1
- **Location:** `chatbox.swift:2830`
- **Title:** --token "" silently starts a fully open board [also: An explicitly empty --token silently starts an open board (fails open, unlike --token-file); `--token ""` (an unset variable) starts an unauthenticated board; --token beats --token-file although the code says the file is preferred]
- **Status:** DONE
- **Evidence (before):** VERIFIED BY AUDITOR (reproduced): `chatbox --port 9731 --db /tmp/v/open.sqlite --token ""` prints "auth: OPEN (no token)" and `curl http://127.0.0.1:9731/health` with no credential answers 200.

Line 2830: `let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)`. The empty --token-file case is refused at 2826-2829 ('refusing to start an open board'), the empty inline value is not. Ran the built server: `chatbox --port 18793 --db /tmp/l3probe/t7.sqlite --token ""` printed `auth: OPEN (no token)` and `curl http://127.0.0.1:18793/inbox?id=nobody` returned 200 with no credential. | chatbox.swift:2830 `let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)`. Lines 2826-2829 refuse an empty --token-file with 'refusing to start an open board', but an explicitly empty --token is never checked: argValue returns "" for both `--token=` and `--token ""`, and argPresent("--token") is true. authorize() (1111) then does `guard let expected = token else { return .ok(.bootstrap) }`, so every request without a credential is bootstrap. No test or doc covers `--token=`. | argValue returns the empty string for `--token ""`, so `let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)` (2830) is nil; `authorize` (1111) then returns .ok(.bootstrap) for every request, making any caller the root credential. The identical empty-value case is refused for --token-file (2826: 'refusing to start an open board'), and the TLS block already guards `--tls-identity "$UNSET"` (3139). Only the banner line `auth: OPEN (no token)` (3212) mentions it. | 2814 comments 'Prefer --token-file: a token passed as argv is visible to every local user in ps', but 2830 is `let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)`, so --token wins. Running the built server with both flags: the argv token answered 200 and the file token 401. Both are accepted together with no warning, and README:75/116 present them as alternatives.

WHY IT MATTERS: An operator who runs `--token "$CHATBOX_TOKEN"` with an unset or empty variable gets the documented open board with no diagnostic. When token==nil, authorize() returns .ok(.bootstrap) for every request, so anyone who can reach the port can read every thread and mint credentials. | A deploy script or unit file using `--token "$SECRET"` with SECRET unset starts a fully open board: anyone who can reach the port reads all messages, forges sends as any session, and issues scoped credentials. The OPEN banner is easy to miss under nohup/systemd, and here it was never intended. | `./chatbox --token "$TOK"` with TOK unset (a documented flag form, file header line 14) comes up with no authentication at all: full message history, the registry and the credential-issuing route are exposed to anyone who can reach the port. | The secret-precedence the comment promises for a security reason is inverted, so a wrapper that appends --token silently puts the shared secret in the process table, and nothing tells the operator which value is live.

CONFIDENCE: high
- **Fix:** Refuse a *present* `--token` or `--token-file` whose value is empty, with exit 2 and a diagnostic naming the flag, before the token file is read. `--token open` (or no token flag) remains the only way to ask for an open board.
- **Evidence (after):** TEST (gate): the same three cases against the pre-fix binary and the fixed one.
BEFORE: `--token ""` STARTED, /health with no credential = 200, banner `auth: OPEN (no token)`; `--token-file ""` STARTED, same; empty token file refused (pre-existing guard).
AFTER: `--token ""` refused — "--token was given but is empty — refusing to start an open board (use --token open to ask for one by name)"; `--token-file ""` refused — "--token-file was given but names no file — refusing to start an open board"; empty token file still refused.
Full suite after the fix: protocol.sh 872 passed, 0 failed (864 + 8 new checks in section 34, which also proves `--token open` still starts a board and that its banner says so).
Mutation `230-audit0023-emptytoken` reintroduces the hole; the harness must report it red (see commit message).
AUDIT (gate): change re-read cold against the finding; the two guards sit before the token file is read and before Store is opened, use argPresent (which counts `--flag=` as present), and exit 2 naming the flag exactly as the other startup refusals do. No check was weakened: section 34 is new and the pre-existing empty-file check is unchanged. Baseline comparison: documented build still 0 warnings; suite 864 -> 872 passed; no scanner metric regressed.
- **Commit:** `06de884`
- **Notes:** Rejected alternatives: (a) treating an empty value as "absent" (that is the bug); (b) silently falling back to the token file (hides the operator's mistake and can still end open); (c) requiring a non-empty token unconditionally (would remove the documented open mode). Commit note: the commit that carries the fix is 06de884. Its message was mangled by shell quoting and misstates the ledger sha ('mark DONE at 64c7e63'); the ledger is authoritative. The commit itself contains the two guards, suite section 34 and this ledger entry (status AUDIT).

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

### 0024

- **Severity / category / module:** S1 / bug / M3
- **Location:** `chatbox-cli.sh:817`
- **Title:** a failed --exec or print spins the wake loop with no backoff
- **Status:** START
- **Evidence (before):** chatbox-cli.sh:812-816 sets `_ok=0` when `framed_of "$_body" | sh -c "$EXEC"` fails; 817-818 only prints 'delivery failed; leaving the message unread'. Unlike the ack-failure path (821-824) it neither increments `_fails` nor sleeps, and --exec does not imply --once (only --hook forces it, line 737). The message stays unread, so the next poll at 775 returns it immediately. The suite only exercises --exec with --once (tests/protocol.sh:1048).

WHY IT MATTERS: A consumer that keeps failing turns the loop into a tight busy loop: the failing command is re-run and the server re-polled as fast as the shell can go, for ever, with no delay - CPU burn and a hammered board on what the docs present as the supported wake loop.

CONFIDENCE: high
- **Fix:** Treat a delivery failure like an ack failure: increment `_fails`, sleep the capped backoff ($_back), and `continue` before re-polling. Test the continuous (non---once) --exec failure path.

### 0025

- **Severity / category / module:** S1 / unsafe / M2
- **Location:** `chatbox-mcp.swift:138`
- **Title:** MCP adapter feeds raw peer text to the model with no untrusted frame [also: MCP adapter returns peer text to the model with no untrusted frame]
- **Status:** START
- **Evidence (before):** toolResult (136-140) returns the server's body verbatim inside the tool result: `reply(id: id, ["content": [["type": "text", "text": body]], "isError": !ok])`, and handleToolCall (162-163) passes /inbox, /thread, /peers bodies straight through. The shipped client instead wraps every read in the fixed banner and per-line '| ' prefix (chatbox-cli.sh:215-239), and README:155 promises 'Every read path frames peer text ... There is no flag to switch the frame off.' The MCP test section (tests/protocol.sh:3797+) never exercises a hostile body. | 136-140 returns the server body verbatim as content[0].text with isError false. Probe: MCP inbox returned the raw listing (`from: node-a-dsh`, subject and body at column 0) with no frame, while chatbox-cli.sh:242-286 sanitises and prefixes every read path and README:155-160 says the frame cannot be switched off.

WHY IT MATTERS: Any session or federated peer that can send to this session chooses bytes that the MCP host presents to the model as tool output, with no 'this is data, not instructions' boundary. One message addressed to the session (any sender may send to any id) can carry 'ignore previous instructions' content and the model has no way to distinguish it from protocol text. | The frame is the product's defence against a peer writing instructions into a model's context, and it is enforced only in the shell client - the MCP path, the one wired into agent hosts, delivers peer-chosen text unframed. An invariant the README states unconditionally holds for only one of two shipped clients.

CONFIDENCE: high
- **Fix:** Apply the CLI's frame inside toolResult (fixed banner, sanitize control/format bytes, prefix every body line) or return a clearly labelled untrusted content block; add an MCP test where a body contains the end banner and assert it cannot appear at column zero. | Apply the same frame/sanitisation to MCP read results, or move framing into the server's read responses so every client inherits it, and state the rule once in the README.

### 0026

- **Severity / category / module:** S1 / bug / M2
- **Location:** `chatbox-mcp.swift:191`
- **Title:** JSON-RPC notifications receive responses (initialize, ping, tools/list, tools/call reply unconditionally)
- **Status:** START
- **Evidence (before):** The switch calls reply()/handleToolCall unconditionally for initialize, ping, tools/list and tools/call (lines 191-206); only the default branch checks isNotification (line 208). With no id in the request, reply() emits id NSNull (line 32), so a notification such as a ping or a tools/list produces an unsolicited response. JSON-RPC 2.0 and MCP require the server to send no reply to a notification.

WHY IT MATTERS: The host receives a response frame it never requested, keyed to a null id; a strict client treats this as a protocol error and the id-keyed stream is polluted. The adapter's own comment (lines 168-169) states the rule it then breaks.

CONFIDENCE: high
- **Fix:** Compute isNotification once and gate every reply path on !isNotification (reply, fail and handleToolCall), so notifications execute silently.

### 0027

- **Severity / category / module:** S1 / bug / M2
- **Location:** `chatbox-mcp.swift:47`
- **Title:** MCP adapter corrupts any message text containing '+' [also: MCP adapter corrupts every + in a parameter value (query built with URLQueryItem)]
- **Status:** START
- **Evidence (before):** 47-50 builds the request from URLQueryItem values; Foundation leaves '+' literal (probe printed `?body=a%26b%3Dc%20d+e`) while the server's parseForm decodes '+' as a space (chatbox.swift:910). End to end: an MCP say with body `a+b and c+d+e` was stored as `a b and c d e`; the same body through curl/chatbox-cli is stored intact. The server's own forward path escapes this on purpose (chatbox.swift:923-938). | Lines 45-50 build the request with `URLQueryItem(name: k, value: v)` then `comps?.queryItems = items`. Foundation leaves + unescaped in the query (a Swift probe printed the URL `...?body=a+b`), and the server's percentDecode (chatbox.swift:909-911) replaces + with a space. End-to-end with the built adapter and server, `say` with body `sum a+b = c` was stored and returned by `inbox?json=1` as `sum a b = c`.

WHY IT MATTERS: The MCP adapter is a documented front-end for model hosts (README:166-172), so messages containing '+' (diff hunks, arithmetic, URLs) reach the peer silently altered - wrong results in the only payload the product carries, from a consumer the server cannot correct. | Every tool call whose value contains + is silently altered -- message bodies, subjects, repo keys, notes. The server's own formEncode comment (chatbox.swift:923-926) calls this exact hazard out and avoids it on the forward path; the MCP adapter is the one client that still does it.

CONFIDENCE: high
- **Fix:** Percent-encode query values with the server's formEncode rule, or POST an application/x-www-form-urlencoded body, in chatbox-mcp.swift; add a suite check that an MCP say preserves '+'. | Do not use URLQueryItem for values: percent-encode them with the same unreserved-set rule the server uses (escaping + as %2B), or POST the arguments as an application/x-www-form-urlencoded body like performForward does.

### 0028

- **Severity / category / module:** S1 / bug / M2
- **Location:** `chatbox-mcp.swift:54`
- **Title:** inbox wait advertised up to 300s but the adapter's HTTP client gives up at 60s [also: MCP HTTP timeout (60/70 s) is shorter than the inbox wait it advertises (max 300 s)]
- **Status:** START
- **Evidence (before):** req.timeoutInterval = 60 (line 54) and the semaphore waits 70s (line 65), while the inbox tool advertises 'seconds to hold the request open (max 300)' (line 116) and the server caps wait at maxWaitSeconds = 300 (chatbox.swift:37, clamped at 1953). A call with wait above ~60 returns status 0 and body 'error: ...timed out', which toolResult (lines 136-140) marks isError. | Line 54 `req.timeoutInterval = 60` and line 65 `if sem.wait(timeout: .now() + 70) == .timedOut { task.cancel(); return (0, "error: the chatbox server did not answer within 70s") }`. The inbox tool tells callers wait holds the request open 'max 300' (line 116), and the server honours up to 300 (chatbox.swift:37, 1951-1953).

WHY IT MATTERS: The documented long-poll wake primitive cannot work through MCP beyond one minute: a host that asks for wait=300 gets a spurious transport error instead of the held connection the server is ready to serve, so wake-on-arrival is broken through the adapter. | Any inbox long poll with wait above roughly 60 seconds always ends in the adapter's own timeout error, never in the message it was waiting for. A host that follows the advertised schema gets a spurious isError:true and misses the delivery the long poll exists to provide.

CONFIDENCE: high
- **Fix:** Derive timeoutInterval from the requested wait plus a margin (or leave the default) and raise the semaphore deadline to match, instead of a fixed 60/70s. | Set timeoutInterval above maxWaitSeconds plus slack (e.g. 320) and raise the semaphore wait to match, or cap the wait value the schema advertises to what the client can actually hold.

### 0029

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:1279`
- **Title:** /health answers 200 with empty counters when the store cannot be read, and omits uptime/build/db state
- **Status:** START
- **Evidence (before):** `handle` (1223) returns `Reply(200, health())` unconditionally, and health builds its body from store.scalar(). `scalar` (498) -> `rows` -> `prepare`, which on a failed prepare logs `chatbox: sql error: ...` and returns nil, so scalar yields "". A board whose --db is not a SQLite file, or whose CREATE TABLE/PRAGMA at 393-447 failed under the silently-ignored exec (449-451), still answers `ok chatbox up` / `agents: ` with HTTP 200. /health also has no uptime, db path, WAL size or build identifier field that could go red.

WHY IT MATTERS: A monitor or KeepAlive probe that keys on HTTP 200 reports a board that cannot serve a single request as healthy; the failure is then discovered by users rather than by the health check, which is exactly what a health check exists to prevent.

CONFIDENCE: high
- **Fix:** Make health() fail closed: when any count query returns nil, answer 503 with the SQLite error. Add uptime, db path and WAL/row counts, plus a build/version field, so a probe has a signal to key on.

### 0030

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:1358`
- **Title:** register and token issuance report success when the store write failed [also: Registration reports success without checking its write]
- **Status:** START
- **Evidence (before):** 1358 stores registration with `store.run(INSERT INTO agents ...)` and 2232 stores a credential with `store.addToken(...)`; neither result is checked and both answer 200 (`ok registered`, `ok credential issued` + secret) unconditionally. With an ABORT trigger on agents, POST /register returned 'ok registered' with empty node/repos while the session was absent from /peers; with one on tokens, POST /token returned a secret while GET /token listed only the pre-existing credential, so it can never authenticate. | register() calls store.run("INSERT INTO agents (id,node,...)") at 1358-1359 and store.run("UPDATE agents SET ...") at 1366-1378, ignoring the -1 Store.run returns on failure (468-477), then re-reads with store.rows (1382-1384) and unconditionally returns 200 "ok registered" plus that row. On a failed write the SELECT returns nothing, so the answer reads "node:   agent:   repos: (none declared)", and owners(ofRepo:) (730-736) will never route mail to the id.

WHY IT MATTERS: A failed write becomes a success answer: a session that is not on the board later fails with 403, and an operator configures a machine with a credential that was never stored. Errors must not be reported as success on write paths. | The session believes it registered and owns its repos; messages to those repos are then stored with no owner and no delivery, and the failure is invisible to both sides.

CONFIDENCE: high
- **Fix:** Use runReporting/changedRows (as the /message insert does at 1540) for both writes and answer 500 with store.lastError() when the store reports no change. | Check the INSERT/UPDATE result with runReporting and return 500 "not registered" when the row was not stored, instead of echoing the registry.

### 0031

- **Severity / category / module:** S1 / perf / M1
- **Location:** `chatbox.swift:1509`
- **Title:** Reply resolution loads every message of the thread, bodies included, with no bound
- **Status:** START
- **Evidence (before):** message() line 1509 runs `for m in store.thread(String(threadId))` just to collect participants; Store.thread (857-862) is `SELECT id, thread_id, created_at, sender, repo, subject, body, reply_to, recipients, origin FROM messages WHERE thread_id = ? ORDER BY id ASC`, with no LIMIT. Every reply materializes the whole conversation, bodies and all, into [[String:String]] on the serial queue. A 100k-message thread at the 8 KB --max-body cap is up to ~800 MB.

WHY IT MATTERS: One ordinary `chatbox reply` into an old thread allocates unbounded memory and blocks the server's only serial queue; the amount of work is chosen by the thread's length, i.e. by whoever posted to it, and it grows forever.

CONFIDENCE: high
- **Fix:** Use a participants-only query instead, e.g. `SELECT DISTINCT sender, recipients FROM messages WHERE thread_id = ?`, or maintain a thread_participants table; never fetch body/repo/subject for recipient resolution.

### 0032

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:1551`
- **Title:** Delivery rows are inserted unchecked; the answer still claims delivered_to [also: Delivery inserts are unchecked, so a stored message can be reported as delivered without any delivery row]
- **Status:** START
- **Evidence (before):** message() stores the row with a checked runReporting (1529-1545) but then loops store.run("INSERT OR IGNORE INTO deliveries (message_id,agent,created_at,node) VALUES (?,?,?,?)") at 1550-1554 and discards the -1 Store.run returns on failure (468-477). The reply at 1637-1645 prints delivered_to: <recipients>; nothing re-reads deliveries before answering. A write failure leaves the message stored with no delivery row for a listed recipient. | Lines 1550-1554: `for r in recipients { store.run("INSERT OR IGNORE INTO deliveries (message_id,agent,created_at,node) VALUES (?,?,?,?)", [String(msgId), r, nowISO(), store.nodeOf(r) ?? ""]) }`. Store.run is @discardableResult and returns -1 when sqlite3_prepare_v2/step fails (453-477). The 200 body at 1637-1644 builds `delivered_to:` from the in-memory `recipients` array, not from the rows the store actually holds.

WHY IT MATTERS: The durable-delivery contract is that a stored message is routed to each recipient; a failed insert loses the report for that session while the sender is told it was delivered, so nobody retries. | If the delivery insert fails (disk full, I/O error, lock past busy_timeout), the message is stored but no recipient can ever read it, while the sender is told `delivered_to: <recipient>` with 200. The one caller who could detect the lost delivery is told the opposite.

CONFIDENCE: high
- **Fix:** Insert each delivery with runReporting and, when changes==0 or rc!=SQLITE_DONE, fail the send (or mark that recipient not delivered) instead of listing it as delivered. | Check the write: use runReporting (or test run's return) for each delivery insert and either answer 500 'stored but not delivered' or report the recipients that really got a row, as deliveryCount() already can.

### 0033

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:1902`
- **Title:** SSE 'bye' frame is built with a doubled backslash, so the documented bye event is never delivered [also: SSE deadline frame uses literal backslash-n, so the bye event is never terminated]
- **Status:** START
- **Evidence (before):** pollEvents sends Data("event: bye\\ndata: {\"reason\":\"deadline\"}\\n\\n".utf8) (1902) — the source has two backslashes before each n, which Swift collapses to a single backslash plus 'n', not a newline (od confirms the bytes). sendEvent() at 1944 uses single \n, so it is consistent. The whole frame therefore arrives as one line: no data field and no blank-line terminator, so an SSE client sees a garbage event name and then EOF. | Line 1902 sends `Data("event: bye\\ndata: {\"reason\":\"deadline\"}\\n\\n".utf8)` -- doubled backslashes, i.e. two-character backslash-n sequences, not newlines. `od -c` on the line shows backslash backslash n for each of the three newline positions, while every other frame (1944 sendEvent, 1920 keep-alive, 1904/1930) uses a real newline. tests/protocol.sh:3786 only greps for the substring `event: bye`, so it passes.

WHY IT MATTERS: README.md:207 and the test's own comment (tests/protocol.sh:3739) promise hello, activity and a bye 'so a client knows to reconnect'. tests/protocol.sh:3786 only substring-matches 'event: bye', which the malformed line still contains, so the defect ships undetected. | An SSE client sees no blank line terminating the frame, so the bye is never dispatched (the spec discards an incomplete event at EOF). The documented purpose of this frame -- 'a bye at the deadline so a client knows to reconnect' -- never reaches a client, and the test cannot catch it.

CONFIDENCE: high
- **Fix:** Use single newline escapes, or reuse the helper: sendEvent(conn, name: "bye", data: "{\"reason\":\"deadline\"}"). | Use single newlines: `Data("event: bye\ndata: {\"reason\":\"deadline\"}\n\n".utf8)`. Strengthen the test to assert the terminating blank line, not just the substring.

### 0034

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:2095`
- **Title:** Scoped credential's /threads count is board-wide, breaking read scoping [also: Scoped GET /threads?json=1 reports the board-wide thread count; GET /threads?json=1 leaks the board-wide thread count to a scoped credential; GET /threads JSON 'matching' counts the whole board, not the scoped caller's visible set]
- **Status:** START
- **Evidence (before):** listThreads scopes the rows (2100-2105 appends `t.id IN (nodeThreadsSQL)` for a non-bootstrap principal) but computes `let matchingThreads = store.threadCount(repo: repo)` (2095), and threadCount (876-880) has no node filter: `SELECT COUNT(*) FROM threads` or `... WHERE repo = ?`. With `json=1` (2110) a scoped token gets `{"shown":1,"matching":<all threads on the board>}` from its own conversation, contradicting README:192-194 ('thread, threads and peers answer for those and nothing else'). | listThreads() computes matchingThreads = store.threadCount(repo: repo) at 2095 and passes it to jsonRows at 2110, so a scoped credential's JSON answer carries "matching": N. Store.threadCount (876-880) is COUNT(*) FROM threads (optionally WHERE repo=?) with no node predicate, while the row query at 2096-2107 is scoped with t.id IN (nodeThreadsSQL). Comparable counts are scoped (agentCount(visibleTo:) 776, deliveryCount(agent:) 806); this one is not. | 2095 computes `matchingThreads = store.threadCount(repo:)` board-wide, and 2110 returns it as `matching` even for a scoped caller, while the rows themselves are scoped at 2100-2105. Probe with 110 threads: a node-a credential participating in 2 got `{"shown": 2, "matching": 110}` from GET /threads?json=1. /peers correctly uses agentCount(visibleTo:); the text form prints only 'threads - 2'. | listThreads computes `let matchingThreads = store.threadCount(repo: repo)` (2095) and returns it via jsonRows(rows, key: "threads", matching: matchingThreads) (2110). threadCount() (876-880) is a bare COUNT(*) over threads with no visibility predicate, while the row query adds `t.id IN (nodeThreadsSQL)` for a scoped principal (2100-2105). listThreads has no bootstrap guard.

WHY IT MATTERS: The machine is the confidentiality boundary, which makes the aggregate part of the contract, not decoration: a compromised or curious machine learns how much conversation the rest of the board holds, and can probe repo keys for board-wide activity without being able to read a single message. The suite tests only that foreign threads are absent, never the count. | A credential bound to one machine learns how many conversations exist board-wide and for any repo key it names, breaking the documented rule that it may read only conversations its machine takes part in. | README:190-193 promises a scoped credential's thread/threads/peers answers 'for those and nothing else'. This is the one scoped read that returns a board-wide (or per-repo) count, disclosing activity that the machine boundary is meant to withhold. | A scoped credential is defined to see only conversations its machine takes part in (comments 2095, 2100-2105; store docs 813-826), yet /threads?json=1 discloses the board-wide thread count and /threads?repo=<any key>&json=1 discloses that repo's count. The wrong 'matching' also contradicts the listing it accompanies.

CONFIDENCE: high
- **Fix:** Add a scoped count to Store (reuse nodeThreadsSQL with the node bound twice when the principal is not bootstrap) and use it for `matching`, so for a scoped reader shown always equals matching. Add a check that `threads?json=1` under a scoped token reports matching==shown. | Give threadCount a visibleTo/scope argument and apply the same nodeThreadsSQL condition used for the rows, or count the already-scoped query. | Scope the count exactly as the rows are scoped - add the same `t.id IN (nodeThreadsSQL)` predicate for non-bootstrap callers (a scoped threadCount). | Count with the same WHERE clause as the listing (pass who.node into threadCount and apply nodeThreadsSQL), so shown and matching describe the same scoped set.

### 0035

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:2107`
- **Title:** /threads hardcodes LIMIT 100 and its text answer hides the truncation [also: GET /threads is permanently capped at the newest 100 with no offset or cursor; ORDER BY threads.last_at has no index; every /threads call scans and sorts the whole threads table; GET /threads silently truncates at a hard-coded 100, ignores --max-rows, and the text form omits the count; GET /threads text form truncates at a hardcoded 100 and never states the matching count]
- **Status:** START
- **Evidence (before):** Line 2107 `sql += " ORDER BY t.last_at DESC LIMIT 100"` -- a literal 100, not the configured maxRows (used by threadPage, agentsListing, tokensListing, and reported by /health as 'max rows'). matchingThreads is computed at 2095 but the text answer at 2111 prints only `rows.count`. Ran with 105 threads: `GET /threads` printed `threads - 100` with 100 `[id]` rows, while `GET /threads?json=1` reported `shown 100 matching 105`. | listThreads builds the query at 2096-2107 and ends with the clause `ORDER BY t.last_at DESC LIMIT 100`. matchingThreads (2095) is reported as `matching`, so the response admits more exist, but no request parameter (offset, page, before=) exists anywhere in the route or in chatbox-cli.sh. Only the repo= filter narrows the set, so older conversations on the same repo are unreachable. | The CREATE INDEX statements (420-446) cover deliveries and messages(thread_id) only; there is no index on threads(last_at) or threads(repo). EXPLAIN QUERY PLAN for the listThreads query is `SCAN t` plus `USE TEMP B-TREE FOR ORDER BY`, and threadCount(repo:) at 879 is `SELECT COUNT(*) FROM threads WHERE repo = ?`, also SCAN threads. The served UI calls /threads?json=1 every 5 s per open page (uiPage refresh() and setInterval(refresh, 5000), lines 1833-1854). | 2107 hard-codes `ORDER BY t.last_at DESC LIMIT 100` (independent of --max-rows) and 2111 prints 'threads - N' with no of-matching note; only the JSON at 2110 carries `matching`. Probe with 110 threads: text answered 'threads - 100', JSON answered shown 100/matching 110. README:229-231 says --max-rows caps a listing and that the count appears in both the text and the JSON form. | listThreads appends `sql += " ORDER BY t.last_at DESC LIMIT 100"` (2107), ignoring maxRows (--max-rows default 500, allowed to 1000000). The text answer is "threads... — \(rows.count)\n" (2111); matchingThreads (2095) is used only in the JSON branch (2110), so nothing tells the reader that rows were dropped.

WHY IT MATTERS: A session asking for its conversations is silently handed the 100 most recent and a header that reads as complete, so older threads are invisible with no note (JSON callers are told; the default text path -- what a model reads -- is not). It also ignores --max-rows, so an operator who raises the bound still cannot see past 100. | Once a board holds more than 100 threads (or more than 100 on one repo), the API and the served read-only UI can never list or open the older ones: history silently becomes unavailable in production with no way to page to it. | A board with many threads pays a full scan and sort of the whole threads table on every listing, on the serial queue, multiplied by every open UI page polling every five seconds. | A human or a text-parsing consumer cannot tell a full listing from a 100-row page, and raising --max-rows does nothing - the same silent truncation the inbox, peers and thread paths were explicitly changed to avoid. | README.md:229-231 promises every bounded listing says how many of how many it is showing in both forms, and every other listing does (showThread 2074-2076, inbox 1680-1682, peers 2172-2174, tokens 2268-2270). With more than 100 threads the text view silently hides the rest and --max-rows cannot raise the limit.

CONFIDENCE: high
- **Fix:** Use `LIMIT \(maxRows)` and print the same `rows.count` of `matchingThreads` wording the peers/tokens/inbox answers use, e.g. `threads - \(rows.count) of \(matchingThreads)` plus a note naming --max-rows. | Accept a cursor such as `before=<last_at>,<id>` (or an offset), bound the page with --max-rows like showThread does, and keep reporting how many rows were skipped. | Add `CREATE INDEX idx_threads_last_at ON threads(last_at DESC)` and `CREATE INDEX idx_threads_repo ON threads(repo)`. | Use maxRows for the limit and add the 'N of M' note to the text form as peers/tokens/thread do; document the effective cap in the README's /threads row. | Use maxRows for the LIMIT and append the same 'N older one(s) are not shown — raise --max-rows' note used by the other listings.

### 0036

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:2135`
- **Title:** Ack reports acknowledgements that did not happen, from an unchecked UPDATE
- **Status:** START
- **Evidence (before):** The three ack forms (2135, 2140, 2147) call store.run(...) then n = Int(store.changedRows()) (2138/2143/2151) and return "ok acked N", ignoring run's -1 on failure. Store.changedRows is sqlite3_changes(), which sqlite3.h:2826 defines as rows changed by "the most recently completed INSERT, UPDATE or DELETE"; a failed acked_at UPDATE is not completed, so the count still describes the preceding UPDATE agents SET last_seen at 2123 (1 for an existing agent).

WHY IT MATTERS: The caller is told mail was marked read while acked_at is unchanged; the route's own comment promises the count is the work the statement really did, so a client that trusts it will not retry.

CONFIDENCE: high
- **Fix:** Run each ack UPDATE through runReporting, answer 500 when rc != SQLITE_DONE, and use only that statement's changes for N.

### 0037

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:2138`
- **Title:** ack reports sqlite3_changes() even when the UPDATE failed, so a failed ack answers 'ok acked N'
- **Status:** START
- **Evidence (before):** Lines 2135-2151 run each ack UPDATE with store.run (which returns -1 on prepare/step failure) and then unconditionally take `n = Int(store.changedRows())`. sqlite3_changes() is not reset by a failed statement; measured with SQLite, after a one-row UPDATE a failing statement left changes() == 1. The preceding statement on this connection is the last_seen UPDATE at 2123, which touches 1 row for a registered session.

WHY IT MATTERS: The comment at 2124-2128 promises the number reported is what the statement really stamped. On a store failure the caller is told `ok acked 1 for <id>` (or 0) while nothing was acknowledged -- the one answer a caller can check is wrong, and unread mail silently stays unread.

CONFIDENCE: high
- **Fix:** Use runReporting() (512) for the three ack UPDATEs and answer 500 when rc != SQLITE_DONE, reporting changes only on success; do not read changedRows() after a failed run.

### 0038

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:2232`
- **Title:** A credential's secret is returned even when the token INSERT did not store it
- **Status:** START
- **Evidence (before):** createToken() calls store.addToken(...) at 2232-2234, which is run("INSERT INTO tokens (id,hash,node,namespaces,note,created_at,expires_at) VALUES (?,?,?,?,?,?,?)") (547-551) with the result discarded, then unconditionally returns 200 "ok credential issued ... secret: <secret>". If the INSERT failed (busy/disk/read-only) or the 48-bit id collided with the PRIMARY KEY, no row matches sha256Hex(secret), and authorize() answers "unauthorized: unknown token" (1118-1120).

WHY IT MATTERS: The board hands a machine a credential that can never authenticate and records no failure, so the first request from that machine fails 401 with no board-side explanation.

CONFIDENCE: high
- **Fix:** Check addToken's result with runReporting; on failure return 500 without printing a secret, and retry once when the error is a PRIMARY KEY collision.

### 0039

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:2406`
- **Title:** Request log records no time, peer, principal or route context; credential issue/revoke unaudited [also: Request target control bytes are echoed into logs and the 404 body (log injection)]
- **Status:** START
- **Evidence (before):** `finish` writes only `chatbox: \(req.method) \(req.path) -> \(status)`. `req.peer` is set (1183) but never logged, and no log line calls nowISO(). The live chatbox.log (14 KB) is exactly `chatbox: GET /health -> 200` / `POST /token -> 200` lines: no timestamp, no client address, no token id/node/session, no repo/thread/message id on success. Credential issuance (2194-2257) and revocation (2287-2310) appear only as `POST /token -> 200` / `POST /token/revoke -> 200`. Only forward outcomes name anything (1723 logs the message id). | finish() logs `"chatbox: \(req.method) \(req.path) -> \(status)\n"` and the 404 body at 1234 echoes req.path too. req.path comes from `target = String(parts[1])` (2335) with no control-byte check, and a bare LF survives because the header block is split on CRLF. Ran: sending `GET /x` + LF + `FORGED?token=...` over nc made chatbox.log contain a real newline and a forged `chatbox: FORGED-BY-CLIENT -> 404` line; the 404 body contained `not found: GET /x` then `FORGED-BY-CLIENT`.

WHY IT MATTERS: After an incident the operator cannot order events, attribute an authentication failure or an issued credential to a machine, or answer 'was the report for repo X stored?'. On a shared board this log is the only forensic record, and it cannot support any of those questions. | Even an unauthenticated 401 request is logged, so any client can forge chatbox.log lines (an operator reading the audit trail sees entries the attacker wrote) and force newlines into a response body. Every other echoed value in this file goes through oneLine(); the request target is the one that does not.

CONFIDENCE: high
- **Fix:** Prefix every line with an ISO-8601 timestamp and include the peer address; add the authenticated token id/node as a field on authorized routes; log register/message/ack/token-issue/token-revoke with the ids they touched (message id, repo, node, credential id). | Reject control characters in the request line in parse() (400 or drop the connection), and/or write oneLine(req.path) in finish() and in the 404 body, the same treatment every other attacker-influenced echo gets.

### 0040

- **Severity / category / module:** S1 / unsafe / M1
- **Location:** `chatbox.swift:2431`
- **Title:** Connections refused at the ceiling get no idle deadline and are not counted, so stalled TLS handshakes accumulate without bound
- **Status:** START
- **Evidence (before):** In serve(), the over-limit branch (2431-2441) only installs a stateUpdateHandler that answers on .ready, starts the socket and returns; it never schedules the idle DispatchWorkItem created at 2453-2460 for counted connections. With TLS, .ready is reached only after the handshake, so a peer that connects and sends no ClientHello stays in .preparing indefinitely. These connections are deliberately not inserted into liveConnections (2443), so the ceiling does not bound their number.

WHY IT MATTERS: On a --tls-identity deployment one peer can open unlimited half-open sockets while the board is at its limit, exhausting file descriptors and denying service — the exact stall the idle deadline exists to bound (comment 2444-2452). /health still reports 'connections: up to N' (1289) as if the ceiling held.

CONFIDENCE: medium
- **Fix:** Schedule the same idle deadline (or a shorter handshake deadline) on the refuse branch, and/or count refused connections toward a separate bound.

### 0041

- **Severity / category / module:** S1 / logic / M1
- **Location:** `chatbox.swift:2810`
- **Title:** `--port` and `--stale-after` silently fall back to their defaults on an unparseable value [also: --port and --stale-after silently substitute the default for an unusable value]
- **Status:** START
- **Evidence (before):** `let port = UInt16(argValue("--port", "8787")) ?? 8787` (2810) and `let staleAfterValue = Int(staleAfterRaw) ?? 604800` (2941) discard what the operator typed. `--port 9000o`, `--port 70000` and `--port ''` all bind 8787 with no message; `--stale-after 7d` becomes 604800. Every other bound is refused when it does not parse (--max-body 3007, --idle-timeout 3018, --max-connections 3026, --max-rows 3034, --max-hops 3123), and --stale-after is only tested for `< 0` (2942). | 2810 `UInt16(argValue("--port", "8787")) ?? 8787` and 2941 `Int(staleAfterRaw) ?? 604800` fall back to the default for an unparseable or out-of-range value. Ran `--port 99999 --stale-after abc`: the banner read 'chatbox listening on port 8787' and 'staleness ... 7d'. Every other bounded flag (--max-body 3002-3011, --idle-timeout, --max-connections, --max-rows, --max-hops, --prune) exits 2 on a bad value.

WHY IT MATTERS: The server that starts is not the one on the command line: clients are pointed at a port nothing listens on while an unintended port is open, and a typo in the presence window silently reverts it to seven days, so gone sessions are reported active. | A configured-looking server listens somewhere the operator did not ask for, and a client or script pointed at the requested port fails with no server-side signal. It contradicts the file's own rule that a value nobody asked for must stop the server.

CONFIDENCE: high
- **Fix:** Parse both with a guard and exit 2 naming the flag and the bad value (`guard let p = UInt16(raw), p > 0 else { ... }`); reject a non-numeric --stale-after instead of defaulting it. | Parse with `guard let p = UInt16(...), p > 0` and `guard let s = Int(...), s >= 0`, exiting 2 with the offending value, as the other flags do.

### 0042

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:2939`
- **Title:** `--prune`/`--prune-dry-run` on a mistyped `--db` creates a new board and reports success [also: --prune opens (and creates) a database before validating it, so a wrong --db path yields success on a brand-new board; Operator modes: Store is opened before --prune validation, a mistyped --db creates a board and reports 'pruned: 0', and conflicting modes silently win; --prune-dry-run can create or rewrite the database it promises not to touch]
- **Status:** START
- **Evidence (before):** Prune opens `Store(path: dbPath, migrating: !argPresent("--prune-dry-run"))` (2939) with no fileExists check, although --backup checks the source (2885) and both modes require an explicit --db 'so it cannot guess wrong' (2980). sqlite3_open creates a missing file and `PRAGMA journal_mode=WAL` writes a 4096-byte board (reproduced under /tmp); with migrating:true the schema is created, prune returns (0,0,0), and the command prints `pruned: 0 message(s)` and exits 0. A dry run also leaves a new 4 KB file, contradicting 'must not leave a changed file behind either' (2936-2938). | Line 2939 `let store = Store(path: dbPath, migrating: !argPresent("--prune-dry-run"))` runs before the prune block at 2973; Store.init calls sqlite3_open (which creates a missing file) and PRAGMA journal_mode=WAL. Ran: `chatbox --db /tmp/l3probe/probe.sqlite --prune 1 --prune-dry-run` created probe.sqlite (4096 B) plus -shm and -wal while printing 'nothing was removed' and exiting 0; `chatbox --db /tmp/l3probe/probe2.sqlite --prune 1` created a full 5-table board (verified with .tables) and printed 'pruned: 0 ...', exit 0. | 2939 constructs Store before the prune checks at 2965-2983. Ran the built binary: `--prune 30 --prune-dry-run --db /tmp/.../wrong.sqlite` (path absent) created wrong.sqlite and printed 'would prune: 0', exit 0; `--prune 30 --db wrong2.sqlite` printed 'pruned: 0' after creating the schema; `--backup x --prune 30` did the backup and exit 0 with no prune; `--prune 30` without --db opened/migrated the default ~/chatbox.sqlite before exiting 2. | The comment at 2936-2938 says a dry run "must not leave a changed file behind either", but Store(path: dbPath, migrating: !argPresent("--prune-dry-run")) is opened at 2939, and Store.init always runs sqlite3_open (387, default READWRITE|CREATE) and exec("PRAGMA journal_mode=WAL") at 393 even when migrating==false. A nonexistent --db path is created and a delete-journal board is converted to WAL; prune() then returns (0,0,0) and the command prints "would prune: 0 ... nothing was removed" and exits 0.

WHY IT MATTERS: Retention appears to have run against the real board when it ran against an empty file the typo created; nothing on the real board is ever pruned and the operator gets exit 0 and a success line. | A mistyped --db path is not detected: the operator is told the prune succeeded (or the dry run changed nothing) while a stray board was created and the intended board was never touched. The dry run also violates its own stated contract at 2936-2938 that it 'must not leave a changed file behind'. | A mistyped --db is indistinguishable from a board with nothing to prune, and a requested prune is silently skipped when another operator mode is present. The operator's only signal is wrong. The backup path already refuses a nonexistent source (2885) and conflicting modes (2853). | A mistyped --db produces a spurious empty board and a green "nothing to prune" answer, and a dry run mutates the live board's journal mode, contradicting its core promise.

CONFIDENCE: high
- **Fix:** Require the --db file to exist before opening it for --prune and --prune-dry-run, as --backup does, and open the dry run read-only so it cannot create a board. | Validate the path before opening it in prune modes, the way --backup/--verify-backup do via readBoard() (2745), and open read-only for --prune-dry-run; refuse when the file does not exist or lacks the board tables (2663). | Validate the operator-mode flag set before opening anything: refuse --prune with --backup/--verify-backup, require --db, and check the path exists and is a board (readBoard) before constructing Store. | In dry-run mode open read-only (SQLITE_OPEN_READONLY or an immutable URI), fail when the file does not exist, and apply no pragma that writes.

### 0043

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:298`
- **Title:** Agent ids may contain ',', but recipients are stored comma-joined and re-split, so a reply can be delivered to an unintended session
- **Status:** START
- **Evidence (before):** validId() (298-301) rejects only control bytes, so ',' (and U+2028/U+2029) pass; validBoardID() (309-313) explicitly refuses ',' for exactly this delimiter reason. messages.recipients is written as recipients.joined(separator: ",") (1532) and later re-parsed with (m["recipients"] ?? "").split(separator: ",") (1511) when a reply's recipients are gathered from thread history; every parsed value is then inserted into deliveries (1550-1553) with store.nodeOf(r).

WHY IT MATTERS: Any credential can register arbitrary ids on its own node, so id "a,victim" is stored literally; after a later reply the split yields "victim" as a separate recipient and a delivery row is created for a session that never participated, giving that machine read access to the thread. A comma in an id silently redirects mail.

CONFIDENCE: high
- **Fix:** Reject ',' and all Unicode whitespace in validId() as validBoardID() already does, or serialise recipients as JSON instead of a comma-joined string.

### 0044

- **Severity / category / module:** S1 / bug / M1
- **Location:** `chatbox.swift:3232`
- **Title:** No SIGTERM/SIGINT/SIGHUP handling: no drain, no WAL checkpoint, no log reopen
- **Status:** START
- **Evidence (before):** The process ends at `dispatchMain()` (3232); grep for signal|SIGTERM|SIGINT|SIGHUP|atexit|DispatchSourceSignal over chatbox.swift matches only DispatchSemaphore.signal() (1759) and comments. Default dispositions therefore apply, so SIGHUP terminates a live board (logrotate's default `kill -HUP`). A POST /message that already committed before SIGTERM loses its 200 with no idempotency key, so a client retry duplicates a report; `/events` (1902 bye) and `inbox?wait=` (2046 timeout body) get a dropped socket with no terminal event. README.md:75 deploys with nohup and no supervisor.

WHY IT MATTERS: Any restart, `pkill` (the documented stop, Deployment.md:50) or log rotation kills the board mid-request with no drain and no shutdown record, so clients cannot tell 'not stored' from 'stored but unanswered' and a retry duplicates a report; rotating chatbox.log takes the service down.

CONFIDENCE: high
- **Fix:** Add a DispatchSourceSignal on the server queue for SIGTERM/SIGINT: stop accepting, log a shutdown line, let in-flight sends finish, end SSE with the existing `bye` event, then exit. Treat SIGHUP as a log reopen (or document copytruncate). Add a bounded --drain-seconds.

### 0045

- **Severity / category / module:** S1 / incomplete / M1
- **Location:** `chatbox.swift:484`
- **Title:** Store.rows treats every non-ROW step result as end-of-data, returning partial results as complete
- **Status:** START
- **Evidence (before):** Line 484 `while sqlite3_step(st) == SQLITE_ROW { ... }` then `return out`: SQLITE_DONE and SQLITE_BUSY/IOERR/CORRUPT/NOMEM are indistinguishable. Every read path uses this helper -- owners(ofRepo:) at 730, visibleAgentIds at 757, deliveries at 792, tokenByHash at 541, thread at 857.

WHY IT MATTERS: On a mid-scan error the caller is handed the rows accumulated so far as if the query finished. owners() then routes a report to a subset of owners, deliveries() shows a truncated inbox with no truncation note, and the matching count comes from a separate query that may report 0 -- wrong results with no error anywhere.

CONFIDENCE: medium
- **Fix:** Record the step result in rows() and surface a non-DONE code (log it and return nil/throw, or have callers distinguish), so a partial scan is never presented as a complete answer.

### 0046

- **Severity / category / module:** S1 / perf / M1
- **Location:** `chatbox.swift:827`
- **Title:** Scoped visibility checks full-scan deliveries and messages; no index on deliveries(node) or messages(sender)
- **Status:** START
- **Evidence (before):** nodeThreadsSQL (827-832) and visibleAgentsWhere (836-843) test `m.sender IN (SELECT id FROM agents WHERE node = ?)` and `d.node = ?`; node(_:participatesIn:) (846-855) uses the same. The only indexes are deliveries(agent), deliveries(agent,acked_at), tokens(hash), messages(thread_id) (420-446). EXPLAIN QUERY PLAN: SCAN messages, SCAN deliveries, SCAN agents. Measured on a 500k-message/500k-delivery board: participation check 94 ms; visibleAgentsWhere 127 ms.

WHY IT MATTERS: Every scoped GET /thread (2060), reply (1489), GET /threads (2103), every scoped send via visibleAgentIds (1566) and every scoped /peers (2162-2163) runs this on the serial queue. deliveries is the fastest-growing table, so scoped-request latency rises linearly with board history.

CONFIDENCE: high
- **Fix:** Add `CREATE INDEX idx_del_node ON deliveries(node, message_id)` and `CREATE INDEX idx_msg_sender ON messages(sender)`, or derive the node's thread set once per request via a CTE/temp table instead of re-deriving it in multiple subqueries.

### 0047

- **Severity / category / module:** S1 / test / M4
- **Location:** `tests/protocol.sh:1505`
- **Title:** --port and --stale-after silently fall back to defaults on an unusable value; no check
- **Status:** START
- **Evidence (before):** The only invalid-window check is line 1505 (--stale-after -1). chatbox.swift:2810 'let port = UInt16(argValue("--port", "8787")) ?? 8787' and :2941 'let staleAfterValue = Int(staleAfterRaw) ?? 604800' mean --port abc, --port 99999 and --stale-after abc all start successfully on the default; checkArguments (2600) only requires that a value token follows the flag, never that the value is usable.

WHY IT MATTERS: A typo'd port silently binds 8787 (with --port 0, an unknown ephemeral port) and a typo'd staleness window silently becomes seven days, so presence reporting behaves unlike what the operator asked for while the CLI reports success.

CONFIDENCE: high
- **Fix:** Validate both values alongside the other value flags (reject non-numeric and out of 1..65535 with exit 2 and the flag named) and add startup-refusal checks for --port abc/0/65536 and --stale-after abc.

### 0048

- **Severity / category / module:** S1 / test / M4
- **Location:** `tests/protocol.sh:3442`
- **Title:** No startup-boundary test for --idle-timeout, --max-connections or --max-rows
- **Status:** START
- **Evidence (before):** Section 27 starts its two servers at 3442-3449 with in-range values only (--max-rows 3 --idle-timeout 1 --max-connections 2); it never runs an out-of-range one, while mb_refuses (2257) does exactly that for --max-body. chatbox.swift:3018, 3026 and 3034 hold the guards ('--idle-timeout must be between 0 ... and 3600', '--max-connections must be between 1 and 65535', '--max-rows must be between 1 and 1000000'), and tests/.scratch/mutate.sh has no mutant for any of the three.

WHY IT MATTERS: Deleting any guard silently misconfigures the board: --max-connections 0 makes every request 503, --max-rows 0 makes every listing empty, --idle-timeout -1 fails open to no deadline. Nothing in the suite or the matrix would go red.

CONFIDENCE: high
- **Fix:** Add a bounds_refuses helper modelled on mb_refuses and assert exit 2 plus the flag named in the log for --max-rows 0/1000001/abc, --max-connections 0/65536/abc, --idle-timeout -1/3601/abc; add matching mutants.

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

### 0049

- **Severity / category / module:** S2 / test / repo
- **Location:** `.github/workflows/codeql.yml:57`
- **Title:** CodeQL extraction build never compiles chatbox-mcp.swift, so the MCP adapter is unscanned
- **Status:** START
- **Evidence (before):** The 'Build for extraction' step runs only 'xcrun swiftc -O chatbox.swift -o chatbox' (codeql.yml:57), while CI builds both binaries (ci.yml:39-40) and README.md states 'CodeQL analyses the same build'. Swift CodeQL is extraction-based, so code that is never compiled is never analysed.

WHY IT MATTERS: The component that reads CHATBOX_TOKEN and constructs outbound HTTP requests has no static security analysis at all. Defects in it (such as the query-encoding corruption above) cannot be reported by the security gate the README advertises as covering the shipped binaries.

CONFIDENCE: high
- **Fix:** Add 'xcrun swiftc -O chatbox-mcp.swift -o chatbox-mcp' to the CodeQL build-for-extraction step.

### 0050

- **Severity / category / module:** S2 / docs / repo
- **Location:** `aisessionserver-wiki/Deployment.md:92`
- **Title:** Local test runbook starts the disposable server on the suite's own staleness port
- **Status:** START
- **Evidence (before):** Deployment.md:92 and Quick-Start.md:253 start the test server with `--port 8791`, and Deployment kills it with `pkill -f "chatbox --port 8791"` (95). README.md:270 uses 8790 and warns (282-283) that 8791 is the suite's own staleness server (`CHATBOX_STALE_PORT` overrides it). With CHATBOX_BIN set — which README.md:278 instructs — tests/protocol.sh:1474 binds 8791, fails, and its readiness probe (1478-1481) is answered by the operator's wrong server, so the presence-timing checks run against a 7-day window.

WHY IT MATTERS: An operator who follows both pages gets a failed run, or staleness checks silently answered by the wrong board because the suite's own server never starts: the test result is not evidence about the build.

CONFIDENCE: high
- **Fix:** Start the disposable server on 8790 in Deployment.md and Quick-Start.md (and fix the pkill pattern), or set CHATBOX_STALE_PORT to a free port in both snippets.

### 0051

- **Severity / category / module:** S2 / docs / repo
- **Location:** `aisessionserver-wiki/Quick-Start.md:255`
- **Title:** Documented local test command silently skips checks and cannot print the promised result
- **Status:** START
- **Evidence (before):** Quick-Start.md:249-259 and Deployment.md:89-95 run the suite with only CHATBOX_URL/CHATBOX_TOKEN and then show `864 passed, 0 failed` as the expected output. The suite skips whole blocks when CHATBOX_DB, CHATBOX_SERVER_LOG, CHATBOX_BIN or CHATBOX_MCP are unset (tests/protocol.sh:398, 498, 869, 1377, 1468, 1560 and the MCP block), printing `skip ...` without counting them; the summary (protocol.sh:4307) prints only passed/failed. README.md:273-279 sets all four and warns the checks are skipped without them.

WHY IT MATTERS: The wiki's 'cheapest way to know a build is good' proves materially less than it claims, and its stated output is unattainable, so an operator gets false confidence immediately before a production restart.

CONFIDENCE: high
- **Fix:** Use README's invocation verbatim on both wiki pages (CHATBOX_DB, CHATBOX_SERVER_LOG, CHATBOX_BIN, CHATBOX_MCP, port 8790) and state the count that invocation actually produces.

### 0052

- **Severity / category / module:** S2 / unsafe / M3
- **Location:** `chatbox-cli.sh:150`
- **Title:** Client puts the credential in curl argv, exposing it to every local user via ps
- **Status:** START
- **Evidence (before):** http_get/http_get_wait build the URL as `_q="...token=$TOKEN"` (150-151, 158-159) and pass it as a curl argument; http_post does the same with `--data-urlencode "token=$TOKEN"` plus -G (530). The whole command line, secret included, is visible in `ps` for the duration of every request, which is exactly the exposure the server documents: 'a token passed as argv is visible to every local user in ps' (chatbox.swift:2814).

WHY IT MATTERS: Every agent machine leaks its credential to any other local process or user. A scoped secret lets the reader act as that machine's sessions (register, send, read its conversations, ack); if the shared bootstrap secret is in CHATBOX_TOKEN the reader owns the whole board.

CONFIDENCE: high
- **Fix:** Keep the secret out of argv: write `header = "Authorization: Bearer ..."` (or the token query) into a 0600 mktemp file and call `curl -K file`, or use --netrc-file; unlink it afterwards. Only token length/absence should ever appear on the command line.

### 0053

- **Severity / category / module:** S2 / logic / M3
- **Location:** `chatbox-cli.sh:29`
- **Title:** ~/.chatbox overrides the environment instead of defaulting to it
- **Status:** START
- **Evidence (before):** chatbox-cli.sh:29-31 sources `${CHATBOX_CONFIG:-$HOME/.chatbox}` before reading CHATBOX_URL/TOKEN/CACERT at :33-40, so a file line `export CHATBOX_URL=...` wins over the caller's `CHATBOX_URL=... chatbox say`. The header at :27-28 calls the file 'Per-machine defaults', and every documented precedence rule is 'an explicit flag always wins'. The suite works around it with CHATBOX_CONFIG=/nonexistent (tests/protocol.sh:3362).

WHY IT MATTERS: An operator pointing one command at another board or a rotated token - `CHATBOX_URL=http://staging ... chatbox say` - silently talks to the ~/.chatbox target instead, posting a real message to the wrong server with no warning.

CONFIDENCE: medium
- **Fix:** Snapshot the environment values before sourcing and restore them after, or source in a subshell and copy only the variables that were unset in the environment.

### 0054

- **Severity / category / module:** S2 / logic / M3
- **Location:** `chatbox-cli.sh:355`
- **Title:** canon_repo accepts Unicode Cf/C1 controls that chatbox.swift refuses [also: Repo-key rule duplicated in client and server diverges on Unicode format controls]
- **Status:** START
- **Evidence (before):** chatbox-cli.sh:355 deletes only the bytes \001-\037 and \177, and 433-436 tests only *,?, [, ], space and tab. Running the shipped function under LC_ALL=C: canon_repo of `github.com/acme/li<U+200B>bfoo`, `.../<U+FEFF>bfoo` and `.../<U+0085>bfoo` all return rc=0. chatbox.swift:153-164 hasControlByte rejects CharacterSet.controlCharacters - the C1 and Cf (zero-width, BOM, bidi) blocks - so the server answers 400. | 355 deletes only bytes 1-31 and 127, but the server's hasControlByte (chatbox.swift:153-164) also rejects Unicode format controls (Cf). Ran both rules over a 29-key corpus: 28 agreed; `host/a<U+200B>b` and `host/a<U+FEFF>b` returned rc=0 with a canonical key from canon_repo while POST /register refused them as 'not a valid repo key'. The comment at 433 claims the server's characters 'are refused here too'.

WHY IT MATTERS: The client and server are documented to apply one identical rule (chatbox.swift:190-202, README:143-146). Here the client certifies a key the server then refuses, so `register --repo`/`say --repo` fail with the server's 400 even though the local remote check passed, and the invisible character is exactly the kind that splits two spellings of one repo. | The client can vouch for and send a key the server rejects, so a claim fails at the last step instead of locally; worse, the two copies of the rule the code calls canonical will drift as either side changes.

CONFIDENCE: high
- **Fix:** Extend the control-byte test to the C1 range and the Cf sequences: reuse the list FORMAT_CONTROLS_SED already builds for display, plus the U+0080-U+009F block, so accept/reject matches the server's CharacterSet.controlCharacters. | Mirror the server's Cf rejection (the sed format-control list at chatbox-cli.sh:197-209 can be reused), or expose one canonicalisation implementation that the client calls.

### 0055

- **Severity / category / module:** S2 / bug / M3
- **Location:** `chatbox-cli.sh:686`
- **Title:** GET query strings are concatenated unencoded, so ids with a space or & break the request
- **Status:** START
- **Evidence (before):** chatbox-cli.sh:686 builds `_q="id=$ID"` and :692 `"id=${POS1:-$ID}"`; http_get/http_get_wait splice them raw into `${URL}${1}?${_q}` (151,159). Verified: `curl 'http://127.0.0.1:1/inbox?id=a b&all=1'` exits 3, 'URL rejected: Malformed input'. An `&` or `=` in --id silently rewrites the query instead. The header at line 17 claims 'All values are URL-encoded by curl ... spaces, quotes, & and newlines are safe'.

WHY IT MATTERS: The server accepts ids containing spaces and & (validId rejects only control bytes), so a legitimate id makes inbox/thread/health fail with a bare curl exit code and no framed output - or quietly polls a different query. The client's own documented safety claim is false on every GET path.

CONFIDENCE: high
- **Fix:** Percent-encode every value before it enters a URL (a small `urlenc` helper), or POST these reads with --data-urlencode as the write paths already do.

### 0056

- **Severity / category / module:** S2 / logic / M3
- **Location:** `chatbox-cli.sh:703`
- **Title:** ack silently drops --all, then the server error names the flag the caller passed
- **Status:** START
- **Evidence (before):** chatbox-cli.sh:548 handles `--all` for every command, but the ack branch at :703 posts only id/message/thread. `chatbox ack --id X --all` therefore exits 2 with the server's 'error: pass message=<id>, thread=<id> or all=1' - an error naming the very flag that was given. The unknown-flag guard at :585 never sees it, because --all is a recognised flag.

WHY IT MATTERS: The server supports all=1 on /ack (chatbox.swift:2139-2143) as the way to mark a whole inbox read, so the documented server capability is unreachable through the client, and the diagnostic misdirects the caller into re-checking a request that was well formed.

CONFIDENCE: high
- **Fix:** Add `[ -n "$ALL" ] && set -- "$@" --data-urlencode "all=1"` in the ack branch, or reject --all at parse time for commands that do not use it.

### 0057

- **Severity / category / module:** S2 / incomplete / M3
- **Location:** `chatbox-cli.sh:775`
- **Title:** watch delivers the 1200-character inbox preview and then acks it
- **Status:** START
- **Evidence (before):** The loop polls GET /inbox (chatbox-cli.sh:775, 795) and frames the plain-text listing (804-816). That renderer truncates every body at 1200 characters with ' ... [truncated]' (chatbox.swift:1694), while the JSON view carries the full body. The client then acks the same messages (:819-820), so the consumer's copy is capped and marked read. tests/protocol.sh:2161 and 2220-2221 confirm the 1200 preview is deliberate.

WHY IT MATTERS: watch is the primary wake path (README:148-153) and the envelope allows bodies up to --max-body (8192 bytes). A report longer than 1200 characters reaches the agent - and a --hook reason - incomplete, and because the delivery is acked the inbox will not offer it again; only a manual `chatbox thread <id>` recovers the rest.

CONFIDENCE: medium
- **Fix:** Detect the truncation marker (or use json=1) and fetch the full body from /thread before delivering, or refuse to ack a message the listing truncated.

### 0058

- **Severity / category / module:** S2 / bug / M2
- **Location:** `chatbox-mcp.swift:177`
- **Title:** Well-formed non-object JSON is reported as -32700 parse error instead of -32600 Invalid Request
- **Status:** START
- **Evidence (before):** The guard at lines 177-181 casts every line to [String: Any]; a valid JSON scalar, string or array (including a JSON-RPC 2.0 batch, which the advertised protocolVersion 2024-11-05 permits) fails the cast and emits fail(id: nil, code: -32700, "parse error") at line 179. JSON-RPC reserves -32700 for JSON that cannot be parsed; a well-formed root of the wrong type is -32600 Invalid Request.

WHY IT MATTERS: A host that batches requests or sends any non-object frame gets a parse-error response it cannot correlate with a request id, instead of the Invalid Request the spec defines, so it cannot tell a malformed envelope from broken JSON.

CONFIDENCE: medium
- **Fix:** Separate JSONSerialization failure (-32700) from a valid root that is not an object (-32600), and either support arrays per the advertised version or reject them as Invalid Request explicitly.

### 0059

- **Severity / category / module:** S2 / incomplete / M2
- **Location:** `chatbox-mcp.swift:197`
- **Title:** notifications/cancelled is a no-op that can never be observed while a call blocks the read loop
- **Status:** START
- **Evidence (before):** Line 197 handles 'notifications/cancelled' with an empty break. call() blocks the single stdio loop on DispatchSemaphore.wait (line 65) for up to 70s, so no further stdin line is read while a tool call is in flight. MCP says a server SHOULD cancel the matching in-flight request on notifications/cancelled; here the notification is both ignored and structurally unreachable.

WHY IT MATTERS: A host that cancels a slow inbox(wait=...) or thread call cannot stop it, and every other tool call is queued behind it for up to the timeout. The adapter behaves as a single-request server, so one slow board call stalls the whole MCP session.

CONFIDENCE: high
- **Fix:** Dispatch each tool call off the read loop and keep a map from JSON-RPC id to URLSessionTask so notifications/cancelled can cancel it; read stdin continuously.

### 0060

- **Severity / category / module:** S2 / bug / M2
- **Location:** `chatbox-mcp.swift:91`
- **Title:** Tool schema declares additionalProperties:false but undeclared arguments are forwarded to the server
- **Status:** START
- **Evidence (before):** Tool.schema sets additionalProperties:false (line 91), yet handleToolCall copies every key of the arguments object into args (lines 151-157) and call() puts every non-empty value into the query (line 47). So say with arguments {from,repo,hop} reaches POST /message?from=..&repo=..&hop=.., a parameter no tool advertised; the same holds for all, json and any other server parameter.

WHY IT MATTERS: The published tool contract and the implementation disagree. A host can drive server parameters the schema forbids (for example hop=, which suppresses forwarding, or all=), so the adapter is not the thin unprivileged pass-through it claims to be.

CONFIDENCE: high
- **Fix:** Drop or reject argument keys not listed in tool.properties before building the request, matching the declared schema.

### 0061

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:1553`
- **Title:** Per-recipient N+1 queries on the send path; recipient count is bounded only by --max-body
- **Status:** START
- **Evidence (before):** The delivery loop 1550-1554 runs one `store.nodeOf(r)` SELECT plus one INSERT per recipient. Then 1568-1579 runs `store.lastSeen(of:)` once per recipient in the `unseen` filter and again inside unseenReason for each unseen id: up to three extra queries per id. Nothing caps the to= list; at the default --max-body=8192 a request carries roughly 1000 ids (~3000 queries), and the documented 4 MB ceiling roughly 500k.

WHY IT MATTERS: One authenticated request chooses how much work the server does, all serialized on the single queue on the write path, so a large to= list stalls every other client for the duration.

CONFIDENCE: high
- **Fix:** Batch the lookups: one `SELECT id, node, last_seen FROM agents WHERE id IN (?,...)` (or a temp table) before the loop, reuse it for the delivery rows and the unseen check, and impose an explicit recipient-count cap.

### 0062

- **Severity / category / module:** S2 / logic / M1
- **Location:** `chatbox.swift:1654`
- **Title:** Boolean parameters are true for any non-empty value: all=0 includes read mail and json=0 emits JSON
- **Status:** START
- **Evidence (before):** includeAcked is computed as `!req.p("all").isEmpty` (1654, and again 1665, 2040) and the JSON switch as `!req.p("json").isEmpty` (1655, 1672, 2069, 2110, 2171, 2267). So all=0, all=false and json=0 select the 'on' behaviour. Only wait= is parsed numerically (waitSeconds 1951-1953).

WHY IT MATTERS: A caller or script that passes all=0 expecting unread-only silently receives already-read mail, and json=0 silently changes the response format, breaking a text parser; both are documented as 1/off-by-omission flags.

CONFIDENCE: high
- **Fix:** Parse the value (accept 1/true/yes) or at least treat 0/false as off, and reject anything else with 400 so a typo cannot flip behaviour silently.

### 0063

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:1748`
- **Title:** Serial forward queue plus a 12 s semaphore wait holds one connection per queued federation forward
- **Status:** START
- **Evidence (before):** forwardQueue is serial (1024). performForward (1731-1780) blocks on `sem.wait(timeout: .now() + 12)` after a URLRequest with timeoutInterval 10 (1744, 1762). dispatch (1198-1211) answers the sender only after that completes, and the accept/idle deadline was already cancelled at 2501, so the connection is held for the whole wait; with a peer down, the Nth queued forward waits roughly N x 10 s.

WHY IT MATTERS: A single dead peer turns every POST /message for an unowned repo into a 10-12 s stall, and queued forwards tie up connection slots until maxConnections (default 256) is exhausted, after which every client receives 503.

CONFIDENCE: medium
- **Fix:** Enforce a total deadline across the queue, use a bounded concurrent worker pool instead of a serial queue, or store the message and answer 202 immediately while retrying the peer in the background.

### 0064

- **Severity / category / module:** S2 / unsafe / M1
- **Location:** `chatbox.swift:1752`
- **Title:** Federation forward buffers the peer's entire response body with no size cap
- **Status:** START
- **Evidence (before):** In performForward the dataTask completion does `if let data = data, let text = String(data: data, encoding: .utf8) { answer = text }` (1757) — URLSession buffers the complete response body first. Nothing bounds how many bytes the peer (or whatever --peer happens to point at) returns; the 12s semaphore wait (1762) bounds only time. On timeout the task is cancelled, but bytes already buffered were allocated on the serial forwardQueue's behalf.

WHY IT MATTERS: A hostile or mis-pointed peer can force a large allocation and occupies the single forwardQueue (comments 1020-1023 say all other sends' forwards queue behind it), on a path that runs for every unroutable message.

CONFIDENCE: medium
- **Fix:** Cap the readable body (inspect Content-Length and abort past a few KB, or use a streamed delegate that stops at a limit); only the first line of the answer is ever used.

### 0065

- **Severity / category / module:** S2 / bug / M1
- **Location:** `chatbox.swift:1773`
- **Title:** Any 2xx from the peer is reported as a delivery without checking the peer is a chatbox board
- **Status:** START
- **Evidence (before):** performForward ends with `if status >= 200 && status < 300 { return "forwarded_to: \(peerURL) (ok)\n" }` (1773). The peer's body is discarded except for its first line on failure, and nothing verifies the chatbox success line ("ok posted"). Any host that answers 200 to POST /message is treated as a successful forward.

WHY IT MATTERS: If --peer is misconfigured (or a fronting proxy answers 2xx itself), the sender is told forwarded_to ... (ok) although nothing was stored — the same 'silent loss announced as a delivery' the redirect refusal at 1766-1772 exists to prevent. The README promises the response says what actually happened.

CONFIDENCE: medium
- **Fix:** Require the peer's answer to begin with the chatbox success line before reporting forwarded_to; otherwise report the peer's own words as a failure.

### 0066

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:1934`
- **Title:** SSE ticks run three board-wide COUNT(*) queries on the shared serial queue every 0.5 s per stream
- **Status:** START
- **Evidence (before):** pollEvents (1895-1926) calls boardState() every tick; boardState (1934-1937) calls boardCounts (767-774), whose query is three `SELECT COUNT(*)` over agents, threads and messages. Ticks are scheduled on `queue` (the only serial queue, 1019) every 0.5 s idle and every 0.25 s after a change (1911, 1923). health() (1279-1282) issues the same three COUNTs on every /health request. Measured: 3.1 ms per boardCounts at 500k messages, warm, and linear in history.

WHY IT MATTERS: The cost scales with board history and with the number of SSE clients, and every scan runs on the same serial queue that serves all requests, so monitoring traffic steals throughput from message delivery and long polls.

CONFIDENCE: medium
- **Fix:** Keep the counts incrementally (update on insert/delete), or detect change with an O(1) signal such as `PRAGMA data_version` or MAX(id) on messages/deliveries, and serve /health from the same cached counters.

### 0067

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:2017`
- **Title:** Each long-poll waiter re-authorizes and re-queries every 0.25 s for up to 300 s
- **Status:** START
- **Evidence (before):** pollInbox (2008-2053) re-runs authorize(req) on every tick (2017) - a SHA-256 plus tokens(hash) lookup (authorize 1105-1152) - and `store.hasUnread(forAgent:)` (2039), rescheduling at longPollInterval = 0.25 s (36, 2049). A 300 s wait (maxWaitSeconds, 37) is about 1200 iterations; maxConnections defaults to 256 (3024), so a full board of idle waiters issues on the order of a thousand auth+query pairs per second.

WHY IT MATTERS: Idle waiting sessions consume continuous CPU and SQLite work proportional to the number of waiters rather than to messages, so the delivery bus gets more expensive as sessions connect even when nothing is being sent.

CONFIDENCE: medium
- **Fix:** Signal waiters from the send path (per-agent condition/broadcast or a shared generation counter) and back the poll off (e.g. 0.25 s rising to 5 s); cache the authorized principal for the life of the wait and re-check revocation on a slower interval.

### 0068

- **Severity / category / module:** S2 / bug / M1
- **Location:** `chatbox.swift:2179`
- **Title:** Read paths echo peer-controlled harness/ip/session/agent/node unescaped while escaping repos in the same loop
- **Status:** START
- **Evidence (before):** peers prints r["agent"] and r["node"] (2179) then r["ip"], r["session"] and r["harness"] (2182) raw, but wraps r["repos"] in oneLine() (2180). register echoes the stored node/agent/session/ip/harness raw at 1388-1391. register's p() only trims whitespace at the ends of a value, so interior CR/LF (e.g. harness=a%0Ab) is stored and later emitted as extra lines.

WHY IT MATTERS: The sh client frames its read paths (chatbox-cli.sh:232-285) so it survives this, but chatbox-mcp.swift returns the body verbatim as tool content (toolResult, 136-140): a second consumer of the same response receives forged lines. oneLine's own doc (315-316) says echoing a value's line breaks is not acceptable.

CONFIDENCE: medium
- **Fix:** Apply oneLine() to every echoed field in peers/register (or reject control characters in register's node/agent/harness/session/ip), as repos already is.

### 0069

- **Severity / category / module:** S2 / incomplete / M1
- **Location:** `chatbox.swift:2598`
- **Title:** No --version, no --help and no build identifier: a rollback cannot be verified
- **Status:** START
- **Evidence (before):** knownFlags (2590-2598) contains no --help/--version, so `./chatbox --help` prints `unknown flag '--help' — refusing to start rather than ignore it` and exits 2. A grep for a version or build string over chatbox.swift and chatbox-cli.sh finds none; the startup banner (3206-3221) and /health list configuration but no build identity. The wiki's build/restart path (Deployment.md:37-51) is rebuild + pkill, and its own troubleshooting table (544) warns a restart may leave the old binary serving.

WHY IT MATTERS: During a rollback the operator cannot tell which binary is actually serving, so 'the restart worked' is unfalsifiable and the documented rebuild-and-kill procedure has no confirmation step.

CONFIDENCE: high
- **Fix:** Add `--version` and print a build string (git describe or a compile-time constant) in the banner and /health; add `--help` that prints the usage text and exits 0.

### 0070

- **Severity / category / module:** S2 / logic / M1
- **Location:** `chatbox.swift:2776`
- **Title:** --verify-backup compares only row counts, so a stale copy can verify as current
- **Status:** START
- **Evidence (before):** verifyBoard() (2763-2784) reads both boards via readBoard and fails only when boardTables.filter { counts[$0] != sourceCounts[$0] } is non-empty (2776). The comment at 2761-2762 claims "any row the board has that the copy does not makes it out of date", but equal counts also hold for a copy that is missing rows and has different ones (a pruned message replaced by a newer one, or a different board with the same totals). --verify-backup then prints "backup ok" (2871).

WHY IT MATTERS: The single command meant to prove a backup is current can certify a copy that is not, and the operator restores a board they believe is up to date.

CONFIDENCE: medium
- **Fix:** Compare content, not only counts: compare MAX(id) and the id set (or a checksum) for messages/threads/deliveries and the token id set, not just COUNT(*).

### 0071

- **Severity / category / module:** S2 / unsafe / M1
- **Location:** `chatbox.swift:3093`
- **Title:** --peer-token exists only on the command line, so the federation credential is visible in ps
- **Status:** START
- **Evidence (before):** `let peerToken = argValue("--peer-token", "")` (3093) is the only way to supply the peer credential; unlike the board token there is no --peer-token-file. README:238 documents `--peer <url> --peer-token <secret>`. There is a one-line/control-byte check (3101-3104) but nothing keeps the value out of the process table.

WHY IT MATTERS: README:247 tells operators to 'Use the peer's bootstrap credential', so any local user who reads the process table obtains the peer's full operator credential, not merely the ability to relay one message. The server already treats an argv secret as a defect and provides --token-file for its own token, so the asymmetry is easy to overlook.

CONFIDENCE: high
- **Fix:** Add `--peer-token-file PATH` (read, trim, refuse unreadable/empty, refuse both flags together), prefer it in the README federation example, and warn on stderr when --peer-token is used, mirroring the --token/--token-file precedent.

### 0072

- **Severity / category / module:** S2 / unsafe / M1
- **Location:** `chatbox.swift:387`
- **Title:** Server-created database, WAL and backups are world-readable (0644)
- **Status:** START
- **Evidence (before):** Store.init uses sqlite3_open (387), which creates files with SQLite's default 0644, and nothing chmods path, the -wal or the -shm. The checkout's own chatbox.sqlite, chatbox.sqlite-wal and chatbox.sqlite.bak-20260913-211112 are all `-rw-r--r--`, while README:74 tells operators to chmod 600 the token. --backup's `VACUUM INTO ?` (2910-2914) creates the copy the same way, and the README server quick start (README:71-79) sets no umask.

WHY IT MATTERS: On any shared host, every local user can read all plain-text reports, the registry and the credential hashes (and copy the WAL); backups carry the same data to wherever they are copied. The per-machine credential boundary means nothing if the board file itself is readable.

CONFIDENCE: high
- **Fix:** Create the board 0600: chmod the DB path after sqlite3_open and the destination after VACUUM INTO, or set umask 077 before opening. Document the expected modes and refuse to serve a group/world-readable board (or at least warn).

### 0073

- **Severity / category / module:** S2 / incomplete / M1
- **Location:** `chatbox.swift:449`
- **Title:** Store.exec ignores every SQLite error, and the db-open refusal drops the cause
- **Status:** START
- **Evidence (before):** `func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }` (449-451) discards both the return code and the message, yet it runs PRAGMA journal_mode=WAL (393), every CREATE TABLE/INDEX (399-446) and the deliveries.node backfill (438). If any of those fails — --db is not a SQLite file, disk full, a filesystem where WAL is unsupported — the server still starts and serves. The open failure at 388 prints `cannot open db at \(path)` with no sqlite3_errmsg, so 'no such directory' and 'permission denied' read identically; boardCounts (2708) does report the reason.

WHY IT MATTERS: A startup mistake becomes a running board that 500s every route (or silently runs without WAL and invalidates the backup story), and the one refusal the operator does see names neither cause nor fix.

CONFIDENCE: high
- **Fix:** Return the sqlite3_exec error and refuse to start when a schema or PRAGMA statement fails; include sqlite3_errmsg(db) (and the offending statement) in the message at 388.

### 0074

- **Severity / category / module:** S2 / bug / M1
- **Location:** `chatbox.swift:460`
- **Title:** Stored text is silently truncated at an embedded NUL byte
- **Status:** START
- **Evidence (before):** prepare() binds every non-nil value with sqlite3_bind_text(st, i+1, v, -1, TRANSIENT) (459-461); sqlite3.h:5005-5007 documents that a negative fourth argument means the length is "the number of bytes up to the first zero terminator". percentDecode (909-910) turns %00 into U+0000 and neither body nor subject is screened (hasControlByte/validId guard only ids and repo keys), so POST /message?body=a%00b stores "a" while the declared Content-Length and the "ok posted" answer describe the whole message.

WHY IT MATTERS: Stored content differs silently from the bytes the request declared, which is data corruption on the write path the board presents as exact.

CONFIDENCE: medium
- **Fix:** Reject control bytes in body/subject, or pass the UTF-8 byte count to sqlite3_bind_text (Int32(v.utf8.count)) so an embedded NUL is preserved as data.

### 0075

- **Severity / category / module:** S2 / logic / M1
- **Location:** `chatbox.swift:499`
- **Title:** Store.scalar returns an arbitrary column via Dictionary.values.first
- **Status:** START
- **Evidence (before):** Lines 498-500: `func scalar(_ sql: String, _ binds: [String?] = []) -> String { rows(sql, binds).first?.values.first ?? "" }`. Dictionary iteration order is unspecified, so for a row with more than one column the returned element is arbitrary. All current call sites (572, 576, 697, 704, 777-778, 807, 878-879, 883, 1280-1282, 1303, 1356, 1494, 2296) happen to select exactly one column.

WHY IT MATTERS: No wrong result today, but the helper accepts any SELECT and silently picks a column without naming it; the first two-column query added later (for example `SELECT COUNT(*), MAX(id)`) returns whichever the hash order gives, with no compile-time or runtime signal. The rest of the store names its columns through the [String: String] row shape.

CONFIDENCE: high
- **Fix:** Read the named column instead of the first value (or assert column_count == 1, or add a `scalar(_:column:)`), so a multi-column query fails loudly rather than returning an arbitrary field.

### 0076

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:50`
- **Title:** nowISO() allocates a fresh ISO8601DateFormatter on every call, including once per recipient
- **Status:** START
- **Evidence (before):** nowISO() (50-54) does `let f = ISO8601DateFormatter()` on each call and has 22 call sites in chatbox.swift, one inside the per-recipient delivery loop at 1553 (its result is a bind value for each INSERT). The file already caches formatters for parsing (`static let iso` / `isoTiny`, 1062-1074) but nowISO does not use them.

WHY IT MATTERS: ISO8601DateFormatter construction is heavy (calendar/locale/ICU setup) and is paid on every authenticated request (authorize at 1137/1142) and once per recipient on a send, adding avoidable CPU to the hot path and the single serial queue.

CONFIDENCE: high
- **Fix:** Cache one formatter in a private global or a Chatbox static, mirroring Self.iso, and call it; keep fresh formatters only in the one-off isoDaysAgo/isoDaysAhead helpers.

### 0077

- **Severity / category / module:** S2 / bug / M1
- **Location:** `chatbox.swift:610`
- **Title:** Repo-key migration ignores BEGIN/COMMIT failures
- **Status:** START
- **Evidence (before):** migrateRepoKeys() calls run("BEGIN IMMEDIATE", []) at 610 and run("COMMIT", []) at 649 without checking either (Store.run returns -1 on failure). If BEGIN fails because another process holds the write lock past busy_timeout=5000, the UPDATEs at 616/627/635/646 execute outside a transaction and auto-commit one at a time, and the final COMMIT fails with "no transaction is active". The changed/left counts returned at 650 feed the banner at 3219-3220.

WHY IT MATTERS: The documented invariant is one atomic, idempotent migration; a partial migration plus a banner claiming keys were normalised leaves two spellings of one repo key, which is the silent mail-split the function exists to prevent.

CONFIDENCE: high
- **Fix:** Check both results with runReporting; on a failed BEGIN report and exit(1) rather than migrating untransacted, and only report changed/left after a COMMIT that succeeded.

### 0078

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:611`
- **Title:** Startup key migration re-reads all four tables and rewrites every non-canonical row on every start
- **Status:** START
- **Evidence (before):** migrateRepoKeys (594-651) runs unconditionally at 3210 before the listener serves, on the listener's queue (3231), and loops `SELECT id, repos FROM agents` (611), `SELECT id, repo FROM threads` (619), `SELECT id, namespaces FROM tokens` (630) and `SELECT id, repo FROM messages` (641), issuing an individual UPDATE per changed row inside one BEGIN IMMEDIATE. Each SELECT materializes every row of its table in memory.

WHY IT MATTERS: On a large board every restart blocks all request processing while it reads, and may rewrite, the whole messages table, even though the migration is idempotent and its work was completed on the first start.

CONFIDENCE: medium
- **Fix:** Record completion in `PRAGMA user_version` or a meta table and skip the scans once it has run; at minimum bound the messages pass so an oversized board does not look hung.

### 0079

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:716`
- **Title:** prune() clears reply_to with one full-table-scan UPDATE per pruned message (O(messages x pruned))
- **Status:** START
- **Evidence (before):** The delete loop at 713-719 runs, per candidate id: `UPDATE messages SET reply_to=0 WHERE reply_to=?` (716), `DELETE FROM deliveries WHERE message_id=?` (717) and `DELETE FROM messages WHERE id=?` (718). No index on messages.reply_to exists among the CREATE INDEX statements (420-446); EXPLAIN QUERY PLAN is `SCAN messages`. Measured: 1,000 such UPDATEs against a 500k-row messages table took 25.7 s in one process (~25 ms each).

WHY IT MATTERS: --prune is the only supported way to bound the board and its cost is quadratic: 100k candidates on a 500k-row board is over 40 minutes of repeated full scans, and hours on a multi-million-row board, so operators abandon pruning and the database only grows.

CONFIDENCE: high
- **Fix:** Add `CREATE INDEX idx_msg_reply ON messages(reply_to)`, or delete in one set-based pass inside the transaction: `UPDATE messages SET reply_to=0 WHERE reply_to IN (...)` with the candidate id list.

### 0080

- **Severity / category / module:** S2 / perf / M1
- **Location:** `chatbox.swift:799`
- **Title:** Inbox listing sorts the whole matching backlog in a temp b-tree to return 200 rows
- **Status:** START
- **Evidence (before):** deliveries(forAgent:includeAcked:) (792-802) is `SELECT ... FROM deliveries d JOIN messages m ON m.id = d.message_id WHERE d.agent = ? ... ORDER BY m.id DESC LIMIT 200`. The available index is `idx_del_unread ON deliveries(agent, acked_at)` (423), which does not order by message_id; EXPLAIN QUERY PLAN shows `SEARCH d USING INDEX idx_del_unread` plus `USE TEMP B-TREE FOR ORDER BY`. deliveryCount (806-811) joins messages only to count delivery rows.

WHY IT MATTERS: A session with a large unread backlog makes the server sort the entire backlog on every inbox poll (including every 0.25 s long-poll tick) in order to emit 200 rows, and the effort is chosen by the backlog size.

CONFIDENCE: high
- **Fix:** Add `CREATE INDEX idx_del_inbox ON deliveries(agent, acked_at, message_id DESC)` so the ORDER BY is index-satisfied, and drop the messages join from deliveryCount.

### 0081

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:1478`
- **Title:** Aux-server readiness accepts any answering server, not the one just started
- **Status:** START
- **Evidence (before):** Section 13b starts its staleness server at 1474 and sets sready=1 on the first successful /health (1478-1482) without checking kill -0 "$spid"; section 16 does the same at 2237-2243. Sections 18 (2545), 21 (3015), 27 (3453) and the migration section (2461) all confirm their own pid, and fed_wait (3931) also requires the board's own 'chatbox listening on port' banner.

WHY IT MATTERS: The aux ports default to fixed 8791/8793. A leaked or unrelated listener holding the shared token answers /health first, so the section runs against a different binary. For 13b that is a false pass for the presence mutations it alone pins (53-touchinterval, 54-stilltouchdead, 58-offactive).

CONFIDENCE: high
- **Fix:** In both readiness loops require kill -0 on the started pid and that board's own startup banner in its log before setting ready, as mig_start and fed_wait already do.

### 0082

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:3254`
- **Title:** Fixed 'bulk' and 'exact' literals break the suite's per-run namespace on re-runs
- **Status:** START
- **Evidence (before):** Section 22 stamps deliveries with 'INSERT INTO deliveries ... FROM messages WHERE sender='bulk'' (3254-3256); section 24 asserts 'select count(*) ... where sender='exact' and body='ok'' = 1 (3318). Every other fixture is prefixed with $RUN. A second run, or a concurrent one (which the header at line 11 promises is safe), re-matches those literals, so 'the bulk fixture holds 205 deliveries' (3257) and the count=1 check both fail.

WHY IT MATTERS: The documented workflow points the suite at a long-lived disposable server; re-running it there produces false failures, and the concurrent-run isolation the header guarantees does not hold for these two fixtures.

CONFIDENCE: high
- **Fix:** Tag the sender/body literals with $RUN, or scope the SELECTs to the ids just inserted, so both fixtures are idempotent and concurrent-safe.

### 0083

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:3576`
- **Title:** Expiry issuance asserted with 'expires: 20' and no 1/36500 boundaries
- **Status:** START
- **Evidence (before):** Line 3576 asserts the issued credential contains 'expires: 20' and line 3593 repeats it for the client. The field is 'expires: <ISO date>', so any 20xx date satisfies the needle: a credential issued for 1 day rather than 30, or with a wrong offset, still passes. Only 0 and the empty string are boundary-tested (3579-3585); chatbox.swift:2225 guards 'days > 0, days <= 36500' but no check exercises 1 or 36501.

WHY IT MATTERS: The expiry is the security backstop for the credential nobody rotates; a wrongly computed duration, or a removed ceiling, is reported as success and goes unnoticed until a credential outlives its intended life.

CONFIDENCE: high
- **Fix:** Compare the issued date with the exact expected date (date -u -v+30d) or at least its YYYY-MM-DD prefix, and add expires=1 accepted / expires=36501 refused-naming-the-range checks.

### 0084

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:3748`
- **Title:** The /events max= ceiling is never exercised
- **Status:** START
- **Evidence (before):** Section 30 requests /events with the default (3748) and with max=2 (3784); nothing requests an over-ceiling max. chatbox.swift:1957-1959 cappedSeconds returns min(raw, ceiling) with ceiling 3600 and logs 'stream, up to Ns' at 1882, which is the observable. A mutant replacing min(raw, ceiling) with raw would leave the suite green, and mutate.sh has no such mutant.

WHY IT MATTERS: The deadline is the only bound on how long an SSE connection is held, so losing the ceiling lets one client hold a connection far past the intended hour. The suite already pins the equivalent inbox wait cap from the server log (871-875) but not this one.

CONFIDENCE: high
- **Fix:** With CHATBOX_SERVER_LOG set, open '/events?max=99999' under --max-time 2 and assert the log says 'stream, up to 3600s'; add the corresponding mutant.

### 0085

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:395`
- **Title:** /token?json=1 secret check is vacuous: the JSON form is never asserted
- **Status:** START
- **Evidence (before):** Line 395 is 'lacks "the json listing never repeats a secret" "$(get /token "json=1")" "$TOK3"', which passes on any non-secret body, including the plain-text listing. /peers, /thread, /threads and /inbox each have a contains check for their JSON keys (948-956, 3266-3269) and section 27 checks the token list in text form only (3501-3503); chatbox.swift:2267 has a json branch for /token that nothing pins.

WHY IT MATTERS: A regression that drops the json branch or returns the wrong shape on the credential list keeps this check green while breaking the documented structured output on the one route that exposes credentials.

CONFIDENCE: high
- **Fix:** Assert the /token&json=1 object explicitly (contains '"tokens"', '"shown"' and '"matching"'), as the peers and inbox JSON checks already do.

### 0086

- **Severity / category / module:** S2 / test / M4
- **Location:** `tests/protocol.sh:3967`
- **Title:** fed_refuse decides "refused" with a fixed sleep and never checks the exit status
- **Status:** START
- **Evidence (before):** fed_refuse (3962-3976) starts the server, does 'sleep 1', and if the process is gone calls ok and only greps the log for the phrase. tls_refuse (1739-1758) and mb_refuses (2263-2279) poll kill -0 and require exit code 2 as well as the phrase. A correct refusal slower than one second is reported as 'it started anyway', and a process that exits 1 after printing the phrase passes.

WHY IT MATTERS: These checks protect the security-relevant federation flags (--peer-token, --server-id, --peer credentials). The fixed sleep produces flaky reds, and the unchecked exit code lets the wrong refusal path look correct.

CONFIDENCE: high
- **Fix:** Replace the fixed sleep with the poll-kill -0 loop used elsewhere and assert the process exit status is 2 as well as the phrase.

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

### 0087

- **Severity / category / module:** S3 / placeholder / repo
- **Location:** `.github/traffic.json:4`
- **Title:** Canned view count served as the live 'Views (14d)' README badge
- **Status:** START
- **Evidence (before):** traffic.json is a static shields.io endpoint payload with "label": "Views (14d)" (line 3) and "message": "33" (line 4), embedded as a badge in README.md:4. Neither workflow writes or regenerates the file, so the displayed traffic figure is a hand-written constant rather than measured data.

WHY IT MATTERS: Project metadata presents a fabricated metric as instrumentation; the badge reads as live analytics while it only changes when someone commits a new literal, which misleads anyone judging adoption.

CONFIDENCE: high
- **Fix:** Remove the badge, or generate .github/traffic.json from real traffic data in CI so the number is measured.

### 0088

- **Severity / category / module:** S3 / style / M1
- **Location:** `chatbox.swift:1617`
- **Title:** Local `who` shadows the Principal parameter in message()
- **Status:** START
- **Evidence (before):** Line 1617 inside `func message(_ req: Request, _ who: Principal)` (1398): `let who = unseen.map { "\($0) (\(unseenReason($0)))" }.joined(separator: ", ")` rebinds the credential parameter to a String for the rest of the function body.

WHY IT MATTERS: Behaviour is unchanged because the Principal is not read after this point, but the shadow makes it impossible to tell at a glance whether a later edit is using the credential or the warning text, and the compiler says nothing.

CONFIDENCE: high
- **Fix:** Rename the local to something like `unseenList` (or `unseenText`) so the Principal keeps its name through the whole handler.

### 0089

- **Severity / category / module:** S3 / dead / M1
- **Location:** `chatbox.swift:260`
- **Title:** The '?' element of the repo-key character check is unreachable
- **Status:** START
- **Evidence (before):** Line 260 `for bad in ["*", "?", "[", "]", " ", "\t"] where s.contains(bad) { return nil }`, but line 238 already ran `if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }`, so s can never contain '?' here. A key with a '?' is silently truncated to the text before it rather than refused, contradicting the error text at 1314/1447 ('do not contain * or ?'). chatbox-cli.sh:435 has the same dead check after its strip at 404, so client and server still agree.

WHY IT MATTERS: The documented rule that a '?' is not a usable key character is not enforced; `github.com/acme/x?y` is accepted and stored as `github.com/acme/x`, which can route a message to a different repository than the sender typed.

CONFIDENCE: high
- **Fix:** Either drop '?' from the list (and let the strip stand, documenting the truncation) or check for the character before the strip so the documented refusal is real; keep the client and server rules identical either way.

## Destructive or system-changing operations (command + rollback, logged before running)

| Date | Command | Why | Rollback |
|---|---|---|---|
| 2026-09-15 | `brew install dash` | second POSIX shell for `-n` checks (the suite targets `sh`; bash-3.2-in-POSIX-mode is the primary) | `brew uninstall dash-shell` |
| 2026-09-15 | `git checkout -b audit/2026-09-15` (from `971faae`) | the brief requires all audit work on `audit/<date>`, never on main | `git branch -D audit/2026-09-15` while main is untouched |

