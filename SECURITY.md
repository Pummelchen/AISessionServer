# Security

AISessionServer moves plain text between agent sessions. This page states what it
protects, what it does not, and how to report a problem. It also records the one
accepted scanner finding, so the dismissal does not live only in a web UI.

## Reporting a vulnerability

Email **0xa0b1@gmail.com** with the affected revision (or `git rev-parse HEAD`), the
request or command that reproduces it, and what you expected instead. Please do not
open a public issue for a live credential leak or a remote crash. You will get an
answer within a few days.

## The premise — a message is not a mount

The channel carries text only. It has no attachment endpoint, never reads a
repository, and never grants access to another machine's files. Everything a session
sends is treated as untrusted data on arrival: the server and the client frame peer
text, and the client strips C0/DEL and Unicode format controls (bidi overrides,
zero-width joiners, BOM) so a message cannot forge a line or reorder one in the
consumer's view.

## What is protected

- **Credentials are per machine.** A scoped credential is bound to one `node` and the
  repo namespaces it may claim, is stored only as a SHA-256, and is revocable with no
  restart and no grace period. It cannot manage other credentials.
- **Reads are scoped.** A scoped credential reads only the conversations its machine
  takes part in; the bootstrap credential is the operator's documented full view.
- **The token stays out of `ps`.** The client passes the credential through a `0600`
  curl config file, and the server prefers `--token-file` over `--token` on argv. The
  peer credential has the same rule (`--peer-token-file`).
- **Writes are checked.** A failed store write is a `500`, never an `ok` that did not
  happen. `POST /register` preserves every field it is not given.
- **The request surface is bounded**: `--max-body` (whole envelope), `--max-rows`,
  `--max-connections`, `--idle-timeout`, `--max-hops`, with a recipient ceiling and a
  forward cap. Chunked request bodies are refused rather than guessed at.
- **Backups are proved.** `--backup` folds the WAL in with `VACUUM INTO` and verifies
  the copy against its source; `--verify-backup` checks one on its own.

## Accepted risk — plaintext transmission (CodeQL `swift/cleartext-transmission`)

CodeQL reports that the default `http://` listener carries the credential and the
message text in the clear. **The rule is accurate, not a false positive**, and the
alert is dismissed as *won't fix* with this page as the record.

- **TLS is available and documented**, not absent: `--tls-identity` plus
  `--tls-password-file` on the server, `CHATBOX_CACERT` on the client, and the client
  refuses a CA over a plain `http://` URL rather than ignoring it. There is
  deliberately no flag to skip verification.
- **Plain is the default because the documented deployment is two machines on one
  private tailnet** ([Deployment](https://github.com/Pummelchen/AISessionServer/wiki/Deployment)),
  where the transport is already encrypted (WireGuard) and a self-signed certificate
  pair is more operational risk than it removes.
- **Making TLS mandatory is a product decision, not a defect fix**: it changes every
  client's URL scheme, every `~/.chatbox`, the peer federation URL and the quick
  start, and it would fight the loopback default that exists so a macOS host can reach
  its own board.
- **The blast radius is bounded even in the clear**: the client defaults to
  `http://127.0.0.1:8787` (loopback cannot carry the credential off the machine), a
  scoped credential reaches only its own conversations, and the server logs a warning
  when a plaintext request arrives from a non-loopback address.

**Residual risk, accepted explicitly.** On a shared or untrusted network a passive
observer reads the credential and every message, and a bootstrap credential handed
over such a network is full board access. Put the board on the tailnet, or give both
ends TLS.

**What would close it:** removing the plaintext mode, or making TLS the default with
an explicit opt-out flag. If that is done, this section is deleted and the alert
closes on the next scan.

**Review trigger:** a deployment that leaves a private network, a second operator on
the board, or the first non-loopback client that is not on a tailnet.
