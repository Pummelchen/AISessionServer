// Chatbox+Reads.swift — thread, inbox, peers and credential listings.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

extension Chatbox {
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
        var out =
            "thread \(id)  repo: \((head["repo"] ?? "").isEmpty ? "-" : oneLine(head["repo"] ?? ""))  subject: \(oneLine(head["subject"] ?? "-"))\n"
        out +=
            "opened: \(head["created_at"] ?? "-") by \(oneLine(head["created_by"] ?? "-"))   "
            + "\(rows.count)\(matching > rows.count ? " of \(matching)" : "") message(s)\n"
        if matching > rows.count {
            out +=
                "note: the newest \(rows.count) are shown, \(matching - rows.count) older one(s) are not"
                + " — raise --max-rows to read further back\n"
        }
        for r in rows {
            let via = (r["origin"] ?? "").isEmpty ? "" : "  (via \(r["origin"] ?? ""))"
            out +=
                "\n--- [\(r["id"] ?? "")] \(r["created_at"] ?? "")  \(oneLine(r["sender"] ?? "")) → \((r["recipients"] ?? "").isEmpty ? "(nobody)" : oneLine(r["recipients"] ?? ""))\(via)\n"
            if !(r["subject"] ?? "").isEmpty, r["id"] == rows.first?["id"] {
                out += "subject: \(oneLine(r["subject"] ?? ""))\n"
            }
            if let rt = r["reply_to"], !rt.isEmpty, rt != "0" { out += "(reply to \(rt))\n" }
            out += "\(r["body"] ?? "")\n"
        }
        return (200, out)
    }

    func listThreads(_ req: Request, _ who: Principal) -> (Int, String) {
        let repoRaw = req.p("repo")
        var repo = ""
        if !repoRaw.isEmpty {
            guard let key = canonicalRepoKey(repoRaw) else {
                return (400, "error: '\(oneLine(repoRaw))' is not a valid repo key\n")
            }
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
        let sql =
            "SELECT t.id, t.repo, t.subject, t.created_at, t.last_at, (SELECT COUNT(*) FROM messages m WHERE m.thread_id=t.id) AS n FROM threads t"
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
        var out =
            "threads\(repo.isEmpty ? "" : " for \(repo)") — \(rows.count)"
            + (matchingThreads > rows.count ? " of \(matchingThreads)" : "") + "\n"
        if matchingThreads > rows.count {
            out += "note: \(matchingThreads - rows.count) older one(s) are not shown — raise --max-rows to see them\n"
        }
        for r in rows {
            out +=
                "\n[\(r["id"] ?? "")] \(r["last_at"] ?? "")  \(r["n"] ?? "0") msg  repo: \((r["repo"] ?? "").isEmpty ? "-" : oneLine(r["repo"] ?? ""))\n  \(oneLine(r["subject"] ?? "-"))\n"
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
            let r = store.runReporting(
                """
                UPDATE deliveries SET acked_at=? WHERE agent=? AND message_id=? AND (acked_at IS NULL OR acked_at='')
                """, [nowISO(), id, req.p("message")])
            rc = r.rc; n = Int(r.changes)
        } else if req.flag("all") {
            let r = store.runReporting(
                """
                UPDATE deliveries SET acked_at=? WHERE agent=? AND (acked_at IS NULL OR acked_at='')
                """, [nowISO(), id])
            rc = r.rc; n = Int(r.changes)
        } else if !req.p("thread").isEmpty {
            // One statement for the whole thread rather than one per message: the count is then
            // what the ack changed, and a long thread is not a long list of statements.
            let r = store.runReporting(
                """
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
            rows[i]["status"] =
                staleAfter == 0
                ? "unknown"
                : (isStale(seen, now: now) ? "stale" : "active")
            rows[i]["age"] = ageDescription(seen, now: now)
        }
        if req.flag("json") { return (200, jsonRows(rows, key: "agents", matching: matchingAgents)) }
        var out = "registered agents — \(rows.count)\(matchingAgents > rows.count ? " of \(matchingAgents)" : "")\n"
        if matchingAgents > rows.count {
            out +=
                "note: \(matchingAgents - rows.count) more are registered than are shown — raise --max-rows to see them\n"
        }
        if staleAfter == 0 { out += "(staleness reporting is off)\n" }
        for r in rows {
            let status = r["status"] ?? "active"
            out +=
                "\n\(oneLine(r["id"] ?? ""))  (\(oneLine(r["agent"] ?? "-")) on \(oneLine(r["node"] ?? "-")))  \(status == "stale" ? "STALE" : status)\n"
            out += "  repos: \((r["repos"] ?? "").isEmpty ? "(none declared)" : oneLine(r["repos"] ?? ""))\n"
            if !(r["ip"] ?? "").isEmpty || !(r["session"] ?? "").isEmpty {
                out +=
                    "  ip: \(oneLine(r["ip"] ?? "-"))  session: \(oneLine(r["session"] ?? "-"))  harness: \(oneLine(r["harness"] ?? "-"))\n"
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
                return (
                    400,
                    "error: '\(oneLine(ns))' is not a usable namespace — use a repo key, a key ending in /*, or *\n"
                )
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
                let days = Int(expiresRaw), days > 0, days <= 36500
            else {
                return (
                    400, "error: expires must be a number of days between 1 and 36500 — got '\(oneLine(expiresRaw))'\n"
                )
            }
            expiresAt = isoDaysAhead(days)
        }
        let secret = randomHex(24)
        let id = "tk-" + randomHex(6)
        let stored = store.addToken(
            id: id, hash: sha256Hex(secret), node: node,
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
        let exposure =
            tlsEnabled || req.peer.isEmpty || isLoopback(req.peer)
            ? ""
            : "\nwarning: this was issued over a non-loopback connection (\(req.peer)) with no TLS\n"
                + "         so the secret above crossed the network in the clear. Prefer issuing\n"
                + "         from the server itself, restart with --tls-identity, or terminate TLS\n"
                + "         in front of it (see the Deployment page).\n"
        return (
            200,
            """
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
            """
        )
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
            out +=
                "note: \(matchingTokens - rows.count) more are issued than are shown — raise --max-rows to see them\n"
        }
        for r in rows {
            let revoked = !(r["revoked_at"] ?? "").isEmpty
            let expires = r["expires_at"] ?? ""
            let expired = !expires.isEmpty && expires <= nowISO()
            let state = revoked || expired ? (revoked ? "REVOKED" : "EXPIRED") : "active"
            out += "\n\(r["id"] ?? "")  \(state)  node: \(r["node"] ?? "-")\n"
            out += "  namespaces: \((r["namespaces"] ?? "").isEmpty ? "(none)" : oneLine(r["namespaces"] ?? ""))\n"
            out +=
                "  issued: \(r["created_at"] ?? "-")   last used: \((r["last_used"] ?? "").isEmpty ? "never" : (r["last_used"] ?? ""))\n"
            out += "  expires: \(expires.isEmpty ? "never (until revoked)" : expires)\n"
            if !(r["note"] ?? "").isEmpty { out += "  note: \(r["note"] ?? "")\n" }
            if revoked { out += "  revoked: \(r["revoked_at"] ?? "")\n" }
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
            FileHandle.standardError.write(
                Data("chatbox: the revoke of \(id) did not run: \(store.lastError())\n".utf8))
            return (
                500,
                "error: the revocation did not run — \(oneLine(id)) is still valid (\(oneLine(store.lastError())))\n"
            )
        }
        audit("credential revoked id=\(oneLine(id))")
        return (
            200,
            """
            ok revoked \(id)
            Every request presenting it is rejected from now on. Other credentials and
            the bootstrap credential are untouched, and no restart is needed.
            """
        )
    }

    /// A bounded listing as an object: the rows plus how many of how many they are. The inbox has
    /// answered this way since TRK-21, for the same reason — an array cannot say that it is a page,
    /// and a consumer that cannot tell is a consumer that silently loses the rest.
    func jsonRows(_ rows: [[String: String]], key: String, matching: Int) -> String {
        let inner = jsonArray(rows).trimmingCharacters(in: .whitespacesAndNewlines)
        return "{\"shown\": \(rows.count), \"matching\": \(matching), \"\(key)\": \(inner)}\n"
    }

    func jsonArray(_ rows: [[String: String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: data, encoding: .utf8)
        else { return "[]\n" }
        return s + "\n"
    }

    // ---------- HTTP plumbing ----------

}
