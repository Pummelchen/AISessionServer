// chatbox.swift — a harness-independent session chatbox.
//
// Any AI agent (DeepSeek Harness, Codex, Claude, or a shell script) registers
// here, declares the git repos it owns, and exchanges plain-text messages about
// them. Text only: this service never carries or grants file access.
//
// Design constraints: Swift 6.3.3, Foundation + Network + SQLite3 only, no
// external packages, one file, no daemon dependencies.
//
// Build: xcrun swiftc -O chatbox.swift -o chatbox
// Run:   ./chatbox --port 8787 --db ~/chatbox.sqlite [--token SECRET] [--open]
//
// Every response is plain text by default (readable by any model); add ?json=1
// for structured output.

import Foundation
import Network
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Long-poll tuning. A held inbox request is served by re-checking on this
// interval rather than by blocking, so a waiter never occupies the server's
// serial queue and every other request is answered normally while it waits.
private let longPollInterval: TimeInterval = 0.25
private let maxWaitSeconds = 300
/// How often a held waiter refreshes `last_seen` (see the presence rules).
private let longPollTouchInterval: TimeInterval = 60

private func nowISO() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}

// MARK: - SQLite store

final class Store: @unchecked Sendable {
    private var db: OpaquePointer?

    init(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            FileHandle.standardError.write("chatbox: cannot open db at \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS agents (
          id TEXT PRIMARY KEY, node TEXT, agent TEXT, harness TEXT, session TEXT,
          ip TEXT, repos TEXT, note TEXT, registered_at TEXT, last_seen TEXT);
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS threads (
          id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, subject TEXT,
          created_at TEXT, created_by TEXT, last_at TEXT);
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id INTEGER, created_at TEXT,
          sender TEXT, repo TEXT, subject TEXT, body TEXT, reply_to INTEGER, recipients TEXT);
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS deliveries (
          message_id INTEGER, agent TEXT, created_at TEXT, acked_at TEXT,
          PRIMARY KEY (message_id, agent));
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_del ON deliveries(agent);")
        // The long-poll path only asks "is there anything unread?", so give that
        // question an index that does not have to scan a long history of read rows.
        exec("CREATE INDEX IF NOT EXISTS idx_del_unread ON deliveries(agent, acked_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_thread ON messages(thread_id);")
    }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ binds: [String?]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            FileHandle.standardError.write("chatbox: sql error: \(String(cString: sqlite3_errmsg(db)))\n".data(using: .utf8)!)
            return nil
        }
        for (i, v) in binds.enumerated() {
            if let v = v { sqlite3_bind_text(st, Int32(i + 1), v, -1, TRANSIENT) }
            else { sqlite3_bind_null(st, Int32(i + 1)) }
        }
        return st
    }

    /// Run a statement; returns last_insert_rowid (or -1).
    @discardableResult
    func run(_ sql: String, _ binds: [String?] = []) -> Int64 {
        guard let st = prepare(sql, binds) else { return -1 }
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            FileHandle.standardError.write("chatbox: step error: \(String(cString: sqlite3_errmsg(db)))\n".data(using: .utf8)!)
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Query rows as dictionaries.
    func rows(_ sql: String, _ binds: [String?] = []) -> [[String: String]] {
        guard let st = prepare(sql, binds) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [[String: String]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var row: [String: String] = [:]
            let n = sqlite3_column_count(st)
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(st, i))
                if let c = sqlite3_column_text(st, i) { row[name] = String(cString: c) }
                else { row[name] = "" }
            }
            out.append(row)
        }
        return out
    }

    /// One scalar as String.
    func scalar(_ sql: String, _ binds: [String?] = []) -> String {
        rows(sql, binds).first?.values.first ?? ""
    }

    // MARK: domain helpers

    func owners(ofRepo repo: String) -> [String] {
        let all = rows("SELECT id, repos FROM agents")
        return all.filter { row in
            let repos = (row["repos"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return repos.contains(repo)
        }.map { $0["id"] ?? "" }.filter { !$0.isEmpty }
    }

    func agentsListing() -> [[String: String]] {
        rows("SELECT id, node, agent, harness, session, ip, repos, note, registered_at, last_seen FROM agents ORDER BY id")
    }

    /// Cheap "is there anything unread?" for the long-poll path — one indexed
    /// lookup instead of the full inbox join, which is what makes a waiter cheap
    /// even when the session has a long history of already-read mail.
    func hasUnread(forAgent agent: String) -> Bool {
        !rows("""
        SELECT 1 FROM deliveries
        WHERE agent = ? AND (acked_at IS NULL OR acked_at = '') LIMIT 1
        """, [agent]).isEmpty
    }

    func deliveries(forAgent agent: String, includeAcked: Bool) -> [[String: String]] {
        let sql = """
        SELECT m.id AS id, m.thread_id AS thread, m.created_at AS at, m.sender AS sender,
               m.repo AS repo, m.subject AS subject, m.body AS body,
               d.acked_at AS acked
        FROM deliveries d JOIN messages m ON m.id = d.message_id
        WHERE d.agent = ? \(includeAcked ? "" : "AND (d.acked_at IS NULL OR d.acked_at = '')")
        ORDER BY m.id DESC LIMIT 200
        """
        return rows(sql, [agent])
    }

    func thread(_ id: String) -> [[String: String]] {
        rows("""
        SELECT id, thread_id, created_at, sender, repo, subject, body, reply_to, recipients
        FROM messages WHERE thread_id = ? ORDER BY id ASC
        """, [id])
    }
}

// MARK: - Request

struct Request {
    var method = "GET"
    var path = "/"
    var params: [String: String] = [:]
    var token: String?

    func p(_ key: String, _ def: String = "") -> String {
        (params[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? def)
    }
}

private func percentDecode(_ s: String) -> String {
    s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
}

private func parseForm(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if kv.count == 2 { out[percentDecode(String(kv[0]))] = percentDecode(String(kv[1])) }
        else if kv.count == 1 { out[percentDecode(String(kv[0]))] = "" }
    }
    return out
}

// MARK: - Server

final class Chatbox: @unchecked Sendable {
    let store: Store
    let token: String?
    let queue = DispatchQueue(label: "chatbox.queue")

    init(store: Store, token: String?) {
        self.store = store
        self.token = token
    }

    // ---------- routing ----------

    /// nil when the request may proceed; otherwise the rejection to send back.
    func unauthorized(_ req: Request) -> (Int, String)? {
        if let required = token, required != "open", req.token != required {
            return (401, "unauthorized: pass ?token= or Authorization: Bearer\n")
        }
        return nil
    }

    /// Route a parsed request — including the one route that answers later.
    func dispatch(_ req: Request, conn: NWConnection) {
        if let (status, body) = unauthorized(req) {
            finish(req, conn: conn, status: status, body: body)
            return
        }
        if req.method == "GET", req.path == "/inbox" {
            let wait = waitSeconds(req)
            if wait > 0 { beginInboxWait(req, seconds: wait, conn: conn); return }
        }
        let (status, body) = handle(req)
        finish(req, conn: conn, status: status, body: body)
    }

    func handle(_ req: Request) -> (Int, String) {
        if let rejection = unauthorized(req) { return rejection }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/help"): return (200, usage(Self.publicURL))
        case ("GET", "/health"): return (200, health())
        case ("POST", "/register"): return register(req)
        case ("POST", "/message"), ("POST", "/say"): return message(req)
        case ("GET", "/inbox"): return inbox(req)
        case ("GET", "/thread"): return showThread(req)
        case ("GET", "/threads"): return listThreads(req)
        case ("POST", "/ack"): return ack(req)
        case ("GET", "/peers"): return peers(req)
        default: return (404, "not found: \(req.method) \(req.path)\n\n" + usage(Self.publicURL))
        }
    }

    static var publicURL = "http://<host>:8787"

    func usage(_ url: String) -> String {
        """
        chatbox — harness-independent session chatbox (text only, no file access)

        Register once, then talk about repos by key.
          register  POST /register?id=<you>&node=<mac>&agent=<dsh|codex|claude>&session=<id>&repos=github.com/acme/libfoo&ip=<ip>
          say       POST /message?from=<you>&repo=<repo-key>&subject=<line>&body=<text>
          reply     POST /message?from=<you>&thread=<id>&body=<text>
          inbox     GET  /inbox?id=<you>            (add &all=1 to include read)
                    add &wait=<seconds> to hold until a message arrives (max 300; empty body on timeout)
          read      GET  /thread?id=<thread-id>
          ack       POST /ack?id=<you>&message=<message-id>
          peers     GET  /peers                     (who owns what)
          health    GET  /health

        Bodies accept JSON or form-encoding, or plain text: curl -d 'text' '\(url)/say?from=x&repo=y'
        Add &json=1 to any GET for structured output. Auth: ?token=<secret> (or Authorization: Bearer).
        """
    }

    func health() -> String {
        let a = store.scalar("SELECT COUNT(*) FROM agents")
        let t = store.scalar("SELECT COUNT(*) FROM threads")
        let m = store.scalar("SELECT COUNT(*) FROM messages")
        return "ok chatbox up\nagents: \(a)\nthreads: \(t)\nmessages: \(m)\nnow: \(nowISO())\n"
    }

    func register(_ req: Request) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("from") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required (who you are, e.g. node1-dsh-abc)\n") }
        let repos = req.p("repos").isEmpty ? req.p("repo") : req.p("repos")
        let ts = nowISO()
        let existing = store.scalar("SELECT id FROM agents WHERE id = ?", [id])
        if existing.isEmpty {
            store.run("INSERT INTO agents (id,node,agent,harness,session,ip,repos,note,registered_at,last_seen) VALUES (?,?,?,?,?,?,?,?,?,?)",
                      [id, req.p("node"), req.p("agent"), req.p("harness"), req.p("session"), req.p("ip"), repos, req.p("note"), ts, ts])
        } else {
            store.run("""
            UPDATE agents SET node=?, agent=?, harness=?, session=?, ip=?,
              repos=CASE WHEN ?='' THEN repos ELSE ? END, note=?, last_seen=? WHERE id=?
            """, [req.p("node"), req.p("agent"), req.p("harness"), req.p("session"), req.p("ip"), repos, repos, req.p("note"), ts, id])
        }
        return (200, """
        ok registered
        id: \(id)
        node: \(req.p("node","-"))  agent: \(req.p("agent","-"))  session: \(req.p("session","-"))
        ip: \(req.p("ip","-"))  harness: \(req.p("harness","-"))
        repos: \(repos.isEmpty ? "(none declared)" : repos)
        at: \(ts)

        Next: POST /message?from=\(id)&repo=<repo>&subject=<...>&body=<...>
        """)
    }

    func message(_ req: Request) -> (Int, String) {
        let from = req.p("from").isEmpty ? req.p("id") : req.p("from")
        guard !from.isEmpty else { return (400, "error: from required\n") }
        var body = req.p("body")
        if body.isEmpty { body = req.p("text") }
        if body.isEmpty { body = req.p("message") }
        let subject = req.p("subject")
        let repo = req.p("repo")
        let threadIn = req.p("thread")
        let toExplicit = req.p("to")
        guard !body.isEmpty || !subject.isEmpty else { return (400, "error: body (or text) required\n") }

        // keep the sender's liveness fresh
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), from])

        var threadId: Int64
        var effRepo = repo
        if !threadIn.isEmpty, let t = Int64(threadIn), t > 0 {
            threadId = t
            // a reply inherits the thread's repo so routing stays consistent
            if effRepo.isEmpty { effRepo = store.scalar("SELECT repo FROM threads WHERE id = ?", [threadIn]) }
        } else {
            threadId = store.run("INSERT INTO threads (repo,subject,created_at,created_by,last_at) VALUES (?,?,?,?,?)",
                                 [repo, subject, nowISO(), from, nowISO()])
        }
        guard threadId > 0 else { return (500, "error: could not open thread\n") }

        // resolve recipients: explicit, else thread participants plus the repo's owners
        var recipients: [String] = []
        if !toExplicit.isEmpty {
            recipients = toExplicit.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            var set = Set<String>()
            if !effRepo.isEmpty { set.formUnion(store.owners(ofRepo: effRepo)) }
            if !threadIn.isEmpty {
                for m in store.thread(String(threadId)) {
                    if let s = m["sender"], !s.isEmpty { set.insert(s) }
                    for r in (m["recipients"] ?? "").split(separator: ",") {
                        let t = r.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { set.insert(t) }
                    }
                }
            }
            recipients = Array(set).sorted()
        }
        recipients = recipients.filter { $0 != from }

        let replyTo = Int64(req.p("reply_to")) ?? 0
        let msgId = store.run("""
        INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,reply_to,recipients)
        VALUES (?,?,?,?,?,?,?,?)
        """, [String(threadId), nowISO(), from, effRepo, subject, body, replyTo == 0 ? nil : String(replyTo), recipients.joined(separator: ",")])

        for r in recipients {
            store.run("INSERT OR IGNORE INTO deliveries (message_id,agent,created_at) VALUES (?,?,?)",
                      [String(msgId), r, nowISO()])
        }
        store.run("UPDATE threads SET last_at=? WHERE id=?", [nowISO(), String(threadId)])

        var note = ""
        if recipients.isEmpty {
            note = effRepo.isEmpty
                ? "\nnote: no recipient — pass repo=<key>, to=<agent>, or thread=<id>\n"
                : "\nnote: nobody has registered as an owner of '\(effRepo)' yet; message stored in thread \(threadId)\n"
        }
        return (200, """
        ok posted
        message: \(msgId)
        thread: \(threadId)
        repo: \(effRepo.isEmpty ? "-" : effRepo)
        delivered_to: \(recipients.isEmpty ? "(nobody)" : recipients.joined(separator: ", "))
        at: \(nowISO())
        \(note)
        """)
    }

    func inbox(_ req: Request) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("for") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required\n") }
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
        let rows = store.deliveries(forAgent: id, includeAcked: !req.p("all").isEmpty)
        if rows.isEmpty { return (200, "inbox for \(id): empty\n") }
        return (200, renderInbox(req, id: id, rows: rows))
    }

    func renderInbox(_ req: Request, id: String, rows: [[String: String]]) -> String {
        if !req.p("json").isEmpty { return jsonArray(rows) }
        let all = !req.p("all").isEmpty
        var out = "inbox for \(id) — \(rows.count) message(s)\(all ? " (including read)" : " unread")\n"
        for r in rows {
            let unread = (r["acked"] ?? "").isEmpty
            out += "\n[\(r["id"] ?? "")]\(unread ? " UNREAD" : " read  ") thread \(r["thread"] ?? "")  \(r["at"] ?? "")\n"
            out += "  from: \(r["sender"] ?? "")   repo: \((r["repo"] ?? "").isEmpty ? "-" : r["repo"]!)\n"
            if !(r["subject"] ?? "").isEmpty { out += "  subject: \(r["subject"]!)\n" }
            let b = r["body"] ?? ""
            out += "  body: \(b.count > 1200 ? String(b.prefix(1200)) + " …[truncated]" : b)\n"
        }
        out += "\nread a thread: GET /thread?id=<thread>   ·   mark read: POST /ack?id=\(id)&message=<id>\n"
        return out
    }

    // ---------- long-poll inbox ----------

    /// `wait=<seconds>` — 0 when absent, zero, negative or unparseable. Capped so
    /// a client cannot pin a connection open indefinitely.
    func waitSeconds(_ req: Request) -> Int {
        guard let raw = Int(req.p("wait")), raw > 0 else { return 0 }
        return min(raw, maxWaitSeconds)
    }

    /// Hold the request open until the session has something to read, or until the
    /// deadline passes. This is what turns the board into a delivery bus: any
    /// agent with a shell can loop on `inbox --wait` and be woken on arrival,
    /// without anything installed in the harness.
    func beginInboxWait(_ req: Request, seconds: Int, conn: NWConnection) {
        // `dispatch` already checked, but this path answers later and is the only
        // route that does, so it re-checks rather than relying on the caller.
        if let (status, body) = unauthorized(req) {
            finish(req, conn: conn, status: status, body: body)
            return
        }
        let id = req.p("id").isEmpty ? req.p("for") : req.p("id")
        guard !id.isEmpty else {
            finish(req, conn: conn, status: 400, body: "error: id required\n")
            return
        }
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
        // The request has already been read, so anything that happens on this
        // socket now means the peer is going away. An *unclean* close releases the
        // waiter immediately. A clean EOF deliberately does not: a client is
        // entitled to half-close its write side and still wait for the answer, and
        // cancelling on EOF would silently deny it one. Either way the deadline
        // bounds how long an abandoned waiter lives.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
            if error != nil { conn.cancel() }
        }
        FileHandle.standardError.write(
            "chatbox: GET /inbox waiting up to \(seconds)s for \(id)\n".data(using: .utf8)!)
        let now = Date()
        pollInbox(req, id: id, deadline: now.addingTimeInterval(TimeInterval(seconds)),
                  nextTouch: now.addingTimeInterval(longPollTouchInterval), conn: conn)
    }

    /// Re-check on a timer until there is something to report or the deadline
    /// passes. Deliberately *not* a blocking wait: the re-check is scheduled, so
    /// the serial queue stays free and other requests are answered normally.
    private func pollInbox(_ req: Request, id: String, deadline: Date, nextTouch: Date,
                           conn: NWConnection) {
        // The client may have given up. A clean end-of-stream is *not* treated as
        // abandonment — see beginInboxWait.
        if case .cancelled = conn.state { return }
        if case .failed = conn.state { return }

        // A waiting session is provably alive, so keep last_seen fresh: otherwise a
        // long wait would make a healthy session look stale to the presence rules.
        var touch = nextTouch
        if Date() >= nextTouch {
            store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
            touch = Date().addingTimeInterval(longPollTouchInterval)
        }

        // Wait for something *unread*. `all=1` widens the payload once there is
        // something to report; it must not itself satisfy the wait, or a session
        // with read history would return instantly for ever and a wake loop would
        // spin with no backoff.
        if store.hasUnread(forAgent: id) {
            let rows = store.deliveries(forAgent: id, includeAcked: !req.p("all").isEmpty)
            finish(req, conn: conn, status: 200, body: renderInbox(req, id: id, rows: rows))
            return
        }
        if Date() >= deadline {
            // A timeout is not an error: an empty body means "nothing arrived".
            finish(req, conn: conn, status: 200, body: "")
            return
        }
        queue.asyncAfter(deadline: .now() + longPollInterval) {
            self.pollInbox(req, id: id, deadline: deadline, nextTouch: touch, conn: conn)
        }
    }

    func showThread(_ req: Request) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("thread") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id (thread) required\n") }
        let rows = store.thread(id)
        guard !rows.isEmpty else { return (404, "no thread \(id)\n") }
        if !req.p("json").isEmpty { return (200, jsonArray(rows)) }
        let head = store.rows("SELECT repo, subject, created_at, created_by FROM threads WHERE id=?", [id]).first ?? [:]
        var out = "thread \(id)  repo: \((head["repo"] ?? "").isEmpty ? "-" : head["repo"]!)  subject: \(head["subject"] ?? "-")\n"
        out += "opened: \(head["created_at"] ?? "-") by \(head["created_by"] ?? "-")   \(rows.count) message(s)\n"
        for r in rows {
            out += "\n--- [\(r["id"] ?? "")] \(r["created_at"] ?? "")  \(r["sender"] ?? "") → \((r["recipients"] ?? "").isEmpty ? "(nobody)" : r["recipients"]!)\n"
            if !(r["subject"] ?? "").isEmpty, r["id"] == rows.first?["id"] { out += "subject: \(r["subject"]!)\n" }
            if let rt = r["reply_to"], !rt.isEmpty, rt != "0" { out += "(reply to \(rt))\n" }
            out += "\(r["body"] ?? "")\n"
        }
        return (200, out)
    }

    func listThreads(_ req: Request) -> (Int, String) {
        let repo = req.p("repo")
        var sql = "SELECT t.id, t.repo, t.subject, t.created_at, t.last_at, (SELECT COUNT(*) FROM messages m WHERE m.thread_id=t.id) AS n FROM threads t"
        var binds: [String?] = []
        if !repo.isEmpty { sql += " WHERE t.repo = ?"; binds.append(repo) }
        sql += " ORDER BY t.last_at DESC LIMIT 100"
        let rows = store.rows(sql, binds)
        if rows.isEmpty { return (200, "no threads\(repo.isEmpty ? "" : " for \(repo)") yet\n") }
        if !req.p("json").isEmpty { return (200, jsonArray(rows)) }
        var out = "threads\(repo.isEmpty ? "" : " for \(repo)") — \(rows.count)\n"
        for r in rows {
            out += "\n[\(r["id"] ?? "")] \(r["last_at"] ?? "")  \(r["n"] ?? "0") msg  repo: \((r["repo"] ?? "").isEmpty ? "-" : r["repo"]!)\n  \(r["subject"] ?? "-")\n"
        }
        return (200, out)
    }

    func ack(_ req: Request) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("agent") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required\n") }
        var n = 0
        if !req.p("message").isEmpty {
            store.run("UPDATE deliveries SET acked_at=? WHERE agent=? AND message_id=?", [nowISO(), id, req.p("message")])
            n = 1
        } else if !req.p("thread").isEmpty {
            let msgs = store.thread(req.p("thread"))
            for m in msgs {
                store.run("UPDATE deliveries SET acked_at=? WHERE agent=? AND message_id=?", [nowISO(), id, m["id"] ?? ""])
                n += 1
            }
        } else {
            return (400, "error: pass message=<id> or thread=<id>\n")
        }
        return (200, "ok acked \(n) for \(id)\n")
    }

    func peers(_ req: Request) -> (Int, String) {
        let rows = store.agentsListing()
        if !req.p("json").isEmpty { return (200, jsonArray(rows)) }
        var out = "registered agents — \(rows.count)\n"
        for r in rows {
            out += "\n\(r["id"] ?? "")  (\(r["agent"] ?? "-") on \(r["node"] ?? "-"))\n"
            out += "  repos: \((r["repos"] ?? "").isEmpty ? "(none declared)" : r["repos"]!)\n"
            if !(r["ip"] ?? "").isEmpty || !(r["session"] ?? "").isEmpty {
                out += "  ip: \(r["ip"] ?? "-")  session: \(r["session"] ?? "-")  harness: \(r["harness"] ?? "-")\n"
            }
            out += "  last seen: \(r["last_seen"] ?? "-")\n"
        }
        return (200, out)
    }

    private func jsonArray(_ rows: [[String: String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "[]\n" }
        return s + "\n"
    }

    // ---------- HTTP plumbing ----------

    func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        var req = Request()
        guard parts.count >= 2 else { return nil }
        req.method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var contentType = ""
        for l in lines {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                if k == "content-length" { } // used below via raw length
                if k == "content-type" { contentType = v.lowercased() }
                if k == "authorization" {
                    if let r = v.range(of: "Bearer ") { req.token = String(v[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
                }
            }
        }
        // path + query
        if let q = target.firstIndex(of: "?") {
            req.path = String(target[target.startIndex..<q])
            req.params = parseForm(String(target[target.index(after: q)...]))
        } else {
            req.path = target
        }
        // body
        let bodyStart = headerEnd.upperBound
        let bodyData = buffer.subdata(in: bodyStart..<buffer.count)
        if !bodyData.isEmpty, let bodyString = String(data: bodyData, encoding: .utf8) {
            if contentType.contains("json"), let d = bodyString.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in obj { req.params[k] = "\(v)" }
            } else if contentType.contains("form") || bodyString.contains("=") {
                for (k, v) in parseForm(bodyString) where req.params[k] == nil { req.params[k] = v }
            }
            if req.params["body"] == nil && req.params["text"] == nil && req.params["message"] == nil && !req.params.keys.contains("subject") {
                req.params["body"] = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let t = req.params["token"], !t.isEmpty { req.token = t }
        return req
    }

    /// Log the outcome and answer. Every route ends here exactly once, whether it
    /// was answered inline or after a long-poll wait.
    func finish(_ req: Request, conn: NWConnection, status: Int, body: String) {
        FileHandle.standardError.write("chatbox: \(req.method) \(req.path) -> \(status)\n".data(using: .utf8)!)
        respond(conn, status: status, body: body)
    }

    func respond(_ conn: NWConnection, status: Int, body: String) {
        let reason = status == 200 ? "OK" : (status == 400 ? "Bad Request" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Error")))
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    func serve(conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .ready = state { self.receive(conn, buffer: Data()) }
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131072) { data, _, isComplete, error in
            var buf = buffer
            if let d = data { buf.append(d) }
            if let req = self.parse(buf) {
                self.dispatch(req, conn: conn)
                return
            }
            if error != nil || isComplete || buf.count > 4_000_000 { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }
}

// MARK: - main

func argValue(_ name: String, _ def: String) -> String {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}

let port = UInt16(argValue("--port", "8787")) ?? 8787
let dbPath = argValue("--db", NSString(string: "~/chatbox.sqlite").expandingTildeInPath)
let tokenArg = argValue("--token", "")
let tokenFile = argValue("--token-file", "")
// Prefer --token-file: a token passed as argv is visible to every local user in `ps`.
let tokenFromFile: String = {
    guard !tokenFile.isEmpty else { return "" }
    let p = NSString(string: tokenFile).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}()
let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)

let store = Store(path: dbPath)
let server = Chatbox(store: store, token: token)
Chatbox.publicURL = "http://\(Host.current().name ?? "localhost"):\(port)"

let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
let listener: NWListener
do {
    listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
} catch {
    FileHandle.standardError.write("chatbox: cannot listen on \(port): \(error)\n".data(using: .utf8)!)
    exit(1)
}
listener.newConnectionHandler = { conn in server.serve(conn: conn) }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let addrs = Host.current().addresses.filter { $0.contains(".") }
        print("chatbox listening on port \(port)")
        print("db: \(dbPath)")
        print("auth: \(token == nil ? "OPEN (no token)" : "token required")")
        for a in addrs { print("  http://\(a):\(port)/") }
    case .failed(let e):
        FileHandle.standardError.write("chatbox: listener failed: \(e)\n".data(using: .utf8)!)
        exit(1)
    default: break
    }
}
listener.start(queue: server.queue)
dispatchMain()
