// Support.swift — shared helpers, value types and the serial queue.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

func transientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// Long-poll tuning. A held inbox request is served by re-checking on this
// interval rather than by blocking, so a waiter never occupies the server's
// serial queue and every other request is answered normally while it waits.
// The interval doubles while there is nothing to report, up to the cap, so an idle board of waiters
// does not query at a fixed rate for the whole five-minute hold; a delivery is still picked up
// within the cap. The re-check itself is a cached-principal validity read, not a full authorize:
// the SHA-256 of the presented secret is not recomputed on every tick.
let longPollInterval: TimeInterval = 0.25
let longPollBackoffCap: TimeInterval = 1.0
/// The most recipients one message may be delivered to. `--max-body` already bounds the list a
/// request can carry; this is the stated ceiling on the fan-out work, so a send cannot make the
/// board write an unbounded number of delivery rows in one transaction. 500 matches `--max-rows`,
/// the board's other listing ceiling, and is far above any real fan-out for this product.
let maxRecipients = 500
let maxWaitSeconds = 300
/// How many messages one inbox answer may carry. The cap is deliberate — a session that falls
/// behind must not be handed an unbounded body — but it is never *silent*: the answer states how
/// many deliveries match and how many of them it is showing.
let inboxLimit = 200
/// How often a held waiter refreshes `last_seen`, at most. It is capped by the
/// staleness window: refreshing every 60s would report a live waiter as stale
/// whenever the window is shorter than that.
func longPollTouchInterval(_ staleAfter: Int) -> TimeInterval {
    if staleAfter <= 0 { return 60 }
    return min(60, max(1, Double(staleAfter) / 2))
}

/// One ISO-8601 style for everything this server writes and reads: UTC, second precision, the exact
/// shape stored in the database and compared there as a string. `Date.ISO8601FormatStyle` is a value
/// type and `Sendable`, so it can be a shared constant; `ISO8601DateFormatter` is a class with
/// mutable state, which Swift 6 refuses as a `static` shared across threads — and building a fresh
/// one per call was the alternative. Verified byte-identical to the old formatter's output, and the
/// same style parses a stamp that carries fractional seconds, which is why one is enough here.
enum ISOStamp {
    // `?? .gmt` rather than `!`: secondsFromGMT 0 is UTC and cannot fail, but the initializer is
    // optional, and the standard rejects the force-unwrap rather than the reasoning behind it.
    static let style = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)

    static func now() -> String { style.format(Date()) }

    static func daysAgo(_ days: Int) -> String {
        style.format(Date().addingTimeInterval(-Double(days) * 86400))
    }

    static func daysAhead(_ days: Int) -> String {
        style.format(Date().addingTimeInterval(Double(days) * 86400))
    }
}

func nowISO() -> String { ISOStamp.now() }

/// The same shape as `nowISO`, so the two compare as strings in SQL.
func isoDaysAgo(_ days: Int) -> String { ISOStamp.daysAgo(days) }

/// An ISO-8601 stamp `days` from now, for a credential's expiry. Compared as a string, like every
/// other timestamp here, which is why the format has to match `nowISO` exactly.
func isoDaysAhead(_ days: Int) -> String { ISOStamp.daysAhead(days) }

/// Credentials are stored only as a SHA-256 of the secret. The secrets are 192 bits
/// of randomness, so a fast hash is the right tool — there is nothing to brute
/// force, and a slow KDF would only make every request expensive.
func sha256Hex(_ s: String) -> String {
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
func secretsMatch(_ a: String, _ b: String) -> Bool {
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
func isLoopback(_ host: String) -> Bool {
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
        FileHandle.standardError.write(
            Data(
                "chatbox: cannot open --tls-identity \(p): OSStatus \(status) — wrong password, or not a PKCS#12 bundle\n"
                    .utf8))
        return nil
    }
    var identities: [SecIdentity] = []
    for item in list {
        // Type-checked rather than `as!`: the contract says the value is an identity,
        // but a bundle that says otherwise should be a diagnostic, not a trap.
        if let raw = item[kSecImportItemIdentity as String] {
            let cf = raw as CFTypeRef
            // `unsafeDowncast`, not `as!`: the type-id check on the previous line has already proved
            // the cast, and this is the explicit CF downcast rather than the force-cast operator
            // SwiftLint flags. A policy that does not carry the identity is skipped, not trapped.
            if CFGetTypeID(cf) == SecIdentityGetTypeID() {
                identities.append(unsafeDowncast(cf, to: SecIdentity.self))
            }
        }
    }
    // Exactly one. A bundle holding several makes the choice arbitrary, and the
    // arbitrary one is presented along with its private key — an operator who bundled
    // a CA or a client-auth key next to the server key would publish the wrong one.
    guard identities.count == 1 else {
        FileHandle.standardError.write(
            Data(
                "chatbox: --tls-identity \(p) holds \(identities.count) identities — a server identity must be the only one in the bundle (OSStatus \(status))\n"
                    .utf8))
        return nil
    }
    return sec_identity_create(identities[0])
}

/// A file's permission bits as three octal digits ("600"), or "" when they cannot be read. `stat`
/// rather than Foundation: this is a number the kernel already has, and a formatter for it would be
/// one more thing that can differ between machines.
/// What this binary is: the revision of the source it was built from, and the executable's own
/// stamp. The deployment path is "rebuild it and pkill the old one", and a restart can leave the old
/// binary serving (`pkill -f "AISessionServer/chatbox"` silently matches nothing, because the process
/// shows as `./chatbox --port …`), so the first question after a rollback is "which build is this?" —
/// and there was no way to ask it, from the banner, from `/health` or from the command line.
let sourceRevision = "audit/2026-09-15"

func buildIdentity() -> String {
    var info = stat()
    let exe = CommandLine.arguments.first ?? "chatbox"
    let built: String
    if stat(exe, &info) == 0 {
        built = ISOStamp.style.format(Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    } else {
        built = "unknown"
    }
    return "build: \(sourceRevision) — \(exe), stamped \(built)"
}

/// The command line, for `--help`. The long form of this text is the server's own usage answer
/// (served as `GET /help` and `GET /ui`) and the README; this is the part an operator needs before
/// starting anything - the flags, and where the full text lives.
func usageSummary() -> String {
    """
    chatbox - harness-independent session chatbox (text only, no file access)

    chatbox --port <n> --db <path> [--token SECRET | --token-file PATH | --token open]
            [--stale-after SECONDS] [--max-body BYTES] [--max-rows N] [--idle-timeout SECONDS]
            [--max-connections N] [--server-id NAME]
            [--tls-identity P12 --tls-password-file PATH]
            [--peer URL (--peer-token-file PATH | --peer-token SECRET) [--max-hops N]]
    chatbox --db <path> --prune DAYS [--prune-dry-run]
    chatbox --db <path> --backup <copy> | chatbox --verify-backup <copy> [--db <board>]
    chatbox --version

    GET /help and GET /ui serve the same text; the README and the wiki carry the full API.
    """
}

func fileMode(_ path: String) -> String {
    var info = stat()
    guard stat(path, &info) == 0 else { return "" }
    return String(format: "%03o", info.st_mode & 0o777)
}

func hasControlByte(_ s: String) -> Bool {
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
            out.unicodeScalars.append(UnicodeScalar(scalar.value + 32) ?? scalar)
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
            if let at = host.lastIndex(of: "@") {
                host = String(host[host.index(after: at)...])
            } else {
                ambiguous = true
            }
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
func validId(_ id: String) -> Bool {
    if id.isEmpty { return false }
    return !hasControlByte(id)
}

/// A board id travels in a hop list, is read back through the same trimming every parameter gets,
/// and is echoed into a thread as `(via …)`. So it is a name and nothing else: no whitespace *at all*
/// (including the Unicode separators `CharacterSet.whitespaces` does not cover, which every parameter
/// reader trims away — a board id that arrives empty is a message that looks like it came from a
/// sender, and that is the one case a board forwards), no control or format characters, and no comma,
/// which would split one board into two entries of the list.
func validBoardID(_ s: String) -> Bool {
    if s.isEmpty || s.contains(",") { return false }
    for scalar in s.unicodeScalars where scalar.properties.isWhitespace { return false }
    return !hasControlByte(s)
}

/// Echoing a rejected value back is useful; echoing its line breaks is not, because
/// the message is printed by clients and read by whatever is driving them.
///
/// The set is the characters a reader treats as a line break, not just `\n`: C0 controls and DEL,
/// plus NEL (U+0085) and the Unicode line and paragraph separators LS/PS (U+2028/U+2029). A value
/// carrying any of those is the value that can repaint a listing, and `oneLine`'s whole contract is
/// that what it returns cannot start a new line. `hasControlByte` does not cover the separators
/// (they are Zl/Zp, not Cc/Cf), so they are named here explicitly.
func oneLine(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F
            || scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029
        {
            out.append(" ")
        } else {
            out.unicodeScalars.append(scalar)
        }
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
    let gone = Mutex(false)
    var peerGone: Bool {
        get { gone.withLock { $0 } }
        set { gone.withLock { $0 = newValue } }
    }
}

/// A one-way "the deadline no longer applies" flag, shared between the accept deadline and the
/// receive loop. The deadline is a `DispatchWorkItem`, which is not `Sendable` — so the two sides
/// agree through this instead of through the work item, and the work item is only ever *executed*.
final class Deadline: Sendable {
    let done = Mutex(false)
    var isCancelled: Bool { done.withLock { $0 } }
    func cancel() { done.withLock { $0 = true } }
}

/// A compact duration for operator-facing text, floored: `7d`, `3h`, `90s` -> `1m`.
func humanSeconds(_ seconds: Int) -> String {
    if seconds <= 0 { return "0s" }
    if seconds >= 86400 { return "\(seconds / 86400)d" }
    if seconds >= 3600 { return "\(seconds / 3600)h" }
    if seconds >= 60 { return "\(seconds / 60)m" }
    return "\(seconds)s"
}

func randomHex(_ bytes: Int) -> String {
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
