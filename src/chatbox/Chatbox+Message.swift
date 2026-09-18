// Chatbox+Message.swift — the send/reply path and its renderers.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

extension Chatbox {
    func message(_ req: Request, _ who: Principal) -> Reply {
        let from = req.p("from").isEmpty ? req.p("id") : req.p("from")
        guard !from.isEmpty else { return Reply(400, "error: from required\n") }
        guard validId(from) else {
            return Reply(400, "error: from must be a single line, without control characters\n")
        }
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
                    return Reply(
                        400,
                        "error: hop must name boards — a board id is one line, with no whitespace, control or format characters\n"
                    )
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
                return Reply(
                    400,
                    "error: '\(oneLine(repo))' is not a valid repo key — keys name a repo, are one line, and do not contain '*', '[' or ']' or a space (a '?' or '#' ends the key)\n"
                )
            }
            canonicalRepo = key
        }
        for one in toExplicit.split(separator: ",") {
            let t = one.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard validId(t) else {
                return Reply(400, "error: to must name ids that are single lines, without control characters\n")
            }
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
                return Reply(
                    403, "forbidden: this credential may reply only to a conversation its machine takes part in\n")
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
            FileHandle.standardError.write(
                Data("chatbox: could not begin the send transaction: \(store.lastError())\n".utf8))
            return Reply(500, "error: the message could not be stored — nothing was written\n")
        }

        var threadId: Int64
        if threadIn.isEmpty {
            threadId = store.run(
                "INSERT INTO threads (repo,subject,created_at,created_by,last_at) VALUES (?,?,?,?,?)",
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
        // An explicit bound on the fan-out. `--max-body` already bounds the request, so the list is
        // finite, but the work per message (a delivery row each, and now a bounded set of lookups)
        // should have a stated ceiling rather than one implied by the envelope size. Refused before
        // anything is stored, so the transaction goes back.
        guard recipients.count <= maxRecipients else {
            store.run("ROLLBACK", [])
            return Reply(
                400, "error: too many recipients — \(recipients.count) named, the limit here is \(maxRecipients)\n")
        }

        // The thread's existence is enforced by the insert, not by a read before it:
        // `INSERT … SELECT … WHERE EXISTS` stores the row only while the thread is still
        // there, so an operator's `--prune` racing this reply cannot leave a message
        // nobody can reach. A reply into a thread that is not there stores nothing at
        // all — no message, no delivery, and not even the sender's liveness stamp.
        let attempt = store.runReporting(
            """
            INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,reply_to,recipients,origin)
            SELECT ?,?,?,?,?,?,?,?,? WHERE EXISTS (SELECT 1 FROM threads WHERE id=?)
            """,
            [
                String(threadId), nowISO(), from, effRepo, subject, body, replyTo == 0 ? nil : String(replyTo),
                recipients.joined(separator: ","), hops.first, String(threadId)
            ])
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
            FileHandle.standardError.write(
                Data("chatbox: the sender's liveness stamp failed: \(store.lastError())\n".utf8))
            return Reply(500, "error: the message could not be stored — nothing was written\n")
        }

        // One lookup for every recipient's node and last-seen, before the loop: the loop used to ask
        // for one node per delivery row, and the warning below asked for last-seen up to three more
        // times per delivered id. A failed read here means the delivery rows would record machines
        // that are not the recipients', so it rolls back like the other failed reads on this path.
        let facts = store.agentFacts(recipients)
        if store.readFailed {
            store.run("ROLLBACK", [])
            return Reply(500, "error: the recipients' details could not be read — nothing was written\n")
        }
        for r in recipients {
            let delivery = store.runReporting(
                """
                INSERT OR IGNORE INTO deliveries (message_id,agent,created_at,node) VALUES (?,?,?,?)
                """, [String(msgId), r, nowISO(), facts[r]?.node ?? ""])
            guard delivery.rc == SQLITE_DONE else {
                store.run("ROLLBACK", [])
                FileHandle.standardError.write(
                    Data("chatbox: the delivery to \(r) failed: \(store.lastError())\n".utf8))
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
            FileHandle.standardError.write(
                Data("chatbox: the send transaction would not commit: \(store.lastError())\n".utf8))
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
            scopedSender
                ? !visibleToSender.contains($0)
                : isStale(facts[$0]?.lastSeen ?? "", now: now)
        }
        func unseenLabel(_ id: String) -> String {
            scopedSender
                ? "not visible to this credential"
                : ((facts[id]?.lastSeen ?? "").isEmpty ? "unregistered" : "stale")
        }
        func unseenReason(_ id: String) -> String {
            if scopedSender { return "not a conversation this machine takes part in" }
            let seen = facts[id]?.lastSeen ?? ""
            return seen.isEmpty ? "never registered" : ageDescription(seen, now: now)
        }
        let deliveredTo =
            deliveredKnown
            ? (delivered.isEmpty
                ? "(nobody)"
                : delivered.map { r in
                    let name = oneLine(r)
                    return unseen.contains(r) ? "\(name) (\(unseenLabel(r)))" : name
                }.joined(separator: ", "))
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
        var plan: ForwardPlan?
        if !peerURL.isEmpty, !effRepo.isEmpty, threadIn.isEmpty, toExplicit.isEmpty,
            store.owners(ofRepo: effRepo).isEmpty
        {
            if hops.isEmpty {
                plan = ForwardPlan(
                    from: from, repo: effRepo, subject: subject, body: body,
                    msgID: msgId)
            } else {
                forwardNote =
                    "forward: not sent — this message came from another board (\(hops.joined(separator: ",")))\n"
            }
        }

        var note = ""
        if recipients.isEmpty {
            note =
                effRepo.isEmpty
                ? "\nnote: no recipient — pass repo=<key>, to=<agent>, or thread=<id>\n"
                : (scopedSender
                    ? "\nnote: no visible owner of '\(effRepo)' from this credential; message stored in thread \(threadId)\n"
                    : "\nnote: nobody has registered as an owner of '\(effRepo)' yet; message stored in thread \(threadId)\n")
        }
        if !unseen.isEmpty {
            // `unseenList`, not `who`: this function's `who` parameter is the credential, and
            // rebinding it here made every later read ambiguous at a glance.
            let unseenList = unseen.map { "\(oneLine($0)) (\(unseenReason($0)))" }.joined(separator: ", ")
            // Only claim nobody will read it when nobody is left to.
            let everyone = unseen.count == delivered.count
            // A scoped sender gets the same warning without the board's own numbers: "no sign of X
            // inside the 7d window" is a statement about the registry, which is what the scope
            // exists to withhold.
            if scopedSender {
                note +=
                    "\nwarning: \(unseenList)"
                    + (everyone
                        ? " — the message is stored, but nobody may read it\n"
                        : " — the message is stored, but it may not reach "
                            + (unseen.count == 1 ? "that session" : "those sessions") + "\n")
            } else {
                note +=
                    "\nwarning: no sign of \(unseenList) inside the \(humanSeconds(staleAfter)) staleness window"
                    + (everyone
                        ? " — the message is stored, but nobody may read it\n"
                        : " — the message is stored, but it may not reach "
                            + (unseen.count == 1 ? "that session" : "those sessions") + "\n")
            }
        }
        audit(
            "message id=\(msgId) thread=\(threadId) repo=\(effRepo.isEmpty ? "-" : effRepo) from=\(oneLine(from)) recipients=\(delivered.count)"
        )
        return Reply(
            200,
            """
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
    func unreadHeader(_ rows: [[String: String]]) -> [String: String] {
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
        // `full=1` turns the 1200-character preview off for a caller that is *consuming* the inbox
        // rather than glancing at it: `watch` delivers and acknowledges in one step, so a preview
        // here is a report cut in half and marked read. The default stays a preview because the
        // listing is read by humans too and `/thread` already carries whole bodies (up to
        // `--max-rows` of them), so a full inbox is the same size class as a request the board
        // already serves.
        let full = req.flag("full")
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
        var out =
            "inbox for \(id) — \(shown)\(matching > shown ? " of \(matching)" : "") message(s)"
            + (all ? " (including read)" : " unread") + "\n"
        if matching > shown {
            out +=
                "note: the \(shown) newest are listed, \(matching - shown) older one(s) are not — "
                + "ack what you have read and ask again, or open a thread: GET /thread?id=<thread>\n"
        }
        for r in rows {
            let unread = (r["acked"] ?? "").isEmpty
            out +=
                "\n[\(r["id"] ?? "")]\(unread ? " UNREAD" : " read  ") thread \(r["thread"] ?? "")  \(r["at"] ?? "")\n"
            // A forwarded message is marked here as well as in the thread view: the inbox is the
            // path a session actually reads, and "from: mac3-dsh" alone cannot tell a report from
            // the board next door apart from one written here.
            let via = (r["origin"] ?? "").isEmpty ? "" : " (via \(r["origin"] ?? ""))"
            out +=
                "  from: \(oneLine(r["sender"] ?? ""))\(via)   repo: \((r["repo"] ?? "").isEmpty ? "-" : oneLine(r["repo"] ?? ""))\n"
            if !(r["subject"] ?? "").isEmpty { out += "  subject: \(oneLine(r["subject"] ?? ""))\n" }
            let b = r["body"] ?? ""
            out += "  body: \(b.count > 1200 && !full ? String(b.prefix(1200)) + " …[truncated]" : b)\n"
        }
        out += "\nread a thread: GET /thread?id=<thread>   ·   mark read: POST /ack?id=\(id)&message=<id>\n"
        return out
    }

}
