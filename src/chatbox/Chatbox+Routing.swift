// Chatbox+Routing.swift — credential resolution, the route table and registration.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

extension Chatbox {

    /// Called on the queue by the signal source, before the listener is cancelled and the log is
    /// folded back into the database.
    func requestShutdown() {
        dispatchPrecondition(condition: .onQueue(queue))
        shuttingDown = true
    }

    // ---------- presence ----------
    //
    // `last_seen` is refreshed by registering, by sending a message that was stored,
    // by reading an inbox or acking,
    // and by a held long poll for as long as its peer is still connected — at most
    // once a minute, and more often when the window is shorter than that. So a
    // session past the window is one that has gone quiet, rather than one that is
    // merely waiting. Nothing is ever probed or evicted: this is an inference, and
    // the response says what the server believes rather than what it knows.

    /// A timestamp this server did not write may still carry fractional seconds, and a stamp that
    /// does not parse at all is not a date — the one style accepts both shapes, so there is no second
    /// attempt to make and nothing shared to guard.
    static func parseISO(_ s: String) -> Date? {
        try? ISOStamp.style.parse(s)
    }

    /// A never-seen or unparseable timestamp counts as stale: the only sessions in
    /// that state are ones that were never really here.
    func isStale(_ lastSeen: String, now: Date) -> Bool {
        guard staleAfter > 0 else { return false }
        guard let then = Self.parseISO(lastSeen) else { return true }
        return now.timeIntervalSince(then) > Double(staleAfter)
    }

    func ageDescription(_ lastSeen: String, now: Date) -> String {
        guard let then = Self.parseISO(lastSeen) else { return "never seen" }
        let seconds = Int(now.timeIntervalSince(then))
        if seconds < 0 { return "just now" }
        return humanSeconds(seconds) + " ago"
    }

    // ---------- routing ----------

    enum Auth {
        case ok(Principal)
        case denied(Int, String)
    }

    /// Resolve the credential on the request. The shared token remains the
    /// bootstrap credential; everything else is looked up by hash, so revoking one
    /// credential takes effect on the very next request with no restart.
    func authorize(_ req: Request) -> Auth {
        if req.tokenConflicts {
            return .denied(400, "error: ?token= and the Authorization header disagree — send one credential\n")
        }
        // The bootstrap secret is the one comparison an attacker can drive byte by byte, so it goes
        // through the constant-time helper rather than `==`. "open" is a literal, not a secret.
        guard let expected = token else { return .ok(.bootstrap) }
        if expected == "open" { return .ok(.bootstrap) }
        let presented = req.token ?? ""
        if !presented.isEmpty, secretsMatch(presented, expected) { return .ok(.bootstrap) }
        guard !presented.isEmpty else {
            return .denied(401, "unauthorized: pass ?token= or Authorization: Bearer\n")
        }
        guard let row = store.tokenByHash(sha256Hex(presented)) else {
            return .denied(401, "unauthorized: unknown token\n")
        }
        if !(row["revoked_at"] ?? "").isEmpty {
            return .denied(401, "unauthorized: this credential has been revoked\n")
        }
        // An expiry is a backstop for the credential nobody remembers, so it is checked the same
        // way revocation is: on every request, with the date in the answer and no grace period.
        let expiresAt = row["expires_at"] ?? ""
        if !expiresAt.isEmpty {
            // The comparison is a string comparison, which is a time comparison only for the
            // canonical 20-character shape this server writes. A value written by another tool —
            // an offset instead of `Z`, the basic format, a date with no time — would compare
            // wrongly, and the direction that matters is the one that keeps a credential alive
            // past its date: an unreadable expiry is treated as expired.
            let canonical = expiresAt.count == 20 && expiresAt.hasSuffix("Z")
            if !canonical {
                return .denied(
                    401,
                    "unauthorized: this credential's expiry ('\(oneLine(expiresAt))') cannot be read — issue another\n")
            }
            if expiresAt <= nowISO() {
                return .denied(401, "unauthorized: this credential expired at \(expiresAt) — issue another\n")
            }
        }
        let id = row["id"] ?? ""
        let now = nowISO()
        // Refresh at most once a minute: a write on every request would be wasted.
        let lastUsed = row["last_used"] ?? ""
        if lastUsed.isEmpty || String(lastUsed.prefix(16)) != String(now.prefix(16)) {
            store.touchToken(id, at: now)
        }
        let namespaces = (row["namespaces"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return .ok(
            Principal(
                isBootstrap: false, tokenId: id, node: row["node"] ?? "",
                namespaces: namespaces))
    }

    /// A scoped credential may only act as a session registered to its own machine.
    /// The bootstrap credential is unrestricted, which is what lets credentials be
    /// handed out one machine at a time without breaking anyone.
    func mayAct(as id: String, _ who: Principal) -> (Int, String)? {
        if who.isBootstrap { return nil }
        guard let node = store.nodeOf(id) else {
            return (
                403, "forbidden: that session is not registered — register it first with this machine's credential\n"
            )
        }
        guard node == who.node else {
            return (403, "forbidden: this credential may not act as that session\n")
        }
        return nil
    }

    /// Route a parsed request — including the one route that answers later.
    func dispatch(_ req: Request, conn: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        var req = req
        req.peer = peerNote(conn)
        // A request line is not a place for control bytes. A bare LF in the target used to reach the
        // log, so one request could write a line of its own into the record an operator reads after
        // an incident - and the same bytes reached the 404 body. It is refused before anything acts
        // on it, and every echo of it (the log, the 404 body) is flattened as well.
        if hasControlByte(req.method) || hasControlByte(req.path) {
            req.principal = "malformed"
            finish(req, conn: conn, status: 400, body: "error: the request line contains control characters\n")
            return
        }
        if req.chunked {
            finish(
                req, conn: conn, status: 400, body: "error: chunked bodies are not supported — send Content-Length\n")
            return
        }
        let who: Principal
        switch authorize(req) {
        case .denied(let status, let body):
            req.principal = "denied"
            finish(req, conn: conn, status: status, body: body)
            return
        case .ok(let principal):
            who = principal
            // Who the request was served as, for the log. A scoped credential is named by the machine
            // it belongs to and the id of the credential itself; the secret is never written.
            req.principal =
                principal.isBootstrap
                ? "bootstrap"
                : "node=\(principal.node) token=\(principal.tokenId)"
        }
        if req.method == "GET", req.path == "/inbox" {
            let wait = waitSeconds(req)
            if wait > 0 { beginInboxWait(req, who: who, seconds: wait, conn: conn); return }
        }
        if req.method == "GET", req.path == "/events" {
            beginEvents(req, who: who, conn: conn)
            return
        }
        if req.method == "GET", req.path == "/ui" {
            finish(req, conn: conn, status: 200, body: uiPage(), contentType: "text/html; charset=utf-8")
            return
        }
        store.beginRequest()
        let answer = handle(req, who)
        if req.method == "GET", answer.status < 500, store.readFailed {
            // The route built an answer from a read that did not finish — an empty thread, a short
            // inbox, a registry missing rows. Answering it would present a truncated view as the
            // truth, which is the one thing a partial read must never do. A GET's answer *is* the
            // data, so a failed read means there is no answer to give. A write is different: its
            // answer is the effect, and the routes that can be misled by a failed read handle that
            // themselves (see `message`), because a blanket 500 would leave the caller unable to tell
            // whether the write happened.
            //
            // `< 500` and not just `200`: a 404 or a 403 *built from* the failed read is the same
            // lie in a different status — "no such thread" and "not your conversation" are answers
            // the store could not actually give. A route that already reports a server-side failure
            // has handled it: `/health` answers 503 with the store's own error, and overwriting that
            // with a generic 500 would make the better answer worse.
            finish(
                req, conn: conn, status: 500,
                body:
                    "error: the store could not be read — the answer would have been partial (\(oneLine(store.lastError())))\n"
            )
            return
        }
        if let plan = answer.forward {
            // The message is stored, and a peer still has to be told. The forward runs off the
            // serial queue so a peer that is slow, unreachable, or this board itself cannot hold up
            // every other request, and the sender is answered with what actually happened rather
            // than a guess. The connection stays open until then, exactly as the long-poll path
            // keeps one — the accept deadline was cancelled when the request arrived.
            let base = answer.body
            let finalReq = req
            // Bounded concurrency: beyond the cap the sender is answered at once, truthfully, rather
            // than queued behind an unbounded backlog (which is what held its connection open).
            guard forwardsInFlight < maxConcurrentForwards else {
                finish(
                    finalReq, conn: conn, status: answer.status,
                    body: base
                        + "forward failed: the board is already forwarding \(forwardsInFlight) messages — the peer can be retried by hand\nthe message is stored here\n",
                    headers: answer.headers)
                return
            }
            forwardsInFlight += 1
            forwardQueue.async {
                let note = self.forwardMessage(plan)
                self.queue.async {
                    self.forwardsInFlight -= 1
                    self.finish(
                        finalReq, conn: conn, status: answer.status, body: base + note,
                        headers: answer.headers)
                }
            }
            return
        }
        finish(req, conn: conn, status: answer.status, body: answer.body, headers: answer.headers)
    }

    /// The plain `(status, body)` a handler returns, as a `Reply`. Only `message` ever sets
    /// `forward`, and every other route goes through here so the routing table stays one shape.
    func reply(_ out: (Int, String)) -> Reply { Reply(out.0, out.1) }

    func handle(_ req: Request, _ who: Principal) -> Reply {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/help"): return Reply(200, usage(publicURL))
        case ("GET", "/health"): return health()
        case ("POST", "/register"): return reply(register(req, who))
        case ("POST", "/message"), ("POST", "/say"): return message(req, who)
        case ("GET", "/inbox"): return inbox(req, who)
        case ("GET", "/thread"): return reply(showThread(req, who))
        case ("GET", "/threads"): return reply(listThreads(req, who))
        case ("POST", "/ack"): return reply(ack(req, who))
        case ("GET", "/peers"): return reply(peers(req, who))
        case ("POST", "/token"): return reply(createToken(req, who))
        case ("GET", "/token"): return reply(listTokens(req, who))
        case ("POST", "/token/revoke"): return reply(revokeToken(req, who))
        default: return Reply(404, "not found: \(oneLine(req.method)) \(oneLine(req.path))\n\n" + usage(publicURL))
        }
    }

    func usage(_ url: String) -> String {
        """
        chatbox — harness-independent session chatbox (text only, no file access)

        Register once, then talk about repos by key.
          register  POST /register?id=<you>&node=<mac>&agent=<dsh|codex|claude>&session=<id>&repos=github.com/acme/libfoo&ip=<ip>
          say       POST /message?from=<you>&repo=<repo-key>&subject=<line>&body=<text>
          reply     POST /message?from=<you>&thread=<id>&body=<text>
          inbox     GET  /inbox?id=<you>            (add &all=1 to include read)
                    add &wait=<seconds> to hold until a message arrives (max 300; empty body on timeout)
                    add &full=1 to carry whole bodies instead of the 1200-character preview
          read      GET  /thread?id=<thread-id>
          ack       POST /ack?id=<you>&message=<message-id>   (or &thread=<id>, or &all=1 for everything unread)
          peers     GET  /peers                     (who owns what)
          events    GET  /events                    (SSE: board activity, bootstrap only)
          health    GET  /health

        Credentials — issuing is restricted to the bootstrap token:
          token     POST /token?node=<mac>&namespaces=github.com/acme/*&note=<text>   (secret shown once)
          tokens    GET  /token                     (list; never shows secrets)
          revoke    POST /token/revoke?id=<tk-id>   (effective immediately, no restart)

        A scoped credential may only act as a session registered to its own node,
        and may only claim repos inside its namespaces. It can still send to any
        repo, which is the point: "whoever owns <repo>, I have a bug to discuss".

        Federation — one hop, when started with --peer <url> and a peer credential
        (--peer-token-file PATH is preferred; --peer-token <secret> is visible in `ps`):
          A message for a repo nobody on this board claims is forwarded to the peer, which
          stores it under a thread of its own; the response says forwarded_to: or why not.
          A forwarded request carries &hop=<board[,board...]>, and a board never forwards a
          message that already has one, so a loop cannot form. --server-id names this board,
          and --max-hops (default 4) bounds the hop list an incoming forward may carry.
          The peer credential should be the peer's bootstrap credential: a scoped one may
          forward only its own machine's sessions, and its refusal is reported.

        Bodies accept JSON or form-encoding, or plain text: curl -d 'text' '\(url)/say?from=x&repo=y'
        Add &json=1 to any GET for structured output. Auth: ?token=<secret> (or Authorization: Bearer).
        """
    }

    /// A probe that keys on the status code has to be able to see a store it cannot read. A failed
    /// count is not zero — it is unknown — and a board that answers 200 with empty counters while no
    /// route can serve a request is precisely the failure a health check exists to report. The counts
    /// come from the same cached `boardState` the events feed uses, so a monitoring poll does not
    /// scan the messages table for a number the feed just computed; `readFailed` is the signal that
    /// the (cheap) read behind it did not complete.
    func health() -> Reply {
        let counts = boardState()
        guard !store.readFailed else {
            return Reply(
                503,
                "error: the store could not be read — the counters are unknown, not zero\n"
                    + "sqlite: \(store.lastError())\n"
                    + "board: \(serverID)\nnow: \(nowISO())\n")
        }
        let a = counts.agents
        let t = counts.threads
        let m = counts.messages
        let presence = staleAfter == 0 ? "off" : "stale after \(humanSeconds(staleAfter))"
        let transport = tlsEnabled ? "tls" : "plain http"
        let idle = idleTimeout == 0 ? "no idle deadline" : "\(idleTimeout)s idle deadline"
        // The board's own name is reported whether or not it forwards: it is the name a peer shows
        // in `(via …)` on a forwarded message, and an operator comparing two boards needs it.
        let peer = peerURL.isEmpty ? "none" : peerURL
        return Reply(
            200,
            "ok chatbox up\n\(buildIdentity())\nagents: \(a)\nthreads: \(t)\nmessages: \(m)\npresence: \(presence)\ntransport: \(transport)\nmax request: \(maxBody) bytes\nmax rows: \(maxRows)\nrecipients per message: \(maxRecipients)\nconnections: up to \(maxConnections), \(idle)\npeer: \(peer) (this board is \(serverID), accepts up to \(maxHops) hops)\nnow: \(nowISO())\n"
        )
    }

    func register(_ req: Request, _ who: Principal) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("from") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required (who you are, e.g. node1-dsh-abc)\n") }
        guard validId(id) else { return (400, "error: id must be a single line, without control characters\n") }
        let node = req.p("node")
        let agent = req.p("agent")
        let harness = req.p("harness")
        let session = req.p("session")
        let ip = req.p("ip")
        let note = req.p("note")
        let repos = req.p("repos").isEmpty ? req.p("repo") : req.p("repos")
        let kept = store.scalar("SELECT repos FROM agents WHERE id = ?", [id])

        // A repo key is a name, not a pattern, and it has one spelling. Canonicalising here
        // is what makes a key that arrived by `curl` mean the same thing as one the client
        // sent. Refusing wildcards also stops a namespace pattern such as `acme/*` from
        // matching *itself* and being claimed as a literal repo key.
        var canonical: [String] = []
        for claimed in repos.split(separator: ",") {
            let repo = claimed.trimmingCharacters(in: .whitespaces)
            if repo.isEmpty { continue }
            guard let key = canonicalRepoKey(repo) else {
                return (
                    400,
                    "error: '\(oneLine(repo))' is not a valid repo key — keys name a repo, are one line, and do not contain '*', '[' or ']' or a space (a '?' or '#' ends the key)\n"
                )
            }
            if !canonical.contains(key) { canonical.append(key) }
        }

        // An omitted repos= preserves the stored claim; a *present* one that names no usable
        // key does not. It cannot, or `repos=,,` would reach the update with an empty string,
        // the update would read that as "preserve", and a scoped credential could keep a claim
        // its namespaces do not allow — which is the one thing this check exists to stop.
        if !repos.isEmpty && canonical.isEmpty {
            return (400, "error: repos= was given but names no usable repo key — omit it to keep the stored claim\n")
        }
        // What the session will own *after* the upsert, and what the namespace check below
        // validates: the stored value too, so a credential cannot inherit a claim it was never
        // allowed to make.
        let effectiveRepos = repos.isEmpty ? kept : canonical.joined(separator: ",")

        // A scoped credential speaks for one machine: it must name that machine,
        // must not take over a session that lives elsewhere, and may only claim
        // repos inside the namespaces it was issued for.
        if !who.isBootstrap {
            guard !node.isEmpty else {
                return (403, "forbidden: node required — a scoped credential must name its own machine\n")
            }
            guard who.mayClaim(node: node) else {
                return (403, "forbidden: this credential may not register for that node\n")
            }
            if let existing = store.nodeOf(id), existing != who.node {
                return (403, "forbidden: this credential may not take over that session\n")
            }
            for claimed in effectiveRepos.split(separator: ",") {
                let repo = claimed.trimmingCharacters(in: .whitespaces)
                if repo.isEmpty { continue }
                guard who.mayClaim(repo: repo) else {
                    return (
                        403,
                        "forbidden: this credential may not claim '\(repo)'"
                            + (who.namespaces.isEmpty
                                ? " (it may claim no repos)\n"
                                : " — allowed: \(who.namespaces.joined(separator: ", "))\n")
                    )
                }
            }
        }
        let ts = nowISO()
        let existing = store.scalar("SELECT id FROM agents WHERE id = ?", [id])
        var wrote: (rc: Int32, changes: Int32, id: Int64) = (SQLITE_DONE, 0, 0)
        if existing.isEmpty {
            wrote = store.runReporting(
                "INSERT INTO agents (id,node,agent,harness,session,ip,repos,note,registered_at,last_seen) VALUES (?,?,?,?,?,?,?,?,?,?)",
                [id, node, agent, harness, session, ip, effectiveRepos, note, ts, ts])
        } else {
            // An omitted (empty) field keeps the stored value — the rule `repos` already followed,
            // now applied to all of them. The update used to write node, agent, harness, session,
            // ip and note unconditionally, so a session that re-registered only to add a repo
            // silently lost the rest of its identity, and because /peers prints the harness line
            // only when a field is set, the loss was invisible in the default view.
            wrote = store.runReporting(
                """
                UPDATE agents SET
                  node    = CASE WHEN ?='' THEN node    ELSE ? END,
                  agent   = CASE WHEN ?='' THEN agent   ELSE ? END,
                  harness = CASE WHEN ?='' THEN harness ELSE ? END,
                  session = CASE WHEN ?='' THEN session ELSE ? END,
                  ip      = CASE WHEN ?='' THEN ip      ELSE ? END,
                  repos   = CASE WHEN ?='' THEN repos   ELSE ? END,
                  note    = CASE WHEN ?='' THEN note    ELSE ? END,
                  last_seen = ?
                WHERE id = ?
                """,
                [
                    node, node, agent, agent, harness, harness, session, session, ip, ip,
                    effectiveRepos, effectiveRepos, note, note, ts, id
                ])
        }
        // The answer reports what is *stored*, not what was sent: with an omitted field preserved,
        // echoing the request would say "session: " while the session was still on the board.
        // A registration that was not written must not be answered as one: the upsert's result was
        // discarded, so a refused INSERT still produced "ok registered" with the empty identity the
        // re-read found.
        guard wrote.rc == SQLITE_DONE else {
            FileHandle.standardError.write(
                Data("chatbox: the registration of \(id) failed: \(store.lastError())\n".utf8))
            return (
                500,
                "error: the registration was not stored — \(oneLine(id)) is not registered (\(oneLine(store.lastError())))\n"
            )
        }
        let stored =
            store.rows(
                """
                SELECT node, agent, harness, session, ip, repos FROM agents WHERE id = ?
                """, [id]
            ).first ?? [:]
        let storedRepos = stored["repos"] ?? ""
        audit(
            "registered id=\(oneLine(id)) node=\(oneLine(stored["node"] ?? "")) repos=\(storedRepos.isEmpty ? "(none)" : oneLine(storedRepos))"
        )
        return (
            200,
            """
            ok registered
            id: \(oneLine(id))
            node: \(oneLine(stored["node"] ?? ""))  agent: \(oneLine(stored["agent"] ?? ""))  session: \(oneLine(stored["session"] ?? ""))
            ip: \(oneLine(stored["ip"] ?? ""))  harness: \(oneLine(stored["harness"] ?? ""))
            repos: \(storedRepos.isEmpty ? "(none declared)" : oneLine(storedRepos))
            at: \(ts)

            Next: POST /message?from=\(id)&repo=<repo>&subject=<...>&body=<...>
            """
        )
    }

}
