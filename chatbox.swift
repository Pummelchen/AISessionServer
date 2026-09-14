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
//        [--stale-after SECONDS]   (default 604800 = 7 days; 0 disables)
//
// Every response is plain text by default (readable by any model); add ?json=1
// for structured output.

import CryptoKit
import Foundation
import Network
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Long-poll tuning. A held inbox request is served by re-checking on this
// interval rather than by blocking, so a waiter never occupies the server's
// serial queue and every other request is answered normally while it waits.
private let longPollInterval: TimeInterval = 0.25
private let maxWaitSeconds = 300
/// How often a held waiter refreshes `last_seen`, at most. It is capped by the
/// staleness window: refreshing every 60s would report a live waiter as stale
/// whenever the window is shorter than that.
private func longPollTouchInterval(_ staleAfter: Int) -> TimeInterval {
    if staleAfter <= 0 { return 60 }
    return min(60, max(1, Double(staleAfter) / 2))
}

private func nowISO() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}

/// Credentials are stored only as a SHA-256 of the secret. The secrets are 192 bits
/// of randomness, so a fast hash is the right tool — there is nothing to brute
/// force, and a slow KDF would only make every request expensive.
private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A repo key names one repository. Wildcards and whitespace are never valid, and
/// allowing them would let a namespace pattern be claimed as a literal key.
/// Loopback traffic never leaves the machine, so a secret on it is not exposed to
/// the network. Everything else is only as private as the transport.
private func isLoopback(_ host: String) -> Bool {
    host.hasPrefix("127.") || host == "::1" || host.hasPrefix("[::1]") || host == "localhost"
}

/// A PKCS#12 bundle is the one identity format that can be loaded without a
/// keychain: `SecPKCS12Import` returns an in-memory `SecIdentity`, and
/// `sec_identity_create` turns it into what the TLS options want. Every symbol here
/// is re-exported through `Network`, so the server still imports nothing beyond
/// Foundation, Network and SQLite3.
///
/// A failure is reported and returns nil; the caller must refuse to start, because
/// a misspelt path that quietly served plaintext is the worst possible outcome for
/// a flag whose entire purpose is encryption.
func loadTLSIdentity(p12Path: String, password: String) -> sec_identity_t? {
    let p = NSString(string: p12Path).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: p) else {
        FileHandle.standardError.write("chatbox: cannot read --tls-identity \(p)\n".data(using: .utf8)!)
        return nil
    }
    var items: CFArray?
    var opts: [String: Any] = [kSecImportExportPassphrase as String: password]
    if #available(macOS 15.0, *) {
        // Documented to keep the imported key out of the default keychain. Without it
        // macOS copies the private key into the login keychain, which is a surprise for
        // an operator and a problem for a server started from launchd or over ssh.
        opts[kSecImportToMemoryOnly as String] = true
    }
    let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
    // The status is not the answer. macOS returns -26276 for a bundle it imported
    // perfectly well — measured against identities produced by LibreSSL, OpenSSL 3 and
    // `security export` alike — so the question is whether an identity came out, and
    // the status is only worth printing when none did.
    guard let list = items as? [[String: Any]] else {
        FileHandle.standardError.write("chatbox: cannot open --tls-identity \(p): OSStatus \(status) — wrong password, or not a PKCS#12 bundle\n".data(using: .utf8)!)
        return nil
    }
    var identities: [SecIdentity] = []
    for item in list {
        // Type-checked rather than `as!`: the contract says the value is an identity,
        // but a bundle that says otherwise should be a diagnostic, not a trap.
        if let raw = item[kSecImportItemIdentity as String] {
            let cf = raw as CFTypeRef
            if CFGetTypeID(cf) == SecIdentityGetTypeID() { identities.append(cf as! SecIdentity) }
        }
    }
    // Exactly one. A bundle holding several makes the choice arbitrary, and the
    // arbitrary one is presented along with its private key — an operator who bundled
    // a CA or a client-auth key next to the server key would publish the wrong one.
    guard identities.count == 1 else {
        FileHandle.standardError.write("chatbox: --tls-identity \(p) holds \(identities.count) identities — a server identity must be the only one in the bundle (OSStatus \(status))\n".data(using: .utf8)!)
        return nil
    }
    return sec_identity_create(identities[0])
}

private func hasControlByte(_ s: String) -> Bool {
    for scalar in s.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F { return true }
    return false
}

/// A repo key is a name, not a pattern and not a paragraph. `*` and `?` would let a
/// namespace pattern match itself; a line break is worse, because every response
/// that echoes a key — a routing note, a `peers` listing, a delivery list — would
/// then be forgeable from the repo name alone, which is the sender's to choose.
private func validRepoKey(_ repo: String) -> Bool {
    if repo.isEmpty { return false }
    for bad in ["*", "?", "[", "]", " ", "\t"] where repo.contains(bad) { return false }
    return !hasControlByte(repo)
}

/// An agent id is a routing key that gets echoed into text: into `peers`, into a
/// delivery list, into "nobody owns this repo" notes. One line by construction.
private func validId(_ id: String) -> Bool {
    if id.isEmpty { return false }
    return !hasControlByte(id)
}

/// Echoing a rejected value back is useful; echoing its line breaks is not, because
/// the message is printed by clients and read by whatever is driving them.
private func oneLine(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F { out.append(" ") } else { out.unicodeScalars.append(scalar) }
    }
    return out
}

/// Shared between the connection watcher and the poll loop. Both run on the
/// server's serial queue, so no locking is needed.
final class Waiter {
    /// The peer has finished sending. It may still be reading (a half-close is
    /// legitimate), so the request is still answered — but it is no longer evidence
    /// that anyone is there, so `last_seen` stops being refreshed.
    var peerGone = false
}

/// A compact duration for operator-facing text, floored: `7d`, `3h`, `90s` -> `1m`.
private func humanSeconds(_ seconds: Int) -> String {
    if seconds <= 0 { return "0s" }
    if seconds >= 86400 { return "\(seconds / 86400)d" }
    if seconds >= 3600 { return "\(seconds / 3600)h" }
    if seconds >= 60 { return "\(seconds / 60)m" }
    return "\(seconds)s"
}

private func randomHex(_ bytes: Int) -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
}

/// Who is making a request. The shared token stays a bootstrap credential and is
/// unrestricted; every other credential belongs to one machine and carries the
/// repo namespaces it may claim.
struct Principal {
    var isBootstrap: Bool
    var tokenId = ""
    var node = ""
    var namespaces: [String] = []

    static let bootstrap = Principal(isBootstrap: true)

    /// `*` allows any repo, `host/owner/*` allows a prefix, anything else is exact.
    static func namespace(_ ns: String, allows repo: String) -> Bool {
        if ns == "*" { return true }
        if ns.hasSuffix("/*") { return repo.hasPrefix(String(ns.dropLast())) }
        return repo == ns
    }

    func mayClaim(repo: String) -> Bool {
        isBootstrap || namespaces.contains { Principal.namespace($0, allows: repo) }
    }

    func mayClaim(node wanted: String) -> Bool {
        isBootstrap || wanted == node
    }
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
        exec("""
        CREATE TABLE IF NOT EXISTS tokens (
          id TEXT PRIMARY KEY, hash TEXT NOT NULL, node TEXT, namespaces TEXT,
          note TEXT, created_at TEXT, last_used TEXT, revoked_at TEXT);
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_tokens_hash ON tokens(hash);")
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

    // MARK: credentials

    func tokenByHash(_ hash: String) -> [String: String]? {
        rows("""
        SELECT id, node, namespaces, last_used, revoked_at FROM tokens WHERE hash = ? LIMIT 1
        """, [hash]).first
    }

    func addToken(id: String, hash: String, node: String, namespaces: String, note: String, at: String) {
        run("INSERT INTO tokens (id,hash,node,namespaces,note,created_at) VALUES (?,?,?,?,?,?)",
            [id, hash, node, namespaces, note, at])
    }

    func tokenExists(_ id: String) -> Bool {
        !rows("SELECT 1 FROM tokens WHERE id = ? LIMIT 1", [id]).isEmpty
    }

    func unreadCount(forAgent agent: String) -> Int {
        Int(scalar("""
        SELECT COUNT(*) FROM deliveries
        WHERE agent = ? AND (acked_at IS NULL OR acked_at = '')
        """, [agent])) ?? 0
    }

    func revokeToken(_ id: String, at: String) {
        run("UPDATE tokens SET revoked_at=? WHERE id=? AND (revoked_at IS NULL OR revoked_at='')", [at, id])
    }

    func touchToken(_ id: String, at: String) {
        run("UPDATE tokens SET last_used=? WHERE id=?", [at, id])
    }

    func tokensListing() -> [[String: String]] {
        rows("""
        SELECT id, node, namespaces, note, created_at, last_used, revoked_at
        FROM tokens ORDER BY created_at, id
        """)
    }

    /// Empty when the session has never registered.
    func lastSeen(of id: String) -> String {
        scalar("SELECT last_seen FROM agents WHERE id = ?", [id])
    }

    /// nil when the session has never registered.
    func nodeOf(_ id: String) -> String? {
        rows("SELECT node FROM agents WHERE id = ? LIMIT 1", [id]).first.map { $0["node"] ?? "" }
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
    /// Set when ?token= and Authorization: Bearer disagree.
    var tokenConflicts = false
    /// Set when the request asks for chunked framing. This server reads a body by its
    /// `Content-Length` and nothing else, so a chunked body is refused rather than
    /// half-read: the alternative is storing the framing itself as the message.
    var chunked = false
    /// The peer address, when the server could determine it. Used to warn when a
    /// freshly issued secret crosses a network in the clear.
    var peer = ""

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
    /// How long a session may go unheard from before it is reported stale. Zero
    /// disables staleness reporting entirely.
    let staleAfter: Int
    /// Whether the listener is serving TLS. It changes two things the server says:
    /// the transport line in `/health`, and whether issuing a credential off
    /// loopback is worth warning about.
    let tlsEnabled: Bool
    /// The largest request the server will read, in bytes. The channel exists to carry a
    /// bug report between sessions, not a diff, so an unbounded post is the wrong shape
    /// as well as a memory risk. It bounds the whole envelope — request line, headers and
    /// body — because that is what actually arrives on the socket and what a sender
    /// controls; a message is the body inside it.
    let maxBody: Int
    let queue = DispatchQueue(label: "chatbox.queue")

    init(store: Store, token: String?, staleAfter: Int, tlsEnabled: Bool, maxBody: Int) {
        self.store = store
        self.token = token
        self.staleAfter = staleAfter
        self.tlsEnabled = tlsEnabled
        self.maxBody = maxBody
    }

    // ---------- presence ----------
    //
    // `last_seen` is refreshed by registering, sending, reading an inbox or acking,
    // and by a held long poll for as long as its peer is still connected — at most
    // once a minute, and more often when the window is shorter than that. So a
    // session past the window is one that has gone quiet, rather than one that is
    // merely waiting. Nothing is ever probed or evicted: this is an inference, and
    // the response says what the server believes rather than what it knows.

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// A timestamp this server did not write may still carry fractional seconds;
    /// failing to parse it would report a live session as never seen.
    static let isoTiny: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        iso.date(from: s) ?? isoTiny.date(from: s)
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
        if token == nil || token == "open" { return .ok(.bootstrap) }
        let presented = req.token ?? ""
        if !presented.isEmpty, presented == token { return .ok(.bootstrap) }
        guard !presented.isEmpty else {
            return .denied(401, "unauthorized: pass ?token= or Authorization: Bearer\n")
        }
        guard let row = store.tokenByHash(sha256Hex(presented)) else {
            return .denied(401, "unauthorized: unknown token\n")
        }
        if !(row["revoked_at"] ?? "").isEmpty {
            return .denied(401, "unauthorized: this credential has been revoked\n")
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
        return .ok(Principal(isBootstrap: false, tokenId: id, node: row["node"] ?? "",
                             namespaces: namespaces))
    }

    /// A scoped credential may only act as a session registered to its own machine.
    /// The bootstrap credential is unrestricted, which is what lets credentials be
    /// handed out one machine at a time without breaking anyone.
    func mayAct(as id: String, _ who: Principal) -> (Int, String)? {
        if who.isBootstrap { return nil }
        guard let node = store.nodeOf(id) else {
            return (403, "forbidden: that session is not registered — register it first with this machine's credential\n")
        }
        guard node == who.node else {
            return (403, "forbidden: this credential may not act as that session\n")
        }
        return nil
    }

    /// Route a parsed request — including the one route that answers later.
    func dispatch(_ req: Request, conn: NWConnection) {
        if req.chunked {
            finish(req, conn: conn, status: 400, body: "error: chunked bodies are not supported — send Content-Length\n")
            return
        }
        let who: Principal
        switch authorize(req) {
        case .denied(let status, let body):
            finish(req, conn: conn, status: status, body: body)
            return
        case .ok(let principal):
            who = principal
        }
        var req = req
        if case let .hostPort(host, _) = conn.endpoint { req.peer = "\(host)" }
        if req.method == "GET", req.path == "/inbox" {
            let wait = waitSeconds(req)
            if wait > 0 { beginInboxWait(req, who: who, seconds: wait, conn: conn); return }
        }
        let (status, body) = handle(req, who)
        finish(req, conn: conn, status: status, body: body)
    }

    func handle(_ req: Request, _ who: Principal) -> (Int, String) {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/help"): return (200, usage(Self.publicURL))
        case ("GET", "/health"): return (200, health())
        case ("POST", "/register"): return register(req, who)
        case ("POST", "/message"), ("POST", "/say"): return message(req, who)
        case ("GET", "/inbox"): return inbox(req, who)
        case ("GET", "/thread"): return showThread(req)
        case ("GET", "/threads"): return listThreads(req)
        case ("POST", "/ack"): return ack(req, who)
        case ("GET", "/peers"): return peers(req)
        case ("POST", "/token"): return createToken(req, who)
        case ("GET", "/token"): return listTokens(req, who)
        case ("POST", "/token/revoke"): return revokeToken(req, who)
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
          ack       POST /ack?id=<you>&message=<message-id>   (or &thread=<id>, or &all=1 for everything unread)
          peers     GET  /peers                     (who owns what)
          health    GET  /health

        Credentials — issuing is restricted to the bootstrap token:
          token     POST /token?node=<mac>&namespaces=github.com/acme/*&note=<text>   (secret shown once)
          tokens    GET  /token                     (list; never shows secrets)
          revoke    POST /token/revoke?id=<tk-id>   (effective immediately, no restart)

        A scoped credential may only act as a session registered to its own node,
        and may only claim repos inside its namespaces. It can still send to any
        repo, which is the point: "whoever owns <repo>, I have a bug to discuss".

        Bodies accept JSON or form-encoding, or plain text: curl -d 'text' '\(url)/say?from=x&repo=y'
        Add &json=1 to any GET for structured output. Auth: ?token=<secret> (or Authorization: Bearer).
        """
    }

    func health() -> String {
        let a = store.scalar("SELECT COUNT(*) FROM agents")
        let t = store.scalar("SELECT COUNT(*) FROM threads")
        let m = store.scalar("SELECT COUNT(*) FROM messages")
        let presence = staleAfter == 0 ? "off" : "stale after \(humanSeconds(staleAfter))"
        let transport = tlsEnabled ? "tls" : "plain http"
        return "ok chatbox up\nagents: \(a)\nthreads: \(t)\nmessages: \(m)\npresence: \(presence)\ntransport: \(transport)\nmax request: \(maxBody) bytes\nnow: \(nowISO())\n"
    }

    func register(_ req: Request, _ who: Principal) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("from") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required (who you are, e.g. node1-dsh-abc)\n") }
        guard validId(id) else { return (400, "error: id must be a single line, without control characters\n") }
        let node = req.p("node")
        let repos = req.p("repos").isEmpty ? req.p("repo") : req.p("repos")
        // What the session will own *after* the upsert. An omitted repos= preserves
        // the stored value, and that stored value has to be inside this credential's
        // namespaces too — otherwise a scoped credential could re-register a session
        // and inherit a claim it was never allowed to make.
        let kept = store.scalar("SELECT repos FROM agents WHERE id = ?", [id])
        let effectiveRepos = repos.isEmpty ? kept : repos

        // A repo key is a name, not a pattern. Refusing wildcards here also stops a
        // namespace pattern such as `acme/*` from matching *itself* and being
        // claimed as a literal repo key, which would route real mail to it.
        for claimed in repos.split(separator: ",") {
            let repo = claimed.trimmingCharacters(in: .whitespaces)
            if repo.isEmpty { continue }
            guard validRepoKey(repo) else {
                return (400, "error: '\(oneLine(repo))' is not a valid repo key — keys name a repo, are one line, and do not contain '*' or '?'\n")
            }
        }

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
                    return (403, "forbidden: this credential may not claim '\(repo)'"
                        + (who.namespaces.isEmpty
                            ? " (it may claim no repos)\n"
                            : " — allowed: \(who.namespaces.joined(separator: ", "))\n"))
                }
            }
        }
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

    func message(_ req: Request, _ who: Principal) -> (Int, String) {
        let from = req.p("from").isEmpty ? req.p("id") : req.p("from")
        guard !from.isEmpty else { return (400, "error: from required\n") }
        guard validId(from) else { return (400, "error: from must be a single line, without control characters\n") }
        if let rejection = mayAct(as: from, who) { return rejection }
        var body = req.p("body")
        if body.isEmpty { body = req.p("text") }
        if body.isEmpty { body = req.p("message") }
        let subject = req.p("subject")
        let repo = req.p("repo")
        let threadIn = req.p("thread")
        let toExplicit = req.p("to")
        guard !body.isEmpty || !subject.isEmpty else { return (400, "error: body (or text) required\n") }
        // Register has always refused a malformed key; the send path did not, so a key
        // could be stored on a thread and then echoed back by every later reply.
        guard repo.isEmpty || validRepoKey(repo) else {
            return (400, "error: '\(oneLine(repo))' is not a valid repo key — keys name a repo, are one line, and do not contain '*' or '?'\n")
        }
        for one in toExplicit.split(separator: ",") {
            let t = one.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard validId(t) else { return (400, "error: to must name ids that are single lines, without control characters\n") }
        }

        // keep the sender's liveness fresh
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), from])

        var threadId: Int64
        var effRepo = repo
        if !threadIn.isEmpty, let t = Int64(threadIn), t > 0 {
            threadId = t
            // a reply inherits the thread's repo so routing stays consistent
            if effRepo.isEmpty { effRepo = store.scalar("SELECT repo FROM threads WHERE id = ?", [threadIn]) }
            // A thread stored before the send path validated its key must not become a
            // way to echo that key back: it is dropped rather than repeated.
            if !effRepo.isEmpty && !validRepoKey(effRepo) { effRepo = "" }
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
        // An explicit to=a,b,a should not deliver, mark or warn twice.
        var already = Set<String>()
        recipients = recipients.filter { already.insert($0).inserted }

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

        // A report sent to a machine that has gone away is still stored, but the
        // sender deserves to know nobody is likely to read it.
        let now = Date()
        // A recipient nobody is listening for: gone quiet, or never registered at all.
        let unseen = recipients.filter { isStale(store.lastSeen(of: $0), now: now) }
        func unseenLabel(_ id: String) -> String {
            store.lastSeen(of: id).isEmpty ? "unregistered" : "stale"
        }
        func unseenReason(_ id: String) -> String {
            let seen = store.lastSeen(of: id)
            return seen.isEmpty ? "never registered" : ageDescription(seen, now: now)
        }
        let deliveredTo = recipients.map { r in
            unseen.contains(r) ? "\(r) (\(unseenLabel(r)))" : r
        }.joined(separator: ", ")

        var note = ""
        if recipients.isEmpty {
            note = effRepo.isEmpty
                ? "\nnote: no recipient — pass repo=<key>, to=<agent>, or thread=<id>\n"
                : "\nnote: nobody has registered as an owner of '\(effRepo)' yet; message stored in thread \(threadId)\n"
        }
        if !unseen.isEmpty {
            let who = unseen.map { "\($0) (\(unseenReason($0)))" }.joined(separator: ", ")
            // Only claim nobody will read it when nobody is left to.
            let everyone = unseen.count == recipients.count
            note += "\nwarning: no sign of \(who) inside the \(humanSeconds(staleAfter)) staleness window"
                + (everyone
                    ? " — the message is stored, but nobody may read it\n"
                    : " — the message is stored, but it may not reach "
                      + (unseen.count == 1 ? "that session" : "those sessions") + "\n")
        }
        return (200, """
        ok posted
        message: \(msgId)
        thread: \(threadId)
        repo: \(effRepo.isEmpty ? "-" : effRepo)
        delivered_to: \(recipients.isEmpty ? "(nobody)" : deliveredTo)
        at: \(nowISO())
        \(note)
        """)
    }

    func inbox(_ req: Request, _ who: Principal) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("for") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required\n") }
        guard validId(id) else { return (400, "error: id must be a single line, without control characters\n") }
        if let rejection = mayAct(as: id, who) { return rejection }
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
            "chatbox: GET /inbox waiting up to \(seconds)s for \(id)\n".data(using: .utf8)!)
        let now = Date()
        pollInbox(req, id: id, deadline: now.addingTimeInterval(TimeInterval(seconds)),
                  nextTouch: now.addingTimeInterval(longPollTouchInterval(staleAfter)),
                  waiter: waiter, conn: conn)
    }

    /// Re-check on a timer until there is something to report or the deadline
    /// passes. Deliberately *not* a blocking wait: the re-check is scheduled, so
    /// the serial queue stays free and other requests are answered normally.
    private func pollInbox(_ req: Request, id: String, deadline: Date, nextTouch: Date,
                           waiter: Waiter, conn: NWConnection) {
        // The client may have given up. A clean end-of-stream is *not* treated as
        // abandonment — see beginInboxWait.
        if case .cancelled = conn.state { return }
        if case .failed = conn.state { return }

        // Re-authorize every tick. A wait can last five minutes, and revoking a
        // credential has to end it rather than let it keep delivering.
        switch authorize(req) {
        case .denied(let status, let body):
            finish(req, conn: conn, status: status, body: body)
            return
        case .ok:
            break
        }

        // A waiting session that is still connected is alive, so keep last_seen
        // fresh — otherwise a long wait would make it look stale. Once the peer has
        // finished sending there is no evidence it is still there, so it stops being
        // refreshed and the session ages normally.
        var touch = nextTouch
        if !waiter.peerGone, Date() >= nextTouch {
            store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
            touch = Date().addingTimeInterval(longPollTouchInterval(staleAfter))
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
            self.pollInbox(req, id: id, deadline: deadline, nextTouch: touch,
                           waiter: waiter, conn: conn)
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

    func ack(_ req: Request, _ who: Principal) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("agent") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id required\n") }
        guard validId(id) else { return (400, "error: id must be a single line, without control characters\n") }
        if let rejection = mayAct(as: id, who) { return rejection }
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
        var n = 0
        if !req.p("message").isEmpty {
            store.run("UPDATE deliveries SET acked_at=? WHERE agent=? AND message_id=?", [nowISO(), id, req.p("message")])
            n = 1
        } else if !req.p("all").isEmpty {
            n = store.unreadCount(forAgent: id)
            store.run("""
            UPDATE deliveries SET acked_at=? WHERE agent=? AND (acked_at IS NULL OR acked_at='')
            """, [nowISO(), id])
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
        var rows = store.agentsListing()
        let now = Date()
        for i in rows.indices {
            let seen = rows[i]["last_seen"] ?? ""
            rows[i]["status"] = staleAfter == 0 ? "unknown"
                : (isStale(seen, now: now) ? "stale" : "active")
            rows[i]["age"] = ageDescription(seen, now: now)
        }
        if !req.p("json").isEmpty { return (200, jsonArray(rows)) }
        var out = "registered agents — \(rows.count)\n"
        if staleAfter == 0 { out += "(staleness reporting is off)\n" }
        for r in rows {
            let status = r["status"] ?? "active"
            out += "\n\(r["id"] ?? "")  (\(r["agent"] ?? "-") on \(r["node"] ?? "-"))  \(status == "stale" ? "STALE" : status)\n"
            out += "  repos: \((r["repos"] ?? "").isEmpty ? "(none declared)" : r["repos"]!)\n"
            if !(r["ip"] ?? "").isEmpty || !(r["session"] ?? "").isEmpty {
                out += "  ip: \(r["ip"] ?? "-")  session: \(r["session"] ?? "-")  harness: \(r["harness"] ?? "-")\n"
            }
            out += "  last seen: \(r["last_seen"] ?? "-")  (\(r["age"] ?? "-"))\n"
        }
        return (200, out)
    }

    // ---------- credentials ----------
    //
    // Issuing and revoking lives behind the bootstrap credential. Scoped
    // credentials are never shown again after creation: only their SHA-256 is kept.

    func createToken(_ req: Request, _ who: Principal) -> (Int, String) {
        guard who.isBootstrap else {
            return (403, "forbidden: only the bootstrap credential may issue credentials\n")
        }
        let node = req.p("node")
        guard !node.isEmpty else {
            return (400, "error: node required (which machine this credential is for)\n")
        }
        let namespaces = req.p("namespaces").isEmpty ? req.p("namespace") : req.p("namespaces")
        let secret = randomHex(24)
        let id = "tk-" + randomHex(6)
        store.addToken(id: id, hash: sha256Hex(secret), node: node,
                       namespaces: namespaces, note: req.p("note"), at: nowISO())
        // CodeQL flags this response as cleartext transmission of sensitive data,
        // and without TLS it is right: the secret travels in the body. Loopback never
        // leaves the machine and a TLS listener is encrypted, so the warning is for
        // the one case that is actually exposed — a plain listener reached from
        // somewhere else.
        let exposure = tlsEnabled || req.peer.isEmpty || isLoopback(req.peer)
            ? ""
            : "\nwarning: this was issued over a non-loopback connection (\(req.peer)) with no TLS\n"
              + "         so the secret above crossed the network in the clear. Prefer issuing\n"
              + "         from the server itself, restart with --tls-identity, or terminate TLS\n"
              + "         in front of it (see the Deployment page).\n"
        return (200, """
        ok credential issued
        id: \(id)
        node: \(node)
        namespaces: \(namespaces.isEmpty ? "(none — this credential may claim no repos)" : namespaces)
        secret: \(secret)
        \(exposure)
        The secret is shown once and never stored — only its SHA-256 is. Put it in
        that machine's ~/.chatbox as CHATBOX_TOKEN, or pass it as ?token= / Bearer.
        Revoke it with: POST /token/revoke?id=\(id)
        """)
    }

    func listTokens(_ req: Request, _ who: Principal) -> (Int, String) {
        guard who.isBootstrap else {
            return (403, "forbidden: only the bootstrap credential may list credentials\n")
        }
        let rows = store.tokensListing()
        if rows.isEmpty { return (200, "no credentials issued\n") }
        if !req.p("json").isEmpty { return (200, jsonArray(rows)) }
        var out = "credentials — \(rows.count)\n"
        for r in rows {
            let revoked = !(r["revoked_at"] ?? "").isEmpty
            out += "\n\(r["id"] ?? "")  \(revoked ? "REVOKED" : "active")  node: \(r["node"] ?? "-")\n"
            out += "  namespaces: \((r["namespaces"] ?? "").isEmpty ? "(none)" : r["namespaces"]!)\n"
            out += "  issued: \(r["created_at"] ?? "-")   last used: \((r["last_used"] ?? "").isEmpty ? "never" : r["last_used"]!)\n"
            if !(r["note"] ?? "").isEmpty { out += "  note: \(r["note"]!)\n" }
            if revoked { out += "  revoked: \(r["revoked_at"]!)\n" }
        }
        return (200, out)
    }

    func revokeToken(_ req: Request, _ who: Principal) -> (Int, String) {
        guard who.isBootstrap else {
            return (403, "forbidden: only the bootstrap credential may revoke credentials\n")
        }
        let id = req.p("id").isEmpty ? req.p("token") : req.p("id")
        guard !id.isEmpty else {
            return (400, "error: id required (the credential id, e.g. tk-ab12cd)\n")
        }
        guard store.tokenExists(id) else { return (404, "no credential \(id)\n") }
        let already = store.scalar("SELECT revoked_at FROM tokens WHERE id = ?", [id])
        if !already.isEmpty {
            return (200, "ok \(id) was already revoked at \(already)\n")
        }
        store.revokeToken(id, at: nowISO())
        return (200, """
        ok revoked \(id)
        Every request presenting it is rejected from now on. Other credentials and
        the bootstrap credential are untouched, and no restart is needed.
        """)
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
        var declared = 0
        var sawLength = false
        for l in lines {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                // The first one wins, here and in `declaredLength`. Two of them are a
                // malformed request, and reading different ones in the two places is worse
                // than reading either: the cap would clear a request the parser then waits
                // on for ever.
                if k == "content-length" && !sawLength { declared = max(0, Int(v) ?? 0); sawLength = true }
                if k == "transfer-encoding" { req.chunked = true }
                if k == "content-type" { contentType = v.lowercased() }
                if k == "authorization" {
                    if let r = v.range(of: "Bearer ") { req.token = String(v[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
                }
            }
        }
        // Wait for the whole body before treating the request as arrived. Without this
        // the parser accepted it as soon as the headers were in, so a body that TCP split
        // across two reads was stored truncated — silently, and only for large messages,
        // which is exactly the sort a size cap exists to talk about.
        //
        // Compared by subtraction, not by adding the two: `Content-Length` is whatever a
        // peer typed, and `headerEnd.upperBound + Int.max` overflows — which is not a wrong
        // answer, it is a trap, and a board that one malformed request can kill. The first
        // of these bounds is already guaranteed (the terminator was found inside the
        // buffer), so the subtraction cannot go negative.
        guard buffer.count >= headerEnd.upperBound,
              buffer.count - headerEnd.upperBound >= declared else { return nil }
        // path + query
        if let q = target.firstIndex(of: "?") {
            req.path = String(target[target.startIndex..<q])
            req.params = parseForm(String(target[target.index(after: q)...]))
        } else {
            req.path = target
        }
        // body — exactly the declared bytes, and nothing that happens to be sitting behind
        // them. Treating trailing bytes as the body is how a peer that understates its
        // Content-Length got a truncated message stored and answered `200`: the tail it
        // sent later belongs to a request that was never made.
        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + declared
        let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
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
        // A query parameter and a header that disagree is a client bug, and silently
        // preferring one of them hides it.
        if let t = req.params["token"], !t.isEmpty, let h = req.token, h != t {
            req.tokenConflicts = true
        } else if let t = req.params["token"], !t.isEmpty {
            req.token = t
        }
        return req
    }

    /// Log the outcome and answer. Every route ends here exactly once, whether it
    /// was answered inline or after a long-poll wait.
    func finish(_ req: Request, conn: NWConnection, status: Int, body: String) {
        FileHandle.standardError.write("chatbox: \(req.method) \(req.path) -> \(status)\n".data(using: .utf8)!)
        respond(conn, status: status, body: body)
    }

    func respond(_ conn: NWConnection, status: Int, body: String) {
        let reason = status == 200 ? "OK"
            : (status == 400 ? "Bad Request"
            : (status == 401 ? "Unauthorized"
            : (status == 403 ? "Forbidden"
            : (status == 404 ? "Not Found"
            : (status == 413 ? "Payload Too Large" : "Error")))))
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
        // Never read far past the cap: the point of the limit is the memory, so the read
        // itself is bounded by it rather than by whatever the peer decides to send.
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(131_072, self.maxBody + 1)) { data, _, isComplete, error in
            var buf = buffer
            if let d = data { buf.append(d) }
            // The cap is checked *before* the parse, and that order is the whole point:
            // a request that happens to arrive in one read would otherwise be parsed and
            // answered before anything looked at its size, so the limit would only apply
            // to the requests that came in pieces. The read bound above is a memory
            // optimisation; this is the rule.
            let announced = self.declaredLength(buf) ?? 0
            if buf.count > self.maxBody || announced > self.maxBody {
                self.tooLarge(conn)
                return
            }
            if let req = self.parse(buf) {
                self.dispatch(req, conn: conn)
                return
            }
            if error != nil || isComplete { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    /// What a request's `Content-Length` says, or nil when its header block is not complete
    /// yet. Read separately from `parse` because the cap has to act on it *before* the body
    /// arrives: a peer that announces eight exabytes should be answered, not waited on until
    /// it gives up, and the announced size is also the earliest honest signal that a request
    /// is too big.
    private func declaredLength(_ buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) else { return nil }
        for l in head.components(separatedBy: "\r\n") {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    /// Answer rather than drop the connection: an oversized report is an ordinary mistake,
    /// and a sender that is told nothing has no way to learn what went wrong.
    private func tooLarge(_ conn: NWConnection) {
        FileHandle.standardError.write("chatbox: request over \(maxBody) bytes -> 413\n".data(using: .utf8)!)
        respond(conn, status: 413, body: """
        error: request too large — the limit is \(maxBody) bytes, and it covers the whole \
        request (request line, headers and body). Raise it with --max-body, or send the \
        report in a shorter form.

        """)
    }
}

// MARK: - main

/// The flags this server understands. Anything else on the command line is a
/// mistake, and the mistake that matters is a security flag: `--tls-identity=/path`
/// (the `=` form, which used to be ignored) and `--tls-identiy /path` (a typo) both
/// left the board serving plain HTTP behind a flag that looked like it had turned
/// encryption on. A flag nobody recognises now stops the server instead.
let knownFlags: Set<String> = ["--port", "--db", "--token", "--token-file", "--stale-after",
                              "--max-body", "--tls-identity", "--tls-password-file"]

func checkArguments(_ argv: [String]) {
    var seen = Set<String>()
    var i = 1
    while i < argv.count {
        let raw = argv[i]
        guard raw.hasPrefix("--") else {
            FileHandle.standardError.write("chatbox: unexpected argument '\(raw)'\n".data(using: .utf8)!)
            exit(2)
        }
        // `--name=value` is one token; `--name value` is two, and the value is whatever
        // follows — including something that looks like another flag, so skip it.
        let name = String(raw.prefix(while: { $0 != "=" }))
        let hasInlineValue = raw.contains("=")
        guard knownFlags.contains(name) else {
            FileHandle.standardError.write("chatbox: unknown flag '\(name)' — refusing to start rather than ignore it\n".data(using: .utf8)!)
            exit(2)
        }
        guard seen.insert(name).inserted else {
            FileHandle.standardError.write("chatbox: '\(name)' given more than once\n".data(using: .utf8)!)
            exit(2)
        }
        // Every flag here takes a value, so a trailing one is a mistake — and silently
        // falling back to the default is the same failure as a misspelt flag: the server
        // starts with a setting nobody asked for.
        if !hasInlineValue && i + 1 >= argv.count {
            FileHandle.standardError.write("chatbox: '\(name)' needs a value\n".data(using: .utf8)!)
            exit(2)
        }
        i += (hasInlineValue ? 1 : 2)
    }
}

func argValue(_ name: String, _ def: String) -> String {
    let args = CommandLine.arguments
    for (i, a) in args.enumerated() {
        if a == name, i + 1 < args.count { return args[i + 1] }
        if a.hasPrefix(name + "=") { return String(a.dropFirst(name.count + 1)) }
    }
    return def
}

/// Whether a flag was given at all, which `argValue` cannot say: it returns the
/// default both when the flag is absent and when it is present with no value.
func argPresent(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

checkArguments(CommandLine.arguments)

let port = UInt16(argValue("--port", "8787")) ?? 8787
let dbPath = argValue("--db", NSString(string: "~/chatbox.sqlite").expandingTildeInPath)
let tokenArg = argValue("--token", "")
let tokenFile = argValue("--token-file", "")
// Prefer --token-file: a token passed as argv is visible to every local user in `ps`.
let tokenFromFile: String = {
    guard !tokenFile.isEmpty else { return "" }
    let p = NSString(string: tokenFile).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
        FileHandle.standardError.write("chatbox: cannot read --token-file \(p)\n".data(using: .utf8)!)
        exit(1)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}()
// A token file that exists but is empty used to mean "no token", which silently
// started an OPEN board. Refuse instead: open mode must be asked for by name.
if !tokenFile.isEmpty && tokenFromFile.isEmpty {
    FileHandle.standardError.write("chatbox: --token-file \(tokenFile) is empty — refusing to start an open board\n".data(using: .utf8)!)
    exit(1)
}
let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)

let store = Store(path: dbPath)
let staleAfterRaw = argValue("--stale-after", "604800")
let staleAfterValue = Int(staleAfterRaw) ?? 604800
if staleAfterValue < 0 {
    // A negative window used to mean "off", which fails open on a typo.
    FileHandle.standardError.write("chatbox: --stale-after must be 0 (off) or a positive number of seconds\n".data(using: .utf8)!)
    exit(2)
}
let staleAfter = staleAfterValue

// A cap that is too small to hold a request line and its headers would refuse every
// request, which looks like a broken server rather than a configured one, so it is
// refused at startup instead. 512 is comfortably above the ~300 bytes a request with a
// bearer token needs.
let maxBodyRaw = argValue("--max-body", "8192")
let maxBodyValue = Int(maxBodyRaw) ?? 0
// A ceiling as well as a floor. The cap is what bounds memory, so a cap that is itself
// unbounded is not a cap: one connection then decides how much this server allocates.
// 4 MB is the guard the receive loop used to carry on its own.
let maxBodyCeiling = 4 * 1024 * 1024
if maxBodyValue < 512 || maxBodyValue > maxBodyCeiling {
    FileHandle.standardError.write("chatbox: --max-body must be between 512 and \(maxBodyCeiling) bytes (a request line and its headers need the floor; the ceiling is what bounds memory) — got '\(maxBodyRaw)'\n".data(using: .utf8)!)
    exit(2)
}
let maxBody = maxBodyValue

// TLS is opt-in, because turning it on changes the URL every client has to use.
// Everything about it fails closed: a password without an identity, an unreadable
// password file, an identity that will not open — each one stops the server rather
// than leaving it listening in the clear under a name that promised otherwise.
let tlsIdentityPath = argValue("--tls-identity", "")
let tlsPasswordFile = argValue("--tls-password-file", "")
// Present but unusable is a mistake, not a request for plain HTTP. `--tls-identity
// "$UNSET"` — or the flag left dangling at the end of argv — would otherwise start a
// cleartext board behind a flag that promised encryption, which is the exact failure
// the rest of this block exists to prevent.
if (argPresent("--tls-identity") || argPresent("--tls-password-file")) && tlsIdentityPath.isEmpty {
    FileHandle.standardError.write("chatbox: --tls-identity was given without a usable path — refusing to start rather than serve in the clear\n".data(using: .utf8)!)
    exit(2)
}
if tlsIdentityPath.isEmpty && !tlsPasswordFile.isEmpty {
    FileHandle.standardError.write("chatbox: --tls-password-file means nothing without --tls-identity\n".data(using: .utf8)!)
    exit(2)
}
// macOS will not open a bundle with an empty passphrase (measured: every
// empty-password bundle, from OpenSSL 3 and LibreSSL alike, comes back as
// errSecAuthFailed), so demanding the file turns a confusing "wrong password" into a
// clear one.
if !tlsIdentityPath.isEmpty && tlsPasswordFile.isEmpty {
    FileHandle.standardError.write("chatbox: --tls-identity needs --tls-password-file — macOS cannot open a PKCS#12 bundle with no passphrase\n".data(using: .utf8)!)
    exit(2)
}
var tlsPassword = ""
if !tlsIdentityPath.isEmpty && !tlsPasswordFile.isEmpty {
    let p = NSString(string: tlsPasswordFile).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
        FileHandle.standardError.write("chatbox: cannot read --tls-password-file \(p)\n".data(using: .utf8)!)
        exit(2)
    }
    tlsPassword = s.trimmingCharacters(in: .whitespacesAndNewlines)
}
var tlsIdentity: sec_identity_t? = nil
if !tlsIdentityPath.isEmpty {
    guard let identity = loadTLSIdentity(p12Path: tlsIdentityPath, password: tlsPassword) else {
        FileHandle.standardError.write("chatbox: refusing to start — TLS was asked for and could not be set up\n".data(using: .utf8)!)
        exit(2)
    }
    tlsIdentity = identity
}

let server = Chatbox(store: store, token: token, staleAfter: staleAfter,
                     tlsEnabled: tlsIdentity != nil, maxBody: maxBody)
let scheme = tlsIdentity == nil ? "http" : "https"
Chatbox.publicURL = "\(scheme)://\(Host.current().name ?? "localhost"):\(port)"

let params: NWParameters
if let identity = tlsIdentity {
    let tls = NWProtocolTLS.Options()
    // No explicit version floor: Network.framework already refuses anything below
    // TLS 1.2 (measured — a client capped at 1.1 is turned away with a protocol
    // alert), so a line here would be a second copy of a platform guarantee. The
    // suite asserts the property instead, which is the part that matters and the
    // part that would notice if the platform ever changed its mind.
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
    params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
} else {
    params = NWParameters.tcp
}
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
        print("staleness: \(staleAfter == 0 ? "off" : "a session unheard from for " + humanSeconds(staleAfter))")
        print("transport: \(tlsIdentity == nil ? "plain HTTP — the token crosses the network in the clear" : "TLS")")
        print("max request: \(maxBody) bytes")
        for a in addrs { print("  \(tlsIdentity == nil ? "http" : "https")://\(a):\(port)/") }
        // stdout is block-buffered when redirected to a file, and this process never
        // exits, so without a flush the banner never reaches chatbox.log.
        fflush(stdout)
    case .failed(let e):
        FileHandle.standardError.write("chatbox: listener failed: \(e)\n".data(using: .utf8)!)
        exit(1)
    default: break
    }
}
listener.start(queue: server.queue)
dispatchMain()
