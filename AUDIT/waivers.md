# Waivers

The audit standard is "every scanner clean, or waived here **in writing**". A waiver is a decision
with a reason, an owner and a review trigger — not a silenced check. Nothing on this page changes
what a scanner reports; it records what was decided about a finding that is accurate.

## W-01 · CodeQL `swift/cleartext-transmission` on the HTTP listener

| | |
|---|---|
| Scanner / rule | CodeQL code scanning, `swift/cleartext-transmission` (severity: high) |
| Alert | [#1](https://github.com/Pummelchen/AISessionServer/security/code-scanning/1), `chatbox.swift:2426`, state **dismissed — won't fix** |
| Filed | 2026-09-15, task [#0014](ledger.md#0014) |
| Owner | the repository owner (the deployment decision is theirs; see [DEC-01](../README.md)) |
| Review trigger | a deployment that leaves a private network, a second operator on the board, or the first non-loopback client that is not on a tailnet |

**What the rule reports.** The server accepts requests on a plain `http://` listener, so the
credential in the query string or the `Authorization` header, and the message text itself, cross the
network in the clear. The rule is **accurate, not a false positive**: `chatbox.swift` runs
`NWListener` with `useTLS` set only when `--tls-identity` and `--tls-password-file` are given, and the
startup banner says so in those words.

**Why it is accepted.**

- TLS is **available and documented**, not absent: `--tls-identity` plus `--tls-password-file` on the
  server, `CHATBOX_CACERT` on the client, and the client refuses a CA over a plain `http://` URL
  rather than ignoring it. There is deliberately no flag to skip verification.
- The default is plain because the documented deployment is two machines on one private tailnet
  ([Deployment](https://github.com/Pummelchen/AISessionServer/wiki/Deployment)), where the transport
  is already encrypted by WireGuard and the certificate story for two self-signed peers is worse than
  the risk it removes.
- Making TLS mandatory is a **product decision, not a defect fix**: it changes every client's URL
  scheme, every `~/.chatbox`, the peer federation URL and the wiki's Quick Start, and it would break
  the loopback default that exists so a macOS host can reach its own board. The audit does not take
  that decision on the owner's behalf; the finding's fix summary says the same.
- The blast radius is bounded by design even in the clear: the client defaults to
  `http://127.0.0.1:8787` (loopback — the one address that cannot carry the credential to another
  machine), a scoped credential reaches only its own machine's conversations, and the server logs a
  warning line when a plaintext request arrives from a non-loopback peer.

**Residual risk, accepted explicitly.** On a shared or untrusted network, a passive observer reads
the credential and every message; a bootstrap credential handed over such a network is full board
access. The mitigation is operational and documented: put the board on the tailnet, or give both
ends TLS.

**What would close it.** Removing the plaintext mode (or making TLS the default with an explicit
opt-out flag). That is the owner's call; if it is taken, this waiver is deleted and the alert closes
by itself on the next scan.
