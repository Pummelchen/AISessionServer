// chatbox.swift — a harness-independent session chatbox.
//
// Any AI agent (DeepSeek Harness, Codex, Claude, or a shell script) registers
// here, declares the git repos it owns, and exchanges plain-text messages about
// them. Text only: this service never carries or grants file access.
//
// Design constraints: Swift 6 (the toolchain at hand), Foundation + Network + SQLite3 only, no
// external packages, one file, no daemon dependencies. The source is typechecked under Swift 6
// language mode with strict concurrency and warnings-as-errors - that is the standard CI enforces,
// not a version pin: `xcrun swiftc -O -swift-version 6 -strict-concurrency=complete
// -warnings-as-errors -typecheck chatbox.swift`.
//
// Build: xcrun swiftc -O chatbox.swift -o chatbox
// Run:   ./chatbox --port 8787 --db ~/chatbox.sqlite [--token SECRET | --token-file PATH]
//        [--stale-after SECONDS]   (default 604800 = 7 days; 0 disables)
//        With no token at all the board is OPEN to anyone who can reach the port.
//
// Federation, one hop, optional: --peer URL --peer-token SECRET [--server-id NAME] [--max-hops N]
// forwards a message for a repo no session here claims to the peer board.
//
// Operator modes, which run and exit rather than listen:
//   ./chatbox --db <path> --prune <days> [--prune-dry-run]
//   ./chatbox --db <path> --backup <copy>       (copies a live board and verifies the copy)
//   ./chatbox --verify-backup <copy> [--db <path>]
//
// Every response is plain text by default (readable by any model); add ?json=1
// for structured output.

import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

/// SQLite's `SQLITE_TRANSIENT`: the destructor that tells sqlite3 to copy the bytes it was handed.
/// A C function pointer is not `Sendable`, so it cannot be a shared global under Swift 6 — it is
/// derived at the one place that binds text.
private func transientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// Long-poll tuning. A held inbox request is served by re-checking on this
// interval rather than by blocking, so a waiter never occupies the server's
// serial queue and every other request is answered normally while it waits.
private let longPollInterval: TimeInterval = 0.25
private let maxWaitSeconds = 300
/// How many messages one inbox answer may carry. The cap is deliberate — a session that falls
/// behind must not be handed an unbounded body — but it is never *silent*: the answer states how
/// many deliveries match and how many of them it is showing.
private let inboxLimit = 200
/// How often a held waiter refreshes `last_seen`, at most. It is capped by the
/// staleness window: refreshing every 60s would report a live waiter as stale
/// whenever the window is shorter than that.
private func longPollTouchInterval(_ staleAfter: Int) -> TimeInterval {
    if staleAfter <= 0 { return 60 }
    return min(60, max(1, Double(staleAfter) / 2))
}

/// One ISO-8601 style for everything this server writes and reads: UTC, second precision, the exact
/// shape stored in the database and compared there as a string. `Date.ISO8601FormatStyle` is a value
/// type and `Sendable`, so it can be a shared constant; `ISO8601DateFormatter` is a class with
/// mutable state, which Swift 6 refuses as a `static` shared across threads — and building a fresh
/// one per call was the alternative. Verified byte-identical to the old formatter's output, and the
/// same style parses a stamp that carries fractional seconds, which is why one is enough here.
private enum ISOStamp {
    static let style = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)

    static func now() -> String { style.format(Date()) }

    static func daysAgo(_ days: Int) -> String {
        style.format(Date().addingTimeInterval(-Double(days) * 86400))
    }

    static func daysAhead(_ days: Int) -> String {
        style.format(Date().addingTimeInterval(Double(days) * 86400))
    }
}

private func nowISO() -> String { ISOStamp.now() }

/// The same shape as `nowISO`, so the two compare as strings in SQL.
private func isoDaysAgo(_ days: Int) -> String { ISOStamp.daysAgo(days) }

/// An ISO-8601 stamp `days` from now, for a credential's expiry. Compared as a string, like every
/// other timestamp here, which is why the format has to match `nowISO` exactly.
private func isoDaysAhead(_ days: Int) -> String { ISOStamp.daysAhead(days) }

/// Credentials are stored only as a SHA-256 of the secret. The secrets are 192 bits
/// of randomness, so a fast hash is the right tool — there is nothing to brute
/// force, and a slow KDF would only make every request expensive.
private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Compare two secrets without letting the clock say how much of one was right.
///
/// `==` on `String` stops at the first differing byte, so the time a wrong credential takes to be
/// refused is proportional to the prefix it guessed correctly — a byte-at-a-time oracle that is
/// only as private as the network is quiet. Both sides are hashed first so the comparison is
/// fixed-width (32 bytes, whatever the secrets' lengths), and the loop XORs every byte into an
/// accumulator with no early return, so the work is the same whether the first byte differs or
/// the last.
private func secretsMatch(_ a: String, _ b: String) -> Bool {
    let x = Array(SHA256.hash(data: Data(a.utf8)))
    let y = Array(SHA256.hash(data: Data(b.utf8)))
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
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
        FileHandle.standardError.write(Data("chatbox: cannot read --tls-identity \(p)\n".utf8))
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
        FileHandle.standardError.write(Data("chatbox: cannot open --tls-identity \(p): OSStatus \(status) — wrong password, or not a PKCS#12 bundle\n".utf8))
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
        FileHandle.standardError.write(Data("chatbox: --tls-identity \(p) holds \(identities.count) identities — a server identity must be the only one in the bundle (OSStatus \(status))\n".utf8))
        return nil
    }
    return sec_identity_create(identities[0])
}

/// A file's permission bits as three octal digits ("600"), or "" when they cannot be read. `stat`
/// rather than Foundation: this is a number the kernel already has, and a formatter for it would be
/// one more thing that can differ between machines.
func fileMode(_ path: String) -> String {
    var info = stat()
    guard stat(path, &info) == 0 else { return "" }
    return String(format: "%03o", info.st_mode & 0o777)
}

private func hasControlByte(_ s: String) -> Bool {
    // `CharacterSet.controlCharacters` is Cc *and* Cf, so this covers the C1 block and the Unicode
    // *format* characters as well as the ASCII controls: the bidi overrides and isolates, the
    // zero-width joiners, the BOM. Format characters are invisible and change no letter, so an id or
    // a repo key containing one is a different key that looks identical — and the client deletes
    // them from what it prints (TRK-29), so an echo of one is a lie either way.
    for scalar in s.unicodeScalars
    where scalar.value < 0x20 || scalar.value == 0x7F || CharacterSet.controlCharacters.contains(scalar) {
        return true
    }
    return false
}

/// A repo key is a name, not a pattern and not a paragraph. `*` and `?` would let a
/// namespace pattern match itself; a line break is worse, because every response
/// that echoes a key — a routing note, a `peers` listing, a delivery list — would
/// then be forgeable from the repo name alone, which is the sender's to choose.
/// ASCII-only case folding, deliberately. Swift's `lowercased()` is full Unicode and the
/// client is `tr` in a POSIX locale, so the two would disagree on `CAFÉ`, on `İ`, and on every
/// other character whose case mapping is not one byte to one byte — and a disagreement here
/// means one repository with two keys again. A key is a machine name, not prose.
func asciiLowercased(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.value >= 65 && scalar.value <= 90 {
            out.unicodeScalars.append(UnicodeScalar(scalar.value + 32)!)
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Space and tab, and nothing else. `CharacterSet.whitespaces` is Unicode-wide while the
/// client's `[[:space:]]` is whatever its locale says, so neither may be left to a default.
let keyTrimSet = CharacterSet(charactersIn: " \t")

/// The one form a repo key is stored and compared in. Returns nil when the input is not a
/// key at all.
///
/// This is deliberately the same rule the client applies, because the two have to agree: a
/// key that arrives by `curl` used to bypass the client entirely, so `git@github.com:acme/x`
/// and `https://github.com/acme/x` were two repositories on the board and mail split between
/// them.
///
/// The **whole** key is lowercased, not just the host. Repository paths are case-insensitive
/// on every forge this is used with, so `github.com/Acme/LibFoo` and `github.com/acme/libfoo`
/// are one repository, and treating them as two is the bug rather than the caution. The price
/// is that a self-hosted host with genuinely case-sensitive paths sees two such repositories
/// merged — written down here, and in [Protocol], rather than left to be discovered.
func canonicalRepoKey(_ raw: String) -> String? {
    if raw.isEmpty || hasControlByte(raw) { return nil }
    var s = raw.trimmingCharacters(in: keyTrimSet)
    if s.isEmpty { return nil }
    // Folded before anything is stripped, not after: `Thing.GIT` would otherwise keep its
    // `.git` on the first pass and lose it on the second, so the function was not idempotent
    // and a migrated key could still be rewritten by the next restart — and a message to the
    // form it settled on would not reach the session that registered the other one.
    s = asciiLowercased(s)

    var ambiguous = false
    if let scheme = s.range(of: "://") {
        // A URL: credentials live in the authority and only there, and a port is not a path.
        s = String(s[scheme.upperBound...])
        let slash = s.firstIndex(of: "/")
        var auth = slash.map { String(s[..<$0]) } ?? s
        let tail = slash.map { String(s[$0...]) } ?? ""
        if let at = auth.lastIndex(of: "@") { auth = String(auth[auth.index(after: at)...]) }
        if auth.hasPrefix("[") {
            if let close = auth.firstIndex(of: "]") { auth = String(auth[...close]) }
        } else if let colon = auth.firstIndex(of: ":") {
            auth = String(auth[..<colon])
        }
        s = auth + tail
    } else {
        // scp syntax: [user@]host:path, and only when the colon precedes any slash.
        let head = s.firstIndex(of: "/").map { String(s[..<$0]) } ?? s
        if let colon = head.firstIndex(of: ":") {
            var host = String(head[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            else { ambiguous = true }
            s = host + "/" + String(s[s.index(after: colon)...])
        }
    }

    if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
    if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
    // To a fixed point, because the migration depends on one pass being enough: `x.git.git`
    // would otherwise become `x.git` now and `x` on the next start, and a message to whichever
    // form it settled on would miss the session that registered the other. Stripping `.git`
    // twice is not a new kind of merge — `x.git` and `x` were already one key, which is what
    // the rule is for.
    while s.hasSuffix("/") { s.removeLast() }
    while s.hasSuffix(".git") {
        s.removeLast(4)
        while s.hasSuffix("/") { s.removeLast() }
    }

    guard let slash = s.firstIndex(of: "/") else { return nil }
    let host = String(s[..<slash])
    let path = String(s[s.index(after: slash)...])
    if host.isEmpty || path.isEmpty { return nil }
    // A host is not a path.
    if host.hasPrefix(".") || host.contains("..") { return nil }
    // A single-label host is only a host when a scheme, or an explicit user, settled it.
    if ambiguous && !(host == "localhost" || host.contains(".")) { return nil }
    // The characters the client refuses, so that what one accepts the other does too.
    // `?` and `#` are deliberately not in this list: the strip above treats them as the start of a
    // URL suffix, which is the documented rule (a `?query` or `#fragment` is URL syntax, not part of
    // a key). The client's `canon_repo` says the same and checks the same set, so the two agree.
    for bad in ["*", "[", "]", " ", "\t"] where s.contains(bad) { return nil }
    return s
}

/// A host on its own, for a host-wide namespace: `example.test/*` was a valid namespace
/// before the canonical rule and has to stay one, or existing credentials stop working.
func canonicalHostOnly(_ raw: String) -> String? {
    guard let probe = canonicalRepoKey(raw + "/x") else { return nil }
    guard let slash = probe.firstIndex(of: "/") else { return nil }
    return String(probe[..<slash])
}

/// A namespace is a canonical key, a canonical key with a trailing `/*`, or `*` alone.
/// Canonicalised on the way in *and* on the way out, so a credential issued before this rule
/// existed still matches exactly what it was meant to and nothing that merely looks like it.
func canonicalNamespace(_ raw: String) -> String? {
    let s = asciiLowercased(raw.trimmingCharacters(in: keyTrimSet))
    if s.isEmpty { return nil }
    if s == "*" { return "*" }
    // A namespace is written as a key, so a `?`, a `#` or a trailing slash means it is not
    // one. Refusing is the only safe direction: dropping them *widens* what a credential
    // issued before the rule may claim — `example.test/y?query/*` used to match nothing and
    // would start matching `example.test/y/victim` — and a credential that quietly claims
    // more than it was issued for is worse than one that claims nothing.
    if s.contains("?") || s.contains("#") { return nil }
    if s.hasSuffix("/*") {
        let base = String(s.dropLast(2))
        if base.hasSuffix("/") { return nil }
        if let key = canonicalRepoKey(base) { return key + "/*" }
        if let host = canonicalHostOnly(base) { return host + "/*" }
        return nil
    }
    if s.hasSuffix("/") { return nil }
    return canonicalRepoKey(s)
}

/// An agent id is a routing key that gets echoed into text: into `peers`, into a
/// delivery list, into "nobody owns this repo" notes. One line by construction.
private func validId(_ id: String) -> Bool {
    if id.isEmpty { return false }
    return !hasControlByte(id)
}

/// A board id travels in a hop list, is read back through the same trimming every parameter gets,
/// and is echoed into a thread as `(via …)`. So it is a name and nothing else: no whitespace *at all*
/// (including the Unicode separators `CharacterSet.whitespaces` does not cover, which every parameter
/// reader trims away — a board id that arrives empty is a message that looks like it came from a
/// sender, and that is the one case a board forwards), no control or format characters, and no comma,
/// which would split one board into two entries of the list.
private func validBoardID(_ s: String) -> Bool {
    if s.isEmpty || s.contains(",") { return false }
    for scalar in s.unicodeScalars where scalar.properties.isWhitespace { return false }
    return !hasControlByte(s)
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
final class Waiter: Sendable {
    /// The peer has finished sending. It may still be reading (a half-close is
    /// legitimate), so the request is still answered — but it is no longer evidence
    /// that anyone is there, so `last_seen` stops being refreshed.
    ///
    /// Set from the connection's receive handler and read by the poll loop, which are separate
    /// `@Sendable` closures: the flag goes through a lock so the type can be `Sendable` without an
    /// unsafe annotation. Both sides already run on the serial queue; the lock is what tells the
    /// compiler so.
    private let gone = Mutex(false)
    var peerGone: Bool {
        get { gone.withLock { $0 } }
        set { gone.withLock { $0 = newValue } }
    }
}

/// A one-way "the deadline no longer applies" flag, shared between the accept deadline and the
/// receive loop. The deadline is a `DispatchWorkItem`, which is not `Sendable` — so the two sides
/// agree through this instead of through the work item, and the work item is only ever *executed*.
final class Deadline: Sendable {
    private let done = Mutex(false)
    var isCancelled: Bool { done.withLock { $0 } }
    func cancel() { done.withLock { $0 = true } }
}

/// What a `URLSession` completion reported: the status, the body and (for a refusal) the Location.
/// The completion is `@Sendable` and cannot write into captured `var`s, so it stores them here —
/// `Mutex` is `Sendable` when its value is, which is what makes this legal without an unsafe
/// annotation.
final class HTTPOutcome: Sendable {
    private let state = Mutex<(status: Int, body: String, location: String)>((0, "", ""))

    func store(status: Int, body: String, location: String) {
        state.withLock { $0 = (status, body, location) }
    }

    var value: (status: Int, body: String, location: String) { state.withLock { $0 } }
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

    /// `*` allows any repo, `host/owner/*` allows a prefix, anything else is exact. Both
    /// sides are canonical, so a namespace written `GitHub.com/Acme/*` allows exactly the
    /// keys `github.com/acme/*` does.
    static func namespace(_ ns: String, allows repo: String) -> Bool {
        guard let n = canonicalNamespace(ns) else { return false }
        if n == "*" { return true }
        if n.hasSuffix("/*") { return repo.hasPrefix(String(n.dropLast())) }
        return repo == n
    }

    func mayClaim(repo: String) -> Bool {
        isBootstrap || namespaces.contains { Principal.namespace($0, allows: repo) }
    }

    func mayClaim(node wanted: String) -> Bool {
        isBootstrap || wanted == node
    }
}

// MARK: - SQLite store

/// The one queue every store access runs on.
///
/// `Store` and `Chatbox` are `@unchecked Sendable` because their mutable state is confined to this
/// queue rather than protected by a type the compiler can see: the HTTP layer is a set of
/// Network.framework callbacks over a synchronous SQLite handle, and re-expressing that as an actor
/// would push `await` through every route for no gain in safety. The confinement is therefore not
/// left as a comment: `Store`'s SQL entry points assert it with
/// `dispatchPrecondition(condition: .onQueue(queue))`, which traps in an optimised build too
/// (measured: SIGTRAP under `-O`), so an access from the wrong context is a crash rather than a data
/// race. The operator modes run their store work inside `chatboxQueue.sync` for the same reason, and
/// the suite — a release build — exercises the whole API, so a new call site that forgets the queue
/// crashes the tests instead of shipping.
let chatboxQueue = DispatchQueue(label: "chatbox.queue")

final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    /// The queue this store may be touched on. See the note on `chatboxQueue`: every entry point
    /// below asserts it.
    let queue: DispatchQueue
    /// The file this store was opened on, kept for the messages that have to name it.
    private let path: String

    init(path: String, migrating: Bool = true, readOnly: Bool = false, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
        // The database is the message history, and the WAL beside it is the same history until it is
        // folded back: neither is for other users on the machine. The process umask is already 077
        // (set in `main`), which covers a file SQLite creates; this covers one that was already there,
        // created by an earlier start or by hand under a looser umask.
        if !readOnly {
            let mode = fileMode(path)
            if !mode.isEmpty && mode != "600" {
                chmod(path, 0o600)
                FileHandle.standardError.write(Data("chatbox: tightened \(path) from mode \(mode) to 600\n".utf8))
            }
        }
        // `readOnly` exists for the prune dry run: `sqlite3_open` *creates* a file that is not there,
        // and any successful open can leave a `-wal`/`-shm` behind, so a mode whose whole promise is
        // "nothing was removed" must not be handed a connection that can write at all.
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            // The *cause* is what the operator needs: "no such directory" and "permission denied"
            // read identically without it, and the refusal is the only place it can be said.
            let why = String(cString: sqlite3_errmsg(db))
            FileHandle.standardError.write(Data("chatbox: cannot open db at \(path): \(why)\n".utf8))
            exit(1)
        }
        // `journal_mode=WAL` writes to the database header and is refused on a read-only connection;
        // a dry run reading a rollback-journal board must not convert it either.
        if !readOnly { exec("PRAGMA journal_mode=WAL;") }
        // Wait rather than fail when another process holds the write lock. Two servers on one
        // database is a supported shape (a restart overlaps the old one), and the alternative
        // is a write that reports failure and a caller that does not look. A connection setting,
        // not a write, so it is set for a read-only connection too.
        exec("PRAGMA busy_timeout=5000;")
        if !migrating { return }
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
          sender TEXT, repo TEXT, subject TEXT, body TEXT, reply_to INTEGER, recipients TEXT,
          origin TEXT);
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS deliveries (
          message_id INTEGER, agent TEXT, created_at TEXT, acked_at TEXT, node TEXT,
          PRIMARY KEY (message_id, agent));
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_del ON deliveries(agent);")
        // The long-poll path only asks "is there anything unread?", so give that
        // question an index that does not have to scan a long history of read rows.
        exec("CREATE INDEX IF NOT EXISTS idx_del_unread ON deliveries(agent, acked_at);")
        exec("""
        CREATE TABLE IF NOT EXISTS tokens (
          id TEXT PRIMARY KEY, hash TEXT NOT NULL, node TEXT, namespaces TEXT,
          note TEXT, created_at TEXT, last_used TEXT, revoked_at TEXT, expires_at TEXT);
        """)
        // Where a message came from, when the request named a relayer: the first entry of its hop
        // list. NULL for every message this board accepted from a sender. It is a *claim* — the
        // same standing as `from`, recorded as told, not verified — and what the server actually
        // guarantees about a hop list is the negative: a message carrying one is never passed on.
        addColumn("messages", "origin", "TEXT")
        // A delivery remembers the recipient's machine as it was when the message was sent. The
        // backfill fills it in for rows written before the column existed — once, with the empty
        // string for a recipient that had no machine, so a later registration cannot inherit it.
        addColumn("deliveries", "node", "TEXT")
        exec("""
        UPDATE deliveries SET node = COALESCE((SELECT a.node FROM agents a WHERE a.id = deliveries.agent), '')
         WHERE node IS NULL;
        """)
        // A credential may carry an expiry. A board that predates the column gets it here: the
        // alter is idempotent, so a restart neither fails nor rewrites anything.
        addColumn("tokens", "expires_at", "TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_tokens_hash ON tokens(hash);")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_thread ON messages(thread_id);")
        // The conversation list is `ORDER BY last_at DESC LIMIT n`, and the served page asks for it
        // every five seconds per open tab: without an index that is a scan of every thread plus a
        // temp b-tree sort, on the queue every request shares. The composite index also serves the
        // `repo = ?` form, where the filter and the ordering have to come from one index or the
        // sort comes back.
        exec("CREATE INDEX IF NOT EXISTS idx_threads_last_at ON threads(last_at DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_threads_repo_last ON threads(repo, last_at DESC);")
        // The scoped visibility rules ask "which conversations does this machine take part in?" by
        // looking for its sessions' messages and for its delivery rows. Without these the answer is a
        // scan of `messages` and of `deliveries` - the fastest-growing table on the board - and every
        // scoped request (a thread, a reply, the listing, the registry) pays for it on the serial
        // queue. `idx_del_node` leads with the node because that is what the rule filters on.
        exec("CREATE INDEX IF NOT EXISTS idx_msg_sender ON messages(sender);")
        exec("CREATE INDEX IF NOT EXISTS idx_del_node ON deliveries(node, message_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_agents_node ON agents(node);")

        // The statements above are not allowed to fail quietly. A name that is not there at all means
        // every route touching it fails, and a board that could not turn WAL on is one whose
        // `--backup` story is a lie, so both are checked here - once, before the listener exists -
        // and the process refuses rather than serving a store it could not prepare. The check is
        // existence, not `type='table'`: a *view* standing in for a table is a shape the read path
        // already handles (it answers 500 through `readFailed`, which is what the suite's read-failure
        // fixture is built on), and refusing there would take that behaviour with it. The failed
        // CREATE that put the view there is logged by `exec` above.
        let wanted = ["agents", "threads", "messages", "deliveries", "tokens"]
        let have = Set(rows("SELECT name FROM sqlite_master WHERE name IN ('agents','threads','messages','deliveries','tokens')").compactMap { $0["name"] })
        let missing = wanted.filter { !have.contains($0) }
        if !missing.isEmpty {
            FileHandle.standardError.write(Data("chatbox: \(path) has no \(missing.joined(separator: ", ")) — refusing to start on a store it could not prepare\n".utf8))
            exit(1)
        }
        if !readOnly {
            let journal = scalar("PRAGMA journal_mode;")
            if journal != "wal" {
                FileHandle.standardError.write(Data("chatbox: \(path) is in journal mode '\(journal)', not WAL — refusing to start (a board without WAL cannot be backed up as documented)\n".utf8))
                exit(1)
            }
        }
    }

    /// Run a statement with no rows to return: a PRAGMA or a schema change. The result code and
    /// SQLite's own message are *not* discarded - a board whose schema or `journal_mode` did not take
    /// effect answers 500 to every route, or quietly loses the WAL the backup story rests on - and
    /// `init` verifies the outcome below. Returns the code so a caller can refuse.
    @discardableResult
    func exec(_ sql: String) -> Int32 {
        dispatchPrecondition(condition: .onQueue(queue))
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK {
            FileHandle.standardError.write(Data("chatbox: sql error: \(String(cString: sqlite3_errmsg(db))) — in \(oneLine(sql))\n".utf8))
        }
        return rc
    }

    private func prepare(_ sql: String, _ binds: [String?]) -> OpaquePointer? {
        dispatchPrecondition(condition: .onQueue(queue))
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            FileHandle.standardError.write(Data("chatbox: sql error: \(String(cString: sqlite3_errmsg(db)))\n".utf8))
            return nil
        }
        for (i, v) in binds.enumerated() {
            // The byte count, not -1: a negative length means "up to the first NUL", so a value with
            // an embedded NUL (`%00` decodes to one) was silently truncated on the way in.
            if let v = v { sqlite3_bind_text(st, Int32(i + 1), v, Int32(v.utf8.count), transientDestructor()) }
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
            FileHandle.standardError.write(Data("chatbox: step error: \(String(cString: sqlite3_errmsg(db)))\n".utf8))
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Set when a read did not run to completion — a `sqlite3_step` that was neither `SQLITE_ROW`
    /// nor `SQLITE_DONE`. `rows` still returns what it collected, because most callers want rows and
    /// cannot do anything else with the failure; what must not happen is that a *truncated* answer is
    /// presented as a complete one, so the request path checks this and answers 500 instead. Cleared
    /// by `beginRequest`.
    private(set) var readFailed = false

    /// Start a fresh read: one request's worth of statements. `dispatch` calls this before a route
    /// runs, so the flag describes *this* answer rather than the last one.
    func beginRequest() {
        dispatchPrecondition(condition: .onQueue(queue))
        readFailed = false
    }

    /// Query rows as dictionaries.
    func rows(_ sql: String, _ binds: [String?] = []) -> [[String: String]] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let st = prepare(sql, binds) else {
            // A statement that will not even prepare is a read that did not happen: the caller gets
            // no rows, and the flag is what stops "no rows" being read as "nothing matched".
            readFailed = true
            return []
        }
        defer { sqlite3_finalize(st) }
        var out: [[String: String]] = []
        while true {
            let step = sqlite3_step(st)
            if step == SQLITE_ROW {
                var row: [String: String] = [:]
                let n = sqlite3_column_count(st)
                for i in 0..<n {
                    let name = String(cString: sqlite3_column_name(st, i))
                    if let c = sqlite3_column_text(st, i) {
                        // The column's own byte count, for the same reason as the bind: `String(cString:)`
                        // stops at the first NUL and would hand back a truncated value.
                        let bytes = Int(sqlite3_column_bytes(st, i))
                        row[name] = String(decoding: UnsafeBufferPointer(start: c, count: bytes), as: UTF8.self)
                    } else { row[name] = "" }
                }
                out.append(row)
                continue
            }
            if step != SQLITE_DONE {
                // BUSY, IOERR, CORRUPT, NOMEM, or anything else: the rows collected so far are a
                // *partial* answer, and a partial answer that looks complete is worse than an error.
                readFailed = true
                FileHandle.standardError.write(Data("chatbox: read failed after \(out.count) row(s): \(String(cString: sqlite3_errmsg(db)))\n".utf8))
            }
            break
        }
        return out
    }

    /// One scalar as String: a one-column query. The row shape is a dictionary, so a query with two
    /// columns has no defined "first", and this used to return whichever column the hash order gave.
    /// A multi-column call is now refused (and logged) instead of answering with an arbitrary field.
    func scalar(_ sql: String, _ binds: [String?] = []) -> String {
        guard let row = rows(sql, binds).first else { return "" }
        guard row.count == 1, let only = row.values.first else {
            FileHandle.standardError.write(Data("chatbox: scalar() needs a one-column query — got \(row.count) columns from \(oneLine(sql))\n".utf8))
            return ""
        }
        return only
    }

    /// A count, or nil when the store could not answer. `scalar` returns "" both for a statement that
    /// failed to prepare and for one that returned no row; `COUNT(*)` always returns a row, so an empty
    /// or non-numeric answer means the store could not be read. Reporting that as 0 would turn
    /// "unknown" into a measurement, which is the opposite of what a health check is for.
    func countOrNil(_ sql: String) -> Int? {
        Int(scalar(sql))
    }

    /// Fold the write-ahead log back into the database file. Called on the way out, so a board that
    /// is stopped leaves a database a plain `cp` can read - the `-wal` is exactly the file a copy
    /// tool misses - and so the next start does not recover a log that grew for however long the
    /// board ran. `TRUNCATE` leaves the log empty rather than merely checkpointed.
    func checkpointWAL() {
        dispatchPrecondition(condition: .onQueue(queue))
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Rows changed by the most recent `run`. `last_insert_rowid` cannot answer this:
    /// an `INSERT … SELECT … WHERE` that matches nothing leaves it at the previous
    /// row's id, so a caller that needs to know whether the row was really stored has
    /// to ask this instead.
    func changedRows() -> Int32 {
        dispatchPrecondition(condition: .onQueue(queue))
        return sqlite3_changes(db)
    }

    /// Run a statement and report what the database did: the step's result code and the rows it
    /// changed. `run` plus `changedRows` cannot tell "the statement stored nothing" from "the
    /// statement failed" — both leave the counter at zero — and a caller that has to answer 404
    /// must not say "no such thread" when the real answer is "the store refused".
    func runReporting(_ sql: String, _ binds: [String?] = []) -> (rc: Int32, changes: Int32, id: Int64) {
        guard let st = prepare(sql, binds) else { return (SQLITE_ERROR, 0, -1) }
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        return (rc, sqlite3_changes(db), sqlite3_last_insert_rowid(db))
    }

    /// The database's own description of the last failure. A caller that has to explain why a
    /// write did not happen should say what SQLite said rather than guess at it.
    func lastError() -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: credentials

    /// Add a column when the table does not have it yet. `ALTER TABLE … ADD COLUMN` is the one
    /// schema change SQLite does in place, and this is what makes an existing board gain the
    /// column on the next start without a migration step for the operator to remember.
    private func addColumn(_ table: String, _ column: String, _ decl: String) {
        if rows("PRAGMA table_info(\(table))").compactMap({ $0["name"] }).contains(column) { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl);")
        // The alter is not retried: if it did not take — a read-only file, a lock held past the
        // busy timeout — the board is now missing a column that authorization reads, and every
        // scoped credential would fail with "unknown token" while the bootstrap credential kept
        // working. A server that cannot migrate must not start.
        if !rows("PRAGMA table_info(\(table))").compactMap({ $0["name"] }).contains(column) {
            FileHandle.standardError.write(Data("chatbox: cannot add \(table).\(column) to \(path) — refusing to serve a half-migrated board\n".utf8))
            exit(1)
        }
    }

    func tokenByHash(_ hash: String) -> [String: String]? {
        rows("""
        SELECT id, node, namespaces, last_used, revoked_at, expires_at FROM tokens WHERE hash = ? LIMIT 1
        """, [hash]).first
    }

    /// Add a credential, and report what the store did. A route that prints a secret it did not
    /// store has handed the operator a credential that can never authenticate, with nothing in the
    /// answer to say so.
    @discardableResult
    func addToken(id: String, hash: String, node: String, namespaces: String, note: String,
                  at: String, expiresAt: String) -> (rc: Int32, changes: Int32) {
        let r = runReporting("INSERT INTO tokens (id,hash,node,namespaces,note,created_at,expires_at) VALUES (?,?,?,?,?,?,?)",
                             [id, hash, node, namespaces, note, at, expiresAt.isEmpty ? nil : expiresAt])
        return (r.rc, r.changes)
    }

    /// The recipients that actually have a delivery row for one message, in the order the rows were
    /// written. A route's `delivered_to` comes from here rather than from the list it intended, so a
    /// delivery that was refused can never be reported as one.
    func recipientsWithDelivery(message id: String) -> [String] {
        rows("SELECT agent FROM deliveries WHERE message_id = ? ORDER BY rowid", [id]).compactMap { $0["agent"] }
    }

    func tokenExists(_ id: String) -> Bool {
        !rows("SELECT 1 FROM tokens WHERE id = ? LIMIT 1", [id]).isEmpty
    }

    /// Revoke one credential, and report what the store did: the route must not answer "rejected from
    /// now on" about an UPDATE that never ran, which is a security control reported as present.
    @discardableResult
    func revokeToken(_ id: String, at: String) -> (rc: Int32, changes: Int32) {
        let r = runReporting("UPDATE tokens SET revoked_at=? WHERE id=? AND (revoked_at IS NULL OR revoked_at='')", [at, id])
        return (r.rc, r.changes)
    }

    func touchToken(_ id: String, at: String) {
        run("UPDATE tokens SET last_used=? WHERE id=?", [at, id])
    }

    func tokensListing(limit: Int) -> [[String: String]] {
        rows("""
        SELECT id, node, namespaces, note, created_at, last_used, revoked_at, expires_at
        FROM tokens ORDER BY created_at, id LIMIT \(limit)
        """)
    }

    func tokenCount() -> Int { Int(scalar("SELECT COUNT(*) FROM tokens")) ?? 0 }

    /// Empty when the session has never registered.
    func lastSeen(of id: String) -> String {
        scalar("SELECT last_seen FROM agents WHERE id = ?", [id])
    }

    /// nil when the session has never registered.
    func nodeOf(_ id: String) -> String? {
        rows("SELECT node FROM agents WHERE id = ? LIMIT 1", [id]).first.map { $0["node"] ?? "" }
    }

    // MARK: domain helpers

    /// Bring keys written before the canonical rule into the one form.
    ///
    /// This is not tidiness. Routing compares an agent's stored `repos` against a canonical
    /// key, so a session registered as `git@github.com:acme/x.git` before this rule existed
    /// would stop receiving mail the moment a sender used the canonical spelling — silently,
    /// which is the worst way for it to happen. Runs once at startup, is idempotent, and
    /// leaves a key it cannot canonicalise exactly as it found it rather than dropping a
    /// claim.
    func migrateRepoKeys() -> (changed: Int, left: Int) {
        var changed = 0
        var left = 0
        func canonicalList(_ raw: String, _ canon: (String) -> String?) -> String {
            var out: [String] = []
            for one in raw.split(separator: ",") {
                let k = one.trimmingCharacters(in: .whitespaces)
                if k.isEmpty { continue }
                let c = canon(k) ?? k
                if !out.contains(c) { out.append(c) }
            }
            return out.joined(separator: ",")
        }
        // One transaction, and a timeout: the migration is the one thing that runs before the
        // listener starts, so a second server holding the write lock must make it wait rather
        // than half-apply and report success it did not have.
        let began = runReporting("BEGIN IMMEDIATE", [])
        if began.rc != SQLITE_DONE {
            // Without the transaction the UPDATEs below would auto-commit one at a time, so a lock
            // held past the busy timeout would leave the board half-migrated - two spellings of one
            // key, the silent mail-split this function exists to prevent - and the banner would still
            // claim the keys were normalised.
            FileHandle.standardError.write(Data("chatbox: cannot start the key migration transaction (\(String(cString: sqlite3_errmsg(db)))) — refusing to migrate without one\n".utf8))
            exit(1)
        }
        for row in rows("SELECT id, repos FROM agents") {
            let raw = row["repos"] ?? ""
            if raw.isEmpty { continue }
            let joined = canonicalList(raw, canonicalRepoKey)
            if joined != raw {
                if run("UPDATE agents SET repos=? WHERE id=?", [joined, row["id"] ?? ""]) >= 0 { changed += 1 } else { left += 1 }
            } else if canonicalRepoKey(raw) == nil { left += 1 }
        }
        for row in rows("SELECT id, repo FROM threads") {
            let raw = row["repo"] ?? ""
            if raw.isEmpty { continue }
            // Left exactly as it was when it cannot be canonicalised. Blanking it would drop
            // the routing of every reply in that thread, which is a data loss this function
            // exists to prevent.
            let canon = canonicalRepoKey(raw) ?? raw
            if canon != raw {
                if run("UPDATE threads SET repo=? WHERE id=?", [canon, row["id"] ?? ""]) >= 0 { changed += 1 } else { left += 1 }
            } else if canonicalRepoKey(raw) == nil { left += 1 }
        }
        for row in rows("SELECT id, namespaces FROM tokens") {
            let raw = row["namespaces"] ?? ""
            if raw.isEmpty { continue }
            let joined = canonicalList(raw, canonicalNamespace)
            if joined != raw {
                if run("UPDATE tokens SET namespaces=? WHERE id=?", [joined, row["id"] ?? ""]) >= 0 { changed += 1 } else { left += 1 }
            } else if canonicalNamespace(raw) == nil { left += 1 }
        }
        // History too: the record is shown by `inbox` and by `&json=1`, so a key there that no
        // longer means what the rule says is a report that reads wrongly even though routing
        // does not depend on it.
        for row in rows("SELECT id, repo FROM messages") {
            let raw = row["repo"] ?? ""
            if raw.isEmpty { continue }
            let canon = canonicalRepoKey(raw) ?? raw
            if canon != raw {
                if run("UPDATE messages SET repo=? WHERE id=?", [canon, row["id"] ?? ""]) >= 0 { changed += 1 } else { left += 1 }
            }
        }
        let committed = runReporting("COMMIT", [])
        if committed.rc != SQLITE_DONE {
            // Nothing was committed: report it as nothing migrated rather than as work done, so the
            // banner cannot claim keys were normalised by a transaction that never landed.
            FileHandle.standardError.write(Data("chatbox: the key migration could not be committed (\(String(cString: sqlite3_errmsg(db)))) — nothing was migrated; the next start will try again\n".utf8))
            return (0, changed + left)
        }
        return (changed, left)
    }

    /// Remove what has been delivered, read and is old enough to let go — and report what a
    /// dry run *would* remove without touching it.
    ///
    /// A message is a candidate only when it has been delivered to somebody **and** every one
    /// of those deliveries has been acknowledged, and only when it is older than the window. An
    /// unacknowledged delivery is the only copy of a report, so it is never a candidate however
    /// old it is; a message with no deliveries at all is kept too, because nobody has read that
    /// either. A thread left with no messages is clutter rather than history and goes with them.
    ///
    /// There is no HTTP route for this and there will not be one: deleting the record of a
    /// cross-repo fix is an operator's decision on the database, not something a session may do
    /// to hide history.
    func prune(olderThanDays days: Int, dryRun: Bool) -> (messages: Int, threads: Int, deliveries: Int)? {
        // The transaction opens *before* anything is read, so the selection, the counts and the
        // deletes all see one snapshot. Reading first left a window in which a reply could be
        // posted into a thread that was about to be deleted, and the reply was then orphaned:
        // its thread row had gone, so its repo and subject went with it.
        let began = dryRun ? 0 : run("BEGIN IMMEDIATE", [])
        if !dryRun && began < 0 { return nil }
        func abandon() -> (messages: Int, threads: Int, deliveries: Int)? {
            if !dryRun { run("ROLLBACK", []) }
            return nil
        }
        let candidates = rows("""
        SELECT m.id AS id, m.thread_id AS thread FROM messages m
        WHERE m.created_at < ?
          AND EXISTS (SELECT 1 FROM deliveries d WHERE d.message_id = m.id)
          AND NOT EXISTS (SELECT 1 FROM deliveries d
                          WHERE d.message_id = m.id AND (d.acked_at IS NULL OR d.acked_at = ''))
        """, [isoDaysAgo(days)])
        // A read that failed part-way left a *partial* candidate list. Deleting what it did return
        // would report success for a prune that never saw the rest of the table, so the transaction
        // goes back with everything else.
        if readFailed { return abandon() }
        if candidates.isEmpty {
            if !dryRun && run("COMMIT", []) < 0 { return abandon() }
            return (0, 0, 0)
        }

        var ids: [String] = []
        var goingPerThread: [String: Int] = [:]
        var deliveries = 0
        for row in candidates {
            let id = row["id"] ?? ""
            guard !id.isEmpty else { continue }
            ids.append(id)
            let thread = row["thread"] ?? ""
            goingPerThread[thread, default: 0] += 1
            deliveries += Int(scalar("SELECT COUNT(*) FROM deliveries WHERE message_id = ?", [id])) ?? 0
        }

        // A thread goes only when every message it has is going. Counted rather than inferred,
        // so the dry run and the real run report the same number.
        var emptied: [String] = []
        for (thread, going) in goingPerThread where !thread.isEmpty {
            let total = Int(scalar("SELECT COUNT(*) FROM messages WHERE thread_id = ?", [thread])) ?? 0
            if total == going { emptied.append(thread) }
        }

        if !dryRun {
            // Every statement is checked. A prune that half-happened would leave deliveries
            // pointing at messages that are gone, which is worse than not pruning at all — and
            // reporting counts for a delete that failed is worse still, because the operator
            // stops looking.
            for id in ids {
                // A reply whose parent has gone would render against a message that is not
                // there, so the reference is cleared rather than left dangling.
                if run("UPDATE messages SET reply_to=0 WHERE reply_to=?", [id]) < 0 { return abandon() }
                if run("DELETE FROM deliveries WHERE message_id = ?", [id]) < 0 { return abandon() }
                if run("DELETE FROM messages WHERE id = ?", [id]) < 0 { return abandon() }
            }
            for thread in emptied {
                // Re-checked inside the transaction: a thread with anything left in it stays.
                if run("DELETE FROM threads WHERE id = ? AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = ?)",
                       [thread, thread]) < 0 { return abandon() }
            }
            if run("COMMIT", []) < 0 { return abandon() }
        }
        return (ids.count, emptied.count, deliveries)
    }

    func owners(ofRepo repo: String) -> [String] {
        let all = rows("SELECT id, repos FROM agents")
        return all.filter { row in
            let repos = (row["repos"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return repos.contains(repo)
        }.map { $0["id"] ?? "" }.filter { !$0.isEmpty }
    }

    /// The registry, bounded and — for a scoped credential — scoped: its own machine's sessions,
    /// plus every session it has a conversation with, and nothing else. `visibleTo` is nil for the
    /// bootstrap credential, which sees the whole board.
    func agentsListing(limit: Int, visibleTo node: String?) -> [[String: String]] {
        let columns = """
        a.id, a.node, a.agent, a.harness, a.session, a.ip, a.repos, a.note, a.registered_at, a.last_seen
        """
        guard let node = node else {
            return rows("SELECT \(columns) FROM agents a ORDER BY a.id LIMIT \(limit)")
        }
        return rows("""
        SELECT \(columns) FROM agents a
         WHERE \(visibleAgentsWhere)
         ORDER BY a.id LIMIT \(limit)
        """, [node, node, node, node, node])
    }

    /// The ids a machine may be told about, as a set. Used where a *listing* is not the answer —
    /// a send response naming its recipients — so the visibility rule stays in one place.
    func visibleAgentIds(forNode node: String) -> Set<String> {
        var out = Set<String>()
        for r in rows("SELECT a.id FROM agents a WHERE \(visibleAgentsWhere)",
                      [node, node, node, node, node]) where !(r["id"] ?? "").isEmpty {
            out.insert(r["id"]!)
        }
        return out
    }

    /// The three board-wide counts, in one query, for the events feed.
    func boardCounts() -> (agents: Int, threads: Int, messages: Int) {
        let r = rows("""
        SELECT (SELECT COUNT(*) FROM agents) AS a,
               (SELECT COUNT(*) FROM threads) AS t,
               (SELECT COUNT(*) FROM messages) AS m
        """).first ?? [:]
        return (Int(r["a"] ?? "") ?? 0, Int(r["t"] ?? "") ?? 0, Int(r["m"] ?? "") ?? 0)
    }

    func agentCount(visibleTo node: String?) -> Int {
        guard let node = node else { return Int(scalar("SELECT COUNT(*) FROM agents")) ?? 0 }
        return Int(scalar("SELECT COUNT(*) FROM agents a WHERE \(visibleAgentsWhere)",
                          [node, node, node, node, node])) ?? 0
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
               m.repo AS repo, m.subject AS subject, m.body AS body, m.origin AS origin,
               d.acked_at AS acked
        FROM deliveries d JOIN messages m ON m.id = d.message_id
        WHERE d.agent = ? \(includeAcked ? "" : "AND (d.acked_at IS NULL OR d.acked_at = '')")
        ORDER BY m.id DESC LIMIT \(inboxLimit)
        """
        return rows(sql, [agent])
    }

    /// How many deliveries match the same question `deliveries` answers, so a full page can say
    /// what it left out instead of dropping the oldest unread mail without a word.
    func deliveryCount(forAgent agent: String, includeAcked: Bool) -> Int {
        Int(scalar("""
        SELECT COUNT(*) FROM deliveries d JOIN messages m ON m.id = d.message_id
        WHERE d.agent = ? \(includeAcked ? "" : "AND (d.acked_at IS NULL OR d.acked_at = '')")
        """, [agent])) ?? 0
    }

    // ---------- who may read what ----------
    //
    // A scoped credential is bound to one machine, and sessions on one machine share an OS user and
    // a filesystem — so the machine, not the session, is the confidentiality boundary. A credential
    // may read the conversations **its machine takes part in** and nothing else. The shared
    // bootstrap credential is the documented exception: whoever holds it holds the database anyway,
    // and an operator needs the whole board.

    /// The threads a node takes part in, as a SQL fragment: a session on it sent a message in the
    /// thread, or a session on it was sent one. The fragment binds the node twice, in that order.
    /// The delivery row records the recipient's machine **at the moment the message was sent**, so
    /// a session that registers later cannot inherit a conversation it was never part of — an
    /// unregistered recipient is stored with an empty node and stays outside every machine's view
    /// until somebody actually sends to it again.
    let nodeThreadsSQL = """
    SELECT m.thread_id FROM messages m
     WHERE m.sender IN (SELECT id FROM agents WHERE node = ?)
        OR m.id IN (SELECT d.message_id FROM deliveries d
                     WHERE d.node = ?)
    """

    /// The `WHERE` clause that decides which agents a machine may see, shared by the listing and
    /// the count so the two cannot disagree. Binds the node five times.
    var visibleAgentsWhere: String {
        """
        a.node = ?
           OR a.id IN (SELECT m.sender FROM messages m WHERE m.thread_id IN (\(nodeThreadsSQL)))
           OR a.id IN (SELECT d.agent FROM deliveries d WHERE d.message_id IN
                         (SELECT m.id FROM messages m WHERE m.thread_id IN (\(nodeThreadsSQL))))
        """
    }

    /// Whether a machine takes part in one conversation.
    func node(_ node: String, participatesIn threadId: String) -> Bool {
        !rows("""
        SELECT 1 FROM messages m
         WHERE m.thread_id = ?
           AND (m.sender IN (SELECT id FROM agents WHERE node = ?)
                OR m.id IN (SELECT d.message_id FROM deliveries d
                             WHERE d.node = ?))
         LIMIT 1
        """, [threadId, node, node]).isEmpty
    }

    /// Everyone who has taken part in one conversation: its senders plus everyone with a delivery row
    /// for one of its messages. This is the set a reply has to answer, and it is read from `deliveries`
    /// rather than by splitting `messages.recipients`.
    ///
    /// That column is comma-joined, and a session id may itself contain a comma (any credential can
    /// register one). Splitting it invented participants who never took part - one reply was enough to
    /// give a stranger's machine a delivery row, and with it read access to the thread. There is no
    /// delimiter to get wrong here, and no message content is read: the loop this replaced
    /// materialised every message of the thread, bodies included, to find the same set of names.
    func threadParticipants(_ id: String) -> [String] {
        rows("""
        SELECT a AS agent FROM (
          SELECT sender AS a FROM messages WHERE thread_id = ?
          UNION
          SELECT d.agent AS a FROM deliveries d JOIN messages m ON m.id = d.message_id
           WHERE m.thread_id = ?
        ) WHERE a IS NOT NULL AND a <> '' ORDER BY a
        """, [id, id]).compactMap { $0["agent"] }
    }

    /// The newest `limit` messages of a thread, in reading order. A conversation has no natural
    /// bound, so an answer that returns all of it is a response whose size the *peer* decides;
    /// the newest are the ones a reader acts on, and the caller says how many were left out.
    func threadPage(_ id: String, limit: Int) -> [[String: String]] {
        rows("""
        SELECT * FROM (
          SELECT id, thread_id, created_at, sender, repo, subject, body, reply_to, recipients, origin
          FROM messages WHERE thread_id = ? ORDER BY id DESC LIMIT \(limit)
        ) ORDER BY id ASC
        """, [id])
    }

    func messageCount(thread id: String) -> Int {
        Int(scalar("SELECT COUNT(*) FROM messages WHERE thread_id = ?", [id])) ?? 0
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
    /// Who the request was served as, rendered once by `dispatch` so every log line can name it:
    /// `bootstrap`, `denied`, or the node and credential id behind a scoped token. Never a secret -
    /// the id is what the credential listing already shows.
    var principal = ""

    func p(_ key: String, _ def: String = "") -> String {
        (params[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? def)
    }

    /// A flag parameter: true when it is present and not one of the spellings of false. It used to be
    /// "true for any non-empty value", so `all=0` included the messages the caller had already read
    /// and `json=0` answered JSON — the opposite of what was written. Absent is false.
    func flag(_ key: String) -> Bool {
        let v = p(key).lowercased()
        return !(v.isEmpty || v == "0" || v == "false" || v == "no" || v == "off")
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

/// Form encoding of one field, for the body of a forward. `URLComponents`' query items leave `+`
/// alone, and the receiver decodes `+` as a space — which is what form encoding says it should do —
/// so a message containing `+` sent that way would arrive with a space in it. Everything outside
/// the unreserved set is escaped here instead.
private func formEncode(_ s: String) -> String {
    var out = ""
    for byte in Array(s.utf8) {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            out.append(Character(UnicodeScalar(byte)))
        default:
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

/// Swallows redirects for the forward session. `URLSession` follows them by default, so a peer
/// behind an http→https redirect would answer this board's `POST` with a `GET` somewhere else, and a
/// final 2xx is what this board reports as `forwarded_to … (ok)` — a silent loss announced as a
/// delivery. With the redirect refused, the 3xx comes back as the answer it is.
final class NoForwardRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A message that is stored here and still has to be told to the peer, because the repo it names
/// has no owner on this board. Built by `message` — which is the only place that knows the send was
/// accepted — and carried out by `forwardMessage` off the serial queue.
struct ForwardPlan {
    var from: String
    var repo: String
    var subject: String
    var body: String
    /// The row this message got here, so the log line names something an operator can look up.
    var msgID: Int64
}

/// One route's answer. `forward` is set only by `POST /message`, and only when the message was
/// stored here *and* a peer still has to be told about it. The answer is owed either way; it is
/// just sent after the peer has answered rather than while it is being asked.
struct Reply {
    var status: Int
    var body: String
    var forward: ForwardPlan?
    /// Extra response headers. Used by the inbox to say *which* messages it rendered, so a client
    /// can acknowledge what it was handed instead of "everything unread" — a header is structural,
    /// so a peer's message body can never add an id to it.
    var headers: [String: String]

    init(_ status: Int, _ body: String, forward: ForwardPlan? = nil,
         headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.forward = forward
        self.headers = headers
    }
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
    /// Seconds a connection has to deliver a complete request before the server closes it. A
    /// connection that sends nothing is not a request, and holding it open is free for whoever
    /// opened it and a resource here. 0 disables the deadline.
    let idleTimeout: Int
    /// How many connections may be open at once. The per-connection memory is bounded by the
    /// request cap; the number of them was not, so one peer could open as many as it liked.
    let maxConnections: Int
    /// The most rows one listing may return — thread messages, the registry, the credential list.
    /// The inbox has its own window because it is a mail queue rather than a listing.
    let maxRows: Int
    /// This board's name. It goes into the hop list of every message this board forwards, so the
    /// peer can tell a message it accepted from a sender from one that has already been relayed.
    let serverID: String
    /// The one peer this board forwards to, as a base URL with no trailing slash, and the credential
    /// it presents there. Empty when federation is off, which is the default.
    let peerURL: String
    let peerToken: String
    /// The longest hop list this board will accept. A forward always carries exactly one id per
    /// board it has passed through and a board never forwards a message that already has one, so
    /// this bound exists only because the list arrives as untrusted input.
    let maxHops: Int
    /// The queue this object's mutable state lives on — the same one the store uses. See
    /// `chatboxQueue` for why `@unchecked Sendable` is acceptable here and what enforces it.
    let queue: DispatchQueue
    /// Forwards run here, not on `queue`. A peer that is slow or gone must not hold up the board,
    /// and the sender is still owed the peer's answer — so the answer waits on this queue while
    /// every other request is served. Serial, so two forwards for the same repo reach the peer in
    /// the order the sends were handled.
    let forwardQueue = DispatchQueue(label: "chatbox.forward")
    /// The session a forward goes out on: a redirect is refused rather than followed, so the answer
    /// this board reports is the peer's own.
    private let forwardSession: URLSession

    init(store: Store, token: String?, staleAfter: Int, tlsEnabled: Bool, maxBody: Int,
         idleTimeout: Int, maxConnections: Int, maxRows: Int, serverID: String,
         peerURL: String, peerToken: String, maxHops: Int, publicURL: String,
         queue: DispatchQueue) {
        self.store = store
        self.token = token
        self.staleAfter = staleAfter
        self.tlsEnabled = tlsEnabled
        self.maxBody = maxBody
        self.idleTimeout = idleTimeout
        self.maxConnections = maxConnections
        self.maxRows = maxRows
        self.serverID = serverID
        self.peerURL = peerURL
        self.peerToken = peerToken
        self.maxHops = maxHops
        self.publicURL = publicURL
        self.queue = queue
        self.forwardSession = URLSession(configuration: .ephemeral,
                                         delegate: NoForwardRedirects(), delegateQueue: nil)
    }

    /// Connections that have been accepted and not yet finished. Kept as identities rather than a
    /// count so a connection that reports both `failed` and `cancelled` cannot be subtracted twice.
    private var liveConnections = Set<ObjectIdentifier>()

    /// Refused connections that are still open: a socket the process holds while it waits to answer
    /// "too many connections". They are not `liveConnections` - refusing one must not keep the server
    /// at its limit - but they are sockets, so they get the idle deadline and a ceiling of their own.
    private var refusedConnections = Set<ObjectIdentifier>()

    /// Set when the process has been asked to stop. The answers that are *held* - a long poll, an
    /// event stream - check it on their next tick, so a restart ends them with an answer instead of
    /// a cut socket, and neither can outlive the process that promised to hold it.
    private var shuttingDown = false

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
                return .denied(401, "unauthorized: this credential's expiry ('\(oneLine(expiresAt))') cannot be read — issue another\n")
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
            finish(req, conn: conn, status: 400, body: "error: chunked bodies are not supported — send Content-Length\n")
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
            req.principal = principal.isBootstrap
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
            finish(req, conn: conn, status: 500, body: "error: the store could not be read — the answer would have been partial (\(oneLine(store.lastError())))\n")
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
            forwardQueue.async {
                let note = self.forwardMessage(plan)
                self.queue.async {
                    self.finish(finalReq, conn: conn, status: answer.status, body: base + note,
                                headers: answer.headers)
                }
            }
            return
        }
        finish(req, conn: conn, status: answer.status, body: answer.body, headers: answer.headers)
    }

    /// The plain `(status, body)` a handler returns, as a `Reply`. Only `message` ever sets
    /// `forward`, and every other route goes through here so the routing table stays one shape.
    private func reply(_ out: (Int, String)) -> Reply { Reply(out.0, out.1) }

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

    /// The URL this board tells callers to use, fixed at startup. It was a `static var` assigned
    /// after the instance was built, which is mutable global state the compiler cannot reason about
    /// — and the only thing that ever read it was the usage text.
    let publicURL: String

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
          events    GET  /events                    (SSE: board activity, bootstrap only)
          health    GET  /health

        Credentials — issuing is restricted to the bootstrap token:
          token     POST /token?node=<mac>&namespaces=github.com/acme/*&note=<text>   (secret shown once)
          tokens    GET  /token                     (list; never shows secrets)
          revoke    POST /token/revoke?id=<tk-id>   (effective immediately, no restart)

        A scoped credential may only act as a session registered to its own node,
        and may only claim repos inside its namespaces. It can still send to any
        repo, which is the point: "whoever owns <repo>, I have a bug to discuss".

        Federation — one hop, when started with --peer <url> [--peer-token <secret>]:
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
    /// route can serve a request is precisely the failure a health check exists to report. `scalar`
    /// logs the SQLite error and answers ""; here that emptiness is the signal.
    func health() -> Reply {
        guard let a = store.countOrNil("SELECT COUNT(*) FROM agents"),
              let t = store.countOrNil("SELECT COUNT(*) FROM threads"),
              let m = store.countOrNil("SELECT COUNT(*) FROM messages") else {
            return Reply(503, "error: the store could not be read — the counters are unknown, not zero\n"
                + "sqlite: \(store.lastError())\n"
                + "board: \(serverID)\nnow: \(nowISO())\n")
        }
        let presence = staleAfter == 0 ? "off" : "stale after \(humanSeconds(staleAfter))"
        let transport = tlsEnabled ? "tls" : "plain http"
        let idle = idleTimeout == 0 ? "no idle deadline" : "\(idleTimeout)s idle deadline"
        // The board's own name is reported whether or not it forwards: it is the name a peer shows
        // in `(via …)` on a forwarded message, and an operator comparing two boards needs it.
        let peer = peerURL.isEmpty ? "none" : peerURL
        return Reply(200, "ok chatbox up\nagents: \(a)\nthreads: \(t)\nmessages: \(m)\npresence: \(presence)\ntransport: \(transport)\nmax request: \(maxBody) bytes\nmax rows: \(maxRows)\nconnections: up to \(maxConnections), \(idle)\npeer: \(peer) (this board is \(serverID), accepts up to \(maxHops) hops)\nnow: \(nowISO())\n")
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
                return (400, "error: '\(oneLine(repo))' is not a valid repo key — keys name a repo, are one line, and do not contain '*', '[' or ']' or a space (a '?' or '#' ends the key)\n")
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
                    return (403, "forbidden: this credential may not claim '\(repo)'"
                        + (who.namespaces.isEmpty
                            ? " (it may claim no repos)\n"
                            : " — allowed: \(who.namespaces.joined(separator: ", "))\n"))
                }
            }
        }
        let ts = nowISO()
        let existing = store.scalar("SELECT id FROM agents WHERE id = ?", [id])
        var wrote: (rc: Int32, changes: Int32, id: Int64) = (SQLITE_DONE, 0, 0)
        if existing.isEmpty {
            wrote = store.runReporting("INSERT INTO agents (id,node,agent,harness,session,ip,repos,note,registered_at,last_seen) VALUES (?,?,?,?,?,?,?,?,?,?)",
                                       [id, node, agent, harness, session, ip, effectiveRepos, note, ts, ts])
        } else {
            // An omitted (empty) field keeps the stored value — the rule `repos` already followed,
            // now applied to all of them. The update used to write node, agent, harness, session,
            // ip and note unconditionally, so a session that re-registered only to add a repo
            // silently lost the rest of its identity, and because /peers prints the harness line
            // only when a field is set, the loss was invisible in the default view.
            wrote = store.runReporting("""
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
            """, [node, node, agent, agent, harness, harness, session, session, ip, ip,
                  effectiveRepos, effectiveRepos, note, note, ts, id])
        }
        // The answer reports what is *stored*, not what was sent: with an omitted field preserved,
        // echoing the request would say "session: " while the session was still on the board.
        // A registration that was not written must not be answered as one: the upsert's result was
        // discarded, so a refused INSERT still produced "ok registered" with the empty identity the
        // re-read found.
        guard wrote.rc == SQLITE_DONE else {
            FileHandle.standardError.write(Data("chatbox: the registration of \(id) failed: \(store.lastError())\n".utf8))
            return (500, "error: the registration was not stored — \(oneLine(id)) is not registered (\(oneLine(store.lastError())))\n")
        }
        let stored = store.rows("""
        SELECT node, agent, harness, session, ip, repos FROM agents WHERE id = ?
        """, [id]).first ?? [:]
        let storedRepos = stored["repos"] ?? ""
        audit("registered id=\(oneLine(id)) node=\(oneLine(stored["node"] ?? "")) repos=\(storedRepos.isEmpty ? "(none)" : oneLine(storedRepos))")
        return (200, """
        ok registered
        id: \(id)
        node: \(stored["node"] ?? "")  agent: \(stored["agent"] ?? "")  session: \(stored["session"] ?? "")
        ip: \(stored["ip"] ?? "")  harness: \(stored["harness"] ?? "")
        repos: \(storedRepos.isEmpty ? "(none declared)" : oneLine(storedRepos))
        at: \(ts)

        Next: POST /message?from=\(id)&repo=<repo>&subject=<...>&body=<...>
        """)
    }

    func message(_ req: Request, _ who: Principal) -> Reply {
        let from = req.p("from").isEmpty ? req.p("id") : req.p("from")
        guard !from.isEmpty else { return Reply(400, "error: from required\n") }
        guard validId(from) else { return Reply(400, "error: from must be a single line, without control characters\n") }
        if let rejection = mayAct(as: from, who) { return Reply(rejection.0, rejection.1) }
        var body = req.p("body")
        if body.isEmpty { body = req.p("text") }
        if body.isEmpty { body = req.p("message") }
        let subject = req.p("subject")
        let repo = req.p("repo")
        let threadIn = req.p("thread")
        let toExplicit = req.p("to")
        // The boards this message has already passed through, oldest first. It is empty when the
        // message came from a sender here, and that is the only case this board ever forwards.
        // A hop list is untrusted input: an id that is not a one-line id is refused, an empty entry
        // is refused (a list is `a,b`, never `a,`), and so is a list longer than --max-hops.
        //
        // An absent parameter and an empty one both mean "no boards", which is why the split only
        // runs when there is something to split — and why it keeps empty entries: `split` drops
        // them by default, so `a,` would have arrived as the one-board list `a` and the rule below
        // could never fire. Measured: it did not, until this said so.
        var hops: [String] = []
        // Read raw, not through `p()`. That trims `.whitespacesAndNewlines`, so a board id made of a
        // character `.whitespaces` leaves alone (U+2028, U+2029) would arrive here as an empty
        // parameter: this board would see "no hops", treat a relayed message as one it accepted from
        // a sender, and pass it on. Measured: a U+2028 `--server-id` relayed a message across three
        // boards, and two mutually-peered boards looped without bound.
        let hopRaw = req.params["hop"] ?? ""
        if !hopRaw.isEmpty {
            for one in hopRaw.split(separator: ",", omittingEmptySubsequences: false) {
                let hop = one.trimmingCharacters(in: .whitespaces)
                guard !hop.isEmpty else {
                    return Reply(400, "error: hop names boards, one per entry — an empty entry is not a board\n")
                }
                guard validBoardID(hop) else {
                    return Reply(400, "error: hop must name boards — a board id is one line, with no whitespace, control or format characters\n")
                }
                hops.append(hop)
            }
        }
        guard hops.count <= maxHops else {
            return Reply(400, "error: hop names \(hops.count) boards — the limit here is \(maxHops)\n")
        }
        guard !body.isEmpty || !subject.isEmpty else { return Reply(400, "error: body (or text) required\n") }
        // Register has always refused a malformed key; the send path did not, so a key
        // could be stored on a thread and then echoed back by every later reply.
        var canonicalRepo = ""
        if !repo.isEmpty {
            guard let key = canonicalRepoKey(repo) else {
                return Reply(400, "error: '\(oneLine(repo))' is not a valid repo key — keys name a repo, are one line, and do not contain '*', '[' or ']' or a space (a '?' or '#' ends the key)\n")
            }
            canonicalRepo = key
        }
        for one in toExplicit.split(separator: ",") {
            let t = one.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard validId(t) else { return Reply(400, "error: to must name ids that are single lines, without control characters\n") }
        }

        // `reply_to` is informational, but it is stored in an integer column: a value
        // that is not a message id used to be dropped to 0 without a word, so the
        // reader saw no reply marker and the sender was never told why. Checked with
        // the other parameters, so a refusal cannot open a thread on its way out.
        let replyToIn = req.p("reply_to")
        var replyTo: Int64 = 0
        if !replyToIn.isEmpty {
            guard let r = Int64(replyToIn), r >= 0 else {
                return Reply(400, "error: reply_to must be a message id, not '\(oneLine(replyToIn))'\n")
            }
            replyTo = r
        }

        // Resolve the thread before anything else is written. A reply must name a thread
        // that exists: `thread=N` with no `threads` row used to store the message under
        // that id anyway, where nothing could reach it — `GET /thread?id=N` answered 404
        // and no participant was ever routed to it. The id is never created on demand,
        // so a caller cannot squat on one and claim a conversation that somebody else
        // has not started. Whether the thread still exists *when the message is stored*
        // is settled by the insert itself, below.
        // The reply's target is resolved *before* the transaction opens, because every refusal in
        // this block is a validation that has written nothing: a transaction left open by an early
        // return is how a board wedges itself — the next send answers "cannot start a transaction
        // within a transaction" and every message after it fails. A reply is a *join*: without the
        // 403, read scoping would be decorative, since a credential could name any sequential thread
        // id, post a line into it and read the whole history it just joined.
        var replyThreadId: Int64 = 0
        var effRepo = canonicalRepo
        if !threadIn.isEmpty {
            guard let t = Int64(threadIn), t > 0 else {
                return Reply(400, "error: thread must be a positive integer, not '\(oneLine(threadIn))'\n")
            }
            if !who.isBootstrap, !store.node(who.node, participatesIn: String(t)) {
                return Reply(403, "forbidden: this credential may reply only to a conversation its machine takes part in\n")
            }
            replyThreadId = t
            // a reply inherits the thread's repo so routing stays consistent
            if effRepo.isEmpty { effRepo = store.scalar("SELECT repo FROM threads WHERE id = ?", [String(t)]) }
            // A thread stored before the send path validated its key must not become a
            // way to echo that key back: it is dropped rather than repeated.
            if !effRepo.isEmpty { effRepo = canonicalRepoKey(effRepo) ?? "" }
        }

        // Everything from here to the commit is one write. A send that cannot deliver to everyone it
        // names is rolled back and refused, because the alternative is a message the sender is told
        // was delivered while no delivery row exists — the report is then unreachable and permanent,
        // and `--prune` deliberately never removes a message with no deliveries, so nothing recovers
        // it. One statement runs per connection at a time and this whole function runs on the serial
        // queue, so the transaction cannot interleave with another request.
        let began = store.runReporting("BEGIN IMMEDIATE", [])
        guard began.rc == SQLITE_DONE else {
            FileHandle.standardError.write(Data("chatbox: could not begin the send transaction: \(store.lastError())\n".utf8))
            return Reply(500, "error: the message could not be stored — nothing was written\n")
        }

        var threadId: Int64
        if threadIn.isEmpty {
            threadId = store.run("INSERT INTO threads (repo,subject,created_at,created_by,last_at) VALUES (?,?,?,?,?)",
                                 [effRepo, subject, nowISO(), from, nowISO()])
        } else {
            threadId = replyThreadId
        }
        guard threadId > 0 else {
            store.run("ROLLBACK", [])
            return Reply(500, "error: could not open thread — nothing was written\n")
        }

        // resolve recipients: explicit, else thread participants plus the repo's owners
        var recipients: [String] = []
        if !toExplicit.isEmpty {
            recipients = toExplicit.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            var set = Set<String>()
            if !effRepo.isEmpty { set.formUnion(store.owners(ofRepo: effRepo)) }
            if !threadIn.isEmpty {
                // One participants-only query. This used to read every message of the thread - bodies
                // included, with no LIMIT - and then split its comma-joined `recipients` back apart,
                // which is how an id containing a comma became two participants.
                set.formUnion(store.threadParticipants(String(threadId)))
            }
            recipients = Array(set).sorted()
        }
        recipients = recipients.filter { $0 != from }
        // An explicit to=a,b,a should not deliver, mark or warn twice.
        var already = Set<String>()
        recipients = recipients.filter { already.insert($0).inserted }
        // A recipient list built from a read that failed is a *partial* list: the repo's owners or
        // the thread's participants came back short, and storing the message against it would leave
        // mail nobody is delivered to. `--prune` never removes a message with no deliveries, so that
        // mail would be unreachable and permanent. The transaction goes back instead — and the
        // thread this send may have just opened goes with it.
        if store.readFailed {
            store.run("ROLLBACK", [])
            return Reply(500, "error: the recipients could not be resolved — nothing was written\n")
        }

        // The thread's existence is enforced by the insert, not by a read before it:
        // `INSERT … SELECT … WHERE EXISTS` stores the row only while the thread is still
        // there, so an operator's `--prune` racing this reply cannot leave a message
        // nobody can reach. A reply into a thread that is not there stores nothing at
        // all — no message, no delivery, and not even the sender's liveness stamp.
        let attempt = store.runReporting("""
        INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,reply_to,recipients,origin)
        SELECT ?,?,?,?,?,?,?,?,? WHERE EXISTS (SELECT 1 FROM threads WHERE id=?)
        """, [String(threadId), nowISO(), from, effRepo, subject, body, replyTo == 0 ? nil : String(replyTo), recipients.joined(separator: ","), hops.first, String(threadId)])
        let msgId = attempt.id
        if attempt.changes == 0 {
            // Nothing was stored, and there are two reasons for that. A statement that *failed* —
            // a locked database, a trigger that refused — is a storage problem: answering "no such
            // thread" would be a lie, and its advice ("send without thread=") would open a
            // duplicate thread. Only a statement that ran and matched no row means the thread is
            // gone, which is the case answering 404 protects.
            store.run("ROLLBACK", [])
            if attempt.rc != SQLITE_DONE {
                FileHandle.standardError.write(Data("chatbox: the message insert failed: \(store.lastError())\n".utf8))
                return Reply(500, "error: the message could not be stored — nothing was written\n")
            }
            return Reply(404, "error: no thread \(threadId) — send without thread= to open one\n")
        }

        // keep the sender's liveness fresh, once the message is known to be stored
        let touched = store.runReporting("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), from])
        guard touched.rc == SQLITE_DONE else {
            store.run("ROLLBACK", [])
            FileHandle.standardError.write(Data("chatbox: the sender's liveness stamp failed: \(store.lastError())\n".utf8))
            return Reply(500, "error: the message could not be stored — nothing was written\n")
        }

        for r in recipients {
            let delivery = store.runReporting("""
            INSERT OR IGNORE INTO deliveries (message_id,agent,created_at,node) VALUES (?,?,?,?)
            """, [String(msgId), r, nowISO(), store.nodeOf(r) ?? ""])
            guard delivery.rc == SQLITE_DONE else {
                store.run("ROLLBACK", [])
                FileHandle.standardError.write(Data("chatbox: the delivery to \(r) failed: \(store.lastError())\n".utf8))
                return Reply(500, "error: the message could not be delivered to \(oneLine(r)) — nothing was written\n")
            }
        }
        let stamped = store.runReporting("UPDATE threads SET last_at=? WHERE id=?", [nowISO(), String(threadId)])
        guard stamped.rc == SQLITE_DONE else {
            store.run("ROLLBACK", [])
            FileHandle.standardError.write(Data("chatbox: the thread stamp failed: \(store.lastError())\n".utf8))
            return Reply(500, "error: the message could not be stored — nothing was written\n")
        }
        let committed = store.runReporting("COMMIT", [])
        guard committed.rc == SQLITE_DONE else {
            store.run("ROLLBACK", [])
            FileHandle.standardError.write(Data("chatbox: the send transaction would not commit: \(store.lastError())\n".utf8))
            return Reply(500, "error: the message could not be stored — nothing was written\n")
        }
        // The answer reports the delivery rows that exist, not the list this route intended.
        let delivered = store.recipientsWithDelivery(message: String(msgId))
        // The message is committed; this list is a second read. If *it* failed, say so — "delivered
        // to nobody" and "we could not read who" are different answers to the same question.
        let deliveredKnown = !store.readFailed

        // A report sent to a machine that has gone away is still stored, but the
        // sender deserves to know nobody is likely to read it.
        //
        // Scoped credentials are the exception: "unregistered", "never registered" and an age are
        // the registry view that `/peers` is scoped to hide, and a send is a way to ask about any
        // id. A scoped sender is told the recipient is not one of its correspondents and nothing
        // more — enough to know the message may go unread, not enough to enumerate the board.
        let scopedSender = !who.isBootstrap
        let now = Date()
        let visibleToSender = scopedSender ? store.visibleAgentIds(forNode: who.node) : []
        // A recipient nobody is listening for: gone quiet, or never registered at all.
        let unseen = delivered.filter {
            scopedSender ? !visibleToSender.contains($0) : isStale(store.lastSeen(of: $0), now: now)
        }
        func unseenLabel(_ id: String) -> String {
            scopedSender ? "not visible to this credential"
                : (store.lastSeen(of: id).isEmpty ? "unregistered" : "stale")
        }
        func unseenReason(_ id: String) -> String {
            if scopedSender { return "not a conversation this machine takes part in" }
            let seen = store.lastSeen(of: id)
            return seen.isEmpty ? "never registered" : ageDescription(seen, now: now)
        }
        let deliveredTo = deliveredKnown
            ? (delivered.isEmpty ? "(nobody)"
               : delivered.map { r in unseen.contains(r) ? "\(r) (\(unseenLabel(r)))" : r }.joined(separator: ", "))
            : "(could not be read)"

        // TRK-17: one hop to the configured peer, for a message this board accepted from a sender
        // and cannot route — the repo has no owner here, which is the case the note below already
        // describes as "nobody has registered as an owner". Decided *after* the local store
        // committed, so a peer that is down cannot cost the local board its own copy.
        //
        // A message that arrived from another board is stored and not passed on. That is what makes
        // a loop impossible rather than merely unlikely: a board forwards only what it accepted
        // from a sender, so a forwarded message can never be forwarded again, here or anywhere else.
        //
        // Two things are deliberately not forwarded. A message addressed with `to=` is local
        // routing, and a reply names a conversation the peer does not have — forwarding it would
        // open a fresh thread there for every follow-up and split the conversation in two silently.
        var forwardNote = ""
        var plan: ForwardPlan? = nil
        if !peerURL.isEmpty, !effRepo.isEmpty, threadIn.isEmpty, toExplicit.isEmpty,
           store.owners(ofRepo: effRepo).isEmpty {
            if hops.isEmpty {
                plan = ForwardPlan(from: from, repo: effRepo, subject: subject, body: body,
                                   msgID: msgId)
            } else {
                forwardNote = "forward: not sent — this message came from another board (\(hops.joined(separator: ",")))\n"
            }
        }

        var note = ""
        if recipients.isEmpty {
            note = effRepo.isEmpty
                ? "\nnote: no recipient — pass repo=<key>, to=<agent>, or thread=<id>\n"
                : (scopedSender
                    ? "\nnote: no visible owner of '\(effRepo)' from this credential; message stored in thread \(threadId)\n"
                    : "\nnote: nobody has registered as an owner of '\(effRepo)' yet; message stored in thread \(threadId)\n")
        }
        if !unseen.isEmpty {
            // `unseenList`, not `who`: this function's `who` parameter is the credential, and
            // rebinding it here made every later read ambiguous at a glance.
            let unseenList = unseen.map { "\($0) (\(unseenReason($0)))" }.joined(separator: ", ")
            // Only claim nobody will read it when nobody is left to.
            let everyone = unseen.count == delivered.count
            // A scoped sender gets the same warning without the board's own numbers: "no sign of X
            // inside the 7d window" is a statement about the registry, which is what the scope
            // exists to withhold.
            if scopedSender {
                note += "\nwarning: \(unseenList)"
                    + (everyone
                        ? " — the message is stored, but nobody may read it\n"
                        : " — the message is stored, but it may not reach "
                          + (unseen.count == 1 ? "that session" : "those sessions") + "\n")
            } else {
                note += "\nwarning: no sign of \(unseenList) inside the \(humanSeconds(staleAfter)) staleness window"
                    + (everyone
                        ? " — the message is stored, but nobody may read it\n"
                        : " — the message is stored, but it may not reach "
                          + (unseen.count == 1 ? "that session" : "those sessions") + "\n")
            }
        }
        audit("message id=\(msgId) thread=\(threadId) repo=\(effRepo.isEmpty ? "-" : effRepo) from=\(oneLine(from)) recipients=\(delivered.count)")
        return Reply(200, """
        ok posted
        message: \(msgId)
        thread: \(threadId)
        repo: \(effRepo.isEmpty ? "-" : effRepo)
        delivered_to: \(delivered.isEmpty ? "(nobody)" : deliveredTo)
        at: \(nowISO())
        \(note)\(forwardNote)
        """, forward: plan)
    }

    /// The ids a page rendered, as a response header the client can act on. Headers are structural,
    /// so a peer's message body can never add an id to the list a wake loop will acknowledge.
    private func unreadHeader(_ rows: [[String: String]]) -> [String: String] {
        let rendered = rows.compactMap { $0["id"] }.filter { !$0.isEmpty }
        return rendered.isEmpty ? [:] : ["X-Chatbox-Unread-Ids": rendered.joined(separator: ",")]
    }

    func inbox(_ req: Request, _ who: Principal) -> Reply {
        let id = req.p("id").isEmpty ? req.p("for") : req.p("id")
        guard !id.isEmpty else { return Reply(400, "error: id required\n") }
        guard validId(id) else { return Reply(400, "error: id must be a single line, without control characters\n") }
        if let rejection = mayAct(as: id, who) { return Reply(rejection.0, rejection.1) }
        store.run("UPDATE agents SET last_seen=? WHERE id=?", [nowISO(), id])
        let rows = store.deliveries(forAgent: id, includeAcked: req.flag("all"))
        // The ids travel in a header, not in the body: headers are structural, so a peer's message
        // body cannot add an id to the list a wake loop will acknowledge. Saying which messages a
        // page contains is what lets a client ack exactly those, instead of "everything unread" —
        // which marked mail read that the page never held, and lost it.
        let headers = unreadHeader(rows)
        if rows.isEmpty && req.p("json").isEmpty {
            // The one-line status the client prints unframed, because it is the server talking
            // about the inbox rather than a peer talking to the session. The JSON form still
            // answers JSON — with the counts it has, which are zero.
            return Reply(200, "inbox for \(id): empty\n")
        }
        return Reply(200, renderInbox(req, id: id, rows: rows), headers: headers)
    }

    func renderInbox(_ req: Request, id: String, rows: [[String: String]]) -> String {
        let all = req.flag("all")
        // The listing is capped, so a session that falls behind would otherwise stop being told
        // about its older unread mail without a word — the opposite of what a durable delivery
        // model promises. Both answers state how many deliveries there are and how many of them
        // are in front of the reader.
        let matching = store.deliveryCount(forAgent: id, includeAcked: all)
        let shown = rows.count
        if req.flag("json") {
            // An object rather than the array every other route returns: this is the one answer
            // that has to say how much of itself it is showing.
            let messages = jsonArray(rows).trimmingCharacters(in: .whitespacesAndNewlines)
            return "{\"shown\": \(shown), \"matching\": \(matching), \"messages\": \(messages)}\n"
        }
        var out = "inbox for \(id) — \(shown)\(matching > shown ? " of \(matching)" : "") message(s)"
            + (all ? " (including read)" : " unread") + "\n"
        if matching > shown {
            out += "note: the \(shown) newest are listed, \(matching - shown) older one(s) are not — "
                + "ack what you have read and ask again, or open a thread: GET /thread?id=<thread>\n"
        }
        for r in rows {
            let unread = (r["acked"] ?? "").isEmpty
            out += "\n[\(r["id"] ?? "")]\(unread ? " UNREAD" : " read  ") thread \(r["thread"] ?? "")  \(r["at"] ?? "")\n"
            // A forwarded message is marked here as well as in the thread view: the inbox is the
            // path a session actually reads, and "from: mac3-dsh" alone cannot tell a report from
            // the board next door apart from one written here.
            let via = (r["origin"] ?? "").isEmpty ? "" : " (via \(r["origin"]!))"
            out += "  from: \(r["sender"] ?? "")\(via)   repo: \((r["repo"] ?? "").isEmpty ? "-" : r["repo"]!)\n"
            if !(r["subject"] ?? "").isEmpty { out += "  subject: \(r["subject"]!)\n" }
            let b = r["body"] ?? ""
            out += "  body: \(b.count > 1200 ? String(b.prefix(1200)) + " …[truncated]" : b)\n"
        }
        out += "\nread a thread: GET /thread?id=<thread>   ·   mark read: POST /ack?id=\(id)&message=<id>\n"
        return out
    }

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
    private func forwardMessage(_ plan: ForwardPlan) -> String {
        let note = performForward(plan)
        let why = note.split(separator: "\n").first.map(String.init) ?? note
        let line = note.hasPrefix("forwarded_to:")
            ? "chatbox: message \(plan.msgID) forwarded to \(peerURL)\n"
            : "chatbox: message \(plan.msgID) could not be forwarded to \(peerURL): \(why)\n"
        FileHandle.standardError.write(Data(line.utf8))
        return note
    }

    /// The request itself, so that the reporting above is in exactly one place and a test can pin
    /// the log line without pinning the wording of every failure.
    private func performForward(_ plan: ForwardPlan) -> String {
        guard var comps = URLComponents(string: peerURL + "/message") else {
            return "forward failed: \(peerURL) is not a usable URL\nthe message is stored here\n"
        }
        comps.query = nil
        guard let url = comps.url else {
            return "forward failed: \(peerURL) is not a usable URL\nthe message is stored here\n"
        }
        let fields = [("from", plan.from), ("repo", plan.repo), ("subject", plan.subject),
                      ("body", plan.body), ("hop", serverID)]
        let encoded = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !peerToken.isEmpty { req.setValue("Bearer \(peerToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(encoded.utf8)
        let sem = DispatchSemaphore(value: 0)
        let outcome = HTTPOutcome()
        let task = forwardSession.dataTask(with: req) { data, response, error in
            var status = 0
            var location = ""
            var body = ""
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                location = http.value(forHTTPHeaderField: "Location") ?? ""
            }
            if let data = data, let text = String(data: data, encoding: .utf8) { body = text }
            if let error = error { body = "error: \(error.localizedDescription)" }
            outcome.store(status: status, body: body, location: location)
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            return "forward failed: \(peerURL) did not answer within 10s\nthe message is stored here; the peer can be retried by hand\n"
        }
        let (status, answer, redirectedTo) = outcome.value
        // A redirect is not a delivery, and this board does not follow one: a peer that moved is
        // named rather than guessed at, because the alternative is a 2xx somewhere else reported as
        // "forwarded".
        if status >= 300 && status < 400 {
            let landed = redirectedTo.isEmpty ? "an address it did not name" : oneLine(redirectedTo)
            return "forward failed: \(peerURL) answered \(status) — it redirected to \(landed); point --peer at the board itself\nthe message is stored here; the peer can be retried by hand\n"
        }
        if status >= 200 && status < 300 { return "forwarded_to: \(peerURL) (ok)\n" }
        let why = answer.split(separator: "\n").first.map(String.init) ?? "no answer"
        // A transport failure has no status to report, and printing "0" for one would read like a
        // response code. The peer's first line is text this board did not write and it ends up in a
        // response a client prints, so it goes through the same one-line treatment as every echo.
        let said = status == 0 ? "— " : "answered \(status) — "
        return "forward failed: \(peerURL) \(said)\(oneLine(why))\nthe message is stored here; the peer can be retried by hand\n"
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
            finish(req, conn: conn, status: 403,
                   body: "forbidden: the board-wide feed needs the bootstrap credential — a session watches its own inbox with GET /inbox?id=<you>&wait=<s>\n")
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
    private func pollEvents(_ conn: NWConnection, last: BoardState, deadline: Date, nextKeepAlive: Date) {
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

    private struct BoardState: Equatable {
        let agents: Int
        let threads: Int
        let messages: Int
    }

    private func boardState() -> BoardState {
        let c = store.boardCounts()
        return BoardState(agents: c.agents, threads: c.threads, messages: c.messages)
    }

    private func eventData(_ state: BoardState) -> String {
        "{\"agents\":\(state.agents),\"threads\":\(state.threads),\"messages\":\(state.messages),\"at\":\"\(nowISO())\"}"
    }

    private func sendEvent(_ conn: NWConnection, name: String, data: String,
                           then done: @escaping @Sendable () -> Void = {}) {
        conn.send(content: Data("event: \(name)\ndata: \(data)\n\n".utf8),
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
        if shuttingDown {
            // A held poll cannot outlive the board: say so rather than let the socket be cut when the
            // process exits, so the client can tell a stop from a network failure.
            finish(req, conn: conn, status: 503, body: "error: the server is shutting down — start it again and ask once more\n")
            return
        }

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
                finish(req, conn: conn, status: 500, body: "error: the store could not be read — the page would have been partial\n")
                return
            }
            finish(req, conn: conn, status: 200, body: renderInbox(req, id: id, rows: rows),
                   headers: unreadHeader(rows))
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

    func showThread(_ req: Request, _ who: Principal) -> (Int, String) {
        let id = req.p("id").isEmpty ? req.p("thread") : req.p("id")
        guard !id.isEmpty else { return (400, "error: id (thread) required\n") }
        // Scoped before it is looked up, so a credential cannot tell a thread it may not read from
        // one that does not exist — both are "not yours to read".
        if !who.isBootstrap, !store.node(who.node, participatesIn: id) {
            return (403, "forbidden: this credential may read only conversations its machine takes part in\n")
        }
        // A conversation has no natural bound, so this answer is bounded instead: the newest
        // `--max-rows` messages, with the number left out stated. Silence about the rest would be
        // the same dishonesty as a silently truncated inbox.
        let matching = store.messageCount(thread: id)
        let rows = store.threadPage(id, limit: maxRows)
        guard !rows.isEmpty else { return (404, "no thread \(oneLine(id))\n") }
        if req.flag("json") { return (200, jsonRows(rows, key: "messages", matching: matching)) }
        let head = store.rows("SELECT repo, subject, created_at, created_by FROM threads WHERE id=?", [id]).first ?? [:]
        var out = "thread \(id)  repo: \((head["repo"] ?? "").isEmpty ? "-" : head["repo"]!)  subject: \(head["subject"] ?? "-")\n"
        out += "opened: \(head["created_at"] ?? "-") by \(head["created_by"] ?? "-")   "
            + "\(rows.count)\(matching > rows.count ? " of \(matching)" : "") message(s)\n"
        if matching > rows.count {
            out += "note: the newest \(rows.count) are shown, \(matching - rows.count) older one(s) are not"
                + " — raise --max-rows to read further back\n"
        }
        for r in rows {
            let via = (r["origin"] ?? "").isEmpty ? "" : "  (via \(r["origin"]!))"
            out += "\n--- [\(r["id"] ?? "")] \(r["created_at"] ?? "")  \(r["sender"] ?? "") → \((r["recipients"] ?? "").isEmpty ? "(nobody)" : r["recipients"]!)\(via)\n"
            if !(r["subject"] ?? "").isEmpty, r["id"] == rows.first?["id"] { out += "subject: \(r["subject"]!)\n" }
            if let rt = r["reply_to"], !rt.isEmpty, rt != "0" { out += "(reply to \(rt))\n" }
            out += "\(r["body"] ?? "")\n"
        }
        return (200, out)
    }

    func listThreads(_ req: Request, _ who: Principal) -> (Int, String) {
        let repoRaw = req.p("repo")
        var repo = ""
        if !repoRaw.isEmpty {
            guard let key = canonicalRepoKey(repoRaw) else { return (400, "error: '\(oneLine(repoRaw))' is not a valid repo key\n") }
            repo = key
        }
        // One `WHERE` clause decides both what is listed and what `matching` counts. The count is an
        // answer about other machines' mail just as much as the rows are: it used to be a board-wide
        // (or repo-wide) `COUNT(*)`, so a credential scoped to one machine was told how many
        // conversations exist that it may not read — a number it could watch grow.
        var conditions: [String] = []
        var binds: [String?] = []
        if !repo.isEmpty { conditions.append("t.repo = ?"); binds.append(repo) }
        if !who.isBootstrap {
            // Only the conversations this machine takes part in. The bootstrap credential lists
            // everything, which is what makes it the operator's view.
            conditions.append("t.id IN (\(store.nodeThreadsSQL))")
            binds.append(who.node); binds.append(who.node)
        }
        let scope = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let matchingThreads = Int(store.scalar("SELECT COUNT(*) FROM threads t" + scope, binds)) ?? 0
        // `--max-rows`, not a literal: every other listing is bounded by the configured number, and
        // an operator who raised it was still handed 100 conversations by this route.
        let sql = "SELECT t.id, t.repo, t.subject, t.created_at, t.last_at, (SELECT COUNT(*) FROM messages m WHERE m.thread_id=t.id) AS n FROM threads t"
            + scope + " ORDER BY t.last_at DESC LIMIT \(maxRows)"
        let rows = store.rows(sql, binds)
        // `json=1` is the machine-readable contract of every listing, so an empty result is an empty
        // *JSON* result. The prose answer is for a human; answering it to a caller that asked for JSON
        // made "empty" look like "broken".
        if req.flag("json") { return (200, jsonRows(rows, key: "threads", matching: matchingThreads)) }
        if rows.isEmpty { return (200, "no threads\(repo.isEmpty ? "" : " for \(repo)") yet\n") }
        // The text answer states how many of how many it is showing, like every other listing: it
        // used to print the page size alone, so a truncated listing was indistinguishable from a
        // complete one and the operator had no reason to raise `--max-rows`.
        var out = "threads\(repo.isEmpty ? "" : " for \(repo)") — \(rows.count)"
            + (matchingThreads > rows.count ? " of \(matchingThreads)" : "") + "\n"
        if matchingThreads > rows.count {
            out += "note: \(matchingThreads - rows.count) older one(s) are not shown — raise --max-rows to see them\n"
        }
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
        // The number reported is the number of delivery rows the statement actually stamped —
        // never the number of messages the request mentioned. `ack?thread=N` used to count every
        // message in the thread, so a session holding one of them was told `ok acked 3`, and
        // `ack?message=N` claimed one whatever the store held: acknowledgements that never
        // happened, reported by the one answer a caller can check.
        //
        // All three forms stamp only rows that are still unread, so all three are idempotent: acking
        // the same thing twice reports the work the second call really did (none), and the first
        // ack time is not moved by the second — a read cursor records when the mail was read.
        var n = 0
        var rc: Int32 = SQLITE_DONE
        if !req.p("message").isEmpty {
            let r = store.runReporting("""
            UPDATE deliveries SET acked_at=? WHERE agent=? AND message_id=? AND (acked_at IS NULL OR acked_at='')
            """, [nowISO(), id, req.p("message")])
            rc = r.rc; n = Int(r.changes)
        } else if req.flag("all") {
            let r = store.runReporting("""
            UPDATE deliveries SET acked_at=? WHERE agent=? AND (acked_at IS NULL OR acked_at='')
            """, [nowISO(), id])
            rc = r.rc; n = Int(r.changes)
        } else if !req.p("thread").isEmpty {
            // One statement for the whole thread rather than one per message: the count is then
            // what the ack changed, and a long thread is not a long list of statements.
            let r = store.runReporting("""
            UPDATE deliveries SET acked_at=? WHERE agent=? AND (acked_at IS NULL OR acked_at='')
              AND message_id IN (SELECT id FROM messages WHERE thread_id=?)
            """, [nowISO(), id, req.p("thread")])
            rc = r.rc; n = Int(r.changes)
        } else {
            return (400, "error: pass message=<id>, thread=<id> or all=1\n")
        }
        // The statement's own result code decides whether anything happened. `changedRows()` is
        // `sqlite3_changes()`, which a *failed* statement does not reset: reading it after a
        // failure reported the preceding `UPDATE agents SET last_seen` — one row — as an
        // acknowledgement, so a caller was told `ok acked 1` about mail that is still unread.
        // A count of zero on a statement that ran is honest and is reported as zero.
        guard rc == SQLITE_DONE else {
            return (500, "error: the acknowledgement could not be stored — nothing was acknowledged\n")
        }
        return (200, "ok acked \(n) for \(id)\n")
    }

    func peers(_ req: Request, _ who: Principal) -> (Int, String) {
        // A scoped credential sees its own machine and its correspondents; the bootstrap credential
        // sees the whole registry.
        let scope = who.isBootstrap ? nil : who.node
        let matchingAgents = store.agentCount(visibleTo: scope)
        var rows = store.agentsListing(limit: maxRows, visibleTo: scope)
        let now = Date()
        for i in rows.indices {
            let seen = rows[i]["last_seen"] ?? ""
            rows[i]["status"] = staleAfter == 0 ? "unknown"
                : (isStale(seen, now: now) ? "stale" : "active")
            rows[i]["age"] = ageDescription(seen, now: now)
        }
        if req.flag("json") { return (200, jsonRows(rows, key: "agents", matching: matchingAgents)) }
        var out = "registered agents — \(rows.count)\(matchingAgents > rows.count ? " of \(matchingAgents)" : "")\n"
        if matchingAgents > rows.count {
            out += "note: \(matchingAgents - rows.count) more are registered than are shown — raise --max-rows to see them\n"
        }
        if staleAfter == 0 { out += "(staleness reporting is off)\n" }
        for r in rows {
            let status = r["status"] ?? "active"
            out += "\n\(r["id"] ?? "")  (\(r["agent"] ?? "-") on \(r["node"] ?? "-"))  \(status == "stale" ? "STALE" : status)\n"
            out += "  repos: \((r["repos"] ?? "").isEmpty ? "(none declared)" : oneLine(r["repos"]!))\n"
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
        guard validId(node) else {
            return (400, "error: node must be a single line, without control characters\n")
        }
        let namespacesRaw = req.p("namespaces").isEmpty ? req.p("namespace") : req.p("namespaces")
        var namespaces: [String] = []
        for one in namespacesRaw.split(separator: ",") {
            let ns = one.trimmingCharacters(in: .whitespaces)
            if ns.isEmpty { continue }
            guard let canon = canonicalNamespace(ns) else {
                return (400, "error: '\(oneLine(ns))' is not a usable namespace — use a repo key, a key ending in /*, or *\n")
            }
            if !namespaces.contains(canon) { namespaces.append(canon) }
        }
        // An optional expiry, in days. 0 or absent means "until revoked by hand", which is what
        // every credential was before this existed — the point of the option is the credential
        // nobody remembers, not a new default.
        let expiresRaw = req.p("expires")
        var expiresAt = ""
        if !expiresRaw.isEmpty || req.params["expires"] != nil {
            // Digits only: `+30` and ` 30` parse as numbers in Swift, and a credential with an
            // expiry nobody typed is worse than a refused request. A blank value is present, so it
            // is a mistake rather than "never".
            guard !expiresRaw.isEmpty, expiresRaw.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let days = Int(expiresRaw), days > 0, days <= 36500 else {
                return (400, "error: expires must be a number of days between 1 and 36500 — got '\(oneLine(expiresRaw))'\n")
            }
            expiresAt = isoDaysAhead(days)
        }
        let secret = randomHex(24)
        let id = "tk-" + randomHex(6)
        let stored = store.addToken(id: id, hash: sha256Hex(secret), node: node,
                                    namespaces: namespaces.joined(separator: ","), note: req.p("note"),
                                    at: nowISO(), expiresAt: expiresAt)
        // Nothing is printed before the row exists: only one copy of the secret is ever shown, and a
        // credential that was not stored cannot authenticate.
        guard stored.rc == SQLITE_DONE, stored.changes == 1 else {
            FileHandle.standardError.write(Data("chatbox: the credential insert failed: \(store.lastError())\n".utf8))
            return (500, "error: the credential was not stored — nothing was issued (\(oneLine(store.lastError())))\n")
        }
        // CodeQL flags this response as cleartext transmission of sensitive data,
        // and without TLS it is right: the secret travels in the body. Loopback never
        // leaves the machine and a TLS listener is encrypted, so the warning is for
        // the one case that is actually exposed — a plain listener reached from
        // somewhere else.
        audit("credential issued id=\(id) node=\(oneLine(node)) expires=\(expiresAt.isEmpty ? "never" : expiresAt)")
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
        namespaces: \(namespaces.isEmpty ? "(none — this credential may claim no repos)" : namespaces.joined(separator: ","))
        expires: \(expiresAt.isEmpty ? "never (until revoked)" : expiresAt)
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
        let matchingTokens = store.tokenCount()
        let rows = store.tokensListing(limit: maxRows)
        if req.flag("json") { return (200, jsonRows(rows, key: "tokens", matching: matchingTokens)) }
        if rows.isEmpty { return (200, "no credentials issued\n") }
        var out = "credentials — \(rows.count)\(matchingTokens > rows.count ? " of \(matchingTokens)" : "")\n"
        if matchingTokens > rows.count {
            out += "note: \(matchingTokens - rows.count) more are issued than are shown — raise --max-rows to see them\n"
        }
        for r in rows {
            let revoked = !(r["revoked_at"] ?? "").isEmpty
            let expires = r["expires_at"] ?? ""
            let expired = !expires.isEmpty && expires <= nowISO()
            let state = revoked || expired ? (revoked ? "REVOKED" : "EXPIRED") : "active"
            out += "\n\(r["id"] ?? "")  \(state)  node: \(r["node"] ?? "-")\n"
            out += "  namespaces: \((r["namespaces"] ?? "").isEmpty ? "(none)" : oneLine(r["namespaces"]!))\n"
            out += "  issued: \(r["created_at"] ?? "-")   last used: \((r["last_used"] ?? "").isEmpty ? "never" : r["last_used"]!)\n"
            out += "  expires: \(expires.isEmpty ? "never (until revoked)" : expires)\n"
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
        let revoked = store.revokeToken(id, at: nowISO())
        if revoked.rc == SQLITE_DONE && revoked.changes == 0 {
            // Revoked between the check above and this statement: a success, not a failure.
            let when = store.scalar("SELECT revoked_at FROM tokens WHERE id = ?", [id])
            if !when.isEmpty { return (200, "ok \(id) was already revoked at \(when)\n") }
        }
        guard revoked.rc == SQLITE_DONE, revoked.changes == 1 else {
            FileHandle.standardError.write(Data("chatbox: the revoke of \(id) did not run: \(store.lastError())\n".utf8))
            return (500, "error: the revocation did not run — \(oneLine(id)) is still valid (\(oneLine(store.lastError())))\n")
        }
        audit("credential revoked id=\(oneLine(id))")
        return (200, """
        ok revoked \(id)
        Every request presenting it is rejected from now on. Other credentials and
        the bootstrap credential are untouched, and no restart is needed.
        """)
    }

    /// A bounded listing as an object: the rows plus how many of how many they are. The inbox has
    /// answered this way since TRK-21, for the same reason — an array cannot say that it is a page,
    /// and a consumer that cannot tell is a consumer that silently loses the rest.
    private func jsonRows(_ rows: [[String: String]], key: String, matching: Int) -> String {
        let inner = jsonArray(rows).trimmingCharacters(in: .whitespacesAndNewlines)
        return "{\"shown\": \(rows.count), \"matching\": \(matching), \"\(key)\": \(inner)}\n"
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
    func finish(_ req: Request, conn: NWConnection, status: Int, body: String,
                contentType: String = "text/plain; charset=utf-8",
                headers: [String: String] = [:]) {
        dispatchPrecondition(condition: .onQueue(queue))
        // One line per request, and it has to be a record rather than a note: when it happened, who
        // asked, as whom, what they asked for and what came back. It used to be `METHOD PATH ->
        // STATUS` and nothing else, so an operator could not order events after an incident,
        // attribute an authentication failure, or tell which credential issued or revoked one.
        // `oneLine` is belt and braces - the request line is refused upstream if it carries a
        // control byte - because a log line a peer can end is a log a peer can write into.
        FileHandle.standardError.write(Data("chatbox: \(nowISO()) \(req.peer.isEmpty ? "-" : req.peer) \(oneLine(req.method)) \(oneLine(req.path)) -> \(status) principal=\(req.principal.isEmpty ? "-" : req.principal)\n".utf8))
        respond(conn, status: status, body: body, contentType: contentType, headers: headers)
    }

    /// The peer's address, for a log line. `-` when the connection has no nameable endpoint, which is
    /// what a log line must say rather than nothing.
    private func peerNote(_ conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "-"
    }

    /// One line per action an operator has to be able to reconstruct after an incident, with the ids
    /// it touched. The *secret* of a credential never appears here; only its id, which the credential
    /// listing already shows.
    private func audit(_ what: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        FileHandle.standardError.write(Data("chatbox: \(nowISO()) audit \(oneLine(what))\n".utf8))
    }

    func respond(_ conn: NWConnection, status: Int, body: String,
                 contentType: String = "text/plain; charset=utf-8",
                 headers: [String: String] = [:]) {
        let reason = status == 200 ? "OK"
            : (status == 400 ? "Bad Request"
            : (status == 401 ? "Unauthorized"
            : (status == 403 ? "Forbidden"
            : (status == 404 ? "Not Found"
            : (status == 413 ? "Payload Too Large"
            : (status == 503 ? "Service Unavailable" : "Error"))))))
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for key in headers.keys.sorted() { head += "\(key): \(headers[key]!)\r\n" }
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    func serve(conn: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        let identity = ObjectIdentifier(conn)
        if liveConnections.count >= maxConnections {
            // Answer rather than drop: a peer that is told nothing cannot tell a busy server from
            // a broken one, and the refusal is cheap because nothing has been read yet. The socket
            // still has to be started before it can carry the answer, and it is deliberately not
            // counted among the *served* connections — refusing it must not keep the server at its
            // limit.
            //
            // It is still a socket this process holds, though, and `.ready` arrives only after the
            // TLS handshake: a peer that opens TCP to a TLS board and says nothing would sit in
            // `.preparing` for ever. The idle deadline covers the refusal branch exactly as it covers
            // a served connection, and how many refusals may be in flight at once is bounded
            // separately — a deadline alone only bounds how long each one lives, not how many a peer
            // can open in that time.
            if refusedConnections.count >= maxConnections {
                FileHandle.standardError.write(Data("chatbox: \(nowISO()) \(peerNote(conn)) refused without an answer: \(maxConnections) refusal(s) already in flight\n".utf8))
                conn.cancel()
                return
            }
            refusedConnections.insert(identity)
            let refusal = Deadline()
            let refusalIdle = DispatchWorkItem { [weak self, weak conn] in
                guard !refusal.isCancelled else { return }
                guard let self = self, let conn = conn else { return }
                self.refusedConnections.remove(identity)
                FileHandle.standardError.write(Data("chatbox: \(nowISO()) \(self.peerNote(conn)) refused connection closed after \(self.idleTimeout)s without a request\n".utf8))
                conn.cancel()
            }
            if idleTimeout > 0 {
                queue.asyncAfter(deadline: .now() + .seconds(idleTimeout), execute: refusalIdle)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    refusal.cancel()
                    self.refusedConnections.remove(identity)
                    self.tooManyConnections(conn)
                case .failed, .cancelled:
                    refusal.cancel()
                    self.refusedConnections.remove(identity)
                    conn.cancel()
                default:
                    break
                }
            }
            conn.start(queue: queue)
            return
        }
        liveConnections.insert(identity)
        // A connection that never finishes a request is closed rather than held: the deadline runs
        // from the moment the socket is accepted, so a peer that completes TCP and then says nothing
        // — including one that never finishes a TLS handshake — is bounded exactly like a slow
        // trickle, and cannot hold a connection slot for ever.
        //
        // The connection is captured *weakly*: a work item scheduled an hour out is retained until
        // its deadline, and a strong reference would keep every finished connection object alive
        // that long (and, before this, kept a failed handshake's socket open long enough for the
        // peer to hang instead of being told no).
        // The deadline fires unless the request has arrived; `deadline.cancel()` is what the
        // receive loop calls instead of cancelling the work item, which it cannot hold.
        let deadline = Deadline()
        let idle = DispatchWorkItem { [weak self, weak conn] in
            guard !deadline.isCancelled else { return }
            guard let self = self, let conn = conn, self.liveConnections.contains(identity) else { return }
            FileHandle.standardError.write(Data("chatbox: idle connection closed after \(self.idleTimeout)s\n".utf8))
            conn.cancel()
        }
        if idleTimeout > 0 {
            queue.asyncAfter(deadline: .now() + .seconds(idleTimeout), execute: idle)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receive(conn, buffer: Data(), deadline: deadline)
            case .failed:
                deadline.cancel()
                self.liveConnections.remove(identity)
                // A failed connection is still a live socket until it is cancelled: leaving it
                // there makes a peer that failed the handshake wait for the deadline instead of
                // being told no.
                conn.cancel()
            case .cancelled:
                deadline.cancel()
                self.liveConnections.remove(identity)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data, deadline: Deadline) {
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
                // The request has arrived, so the accept deadline has done its job. Anything the
                // connection does from here — a long poll included — is the server's own time.
                deadline.cancel()
                self.dispatch(req, conn: conn)
                return
            }
            if error != nil || isComplete {
                // The peer has stopped sending and the buffer still does not hold a request. If it
                // announced a body and did not send all of it, say so: a client that gets nothing
                // back cannot tell a truncated request from a server that is still thinking, and
                // this is exactly the case where it needs to know the message was not stored.
                if let promised = self.bodyShortfall(buf) {
                    self.truncatedBody(conn, promised: promised)
                    return
                }
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf, deadline: deadline)
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

    /// The `Content-Length` a request promised when its body is still incomplete, or nil when
    /// there is nothing to complain about: no header block, no declared length, or a body that
    /// arrived in full. Only asked once the peer has stopped sending, because until then a short
    /// body is simply a body that has not finished arriving.
    private func bodyShortfall(_ buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let promised = declaredLength(buffer) ?? 0
        return buffer.count - headerEnd.upperBound < promised ? promised : nil
    }

    /// The connection ceiling, answered rather than dropped.
    private func tooManyConnections(_ conn: NWConnection) {
        FileHandle.standardError.write(Data("chatbox: over \(maxConnections) connections -> 503\n".utf8))
        respond(conn, status: 503, body: """
        error: the server is at its connection limit (\(maxConnections)) — retry shortly, or raise \
        it with --max-connections.

        """)
    }

    /// A body that stops before the length it announced is a request that was never made, and the
    /// sender is the one party who cannot tell that from a slow server. Nothing is stored.
    private func truncatedBody(_ conn: NWConnection, promised: Int) {
        FileHandle.standardError.write(Data("chatbox: \(nowISO()) \(peerNote(conn)) body shorter than Content-Length -> 400\n".utf8))
        respond(conn, status: 400, body: """
        error: the body is shorter than the \(promised) bytes Content-Length announced — \
        nothing was stored. Send exactly the bytes you declare.

        """)
    }

    /// Answer rather than drop the connection: an oversized report is an ordinary mistake,
    /// and a sender that is told nothing has no way to learn what went wrong.
    private func tooLarge(_ conn: NWConnection) {
        FileHandle.standardError.write(Data("chatbox: \(nowISO()) \(peerNote(conn)) request over \(maxBody) bytes -> 413\n".utf8))
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
/// Flags that carry a value.
let valueFlags: Set<String> = ["--port", "--db", "--token", "--token-file", "--stale-after",
                              "--max-body", "--tls-identity", "--tls-password-file", "--prune",
                              "--backup", "--verify-backup", "--idle-timeout", "--max-connections",
                              "--max-rows", "--server-id", "--peer", "--peer-token",
                              "--max-hops"]
/// Flags that are their own value. A boolean flag at the end of the line is complete, and one
/// that is handed a value is a mistake worth naming.
let boolFlags: Set<String> = ["--prune-dry-run"]
let knownFlags: Set<String> = valueFlags.union(boolFlags)

func checkArguments(_ argv: [String]) {
    var seen = Set<String>()
    var i = 1
    while i < argv.count {
        let raw = argv[i]
        guard raw.hasPrefix("--") else {
            FileHandle.standardError.write(Data("chatbox: unexpected argument '\(raw)'\n".utf8))
            exit(2)
        }
        // `--name=value` is one token; `--name value` is two, and the value is whatever
        // follows — including something that looks like another flag, so skip it.
        let name = String(raw.prefix(while: { $0 != "=" }))
        let hasInlineValue = raw.contains("=")
        guard knownFlags.contains(name) else {
            FileHandle.standardError.write(Data("chatbox: unknown flag '\(name)' — refusing to start rather than ignore it\n".utf8))
            exit(2)
        }
        guard seen.insert(name).inserted else {
            FileHandle.standardError.write(Data("chatbox: '\(name)' given more than once\n".utf8))
            exit(2)
        }
        // Every flag here takes a value, so a trailing one is a mistake — and silently
        // falling back to the default is the same failure as a misspelt flag: the server
        // starts with a setting nobody asked for.
        if valueFlags.contains(name) && !hasInlineValue && i + 1 >= argv.count {
            FileHandle.standardError.write(Data("chatbox: '\(name)' needs a value\n".utf8))
            exit(2)
        }
        if boolFlags.contains(name) && hasInlineValue {
            FileHandle.standardError.write(Data("chatbox: '\(name)' does not take a value\n".utf8))
            exit(2)
        }
        i += (hasInlineValue || boolFlags.contains(name)) ? 1 : 2
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
///
/// The `=` form counts as present. Testing only for the bare token meant `--prune=` was
/// invisible to every guard — `argPresent` false, value empty — and the operator who typed it
/// got a running board back instead of a prune.
func argPresent(_ name: String) -> Bool {
    CommandLine.arguments.contains { $0 == name || $0.hasPrefix(name + "=") }
}

// ---- reading a board that is *not* this process's database ----
//
// The backup mode checks a file the server has not opened, and it must never create or modify
// what it is checking: verification that writes is not verification. So it opens read-only, and
// a file that is not a database at all — or an empty one, which is what a hand copy of a WAL
// database looks like — fails here rather than being reported as a good backup.

/// The tables a usable board has. A copy missing any of them is not a backup of anything.
let boardTables = ["agents", "threads", "messages", "deliveries", "tokens"]

/// One text value, or nil when the statement cannot even be prepared or stepped.
func sqliteText(_ db: OpaquePointer?, _ sql: String) -> String? {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
    return String(cString: c)
}

/// Whether a non-empty `-wal` sits beside this file. If one does, the file is not at rest: the
/// write-ahead log is part of its content and has to be read with it, the ordinary way. If none
/// does, the file can be read as an immutable snapshot — which writes no `-shm` beside it, and is
/// therefore the only way to verify a backup sitting on a read-only mount.
func hasPendingWAL(_ path: String) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path + "-wal"),
          let n = attrs[.size] as? NSNumber else { return false }
    return n.intValue > 0
}

/// A path as the body of a `file:` URI: the three characters that would change its meaning.
func uriPath(_ path: String) -> String {
    path.replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: "?", with: "%3F")
        .replacingOccurrences(of: "#", with: "%23")
}

/// Row counts for every board table, or the reason the file cannot be read as a board. An empty
/// file, a 4 KB header, a truncated copy, a plain text file and a database with no board tables
/// all fail — which is the point: none of them is a backup, and each one used to look like one.
/// The reason is carried out so the caller can name the real problem instead of guessing at it.
/// What reading a board file produced: its table counts, or the reason it is not a board. A plain
/// enum rather than `Result` because the failure is a sentence for the operator, not an `Error`.
enum BoardRead {
    case counts([String: Int])
    case problem(String)
}

func boardCounts(_ path: String) -> BoardRead {
    var db: OpaquePointer?
    let pending = hasPendingWAL(path)
    let target = pending ? path : "file:\(uriPath(path))?immutable=1"
    let flags = pending ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK else {
        let why = String(cString: sqlite3_errmsg(db))
        sqlite3_close(db)
        return .problem("cannot be opened (\(why))")
    }
    defer { sqlite3_close(db) }
    // Integrity first: a half-copied file can open and still be unreadable.
    guard let integrity = sqliteText(db, "PRAGMA integrity_check") else {
        return .problem("cannot be read (\(String(cString: sqlite3_errmsg(db))))")
    }
    guard integrity == "ok" else {
        return .problem("fails its integrity check (\(integrity))")
    }
    var out: [String: Int] = [:]
    for table in boardTables {
        guard let n = sqliteText(db, "SELECT COUNT(*) FROM \(table)") else {
            return .problem("has no usable `\(table)` table (\(String(cString: sqlite3_errmsg(db))))")
        }
        out[table] = Int(n)
    }
    return .counts(out)
}

/// The `agents=3 threads=5 …` line, shared by both modes so the two outputs cannot drift.
func boardCountsLine(_ counts: [String: Int]) -> String {
    boardTables.map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
}

/// Bytes on disk, or `?` when the file cannot be measured. The size is reported because the
/// whole trap is a copy whose size looked plausible.
func fileSize(_ path: String) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let n = attrs[.size] as? NSNumber else { return "?" }
    return "\(n.intValue)"
}

/// Read a file as a board, or explain why it is not one. Shared by both modes so neither can
/// report a file it could not read as verified.
func readBoard(_ path: String) -> BoardRead {
    let shown = NSString(string: path).expandingTildeInPath
    switch boardCounts(shown) {
    case .counts(let counts):
        return .counts(counts)
    case .problem(let why):
        // An absent file gets its own sentence: "not a usable board" is the wrong thing to say
        // about a path that was never there.
        if !FileManager.default.fileExists(atPath: shown) {
            return .problem("\(shown) does not exist — a backup you have not read is not a backup")
        }
        return .problem("\(shown) is not a usable board — \(why)")
    }
}

/// Check a copy against the board it came from. Used by `--verify-backup --db <board>`, where the
/// question is "is this copy current?": any row the board has that the copy does not makes it out
/// of date. `--backup` deliberately does *not* use this — see `verifyCopy`.
func verifyBoard(_ path: String, against sourcePath: String) -> String? {
    let shown = NSString(string: path).expandingTildeInPath
    let source = NSString(string: sourcePath).expandingTildeInPath
    let counts: [String: Int]
    switch readBoard(shown) {
    case .counts(let c): counts = c
    case .problem(let why): return why
    }
    let sourceCounts: [String: Int]
    switch readBoard(source) {
    case .counts(let c): sourceCounts = c
    case .problem(let why): return "\(why), so there is nothing to compare \(shown) with"
    }
    let differing = boardTables.filter { counts[$0] != sourceCounts[$0] }
    if !differing.isEmpty {
        let detail = differing.map {
            "\($0): \(counts[$0] ?? 0) in the copy, \(sourceCounts[$0] ?? 0) in \(source)"
        }
        return "\(shown) is out of date — " + detail.joined(separator: "; ")
    }
    return nil
}

/// Check a copy against the counts the source had when the copy was taken.
///
/// A live board keeps accepting writes while it is being copied, so a copy is a *snapshot*: it
/// legitimately holds fewer rows than a re-read of the board a moment later. Requiring equality
/// with the board would fail the one case this command exists for — under a steady writer, the
/// backup of a live board failed almost every time. A copy that holds *fewer* rows than the source
/// had before the copy began is the defect: it lost committed data.
func verifyCopy(_ path: String, atLeast snapshot: [String: Int]) -> String? {
    let shown = NSString(string: path).expandingTildeInPath
    let counts: [String: Int]
    switch readBoard(shown) {
    case .counts(let c): counts = c
    case .problem(let why): return why
    }
    let behind = boardTables.filter { (counts[$0] ?? -1) < (snapshot[$0] ?? 0) }
    if !behind.isEmpty {
        let detail = behind.map { "\($0): \(counts[$0] ?? 0) in the copy, \(snapshot[$0] ?? 0) before it" }
        return "\(shown) lost rows — " + detail.joined(separator: "; ")
    }
    return nil
}

// Every file this process creates holds message history or a copy of it: the database, the WAL
// beside it, and a `--backup` copy. The umask is what decides their mode, and the default (022) made
// them world-readable. 077 is the rule, and `Store.init` also tightens a database that already
// existed under a looser one.
umask(0o077)

checkArguments(CommandLine.arguments)

// The port is the address every client is pointed at, so a value this server cannot bind is
// refused instead of quietly replaced by the default: `--port 9000o` used to bind 8787 and leave
// the caller talking to nothing, with no server-side signal. `UInt16` accepts "0", which asks the
// kernel for an unnamed port, so the floor is 1 — the same rule as the other bounded flags below.
let portRaw = argValue("--port", "8787")
let portValue = UInt16(portRaw) ?? 0
if portValue < 1 {
    FileHandle.standardError.write(Data("chatbox: --port must be between 1 and 65535 — got '\(portRaw)'\n".utf8))
    exit(2)
}
let port = portValue
let dbPath = argValue("--db", NSString(string: "~/chatbox.sqlite").expandingTildeInPath)
let tokenArg = argValue("--token", "")
let tokenFile = argValue("--token-file", "")
// A *present* flag with an empty value is a mistake, not a request for an open board. `argValue`
// cannot tell "flag absent" from "flag given nothing", so `--token "$SECRET"` with SECRET unset —
// and `--token-file ""` in a unit file that meant to name one — used to clear the token and come up
// with `auth: OPEN (no token)`: every route as bootstrap, no diagnostic, no log line. Open mode is
// asked for by name (`--token open`) or by passing no token flag at all.
if argPresent("--token") && tokenArg.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --token was given but is empty — refusing to start an open board (use --token open to ask for one by name)\n".utf8))
    exit(2)
}
if argPresent("--token-file") && tokenFile.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --token-file was given but names no file — refusing to start an open board\n".utf8))
    exit(2)
}
// Prefer --token-file: a token passed as argv is visible to every local user in `ps`.
let tokenFromFile: String = {
    guard !tokenFile.isEmpty else { return "" }
    let p = NSString(string: tokenFile).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
        FileHandle.standardError.write(Data("chatbox: cannot read --token-file \(p)\n".utf8))
        exit(1)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}()
// A token file that exists but is empty used to mean "no token", which silently
// started an OPEN board. Refuse instead: open mode must be asked for by name.
if !tokenFile.isEmpty && tokenFromFile.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --token-file \(tokenFile) is empty — refusing to start an open board\n".utf8))
    exit(1)
}
let token = !tokenArg.isEmpty ? tokenArg : (tokenFromFile.isEmpty ? nil : tokenFromFile)

// Every flag is validated before any mode acts on it. `--stale-after` used to be checked after the
// store had been opened and after the operator modes had already exited, so `--prune 30
// --stale-after abc` pruned, printed success and never read the window on the command line.
let staleAfterRaw = argValue("--stale-after", "604800")
// `?? -1` rather than `?? 604800`: a window nobody asked for must stop the server, not restore the
// seven-day default. `--stale-after 7d` used to be accepted *as* the default, so a session that had
// gone quiet was still reported active — presence reporting behaving unlike the command line.
let staleAfterValue = Int(staleAfterRaw) ?? -1
if staleAfterValue < 0 {
    // A negative window used to mean "off", which fails open on a typo.
    FileHandle.standardError.write(Data("chatbox: --stale-after must be 0 (off) or a positive number of seconds — got '\(staleAfterRaw)'\n".utf8))
    exit(2)
}
let staleAfter = staleAfterValue

// ---- operator mode: backup, and exit ----
//
// Deliberately before `Store` is opened: opening a store *creates* the schema, so a backup that
// opened the source first would happily "back up" a board that did not exist and call the empty
// result verified.
//
// The SQLite file is the service, and copying it by hand is the trap that produced two 4 KB
// backups on node1: in WAL mode committed rows live in `-wal` until a checkpoint, so a `cp` of
// the main file copies an empty database that looks plausible. `VACUUM INTO` writes a
// consistent, compacted copy of a live database, folds the WAL in, and refuses an existing
// destination rather than quietly replacing a good backup with today's.
let backupRaw = argValue("--backup", "")
let verifyRaw = argValue("--verify-backup", "")
// Read here, with the other operator modes, so the flags can be checked against each other before
// any of them acts.
let pruneRaw = argValue("--prune", "")
if argPresent("--backup") && backupRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --backup needs a destination path\n".utf8))
    exit(2)
}
if argPresent("--verify-backup") && verifyRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --verify-backup needs a path to check\n".utf8))
    exit(2)
}
if !backupRaw.isEmpty && !verifyRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --backup and --verify-backup do different things — give one of them\n".utf8))
    exit(2)
}
// One operator mode at a time. Each of these runs and exits, so a second one was silently ignored:
// `--backup x --prune 30` copied the board, exited 0 and never pruned, and the operator had every
// reason to believe both had happened.
let operatorModes = [("--backup", backupRaw), ("--verify-backup", verifyRaw), ("--prune", pruneRaw)]
    .filter { !$0.1.isEmpty }.map { $0.0 }
if operatorModes.count > 1 {
    FileHandle.standardError.write(Data("chatbox: \(operatorModes.joined(separator: " and ")) ask for different things — give one operator mode\n".utf8))
    exit(2)
}
if !verifyRaw.isEmpty {
    // `--db` is optional here and only means "and compare against this board": the default is
    // `~/chatbox.sqlite`, and silently comparing a copy the operator named against whatever
    // board happens to live in the home directory is how a verified backup becomes a mystery.
    if argPresent("--db") {
        if let problem = verifyBoard(verifyRaw, against: dbPath) {
            FileHandle.standardError.write(Data("chatbox: \(problem)\n".utf8))
            exit(1)
        }
    } else if case .problem(let why) = readBoard(verifyRaw) {
        FileHandle.standardError.write(Data("chatbox: \(why)\n".utf8))
        exit(1)
    }
    let shown = NSString(string: verifyRaw).expandingTildeInPath
    print("backup ok: \(shown) (\(fileSize(shown)) bytes)")
    if case .counts(let counts) = boardCounts(shown) { print(boardCountsLine(counts)) }
    if argPresent("--db") { print("compared with: \(NSString(string: dbPath).expandingTildeInPath)") }
    exit(0)
}
if !backupRaw.isEmpty {
    // An explicit --db, because the default is `~/chatbox.sqlite` and a backup of the wrong
    // board is indistinguishable from a backup of an empty one.
    guard argPresent("--db") else {
        FileHandle.standardError.write(Data("chatbox: --backup needs an explicit --db <path> — refusing to guess which board to copy\n".utf8))
        exit(2)
    }
    let sourcePath = NSString(string: dbPath).expandingTildeInPath
    let destPath = NSString(string: backupRaw).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: sourcePath) else {
        FileHandle.standardError.write(Data("chatbox: \(sourcePath) does not exist — nothing to back up\n".utf8))
        exit(1)
    }
    // The counts *before* the copy, which is what the copy is proved against: a live board moves
    // on while it is being copied, and requiring the snapshot to equal a later re-read would fail
    // every backup taken under a writer — the case this command exists for.
    let sourceCounts: [String: Int]
    switch readBoard(sourcePath) {
    case .counts(let c): sourceCounts = c
    case .problem(let why):
        FileHandle.standardError.write(Data("chatbox: \(why) — refusing to copy it as if it were a board\n".utf8))
        exit(1)
    }
    var db: OpaquePointer?
    guard sqlite3_open_v2(sourcePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        FileHandle.standardError.write(Data("chatbox: cannot open \(sourcePath)\n".utf8))
        exit(1)
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    // `VACUUM INTO` reads a consistent snapshot, so it is safe against a live board, and it
    // refuses a destination that already exists — overwriting yesterday's only good backup with
    // a half-written file is worse than an error message.
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &st, nil) == SQLITE_OK else {
        FileHandle.standardError.write(Data("chatbox: cannot prepare the copy of \(sourcePath)\n".utf8))
        exit(1)
    }
    sqlite3_bind_text(st, 1, destPath, -1, transientDestructor())
    let rc = sqlite3_step(st)
    sqlite3_finalize(st)
    if rc != SQLITE_DONE {
        let reason = String(cString: sqlite3_errmsg(db))
        FileHandle.standardError.write(Data("chatbox: the copy to \(destPath) failed: \(reason) — nothing was verified\n".utf8))
        exit(1)
    }
    // The copy is verified in the same command: a backup nobody read is not a backup. If it is not
    // usable it is removed, because a file that failed verification must not sit there looking like
    // one — and because leaving it would make the obvious retry fail on "already exists".
    if let problem = verifyCopy(destPath, atLeast: sourceCounts) {
        try? FileManager.default.removeItem(atPath: destPath)
        FileHandle.standardError.write(Data("chatbox: \(problem) — the copy was removed\n".utf8))
        exit(1)
    }
    print("source: \(sourcePath) (\(fileSize(sourcePath)) bytes)")
    print("backup: \(destPath) (\(fileSize(destPath)) bytes)")
    print(boardCountsLine(sourceCounts) + "  (nothing below this was lost)")
    exit(0)
}

// ---- operator mode: prune, and exit ----
//
// Before the key migration, deliberately: a dry run must not write anything at all, and the
// migration rewrites rows. It runs on the next start as usual.
//
// Deliberately not a route on the running server. Deleting the record of a cross-repo fix is an
// operator's decision on the database; a session must not be able to hide history, and the
// running board must not start deleting rows on a timer nobody is watching.
//
// Like the backup modes, this validates the *file* before anything opens it. `sqlite3_open` creates
// a missing file, so a mistyped `--db` used to produce a brand-new board and a cheerful
// "pruned: 0 message(s)" - and a dry run left that new file behind, in a mode whose whole promise is
// that it changes nothing.
// The window has to stay expressible. `isoDaysAgo` renders an ISO string, and past the year
// 9999 the formatter drops the sign and the cutoff lands in the *future* — where `created_at <
// cutoff` is true for everything, so a typo would prune every acknowledged message regardless
// of age. 100 years is past the life of any board.
let pruneCeiling = 36500
// Present but unusable is a mistake, not a request to start the server: an operator who typed
// `--prune` and got a running board back would reasonably believe the board was pruned.
if argPresent("--prune") && pruneRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --prune needs a number of days\n".utf8))
    exit(2)
}
if argPresent("--prune-dry-run") && pruneRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --prune-dry-run means nothing without --prune\n".utf8))
    exit(2)
}
if !pruneRaw.isEmpty {
    guard let pruneDays = Int(pruneRaw), pruneDays >= 0, pruneDays <= pruneCeiling else {
        FileHandle.standardError.write(Data("chatbox: --prune needs a number of days between 0 and \(pruneCeiling) (0 means every acknowledged message, whatever its age) — got '\(pruneRaw)'\n".utf8))
        exit(2)
    }
    // An explicit --db, because the default is `~/chatbox.sqlite` and a prune aimed at the
    // wrong board is indistinguishable from one that found nothing to do.
    guard argPresent("--db") else {
        FileHandle.standardError.write(Data("chatbox: --prune needs an explicit --db <path> — refusing to guess which board to prune\n".utf8))
        exit(2)
    }
    let prunePath = NSString(string: dbPath).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: prunePath) else {
        FileHandle.standardError.write(Data("chatbox: \(prunePath) does not exist — refusing to create a board to prune\n".utf8))
        exit(1)
    }
    if case .problem(let why) = readBoard(prunePath) {
        FileHandle.standardError.write(Data("chatbox: \(why) — refusing to open it for prune\n".utf8))
        exit(1)
    }
    let dryRun = argPresent("--prune-dry-run")
    // The operator modes have no server yet, so they run their store work on the same queue the
    // server would: one rule, no exception to remember. A dry run gets a read-only connection, so it
    // cannot create, convert or migrate the file it is only reading; the store is built inside the
    // closure because `prune` needs it for the length of the call and nothing beyond it does.
    let pruned = chatboxQueue.sync {
        Store(path: prunePath, migrating: !dryRun, readOnly: dryRun, queue: chatboxQueue)
            .prune(olderThanDays: pruneDays, dryRun: dryRun)
    }
    guard let result = pruned else {
        FileHandle.standardError.write(Data("chatbox: the prune failed and was rolled back — nothing was changed\n".utf8))
        exit(1)
    }
    print("database: \(dbPath)")
    print("\(dryRun ? "would prune" : "pruned"): \(result.messages) message(s), \(result.threads) thread(s), \(result.deliveries) delivery(ies)")
    print("window: delivered and fully acknowledged, older than \(pruneDays) day(s)")
    print("never pruned: any message with an unacknowledged delivery, and any message nobody was sent")
    if dryRun { print("nothing was removed — drop --prune-dry-run to do it") }
    exit(0)
}

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
    FileHandle.standardError.write(Data("chatbox: --max-body must be between 512 and \(maxBodyCeiling) bytes (a request line and its headers need the floor; the ceiling is what bounds memory) — got '\(maxBodyRaw)'\n".utf8))
    exit(2)
}
let maxBody = maxBodyValue

// The other three bounds. Each is checked at startup for the same reason the request cap is: a
// value that bounds nothing, or bounds everything, looks like a configured server from outside and
// is discovered only under load.
let idleRaw = argValue("--idle-timeout", "30")
let idleValue = Int(idleRaw) ?? -1
if idleValue < 0 || idleValue > 3600 {
    FileHandle.standardError.write(Data("chatbox: --idle-timeout must be between 0 (no deadline) and 3600 seconds — got '\(idleRaw)'\n".utf8))
    exit(2)
}
let idleTimeout = idleValue

let maxConnRaw = argValue("--max-connections", "256")
let maxConnValue = Int(maxConnRaw) ?? 0
if maxConnValue < 1 || maxConnValue > 65535 {
    FileHandle.standardError.write(Data("chatbox: --max-connections must be between 1 and 65535 — got '\(maxConnRaw)'\n".utf8))
    exit(2)
}
let maxConnections = maxConnValue

let maxRowsRaw = argValue("--max-rows", "500")
let maxRowsValue = Int(maxRowsRaw) ?? 0
if maxRowsValue < 1 || maxRowsValue > 1000000 {
    FileHandle.standardError.write(Data("chatbox: --max-rows must be between 1 and 1000000 — got '\(maxRowsRaw)'\n".utf8))
    exit(2)
}
let maxRows = maxRowsValue

// Federation (TRK-17): one hop to one peer. `--server-id` is the name this board stamps into every
// hop list it writes and the default is the machine's own name, so a board that never federates
// still has an identity to report. A peer URL that cannot be used, or a peer credential with
// nowhere to go, is a configuration that promises forwarding and does none — refused at startup,
// like the bounds above, rather than discovered when a report goes missing.
let serverIDRaw = argValue("--server-id", Host.current().name ?? "chatbox")
let serverID = serverIDRaw
// The machine's own name is held to the same rule as a given one, and it is refused rather than
// repaired: a board id that is silently altered is one the operator did not choose, and the error
// names the flag that fixes it. There is no trimming here on purpose — a leading or trailing space
// is exactly the shape that would arrive empty on the peer.
if !validBoardID(serverID) {
    FileHandle.standardError.write(Data("chatbox: --server-id must be a name with no whitespace, control or format characters and no comma — got '\(oneLine(serverIDRaw))'\n".utf8))
    exit(2)
}
let peerRaw = argValue("--peer", "")
var peerURL = ""
if !peerRaw.isEmpty {
    guard var comps = URLComponents(string: peerRaw),
          let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = comps.host, !host.isEmpty else {
        FileHandle.standardError.write(Data("chatbox: --peer must be an http(s) URL naming a board — got '\(oneLine(peerRaw))'\n".utf8))
        exit(2)
    }
    // A peer is a board, not a request: a query or a fragment cannot mean anything here, and
    // keeping one would put it in the middle of every forwarded URL rather than at the end.
    if comps.query != nil || comps.fragment != nil {
        FileHandle.standardError.write(Data("chatbox: --peer names a board, not a request — drop the query or fragment from '\(oneLine(peerRaw))'\n".utf8))
        exit(2)
    }
    // Credentials in the URL are refused because the peer URL is *echoed*: /health prints it for
    // any credential to read, and so does every answer that names the peer. `--peer-token` exists
    // for the secret, and it is not printed.
    if comps.user != nil || comps.password != nil {
        FileHandle.standardError.write(Data("chatbox: --peer must not carry credentials — they would be printed by /health; use --peer-token\n".utf8))
        exit(2)
    }
    if let peerPort = comps.port, peerPort < 1 || peerPort > 65535 {
        FileHandle.standardError.write(Data("chatbox: --peer must name a port between 1 and 65535 — got '\(peerPort)'\n".utf8))
        exit(2)
    }
    // Stored without a trailing slash, so appending "/message" cannot double it.
    while comps.path.hasSuffix("/") { comps.path.removeLast() }
    guard let normalized = comps.string else {
        FileHandle.standardError.write(Data("chatbox: --peer is not a usable URL — got '\(oneLine(peerRaw))'\n".utf8))
        exit(2)
    }
    peerURL = normalized
}
if argPresent("--peer") && peerURL.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --peer needs a board URL — refusing to start with a peer that names nothing\n".utf8))
    exit(2)
}
let peerToken = argValue("--peer-token", "")
if peerURL.isEmpty && !peerToken.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --peer-token means nothing without --peer\n".utf8))
    exit(2)
}
// A token with a line break in it was silently dropped by the HTTP layer, so the forward went out
// unauthenticated and was answered 401 — a misconfiguration reported as a peer problem. Refused
// where the operator can see it instead.
if !peerToken.isEmpty && hasControlByte(peerToken) {
    FileHandle.standardError.write(Data("chatbox: --peer-token must be one line, without control characters\n".utf8))
    exit(2)
}
// A peer that is this board cannot be forwarded to: the request would arrive here while this board
// waits for its own answer, and the message would be stored a second time. Detected by port *and* a
// local address, so two boards on different machines that both use 8787 are not confused for one.
if !peerURL.isEmpty, let peerComps = URLComponents(string: peerURL) {
    let peerPort = peerComps.port ?? ((peerComps.scheme ?? "") == "https" ? 443 : 80)
    var selfHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]
    if let own = Host.current().name?.lowercased() {
        selfHosts.insert(own)
        if let short = own.split(separator: ".").first { selfHosts.insert(String(short)) }
    }
    for address in Host.current().addresses { selfHosts.insert(address.lowercased()) }
    if peerPort == Int(port), selfHosts.contains((peerComps.host ?? "").lowercased()) {
        FileHandle.standardError.write(Data("chatbox: --peer names this board (port \(port)) — a forward would be a duplicate, not a delivery\n".utf8))
        exit(2)
    }
}
let maxHopsRaw = argValue("--max-hops", "4")
let maxHopsValue = Int(maxHopsRaw) ?? 0
if maxHopsValue < 1 || maxHopsValue > 64 {
    FileHandle.standardError.write(Data("chatbox: --max-hops must be between 1 and 64 — got '\(maxHopsRaw)'\n".utf8))
    exit(2)
}
let maxHops = maxHopsValue

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
    FileHandle.standardError.write(Data("chatbox: --tls-identity was given without a usable path — refusing to start rather than serve in the clear\n".utf8))
    exit(2)
}
if tlsIdentityPath.isEmpty && !tlsPasswordFile.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --tls-password-file means nothing without --tls-identity\n".utf8))
    exit(2)
}
// macOS will not open a bundle with an empty passphrase (measured: every
// empty-password bundle, from OpenSSL 3 and LibreSSL alike, comes back as
// errSecAuthFailed), so demanding the file turns a confusing "wrong password" into a
// clear one.
if !tlsIdentityPath.isEmpty && tlsPasswordFile.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --tls-identity needs --tls-password-file — macOS cannot open a PKCS#12 bundle with no passphrase\n".utf8))
    exit(2)
}
var tlsPassword = ""
if !tlsIdentityPath.isEmpty && !tlsPasswordFile.isEmpty {
    let p = NSString(string: tlsPasswordFile).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
        FileHandle.standardError.write(Data("chatbox: cannot read --tls-password-file \(p)\n".utf8))
        exit(2)
    }
    tlsPassword = s.trimmingCharacters(in: .whitespacesAndNewlines)
}
var tlsIdentity: sec_identity_t? = nil
if !tlsIdentityPath.isEmpty {
    guard let identity = loadTLSIdentity(p12Path: tlsIdentityPath, password: tlsPassword) else {
        FileHandle.standardError.write(Data("chatbox: refusing to start — TLS was asked for and could not be set up\n".utf8))
        exit(2)
    }
    tlsIdentity = identity
}

// The store the *server* serves from. Created here - after every flag has been validated and after
// the operator modes have run and exited - so a mistyped flag or a prune aimed at the wrong file
// cannot leave a migrated database behind. It is created on the queue it will be used on, so its
// `dispatchPrecondition` holds from the first statement of the schema migration to the last request
// it serves.
let store = chatboxQueue.sync { Store(path: dbPath, queue: chatboxQueue) }

// The public URL is part of the configuration the board is built from, not a global it writes back
// into: it is what every usage answer tells a caller to connect to.
let scheme = tlsIdentity == nil ? "http" : "https"
let publicURL = "\(scheme)://\(Host.current().name ?? "localhost"):\(port)"
let server = Chatbox(store: store, token: token, staleAfter: staleAfter,
                     tlsEnabled: tlsIdentity != nil, maxBody: maxBody,
                     idleTimeout: idleTimeout, maxConnections: maxConnections, maxRows: maxRows,
                     serverID: serverID, peerURL: peerURL, peerToken: peerToken, maxHops: maxHops,
                     publicURL: publicURL, queue: chatboxQueue)

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
    FileHandle.standardError.write(Data("chatbox: cannot listen on \(port): \(error)\n".utf8))
    exit(1)
}
listener.newConnectionHandler = { conn in server.serve(conn: conn) }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let addrs = Host.current().addresses.filter { $0.contains(".") }
        print("chatbox listening on port \(port)")
        print("db: \(dbPath)")
        // Before anything reads a key: a board that has been running has keys written under the old
// rules, and they have to mean the same thing as the new ones or mail goes missing.
        let migratedKeys = store.migrateRepoKeys()
        // The board's own configuration, read from the board: this closure is `@Sendable`, and a
        // top-level `var` is main-actor isolated, so reaching for `peerURL`/`tlsIdentity` here was
        // both a concurrency error and a second source of truth. `server` is the one source.
        let boardIsOpen = server.token == nil || server.token == "open"
        print("auth: \(boardIsOpen ? "OPEN (no token)" : "token required")")
        let idleBanner = server.idleTimeout == 0 ? "no idle deadline" : "\(server.idleTimeout)s idle deadline"
        print("bounds: \(server.maxRows) rows per listing, \(server.maxConnections) connections, \(idleBanner)")
        print("federation: \(server.peerURL.isEmpty ? "off — this board is '\(server.serverID)' and forwards nothing" : "forwarding to \(server.peerURL) as '\(server.serverID)', at most \(server.maxHops) hops accepted")")
        print("staleness: \(server.staleAfter == 0 ? "off" : "a session unheard from for " + humanSeconds(server.staleAfter))")
        print("transport: \(server.tlsEnabled ? "TLS" : "plain HTTP — the token crosses the network in the clear")")
        print("max request: \(server.maxBody) bytes")
        if migratedKeys.changed > 0 { print("normalised: \(migratedKeys.changed) stored repo key(s) rewritten to the canonical form") }
        if migratedKeys.left > 0 { print("normalised: \(migratedKeys.left) stored key(s) are not usable keys and were left alone — see Protocol") }
        for a in addrs { print("  \(server.tlsEnabled ? "https" : "http")://\(a):\(port)/") }
        // stdout is block-buffered when redirected to a file, and this process never
        // exits, so without a flush the banner never reaches chatbox.log.
        fflush(stdout)
    case .failed(let e):
        FileHandle.standardError.write(Data("chatbox: listener failed: \(e)\n".utf8))
        exit(1)
    default: break
    }
}
listener.start(queue: server.queue)

// A stop has to be a stop. `kill -TERM` (what a supervisor sends), `kill -INT` (Ctrl-C) and any
// `pkill` all take this path: stop accepting, end the held answers, fold the write-ahead log back
// into the database, leave a line saying so, and exit 0. Without it the process died where it stood,
// so a client could not tell "not stored" from "stored but unanswered", a retry duplicated a report,
// and the `-wal` was left for whoever read the file next.
//
// SIGHUP is *ignored* rather than handled: this board writes to the stderr its operator redirected,
// so rotating that file is `copytruncate` and needs no signal. Dying on `kill -HUP` - which is what
// logrotate sends by default - was an outage with nothing on the other side of it.
//
// `signal(..., SIG_IGN)` first: the dispatch source takes over delivery, and the default disposition
// must not be able to fire in the window before it does.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)
let stopSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: server.queue)
let stopSourceInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: server.queue)
let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: server.queue)
let shutdownHandler: @Sendable () -> Void = {
    server.requestShutdown()
    listener.cancel()
    store.checkpointWAL()
    FileHandle.standardError.write(Data("chatbox: \(nowISO()) shutdown: stopped accepting, held answers ended, WAL checkpointed — exiting\n".utf8))
    // The queue is serial, so everything already accepted has run by the time this runs; the held
    // answers end on their own timers within half a second. This is the grace they get to leave.
    server.queue.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
stopSource.setEventHandler(handler: shutdownHandler)
stopSourceInt.setEventHandler(handler: shutdownHandler)
hupSource.setEventHandler {
    FileHandle.standardError.write(Data("chatbox: \(nowISO()) SIGHUP ignored — this board logs to stderr; rotate it with copytruncate, or stop it with SIGTERM\n".utf8))
}
stopSource.resume()
stopSourceInt.resume()
hupSource.resume()

dispatchMain()
