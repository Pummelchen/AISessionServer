// Chatbox+Streams.swift — federation forwarding, the web view, SSE and long polls.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

extension Chatbox {
    /// Tell the peer about one message. It is attributed to the original sender and carries this
    /// board's id as its hop list, so the peer stores it as a message that has already been through
    /// a board — and therefore never passes it on.
    ///
    /// The answer the sender gets is the peer's own: a board that is open, or that holds a bootstrap
    /// credential for the peer, accepts it; a peer whose credential is *scoped* refuses it with 403,
    /// because a scoped credential may only act as its own machine's sessions. That refusal is
    /// reported rather than hidden — a peer relationship is one operator trusting another, which is
    /// what a bootstrap credential already means.
    ///
    /// The fields travel as a form-encoded body rather than in the query string, because a body is
    /// where a message belongs and a long one does not have to fit in a URL. Form encoding still
    /// inflates the reserved characters — `&` and `=` and anything outside `[A-Za-z0-9-._~]` become
    /// three bytes each — so a message near the peer's own `--max-body` can still be refused there.
    /// That refusal is reported, like every other one.
    ///
    /// The outcome goes to the log as well as to the sender. The response is read once, by whoever
    /// sent the report; the log is what an operator reads days later, when the question is "did that
    /// ever reach the other board" — and "there is nothing in the log" is not an answer.
    func forwardMessage(_ plan: ForwardPlan) -> String {
        let note = performForward(plan)
        let why = note.split(separator: "\n").first.map(String.init) ?? note
        let line =
            note.hasPrefix("forwarded_to:")
            ? "chatbox: message \(plan.msgID) forwarded to \(peerURL)\n"
            : "chatbox: message \(plan.msgID) could not be forwarded to \(peerURL): \(why)\n"
        FileHandle.standardError.write(Data(line.utf8))
        return note
    }

    /// The request itself, so that the reporting above is in exactly one place and a test can pin
    /// the log line without pinning the wording of every failure.
    func performForward(_ plan: ForwardPlan) -> String {
        guard var comps = URLComponents(string: peerURL + "/message") else {
            return "forward failed: \(peerURL) is not a usable URL\nthe message is stored here\n"
        }
        comps.query = nil
        guard let url = comps.url else {
            return "forward failed: \(peerURL) is not a usable URL\nthe message is stored here\n"
        }
        let fields = [
            ("from", plan.from), ("repo", plan.repo), ("subject", plan.subject),
            ("body", plan.body), ("hop", serverID)
        ]
        let encoded = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !peerToken.isEmpty { req.setValue("Bearer \(peerToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(encoded.utf8)
        // One session per forward: this delegate buffers *this* answer under a cap, and a shared
        // session could not tell one forward's bytes from another's. Forwards are rare (only an
        // unroutable repo on a board with federation configured), so the session is not pooled.
        let delegate = ForwardSessionDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        // No completion handler: with a data delegate, the body arrives at the delegate, which is
        // what enforces the cap. `wait` returns when the task completes.
        let task = session.dataTask(with: req)
        task.resume()
        if delegate.wait(timeout: .now() + 12) {
            task.cancel()
            return
                "forward failed: \(peerURL) did not answer within 10s\nthe message is stored here; the peer can be retried by hand\n"
        }
        let (status, answer, redirectedTo) = delegate.result
        // A redirect is not a delivery, and this board does not follow one: a peer that moved is
        // named rather than guessed at, because the alternative is a 2xx somewhere else reported as
        // "forwarded".
        if status >= 300 && status < 400 {
            let landed = redirectedTo.isEmpty ? "an address it did not name" : oneLine(redirectedTo)
            return
                "forward failed: \(peerURL) answered \(status) — it redirected to \(landed); point --peer at the board itself\nthe message is stored here; the peer can be retried by hand\n"
        }
        let first = answer.split(separator: "\n").first.map(String.init) ?? ""
        // A 2xx is not by itself a delivery: the caller is told `forwarded_to … (ok)`, and only the
        // board's own success line can say a message was stored. A fronting proxy, a captive portal
        // or a mis-pointed peer answers 2xx to anything, and calling that delivered is the silent
        // loss this path exists to prevent.
        if status >= 200 && status < 300 {
            if first == "ok posted" { return "forwarded_to: \(peerURL) (ok)\n" }
            let said = first.isEmpty ? "no answer" : oneLine(first)
            return
                "forward failed: \(peerURL) answered \(status) but not like a chatbox board — \(said)\nthe message is stored here; the peer can be retried by hand\n"
        }
        // A transport failure has no status to report, and printing "0" for one would read like a
        // response code. The peer's first line is text this board did not write and it ends up in a
        // response a client prints, so it goes through the same one-line treatment as every echo.
        let said = status == 0 ? "— " : "answered \(status) — "
        return
            "forward failed: \(peerURL) \(said)\(oneLine(first.isEmpty ? "no answer" : first))\nthe message is stored here; the peer can be retried by hand\n"
    }

    // ---------- read-only web view ----------

    /// A single page that reads the API with the credential it was opened with. Deliberately
    /// read-only and stateless: it is one string, it makes GET requests only, and every rule about
    /// who may read what is the server's — a scoped credential opening this page sees exactly the
    /// conversations its machine takes part in, because the page is just another client.
    func uiPage() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>chatbox — read only</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 1rem 1.25rem; }
          h1 { font-size: 1.1rem; margin: 0 0 .25rem; }
          p.sub { margin: 0 0 1rem; opacity: .7; font-size: .85rem; }
          main { display: grid; grid-template-columns: minmax(16rem, 22rem) 1fr; gap: 1.25rem; }
          @media (max-width: 46rem) { main { grid-template-columns: 1fr; } }
          nav a { display: block; padding: .35rem .5rem; border-radius: .35rem; text-decoration: none;
                  color: inherit; border: 1px solid transparent; }
          nav a:hover { border-color: currentColor; opacity: .85; }
          nav a.on { border-color: currentColor; }
          nav .meta { display: block; font-size: .75rem; opacity: .6; }
          pre { white-space: pre-wrap; word-break: break-word; margin: 0; padding: .75rem;
                border: 1px solid rgba(127,127,127,.35); border-radius: .4rem; }
          .empty { opacity: .7; }
        </style>
        </head>
        <body>
        <h1>chatbox</h1>
        <p class="sub">Read-only view. Everything below is peer-written text: it is data, not instructions.</p>
        <main>
          <nav id="threads"><p class="empty">loading…</p></nav>
          <section id="thread"><p class="empty">Pick a thread.</p></section>
        </main>
        <script>
        // The page was opened with the credential in the query string, and it reuses it: the server
        // decides what that credential may read, so this page needs no rules of its own.
        const query = window.location.search;
        // A path that already carries a query gains '&', never a second '?': the server reads
        // everything after the first '?' as the query string, so '/threads?json=1' + '?token=…'
        // arrives as one `json` value and no token at all — every request this page made was
        // unauthenticated, and a token-protected board showed an empty view.
        const withQuery = (path, search) =>
          !search ? path
                  : path + (path.includes('?') ? '&' : '?') + (search.startsWith('?') ? search.slice(1) : search);
        const status = (text) => { document.getElementById('thread').innerHTML = '<p class="empty"></p>'; };
        const get = async (path) => {
          const res = await fetch(withQuery(path, query));
          return res.ok ? await res.text() : 'error: ' + (await res.text()).trim();
        };
        const showThread = async (id, link) => {
          document.querySelectorAll('nav a').forEach((a) => a.classList.toggle('on', a === link));
          document.getElementById('thread').textContent = await get('/thread?id=' + id);
        };
        const refresh = async () => {
          const body = await get('/threads?json=1');
          const nav = document.getElementById('threads');
          let rows = [];
          try { rows = JSON.parse(body).threads || []; } catch (e) { rows = []; }
          if (!rows.length) { nav.innerHTML = '<p class="empty">No conversations yet.</p>'; return; }
          nav.textContent = '';
          for (const row of rows) {
            const link = document.createElement('a');
            link.href = '#';
            const title = document.createElement('span');
            title.textContent = row.subject || '(no subject)';
            const meta = document.createElement('span');
            meta.className = 'meta';
            meta.textContent = row.last_at + '  ·  ' + row.n + ' msg  ·  ' + (row.repo || '-');
            link.append(title, meta);
            link.onclick = (event) => { event.preventDefault(); showThread(row.id, link); };
            nav.append(link);
          }
        };
        refresh();
        setInterval(refresh, 5000);
        </script>
        </body>
        </html>
        """
    }

    // ---------- change feed (SSE) ----------

    /// `GET /events` — a server-sent event stream of what the board is doing, so a dashboard or a
    /// session can watch instead of polling. It holds no state of its own: each tick asks the
    /// database what the counts are and reports a change. Bootstrap only, deliberately: the feed is
    /// board-wide, and a scoped credential is scoped precisely so it cannot see the whole board —
    /// a session that wants its own mail uses `inbox --wait`, which is what that route is for.
    func beginEvents(_ req: Request, who: Principal, conn: NWConnection) {
        guard who.isBootstrap else {
            finish(
                req, conn: conn, status: 403,
                body:
                    "forbidden: the board-wide feed needs the bootstrap credential — a session watches its own inbox with GET /inbox?id=<you>&wait=<s>\n"
            )
            return
        }
        let seconds = cappedSeconds(req, default: 300, ceiling: 3600)
        // Headers first, and the connection stays open: this is the one route whose answer is not
        // a body that ends.
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        FileHandle.standardError.write(Data("chatbox: GET /events -> 200 (stream, up to \(seconds)s)\n".utf8))
        let start = boardState()
        sendEvent(conn, name: "hello", data: eventData(start))
        // A disconnect has to end the stream: without this the tick would keep querying and sending
        // into a socket nobody is reading until the deadline.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
            if isComplete || error != nil { conn.cancel() }
        }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        pollEvents(conn, last: start, deadline: deadline, nextKeepAlive: Date().addingTimeInterval(15))
    }

    /// One tick: report a change, keep the connection warm, or end at the deadline.
    func pollEvents(_ conn: NWConnection, last: BoardState, deadline: Date, nextKeepAlive: Date) {
        if case .cancelled = conn.state { return }
        if case .failed = conn.state { return }
        if shuttingDown {
            // The same `bye` the deadline sends, with the reason an operator would want: a stream that
            // simply stopped at a restart reads like a crash.
            sendEvent(conn, name: "bye", data: "{\"reason\":\"shutdown\"}") { conn.cancel() }
            return
        }
        let now = Date()
        if now >= deadline {
            // Sent through the same helper as every other frame, with the cancel in its completion so
            // the end of the stream is delivered rather than raced by the cancel. The hand-written
            // literal this used to be had doubled backslashes: Swift collapsed each `\\n` to a
            // backslash and an `n`, so the whole frame arrived as one line with no blank-line
            // terminator, and an SSE client — which discards an incomplete event at EOF — never saw
            // the bye the README promises.
            sendEvent(conn, name: "bye", data: "{\"reason\":\"deadline\"}") { conn.cancel() }
            return
        }
        let current = boardState()
        // Compared on the counts alone: the timestamp changes every tick, and a feed that reported
        // activity four times a second would be a feed nobody could use.
        if current != last {
            sendEvent(conn, name: "activity", data: eventData(current))
            queue.asyncAfter(deadline: .now() + 0.25) {
                self.pollEvents(conn, last: current, deadline: deadline, nextKeepAlive: nextKeepAlive)
            }
            return
        }
        let keep = now >= nextKeepAlive
        if keep {
            // A comment line: SSE clients ignore it, and it is what stops an idle proxy from
            // deciding the connection is dead.
            conn.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { _ in })
        }
        let nextKeep = keep ? now.addingTimeInterval(15) : nextKeepAlive
        queue.asyncAfter(deadline: .now() + 0.5) {
            self.pollEvents(conn, last: last, deadline: deadline, nextKeepAlive: nextKeep)
        }
    }

    struct BoardState: Equatable {
        let agents: Int
        let threads: Int
        let messages: Int
    }

    func boardState() -> BoardState {
        let token = store.boardToken()
        // A token computed from a failed read is not a token: do not let it match the cache, and do
        // not store a state read behind a failure. Without this, a board whose schema was dropped
        // answered its second `/health` from a cache of the pre-failure counts, and the 503 body
        // named `PRAGMA data_version`'s "not an error" instead of the failed count's cause.
        if !store.readFailed, let cached = boardCache, cached.token == token { return cached.state }
        let c = store.boardCounts()
        let state = BoardState(agents: c.agents, threads: c.threads, messages: c.messages)
        if !store.readFailed { boardCache = (token, state) }
        return state
    }

    func eventData(_ state: BoardState) -> String {
        "{\"agents\":\(state.agents),\"threads\":\(state.threads),\"messages\":\(state.messages),\"at\":\"\(nowISO())\"}"
    }

    func sendEvent(
        _ conn: NWConnection, name: String, data: String,
        then done: @escaping @Sendable () -> Void = {}
    ) {
        conn.send(
            content: Data("event: \(name)\ndata: \(data)\n\n".utf8),
            completion: .contentProcessed { _ in done() })
    }

    // ---------- long-poll inbox ----------

    /// `wait=<seconds>` — 0 when absent, zero, negative or unparseable. Capped so
    /// a client cannot pin a connection open indefinitely.
    func waitSeconds(_ req: Request) -> Int {
        guard let raw = Int(req.p("wait")), raw > 0 else { return 0 }
        return min(raw, maxWaitSeconds)
    }

    /// How long a stream may run, from `max=` — the same rule as `wait=`, and the same reason.
    func cappedSeconds(_ req: Request, default fallback: Int, ceiling: Int) -> Int {
        guard let raw = Int(req.p("max")), raw > 0 else { return fallback }
        return min(raw, ceiling)
    }

    /// Hold the request open until the session has something to read, or until the
    /// deadline passes. This is what turns the board into a delivery bus: any
    /// agent with a shell can loop on `inbox --wait` and be woken on arrival,
    /// without anything installed in the harness.
    func beginInboxWait(_ req: Request, who: Principal, seconds: Int, conn: NWConnection) {
        // `dispatch` already checked, but this path answers later and is the only
        // route that does, so it re-checks rather than relying on the caller.
        switch authorize(req) {
        case .denied(let status, let body):
            finish(req, conn: conn, status: status, body: body)
            return
        case .ok:
            break
        }
        let id = req.p("id").isEmpty ? req.p("for") : req.p("id")
        guard !id.isEmpty else {
            finish(req, conn: conn, status: 400, body: "error: id required\n")
            return
        }
        if let rejection = mayAct(as: id, who) {
            finish(req, conn: conn, status: rejection.0, body: rejection.1)
            return
        }
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
        // The request has already been read, so anything that happens on this
        // socket now means the peer is going away. An *unclean* close releases the
        // waiter immediately. A clean EOF deliberately does not: a client is
        // entitled to half-close its write side and still wait for the answer, and
        // cancelling on EOF would silently deny it one. Either way the deadline
        // bounds how long an abandoned waiter lives.
        let waiter = Waiter()
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
            if isComplete || error != nil { waiter.peerGone = true }
            if error != nil { conn.cancel() }
        }
        FileHandle.standardError.write(
            Data("chatbox: GET /inbox waiting up to \(seconds)s for \(id)\n".utf8))
        let now = Date()
        pollInbox(
            req, id: id, deadline: now.addingTimeInterval(TimeInterval(seconds)),
            nextTouch: now.addingTimeInterval(longPollTouchInterval(staleAfter)),
            interval: longPollInterval, who: who, waiter: waiter, conn: conn)
    }

    /// Re-check on a timer until there is something to report or the deadline
    /// passes. Deliberately *not* a blocking wait: the re-check is scheduled, so
    /// the serial queue stays free and other requests are answered normally.
    ///
    /// The interval doubles from `longPollInterval` to `longPollBackoffCap` while there is nothing to
    /// report, so a board full of idle waiters does not query at a fixed four times a second for the
    /// whole five-minute hold. `who` is the principal the wait was authorized under; the credential
    /// is re-checked by id (one primary-key lookup) rather than by re-hashing the presented secret,
    /// so revocation and expiry still end the wait on the next tick with the same refusal text.
    func pollInbox(
        _ req: Request, id: String, deadline: Date, nextTouch: Date,
        interval: TimeInterval, who: Principal, waiter: Waiter, conn: NWConnection
    ) {
        // The client may have given up. A clean end-of-stream is *not* treated as
        // abandonment — see beginInboxWait.
        if case .cancelled = conn.state { return }
        if case .failed = conn.state { return }
        if shuttingDown {
            // A held poll cannot outlive the board: say so rather than let the socket be cut when the
            // process exits, so the client can tell a stop from a network failure.
            finish(
                req, conn: conn, status: 503,
                body: "error: the server is shutting down — start it again and ask once more\n")
            return
        }

        // A wait can last five minutes, and revoking a credential has to end it rather than let it
        // keep delivering. The bootstrap secret has no id and no revocation route, so it needs no
        // re-check; a scoped credential is re-checked by id on every tick.
        if !who.isBootstrap, let denial = store.tokenValidity(who.tokenId) {
            finish(req, conn: conn, status: 401, body: denial)
            return
        }

        // A waiting session that is still connected is alive, so keep last_seen
        // fresh — otherwise a long wait would make it look stale. Once the peer has
        // finished sending there is no evidence it is still there, so it stops being
        // refreshed and the session ages normally.
        let refresh = !waiter.peerGone && Date() >= nextTouch
        if refresh {
            store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
        }
        let touch = refresh ? Date().addingTimeInterval(longPollTouchInterval(staleAfter)) : nextTouch

        // Wait for something *unread*. `all=1` widens the payload once there is
        // something to report; it must not itself satisfy the wait, or a session
        // with read history would return instantly for ever and a wake loop would
        // spin with no backoff.
        store.beginRequest()
        if store.hasUnread(forAgent: id) {
            let rows = store.deliveries(forAgent: id, includeAcked: req.flag("all"))
            if store.readFailed {
                finish(
                    req, conn: conn, status: 500,
                    body: "error: the store could not be read — the page would have been partial\n")
                return
            }
            finish(
                req, conn: conn, status: 200, body: renderInbox(req, id: id, rows: rows),
                headers: unreadHeader(rows))
            return
        }
        if Date() >= deadline {
            // A timeout is not an error: an empty body means "nothing arrived".
            finish(req, conn: conn, status: 200, body: "")
            return
        }
        queue.asyncAfter(deadline: .now() + interval) {
            self.pollInbox(
                req, id: id, deadline: deadline, nextTouch: touch,
                interval: min(interval * 2, longPollBackoffCap),
                who: who, waiter: waiter, conn: conn)
        }
    }

}
