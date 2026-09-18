// main.swift — process-wide setup, argument validation and the executable entry point.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

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
    FileHandle.standardError.write(
        Data(
            "chatbox: --token was given but is empty — refusing to start an open board (use --token open to ask for one by name)\n"
                .utf8))
    exit(2)
}
if argPresent("--token-file") && tokenFile.isEmpty {
    FileHandle.standardError.write(
        Data("chatbox: --token-file was given but names no file — refusing to start an open board\n".utf8))
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
    FileHandle.standardError.write(
        Data("chatbox: --token-file \(tokenFile) is empty — refusing to start an open board\n".utf8))
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
    FileHandle.standardError.write(
        Data("chatbox: --stale-after must be 0 (off) or a positive number of seconds — got '\(staleAfterRaw)'\n".utf8))
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
    FileHandle.standardError.write(
        Data("chatbox: --backup and --verify-backup do different things — give one of them\n".utf8))
    exit(2)
}
// One operator mode at a time. Each of these runs and exits, so a second one was silently ignored:
// `--backup x --prune 30` copied the board, exited 0 and never pruned, and the operator had every
// reason to believe both had happened.
if operatorModes.count > 1 {
    FileHandle.standardError.write(
        Data(
            "chatbox: \(operatorModes.joined(separator: " and ")) ask for different things — give one operator mode\n"
                .utf8))
    exit(2)
}
if argPresent("--prune") && pruneRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --prune needs a number of days\n".utf8))
    exit(2)
}
if argPresent("--prune-dry-run") && pruneRaw.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --prune-dry-run means nothing without --prune\n".utf8))
    exit(2)
}
let maxBodyRaw = argValue("--max-body", "8192")
let maxBodyValue = Int(maxBodyRaw) ?? 0
// A ceiling as well as a floor. The cap is what bounds memory, so a cap that is itself
// unbounded is not a cap: one connection then decides how much this server allocates.
// 4 MB is the guard the receive loop used to carry on its own.
let maxBodyCeiling = 4 * 1024 * 1024
if maxBodyValue < 512 || maxBodyValue > maxBodyCeiling {
    FileHandle.standardError.write(
        Data(
            "chatbox: --max-body must be between 512 and \(maxBodyCeiling) bytes (a request line and its headers need the floor; the ceiling is what bounds memory) — got '\(maxBodyRaw)'\n"
                .utf8))
    exit(2)
}
let maxBody = maxBodyValue

// The other three bounds. Each is checked at startup for the same reason the request cap is: a
// value that bounds nothing, or bounds everything, looks like a configured server from outside and
// is discovered only under load.
let idleRaw = argValue("--idle-timeout", "30")
let idleValue = Int(idleRaw) ?? -1
if idleValue < 0 || idleValue > 3600 {
    FileHandle.standardError.write(
        Data("chatbox: --idle-timeout must be between 0 (no deadline) and 3600 seconds — got '\(idleRaw)'\n".utf8))
    exit(2)
}
let idleTimeout = idleValue

let maxConnRaw = argValue("--max-connections", "256")
let maxConnValue = Int(maxConnRaw) ?? 0
if maxConnValue < 1 || maxConnValue > 65535 {
    FileHandle.standardError.write(
        Data("chatbox: --max-connections must be between 1 and 65535 — got '\(maxConnRaw)'\n".utf8))
    exit(2)
}
let maxConnections = maxConnValue

let maxRowsRaw = argValue("--max-rows", "500")
let maxRowsValue = Int(maxRowsRaw) ?? 0
if maxRowsValue < 1 || maxRowsValue > 1000000 {
    FileHandle.standardError.write(
        Data("chatbox: --max-rows must be between 1 and 1000000 — got '\(maxRowsRaw)'\n".utf8))
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
    FileHandle.standardError.write(
        Data(
            "chatbox: --server-id must be a name with no whitespace, control or format characters and no comma — got '\(oneLine(serverIDRaw))'\n"
                .utf8))
    exit(2)
}
let peerRaw = argValue("--peer", "")
var peerURL = ""
if !peerRaw.isEmpty {
    guard var comps = URLComponents(string: peerRaw),
        let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
        let host = comps.host, !host.isEmpty
    else {
        FileHandle.standardError.write(
            Data("chatbox: --peer must be an http(s) URL naming a board — got '\(oneLine(peerRaw))'\n".utf8))
        exit(2)
    }
    // A peer is a board, not a request: a query or a fragment cannot mean anything here, and
    // keeping one would put it in the middle of every forwarded URL rather than at the end.
    if comps.query != nil || comps.fragment != nil {
        FileHandle.standardError.write(
            Data(
                "chatbox: --peer names a board, not a request — drop the query or fragment from '\(oneLine(peerRaw))'\n"
                    .utf8))
        exit(2)
    }
    // Credentials in the URL are refused because the peer URL is *echoed*: /health prints it for
    // any credential to read, and so does every answer that names the peer. `--peer-token` exists
    // for the secret, and it is not printed.
    if comps.user != nil || comps.password != nil {
        FileHandle.standardError.write(
            Data(
                "chatbox: --peer must not carry credentials — they would be printed by /health; use --peer-token\n".utf8
            ))
        exit(2)
    }
    if let peerPort = comps.port, peerPort < 1 || peerPort > 65535 {
        FileHandle.standardError.write(
            Data("chatbox: --peer must name a port between 1 and 65535 — got '\(peerPort)'\n".utf8))
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
    FileHandle.standardError.write(
        Data("chatbox: --peer needs a board URL — refusing to start with a peer that names nothing\n".utf8))
    exit(2)
}
// The peer credential is the peer's *bootstrap* credential (README), so a copy in `ps` is a copy of
// the other board's full operator key. `--peer-token-file` is the way in that keeps it off the
// command line, mirroring `--token-file`; `--peer-token` still works and says what it costs.
let peerTokenArg = argValue("--peer-token", "")
let peerTokenFile = argValue("--peer-token-file", "")
if argPresent("--peer-token-file") && peerTokenFile.isEmpty {
    FileHandle.standardError.write(Data("chatbox: --peer-token-file was given but names no file\n".utf8))
    exit(2)
}
let peerTokenFromFile: String = {
    guard !peerTokenFile.isEmpty else { return "" }
    let p = NSString(string: peerTokenFile).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
        FileHandle.standardError.write(Data("chatbox: cannot read --peer-token-file \(p)\n".utf8))
        exit(2)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}()
if !peerTokenFile.isEmpty && peerTokenFromFile.isEmpty {
    FileHandle.standardError.write(
        Data("chatbox: --peer-token-file \(peerTokenFile) is empty — refusing to forward unauthenticated\n".utf8))
    exit(2)
}
if !peerTokenArg.isEmpty && !peerTokenFromFile.isEmpty {
    FileHandle.standardError.write(Data("chatbox: give --peer-token or --peer-token-file, not both\n".utf8))
    exit(2)
}
if !peerTokenArg.isEmpty && peerTokenFromFile.isEmpty {
    FileHandle.standardError.write(
        Data(
            "chatbox: note: --peer-token on the command line is visible to every local user in `ps`; --peer-token-file keeps it out\n"
                .utf8))
}
let peerToken = peerTokenFromFile.isEmpty ? peerTokenArg : peerTokenFromFile
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
        FileHandle.standardError.write(
            Data(
                "chatbox: --peer names this board (port \(port)) — a forward would be a duplicate, not a delivery\n"
                    .utf8))
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
    FileHandle.standardError.write(
        Data(
            "chatbox: --tls-identity was given without a usable path — refusing to start rather than serve in the clear\n"
                .utf8))
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
    FileHandle.standardError.write(
        Data(
            "chatbox: --tls-identity needs --tls-password-file — macOS cannot open a PKCS#12 bundle with no passphrase\n"
                .utf8))
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
var tlsIdentity: sec_identity_t?
if !tlsIdentityPath.isEmpty {
    guard let identity = loadTLSIdentity(p12Path: tlsIdentityPath, password: tlsPassword) else {
        FileHandle.standardError.write(
            Data("chatbox: refusing to start — TLS was asked for and could not be set up\n".utf8))
        exit(2)
    }
    tlsIdentity = identity
}

// The store the *server* serves from. Created here - after every flag has been validated and after
// the operator modes have run and exited - so a mistyped flag or a prune aimed at the wrong file
// cannot leave a migrated database behind. It is created on the queue it will be used on, so its
// `dispatchPrecondition` holds from the first statement of the schema migration to the last request
// it serves.
// `--help` and `--version` answer and exit **before the store is opened**. They used to be refused as
// unknown flags ("unknown flag '--help' - refusing to start rather than ignore it", exit 2), which is
// the one answer an operator asking "what is this binary" or "how do I run it" must not get - and
// answering them after the store would open the configured database, tighten its mode and touch the
// live board's file just to print a string.
if argPresent("--version") {
    print(buildIdentity())
    exit(0)
}
if argPresent("--help") {
    print(usageSummary())
    exit(0)
}

runOperatorModeIfRequested(verifyRaw: verifyRaw, backupRaw: backupRaw, pruneRaw: pruneRaw, dbPath: dbPath)
startServer(
    port: port, dbPath: dbPath, token: token, staleAfter: staleAfter, tlsIdentity: tlsIdentity,
    maxBody: maxBody, idleTimeout: idleTimeout, maxConnections: maxConnections, maxRows: maxRows,
    serverID: serverID, peerURL: peerURL, peerToken: peerToken, maxHops: maxHops)
