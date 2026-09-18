// Chatbox+IO.swift — request parsing, logging, the connection loop and its bounds.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

extension Chatbox {
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
                    if let r = v.range(of: "Bearer ") {
                        req.token = String(v[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
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
            buffer.count - headerEnd.upperBound >= declared
        else { return nil }
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
                let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            {
                for (k, v) in obj { req.params[k] = "\(v)" }
            } else if contentType.contains("form") || bodyString.contains("=") {
                for (k, v) in parseForm(bodyString) where req.params[k] == nil { req.params[k] = v }
            }
            if req.params["body"] == nil && req.params["text"] == nil && req.params["message"] == nil
                && !req.params.keys.contains("subject")
            {
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
    func finish(
        _ req: Request, conn: NWConnection, status: Int, body: String,
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        // One line per request, and it has to be a record rather than a note: when it happened, who
        // asked, as whom, what they asked for and what came back. It used to be `METHOD PATH ->
        // STATUS` and nothing else, so an operator could not order events after an incident,
        // attribute an authentication failure, or tell which credential issued or revoked one.
        // `oneLine` is belt and braces - the request line is refused upstream if it carries a
        // control byte - because a log line a peer can end is a log a peer can write into.
        FileHandle.standardError.write(
            Data(
                "chatbox: \(nowISO()) \(req.peer.isEmpty ? "-" : req.peer) \(oneLine(req.method)) \(oneLine(req.path)) -> \(status) principal=\(req.principal.isEmpty ? "-" : req.principal)\n"
                    .utf8))
        respond(conn, status: status, body: body, contentType: contentType, headers: headers)
    }

    /// The peer's address, for a log line. `-` when the connection has no nameable endpoint, which is
    /// what a log line must say rather than nothing.
    func peerNote(_ conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "-"
    }

    /// One line per action an operator has to be able to reconstruct after an incident, with the ids
    /// it touched. The *secret* of a credential never appears here; only its id, which the credential
    /// listing already shows.
    func audit(_ what: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        FileHandle.standardError.write(Data("chatbox: \(nowISO()) audit \(oneLine(what))\n".utf8))
    }

    func respond(
        _ conn: NWConnection, status: Int, body: String,
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) {
        let reason =
            status == 200
            ? "OK"
            : (status == 400
                ? "Bad Request"
                : (status == 401
                    ? "Unauthorized"
                    : (status == 403
                        ? "Forbidden"
                        : (status == 404
                            ? "Not Found"
                            : (status == 413
                                ? "Payload Too Large"
                                : (status == 503 ? "Service Unavailable" : "Error"))))))
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for key in headers.keys.sorted() { head += "\(key): \(headers[key] ?? "")\r\n" }
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
                FileHandle.standardError.write(
                    Data(
                        "chatbox: \(nowISO()) \(peerNote(conn)) refused without an answer: \(maxConnections) refusal(s) already in flight\n"
                            .utf8))
                conn.cancel()
                return
            }
            refusedConnections.insert(identity)
            let refusal = Deadline()
            let refusalIdle = DispatchWorkItem { [weak self, weak conn] in
                guard !refusal.isCancelled else { return }
                guard let self = self, let conn = conn else { return }
                self.refusedConnections.remove(identity)
                FileHandle.standardError.write(
                    Data(
                        "chatbox: \(nowISO()) \(self.peerNote(conn)) refused connection closed after \(self.idleTimeout)s without a request\n"
                            .utf8))
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

    func receive(_ conn: NWConnection, buffer: Data, deadline: Deadline) {
        // Never read far past the cap: the point of the limit is the memory, so the read
        // itself is bounded by it rather than by whatever the peer decides to send.
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(131_072, self.maxBody + 1)) {
            data, _, isComplete, error in
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
    func declaredLength(_ buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8)
        else { return nil }
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
    func bodyShortfall(_ buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let promised = declaredLength(buffer) ?? 0
        return buffer.count - headerEnd.upperBound < promised ? promised : nil
    }

    /// The connection ceiling, answered rather than dropped.
    func tooManyConnections(_ conn: NWConnection) {
        FileHandle.standardError.write(Data("chatbox: over \(maxConnections) connections -> 503\n".utf8))
        respond(
            conn, status: 503,
            body: """
                error: the server is at its connection limit (\(maxConnections)) — retry shortly, or raise \
                it with --max-connections.

                """)
    }

    /// A body that stops before the length it announced is a request that was never made, and the
    /// sender is the one party who cannot tell that from a slow server. Nothing is stored.
    func truncatedBody(_ conn: NWConnection, promised: Int) {
        FileHandle.standardError.write(
            Data("chatbox: \(nowISO()) \(peerNote(conn)) body shorter than Content-Length -> 400\n".utf8))
        respond(
            conn, status: 400,
            body: """
                error: the body is shorter than the \(promised) bytes Content-Length announced — \
                nothing was stored. Send exactly the bytes you declare.

                """)
    }

    /// Answer rather than drop the connection: an oversized report is an ordinary mistake,
    /// and a sender that is told nothing has no way to learn what went wrong.
    func tooLarge(_ conn: NWConnection) {
        FileHandle.standardError.write(
            Data("chatbox: \(nowISO()) \(peerNote(conn)) request over \(maxBody) bytes -> 413\n".utf8))
        respond(
            conn, status: 413,
            body: """
                error: request too large — the limit is \(maxBody) bytes, and it covers the whole \
                request (request line, headers and body). Raise it with --max-body, or send the \
                report in a shorter form.

                """)
    }
}
