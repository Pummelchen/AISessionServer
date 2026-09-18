// Startup.swift — open the store, build the server, bind the listener and run.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

func startServer(
    port: UInt16, dbPath: String, token: String?, staleAfter: Int, tlsIdentity: sec_identity_t?,
    maxBody: Int, idleTimeout: Int, maxConnections: Int, maxRows: Int, serverID: String,
    peerURL: String, peerToken: String, maxHops: Int
) {
    let store = chatboxQueue.sync { Store(path: dbPath, queue: chatboxQueue) }

    // The public URL is part of the configuration the board is built from, not a global it writes back
    // into: it is what every usage answer tells a caller to connect to.
    let scheme = tlsIdentity == nil ? "http" : "https"
    let publicURL = "\(scheme)://\(Host.current().name ?? "localhost"):\(port)"
    let server = Chatbox(
        store: store, token: token, staleAfter: staleAfter,
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
    // Refused rather than force-unwrapped: `--port` is validated earlier, so this is unreachable in
    // practice, but an invalid port here would otherwise trap instead of saying why it refused.
    guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
        FileHandle.standardError.write(Data("chatbox: \(port) is not a usable port\n".utf8))
        exit(1)
    }
    let listener: NWListener
    do {
        listener = try NWListener(using: params, on: listenerPort)
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
            print(buildIdentity())
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
            print(
                "federation: \(server.peerURL.isEmpty ? "off — this board is '\(server.serverID)' and forwards nothing" : "forwarding to \(server.peerURL) as '\(server.serverID)', at most \(server.maxHops) hops accepted")"
            )
            print(
                "staleness: \(server.staleAfter == 0 ? "off" : "a session unheard from for " + humanSeconds(server.staleAfter))"
            )
            print("transport: \(server.tlsEnabled ? "TLS" : "plain HTTP — the token crosses the network in the clear")")
            print("max request: \(server.maxBody) bytes")
            if migratedKeys.changed > 0 {
                print("normalised: \(migratedKeys.changed) stored repo key(s) rewritten to the canonical form")
            }
            if migratedKeys.left > 0 {
                print(
                    "normalised: \(migratedKeys.left) stored key(s) are not usable keys and were left alone — see Protocol"
                )
            }
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
        FileHandle.standardError.write(
            Data(
                "chatbox: \(nowISO()) shutdown: stopped accepting, held answers ended, WAL checkpointed — exiting\n"
                    .utf8))
        // The queue is serial, so everything already accepted has run by the time this runs; the held
        // answers end on their own timers. A waiter's next tick is at most `longPollBackoffCap` away, so
        // the grace is that plus a margin — a flat half-second was right only for the old fixed 0.25 s
        // tick and cut a backed-off long poll's socket before it could send its 503.
        server.queue.asyncAfter(deadline: .now() + longPollBackoffCap + 0.5) { exit(0) }
    }
    stopSource.setEventHandler(handler: shutdownHandler)
    stopSourceInt.setEventHandler(handler: shutdownHandler)
    hupSource.setEventHandler {
        FileHandle.standardError.write(
            Data(
                "chatbox: \(nowISO()) SIGHUP ignored — this board logs to stderr; rotate it with copytruncate, or stop it with SIGTERM\n"
                    .utf8))
    }
    stopSource.resume()
    stopSourceInt.resume()
    hupSource.resume()

    dispatchMain()

}
