// Chatbox.swift — the server type: configuration, stored state and construction.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

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
    /// every other request is served.
    ///
    /// **Concurrent, deliberately.** It used to be serial, so the Nth forward waited behind N-1
    /// peer timeouts while its sender's connection stayed open: with a dead peer, N messages cost
    /// roughly N x 10 s and enough of them exhausted `--max-connections`. Each forward now runs as
    /// soon as it is accepted, so the wait for any one sender is bounded by the peer's own timeout
    /// rather than by the queue depth. The cost is the ordering the serial queue gave: two forwards
    /// for the same repo may reach the peer concurrently. `maxConcurrentForwards` bounds how many
    /// outbound requests exist at once, and `maxConnections` bounds the held sender connections.
    let forwardQueue = DispatchQueue(label: "chatbox.forward", attributes: .concurrent)
    /// How many forwards may be in flight at once. It bounds the outbound URLSessions a burst can
    /// create; beyond it a sender is told the board is already forwarding rather than queued behind
    /// an unbounded backlog.
    let maxConcurrentForwards = 8
    /// The number of forwards currently in flight. Only touched on `queue`, which is where it is
    /// incremented (before handing the forward to `forwardQueue`) and decremented (in the completion
    /// that hops back to `queue`), so no lock is needed.
    var forwardsInFlight = 0

    init(
        store: Store, token: String?, staleAfter: Int, tlsEnabled: Bool, maxBody: Int,
        idleTimeout: Int, maxConnections: Int, maxRows: Int, serverID: String,
        peerURL: String, peerToken: String, maxHops: Int, publicURL: String,
        queue: DispatchQueue
    ) {
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
    }

    /// Connections that have been accepted and not yet finished. Kept as identities rather than a
    /// count so a connection that reports both `failed` and `cancelled` cannot be subtracted twice.
    var liveConnections = Set<ObjectIdentifier>()

    /// Refused connections that are still open: a socket the process holds while it waits to answer
    /// "too many connections". They are not `liveConnections` - refusing one must not keep the server
    /// at its limit - but they are sockets, so they get the idle deadline and a ceiling of their own.
    var refusedConnections = Set<ObjectIdentifier>()

    /// Set when the process has been asked to stop. The answers that are *held* - a long poll, an
    /// event stream - check it on their next tick, so a restart ends them with an answer instead of
    /// a cut socket, and neither can outlive the process that promised to hold it.
    var shuttingDown = false
    /// The URL this board tells callers to use, fixed at startup. It was a `static var` assigned
    /// after the instance was built, which is mutable global state the compiler cannot reason about
    /// — and the only thing that ever read it was the usage text.
    let publicURL: String
    /// The last computed counts and the `boardToken` they were computed under. Both `pollEvents`
    /// and `health` run on the serial queue, so this needs no lock; it exists so an idle stream (or
    /// a monitoring poll) does not scan the messages table several times a second for a number that
    /// has not changed. A change this process cannot see (another process's `--prune`) moves
    /// `PRAGMA data_version`, so the cache is not blind to it.
    var boardCache: (token: String, state: BoardState)?
}
