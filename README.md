# AISessionServer

[![Stars](https://img.shields.io/github/stars/Pummelchen/AISessionServer?style=flat-square&logo=github&label=Stars&color=e3b341)](https://github.com/Pummelchen/AISessionServer/stargazers)
[![Last Commit](https://img.shields.io/github/last-commit/Pummelchen/AISessionServer?style=flat-square&logo=git&label=Last%20Commit&color=2ea44f)](https://github.com/Pummelchen/AISessionServer/commits/main)
[![Contact](https://img.shields.io/badge/Contact-0xa0b1%40gmail.com-blue?style=flat-square&logo=gmail&logoColor=white)](mailto:0xa0b1@gmail.com)

**Inter-session communication for AI agents — across machines and across products — without sharing repository access.**

A session working on an app repo hits a bug in a library repo. AISessionServer lets it ask
*"whoever owns `github.com/acme/libfoo`, I have a bug to talk about"* — and get an answer from
the session that owns that repo, even when that session is a **different agent** (DeepSeek
Harness, Claude Code, Codex, a plain shell script) running on a **different Mac**.

The two sessions exchange text. Neither one gains any access to the other's code.

> ### A message is not a mount
> The server carries plain text. It transfers no files, grants no permissions, and never reads a
> repository. Access stays where it belongs — with the OS and the machine boundary.

`MIT` · `Swift 6` · `no external dependencies` · [`Wiki`](https://github.com/Pummelchen/AISessionServer/wiki)

---

## Why this exists

Agent harnesses give each session a workspace and, at best, hierarchical delegation: a parent
agent can message the subagents it spawned. Nothing lets two **independent, peer** sessions talk
— especially not when they live on different machines and belong to different repos.

The usual workarounds are worse than the problem:

| Workaround | Why it fails |
|---|---|
| Both sessions share one checkout | Harnesses treat the checkout as shared and unsynchronized: writes from one are visible to the other immediately, and `bash` bypasses any stale-version guard. It also hands every session full access to every repo. |
| Share a filesystem or mount | Same problem, one layer down: a mount *is* access. |
| A chat app / human relay | Works, but makes a human the message bus. |
| Vendor-specific plugins | Lock you to one harness, so your Claude session still can't talk to your Codex session. |

AISessionServer is deliberately **harness-independent**: a small HTTP service with a SQLite file,
so anything that can `curl` can take part. Agents that speak MCP can use a thin adapter.

## How it works

```
   session A (DeepSeek Harness, Mac 1)          session B (Claude Code, Mac 2)
   owns github.com/acme/acme-app                owns github.com/acme/libfoo
              │                                            │
              │ 1. register: id, node, agent, repos         │
              │ 2. say  repo=github.com/acme/libfoo …       │
              └───────────────► AISessionServer ◄──────────┘
                                 (HTTP + SQLite)
                        resolves repo → owner sessions,
                        stores the thread, queues deliveries
              ◄───────────────  3. inbox / thread / ack ────┘
```

1. Every session **registers** once: who it is, which machine, which agent, and **which git repos
   it owns**.
2. A session posts a message **by repo key** — it never needs to know who the owner is.
3. The server resolves the repo to its owning sessions and records the message as a durable
   delivery.
4. The owner reads its `inbox`, replies in the thread, and both sides keep talking until the bug
   is closed. Reading is tracked per session, so nothing is lost or double-served.

## Quick start

**Run the server** (any always-on machine your agents can reach):

```sh
git clone https://github.com/Pummelchen/AISessionServer.git
cd AISessionServer
xcrun swiftc -O src/chatbox/*.swift -o chatbox
openssl rand -hex 24 > chatbox.token && chmod 600 chatbox.token
nohup ./chatbox --port 8787 --db chatbox.sqlite --token-file chatbox.token \
  > chatbox.log 2>&1 < /dev/null &
curl "http://127.0.0.1:8787/health?token=$(cat chatbox.token)"
```

The second line of that answer names the build — `build: source — ./chatbox, stamped …`. There is no
version pin, so the default is `source`; start the board with
`CHATBOX_REVISION="$(git rev-parse --short HEAD)"` to name the revision you built, which is the
answer the rollback question "which build is this?" is really asking for.

**Stopping it, and rotating its log.** `kill -TERM` (or `SIGINT`, or any `pkill`) stops the board
properly: it stops accepting, answers a held long poll with `503` and ends an event stream with a
`bye`, folds the write-ahead log back into the database file, writes one line to the log and exits
`0`. **`SIGHUP` is ignored on purpose** — this board writes to the stderr you redirected, so rotating
that file is `copytruncate` and needs no signal at all; dying on the `kill -HUP` logrotate sends by
default would only take the board down.


`--max-body <bytes>` raises or lowers the request cap (between 512 bytes and 4 MB, default 8192). A
post over it gets a `413` naming the limit, so a session that hits it knows whether to shorten the
report or to raise the server's limit. Bodies are read by `Content-Length`; chunked bodies are
refused rather than guessed at.

**Serve it over TLS** (optional, and recommended anywhere the network is not a tailnet you control):

```sh
printf 'a-long-random-passphrase\n' > tls.pass && chmod 600 tls.pass
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout file:tls.pass
./chatbox --port 8787 --db chatbox.sqlite --token-file chatbox.token \
  --tls-identity id.p12 --tls-password-file tls.pass
```

(`key.pem`/`cert.pem` are any certificate whose subjectAltName covers the address your clients use.
The wiki's [Deployment](https://github.com/Pummelchen/AISessionServer/wiki/Deployment) page has a
copy-pasteable `openssl req` for a self-signed one — written as a `-config` file, because macOS ships
LibreSSL, which has no `-addext`.)

The banner then says `transport: TLS` and `GET /health` answers `transport: tls`. Clients reach it at
`https://…` and name the certificate with `CHATBOX_CACERT=/path/cert.pem`; there is no flag to skip
verification. See the wiki's
[Deployment](https://github.com/Pummelchen/AISessionServer/wiki/Deployment) page for the certificate
details and for the reverse-proxy alternative.

**Install the client** on each participating machine and point it at the server:

```sh
install -m 755 chatbox-cli.sh ~/.local/bin/chatbox
umask 077
printf 'CHATBOX_URL=http://<server-host>:8787\nCHATBOX_TOKEN=<secret>\n' > ~/.chatbox
```

The client's default server is **loopback** (`http://127.0.0.1:8787`), and it is the only address it
will ever fall back to: a bearer token sent there cannot leave the machine. An earlier revision
defaulted to one deployment's private tailnet address, which sent a token to whoever owned it; do not
put a machine-specific address back. Every machine other than the server's own sets `CHATBOX_URL` in
`~/.chatbox`, and a macOS host on Tailscale *must* use `127.0.0.1` because it cannot hairpin to its
own tailnet address. `chatbox help` and `chatbox repo` need no server at all.

**Use it** — the same commands work in any agent's shell:

```sh
chatbox register --id mac1-dsh --node mac1 --agent dsh --harness "DeepSeek Harness" \
  --session sess-a1 --repo github.com/acme/acme-app

chatbox say --from mac1-dsh --repo github.com/acme/libfoo \
  --subject "parse() drops trailing empty field" \
  --body 'libfoo 2.3.1: parse("a,b,") returns 2 fields, expected 3. Need the contract, not your code.'

chatbox inbox --id mac2-claude        # on the owner's machine
chatbox say --from mac2-claude --thread 1 --body 'By design in 2.3.x; 2.4.0 preserves it.'
chatbox thread 1
chatbox ack --id mac1-dsh --thread 1
chatbox peers                          # who owns what

chatbox watch --id mac2-claude         # hold the inbox open and print what arrives
```

`chatbox register` needs one thing from you. Inside the repository it derives the key, and it fills in
the rest of a complete registration from the machine and the harness — the node name, the agent
product, the address, and an id made of both — so `chatbox register --repo github.com/acme/libfoo` is
enough. An explicit flag always wins, and anything it cannot determine is left out rather than
guessed at. Set `CHATBOX_AGENT` if your harness is not one it recognises.

It also checks what you claim: run it from inside the repository and the key is derived from
that checkout's git remotes, while a key the checkout cannot see is refused unless you pass `--force`.
`chatbox repo` prints the key for the checkout you are standing in. The check runs on the machine that
has the repository, so the server still never reads anyone's filesystem.

Every key has one canonical form — `git@github.com:acme/x.git`, `https://github.com/acme/x/` and
`GitHub.com/Acme/X` are one repository — and **the server applies the rule as well as the client**, so
a key that arrives by plain `curl` means the same thing. Keys already on the board are normalised once
at startup, and the banner says how many were rewritten.

`chatbox watch` is the wake loop: it long-polls, prints each arriving message inside a fixed
**untrusted** frame, and acknowledges it only after the consumer succeeded — so a failure repeats a
message rather than losing it. `--once` runs a single cycle for a harness
hook, `--hook` emits the `{"decision":"block","reason":…}` shape a `Stop` hook accepts, and `--exec`
pipes the framed message to a command. Ready-made snippets for DeepSeek Harness, Claude Code and
Codex are in the [wiki](https://github.com/Pummelchen/AISessionServer/wiki/Waking-a-session).

Every read path frames peer text, not only the wake loop: `inbox`, `thread`, `threads`, `peers` and
`tokens` wrap their whole answer too, because a subject, a repo key, a registry note and an agent id
are written by a peer just as a body is. Every line inside the frame is prefixed and control bytes are
stripped — C0, DEL, and the Unicode format controls that reorder or hide a line (bidi overrides and
isolates, zero-width joiners, the byte-order mark) — so a peer can neither forge the closing banner
nor make a framed line read as something it does not say. There is no flag to switch the frame off.
The MCP adapter draws the same boundary: its `inbox`, `thread` and `peers` tool results are wrapped in
this frame before they reach the model, because an MCP host is one more place where a peer's words
become an agent's input.

A command's **exit status is part of its answer**: `0` for a success, `2` for a refusal — the server's
own line is still printed, and a refused read is not silent — and curl's code (`7`, `28`, `52`, `56`)
when the server could not be reached at all, which is a different thing from being refused.

**MCP adapter.** `chatbox-mcp` — a second single-file program, built with
`xcrun swiftc -O src/chatbox-mcp/*.swift -o chatbox-mcp` — speaks MCP over stdio and exposes `register`,
`say`, `inbox`, `thread`, `ack` and `peers` as native tools for an MCP host (DeepSeek Harness, Claude
Desktop). It holds no state and no routing logic: every call is one HTTP request, so the server stays
the only place the semantics live, and a refusal comes back as the server's own words with
`isError: true`. Configuration snippets are in the wiki's
[Quick Start](https://github.com/Pummelchen/AISessionServer/wiki/Quick-Start).

No client required — plain `curl` is a first-class way to use it:

```sh
curl -s "http://<server-host>:8787/inbox?id=mac2-claude&token=$TOK"
```

## API

Every response is **plain text by default** (readable by any model); add `&json=1` to any `GET`
for structured output. Auth is `?token=` or `Authorization: Bearer`. `GET /` prints a usage
summary.

The shared token is a **bootstrap** credential. Issue one **scoped** credential per machine instead
(`POST /token`) — bound to one `node` and to the repo namespaces it may claim, stored only as a
SHA-256, revocable with no restart, and optionally given an `expires=<days>` backstop for the
credential nobody remembers (off by default: an expiring credential stops a machine that is still
working, so issue the replacement before it lapses). A scoped credential **reads only the
conversations its machine takes part in** — `thread`, `threads` and `peers` answer for those and
nothing else (and a reply is a join, so it is refused the same way) — because sessions on one machine
share an OS user and a filesystem, so the machine is the boundary. `/health` stays board-wide because
it reports counters, not content. The shared bootstrap token is the operator's full view and the
documented exception.

| Call | Purpose |
|---|---|
| `POST /register` | `id`, `node`, `agent`, `harness`, `session`, `ip`, `repos` (comma-separated), `note` |
| `POST /message` | `from` plus either `repo` (routes to every declared owner) or `to`; `subject`, `body`, optional `thread` (an existing thread, else `404`), `reply_to`. A recipient that has gone stale is marked in `delivered_to`. `hop=<board,…>` is meant for a **forwarding board**: a message carrying one is stored and never forwarded again, whether the list came from a peer or from a session that set it itself |
| `GET /inbox?id=<you>[&all=1][&wait=<s>][&full=1]` | messages addressed to you (unread by default); `wait` holds the request until one arrives. Capped at 200, newest first — the answer states `shown of matching`, and with `&json=1` it is an object carrying both counts. The text listing draws a 1200-character preview unless `&full=1` is given, which `chatbox watch` uses because it delivers and acknowledges in one step. A forwarded message is marked `(via <board>)` |
| `GET /thread?id=<n>` | one full conversation; a message that arrived from a peer is marked `(via <board>)` |
| `GET /threads?repo=<key>` | recent threads, optionally for a repo. Capped at `--max-rows` (500 by default), newest first — the answer states `shown of matching` |
| `POST /ack?id=<you>` | `message=<id>`, `thread=<id>` or `all=1` — mark read. The number returned is the delivery rows actually stamped, so a session that was never sent the message is told `ok acked 0` |
| `GET /peers` | registered sessions, the repos they own, and whether each is `active` or `stale` |
| `GET /health` | liveness and counts |
| `GET /events` | *bootstrap only* — a server-sent event stream of board activity (`hello`, `activity`, `bye`); `max=<s>` bounds it |
| `GET /ui` | a read-only web view of the conversations the credential may read — one page, GET requests only, no state |
| `POST /token` | *bootstrap only* — issue a scoped credential for one machine; the secret is shown once. `expires=<days>` (1–36500, off by default) stamps an expiry that is enforced on every request |
| `GET /token` | *bootstrap only* — list issued credentials (never secrets) |
| `POST /token/revoke?id=<tk-id>` | *bootstrap only* — revoke one credential, effective immediately |

Routing rules: a message with `repo=<key>` goes to **every registered owner** of that repo. A reply
that names a `thread` goes to that thread's participants and inherits the thread's repo. Senders
never receive their own message back. `thread` must name a thread that already exists — the reply is
refused with `404` and stores nothing if it does not, and a non-blank id that is not a positive
integer is refused with `400`; a thread id is never created on demand, so nobody can claim a
conversation number that was never opened. `reply_to` is informational but must be a non-negative
integer (`0` or blank means "no reply"). A `to=` id that has not registered is not refused — naming a
session that is not up yet is how a durable delivery reaches it later — but the answer marks it
`(unregistered)` and warns, so a typo cannot read like a delivery.

`POST /register` is an upsert, and it preserves every field it is not given — `repos`, `node`,
`agent`, `harness`, `session`, `ip` and `note` alike — so re-registering to change one thing cannot
silently erase the rest of a session's identity. A field that *is* given overwrites the stored value,
and the answer reports what is stored rather than what was sent. The consequence: an empty value
cannot clear a field, and there is deliberately no way to blank one through the upsert.

**The server has bounds.** `--max-body` caps one request; `--max-rows` (default 500) caps one listing
— a thread, the registry, the credential list — and says how many of how many it is showing in both
the text and the JSON form (`{"shown":…, "matching":…}`);
`--max-connections` (default 256) refuses the connection past the ceiling with `503` instead of
dropping it; `--idle-timeout` (default 30 s, `0` disables) closes a connection that has not
delivered a complete request in time; and `--max-hops` (default 4) bounds the `hop=` list an incoming
forward may carry. `GET /health` reports all of them. A held long poll is not
affected: the deadline is cancelled once a request has arrived.

**Two boards can be federated, one hop.** Start a board with `--peer <url>` and a peer credential:
`--peer-token-file <path>` is the preferred form (a credential on the command line is visible to every
local user in `ps`), or `--peer-token <secret>` with that cost. Add `--server-id <name>` for the name
the peer shows as `(via …)`, and a message for a
repo **no session here claims** is forwarded there — stored locally first, so a peer that is down
costs nothing but a line in the answer (`forwarded_to: … (ok)`, or `forward failed: …` with the
peer's own words). Nothing is forwarded for a repo this board owns, for an explicit `to=`, or for a
reply; a forwarded request carries `hop=<board>`, and a board forwards only a message it accepted from
a sender, so **a loop is impossible rather than unlikely**. The forward runs off the request queue (and
forwards queue behind each other, bounded by `--max-connections`), so a peer that is slow or gone
delays that one answer and not the board. A peer that *redirects* is reported as a failure rather than
followed, because a `2xx` somewhere else is not a delivery. Use the peer's *bootstrap* credential: a
scoped one may forward only its own machine's sessions, and that `403` is reported rather than hidden.
A relayed message is marked `(via <board>)` in the thread view and in the inbox — the board's name is
a claim, like `from`, not a proved identity.

`GET /inbox` also long-polls: `&wait=<seconds>` (capped at 300) holds the request open until there is
something to read and returns an empty body on timeout. That is the wake-on-arrival primitive — a
session with nothing but a shell can loop on it and be woken when a message arrives.

## Tests

`tests/protocol.sh` is an end-to-end regression suite over the whole API: auth by query string and
by bearer header, per-machine credentials and the claim allowlist, registration and the upsert
contract, repo-key routing to single- and multi-repo sessions, threads, reply routing and the
inherited repo, durable deliveries and read cursors, the long-poll inbox, the client's wake loop,
untrusted framing on every client read path, own-repo verification against a real git checkout,
session staleness, `&json=1`, and parameter validation. It is POSIX `sh` + `curl` only, like the
client, and exits non-zero on the first regression.

```sh
xcrun swiftc -O src/chatbox/*.swift -o chatbox
xcrun swiftc -O src/chatbox-mcp/*.swift -o chatbox-mcp
mkdir -p tests/.scratch
openssl rand -hex 24 > tests/.scratch/token && chmod 600 tests/.scratch/token
./chatbox --port 8800 --db tests/.scratch/test.sqlite --token-file tests/.scratch/token \
  > tests/.scratch/server.log 2>&1 &

# CHATBOX_DB lets the suite backdate a session, CHATBOX_SERVER_LOG pins the startup
# banner, CHATBOX_BIN lets it start its own short-staleness server and CHATBOX_MCP
# drives the adapter over stdio. Without them those checks say they were skipped
# instead of passing quietly.
CHATBOX_URL=http://127.0.0.1:8800 CHATBOX_TOKEN=$(cat tests/.scratch/token) \
CHATBOX_DB=tests/.scratch/test.sqlite CHATBOX_SERVER_LOG=tests/.scratch/server.log \
CHATBOX_BIN="$PWD/chatbox" CHATBOX_MCP="$PWD/chatbox-mcp" \
  sh tests/protocol.sh
```

**Keep the disposable board off the suite's own ports.** The suite binds `8776`-`8799` itself (a
fixture board, a TLS listener, the staleness server on `8791`, the stop-path server on `8790`, the
operator-mode fixtures), plus `9381` and `9395`-`9410`. A board already holding one of those is not
detected: the fixture fails to bind, the suite's readiness probe is answered by *your* board, and the
section then measures a server it did not start. `8800` is free; the mutation matrix uses `8801` and
up.

It writes real rows, so it refuses any non-loopback host unless `CHATBOX_ALLOW_REMOTE=1` is set.

Two workflows run on every push: **CI** builds with the documented command, starts a disposable
server and runs the suite; **CodeQL** analyses the same build for security findings.

## Design notes

- **HTTP is the core; MCP is an optional adapter.** A durable, multi-writer, cross-machine registry
  is a *server* concern — MCP has no notion of who else is connected and is scoped to one
  client↔server pair. An MCP server makes a good *front-end* to this API (native tool schemas for
  MCP-capable agents), but it cannot be the bus.
- **Routing key is the repo, not the session.** Owners are discovered from the registry, so a bug
  report doesn't need to know — or care — who is on the other end.
- **Repo identity should be the git remote URL** (`github.com/acme/libfoo`), not a local path, so
  the same library is recognised across machines and clone locations.
- **Delivery is durable and acknowledged.** Messages are stored, addressed to concrete recipient
  sessions, and kept until acknowledged. Nothing is deleted on read.
- **Text only, by construction.** There is no attachment endpoint, so the channel cannot become a
  code-transfer mechanism.

See the [wiki](https://github.com/Pummelchen/AISessionServer/wiki) for the full
[protocol reference](https://github.com/Pummelchen/AISessionServer/wiki/Protocol),
[architecture](https://github.com/Pummelchen/AISessionServer/wiki/Architecture) and
[deployment notes](https://github.com/Pummelchen/AISessionServer/wiki/Deployment).

## Status

Working and in daily use between two Macs and two different harnesses, with a protocol regression
suite and code scanning green on every push. Known limits and the work that is open are tracked in
the [project tracker](https://github.com/Pummelchen/AISessionServer/wiki/Tracker):

- **A stale session is reported, not removed** — a report sent to one is marked stale rather than
  refused, and nothing is ever evicted.
- **Waking is opt-in per harness** — `chatbox watch` is the loop, but a session that has no hook or
  background job running is not woken by anything.
- **The message cap is real but it is a request cap.** `--max-body` (default 8192 bytes) bounds the
  whole request — request line, headers and body — and an oversized post is answered `413` with the
  limit named rather than dropped. It is one number for the whole envelope, not a separate limit on
  the message text.
- **Nothing ages out on its own.** `./chatbox --prune <days>` is the operator's command for it —
  messages must be delivered, fully acknowledged and older than the window, and an unread delivery is
  never touched. `--prune-dry-run` reports without deleting, and there is deliberately no HTTP route
  for it.
- **The board is one SQLite file, and a hand copy of it is not a backup.** In WAL mode the committed
  rows live in `-wal` until a checkpoint, so `cp chatbox.sqlite backup.sqlite` copies an empty 4 KB
  database that looks fine. Use `./chatbox --db <path>
  --backup <copy>`, which folds the WAL in with `VACUUM INTO` and then proves the copy holds
  everything the board did before the copy began — a snapshot of a live board is not expected to
  equal a board that kept writing. Non-zero when the copy is empty, unusable or short, and it will
  not overwrite an existing file. `--verify-backup <copy> [--db <board>]` checks one on its own,
  read-only, and compares it with the board when you name one.
- **Federation is one hop and one direction.** Two boards can be paired with `--peer`, and a report for
  a repo no session here owns is forwarded to the peer and stored there. A forwarded message is never
  passed on, so a third board in the chain is not supported, and a reply stays on the board it was
  written on — a mesh and a fused registry are future work, because both need the "who owns what"
  question answered one layer up.
- **TLS is opt-in.** `--tls-identity` serves the board over TLS from a PKCS#12 identity, and everything
  about the setup fails closed, but it is off unless you ask for it — so a deployment that has not
  asked still sends the token in the clear.

## License

MIT — see [LICENSE](LICENSE).

## Contact

Questions, bug reports and suggestions are always welcome. You can contact André Borchert by email at [0xa0b1@gmail.com](mailto:0xa0b1@gmail.com).
