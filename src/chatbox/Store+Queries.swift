// Store+Queries.swift — registry, inbox, thread and board-count queries.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

extension Store {
    /// nil when the session has never registered.
    func nodeOf(_ id: String) -> String? {
        rows("SELECT node FROM agents WHERE id = ? LIMIT 1", [id]).first.map { $0["node"] ?? "" }
    }

    /// Node and last-seen for a set of agent ids, in a bounded number of queries instead of one per
    /// id. The send path used to ask for each recipient's node while inserting its delivery and then
    /// for its last-seen up to three more times in the unseen-recipient warning — so one request's
    /// query count grew with the length of its `to=` list, on the serial queue every request shares.
    /// Chunked because SQLite's bound-variable limit is finite and a `to=` list is not.
    func agentFacts(_ ids: [String]) -> [String: (node: String, lastSeen: String)] {
        var out: [String: (node: String, lastSeen: String)] = [:]
        var i = 0
        while i < ids.count {
            let end = min(i + 500, ids.count)
            let chunk = Array(ids[i..<end])
            i = end
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in rows(
                "SELECT id, node, last_seen FROM agents WHERE id IN (\(placeholders))",
                chunk.map { Optional($0) })
            {
                let id = row["id"] ?? ""
                if !id.isEmpty { out[id] = (row["node"] ?? "", row["last_seen"] ?? "") }
            }
        }
        return out
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
    ///
    /// It really does run **once**: completion is recorded in `PRAGMA user_version` (0 = not yet
    /// migrated, 1 = done), because otherwise every restart reads all four tables on the listener's
    /// queue and may rewrite every non-canonical row of `messages`, the fastest-growing table — for
    /// a migration that has nothing left to do. A board restored from a backup taken before the
    /// record existed has version 0 and is migrated again; a change to the canonical rule itself
    /// must bump the recorded version so the sweep happens for the board that predates it.
    func migrateRepoKeys() -> (changed: Int, left: Int) {
        if (Int(scalar("PRAGMA user_version")) ?? 0) >= 1 { return (0, 0) }
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
            FileHandle.standardError.write(
                Data(
                    "chatbox: cannot start the key migration transaction (\(String(cString: sqlite3_errmsg(db)))) — refusing to migrate without one\n"
                        .utf8))
            exit(1)
        }
        for row in rows("SELECT id, repos FROM agents") {
            let raw = row["repos"] ?? ""
            if raw.isEmpty { continue }
            let joined = canonicalList(raw, canonicalRepoKey)
            if joined != raw {
                if run("UPDATE agents SET repos=? WHERE id=?", [joined, row["id"] ?? ""]) >= 0 {
                    changed += 1
                } else {
                    left += 1
                }
            } else if canonicalRepoKey(raw) == nil {
                left += 1
            }
        }
        for row in rows("SELECT id, repo FROM threads") {
            let raw = row["repo"] ?? ""
            if raw.isEmpty { continue }
            // Left exactly as it was when it cannot be canonicalised. Blanking it would drop
            // the routing of every reply in that thread, which is a data loss this function
            // exists to prevent.
            let canon = canonicalRepoKey(raw) ?? raw
            if canon != raw {
                if run("UPDATE threads SET repo=? WHERE id=?", [canon, row["id"] ?? ""]) >= 0 {
                    changed += 1
                } else {
                    left += 1
                }
            } else if canonicalRepoKey(raw) == nil {
                left += 1
            }
        }
        for row in rows("SELECT id, namespaces FROM tokens") {
            let raw = row["namespaces"] ?? ""
            if raw.isEmpty { continue }
            let joined = canonicalList(raw, canonicalNamespace)
            if joined != raw {
                if run("UPDATE tokens SET namespaces=? WHERE id=?", [joined, row["id"] ?? ""]) >= 0 {
                    changed += 1
                } else {
                    left += 1
                }
            } else if canonicalNamespace(raw) == nil {
                left += 1
            }
        }
        // History too: the record is shown by `inbox` and by `&json=1`, so a key there that no
        // longer means what the rule says is a report that reads wrongly even though routing
        // does not depend on it.
        for row in rows("SELECT id, repo FROM messages") {
            let raw = row["repo"] ?? ""
            if raw.isEmpty { continue }
            let canon = canonicalRepoKey(raw) ?? raw
            if canon != raw {
                if run("UPDATE messages SET repo=? WHERE id=?", [canon, row["id"] ?? ""]) >= 0 {
                    changed += 1
                } else {
                    left += 1
                }
            }
        }
        let committed = runReporting("COMMIT", [])
        if committed.rc != SQLITE_DONE {
            // Nothing was committed: report it as nothing migrated rather than as work done, so the
            // banner cannot claim keys were normalised by a transaction that never landed.
            FileHandle.standardError.write(
                Data(
                    "chatbox: the key migration could not be committed (\(String(cString: sqlite3_errmsg(db)))) — nothing was migrated; the next start will try again\n"
                        .utf8))
            return (0, changed + left)
        }
        // Record it *after* the commit: a flag set before the work landed would skip the retry the
        // failure above promises. If this write itself fails the migration simply runs again next
        // start, which is idempotent.
        if run("PRAGMA user_version=1") < 0 {
            FileHandle.standardError.write(
                Data(
                    "chatbox: the key migration committed but its completion could not be recorded; the next start will run it again\n"
                        .utf8))
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
        let candidates = rows(
            """
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
                // Named rather than inlined into the `if`, so the loop body is not a single `if`
                // (which reads as a filter and is what SwiftLint's `for_where` asks to rewrite).
                let stale =
                    run(
                        "DELETE FROM threads WHERE id = ? AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = ?)",
                        [thread, thread]) < 0
                if stale { return abandon() }
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
        return rows(
            """
            SELECT \(columns) FROM agents a
             WHERE \(visibleAgentsWhere)
             ORDER BY a.id LIMIT \(limit)
            """, [node, node, node, node, node])
    }

    /// The ids a machine may be told about, as a set. Used where a *listing* is not the answer —
    /// a send response naming its recipients — so the visibility rule stays in one place.
    func visibleAgentIds(forNode node: String) -> Set<String> {
        var out = Set<String>()
        for r in rows(
            "SELECT a.id FROM agents a WHERE \(visibleAgentsWhere)",
            [node, node, node, node, node]) where !(r["id"] ?? "").isEmpty
        {
            out.insert(r["id"] ?? "")
        }
        return out
    }

    /// The three board-wide counts, in one query, for the events feed.
    func boardCounts() -> (agents: Int, threads: Int, messages: Int) {
        let r =
            rows(
                """
                SELECT (SELECT COUNT(*) FROM agents) AS a,
                       (SELECT COUNT(*) FROM threads) AS t,
                       (SELECT COUNT(*) FROM messages) AS m
                """
            ).first ?? [:]
        return (Int(r["a"] ?? "") ?? 0, Int(r["t"] ?? "") ?? 0, Int(r["m"] ?? "") ?? 0)
    }

    /// A cheap fingerprint of the board that changes whenever `boardCounts` would change.
    ///
    /// Two `MAX(id)` reads on `INTEGER PRIMARY KEY` tables are index lookups, and `COUNT(*) FROM
    /// agents` is a small table — where the three `COUNT(*)` over `messages` are a scan of the
    /// fastest-growing table. `PRAGMA data_version` covers the write this connection cannot see:
    /// it changes when *another* connection modifies the file, which is how an operator's `--prune`
    /// in a second process is noticed. The SSE tick and `/health` both go through `Chatbox.boardState`,
    /// which recomputes the counts only when this token changes.
    func boardToken() -> String {
        let r =
            rows(
                """
                SELECT (SELECT COALESCE(MAX(id), 0) FROM messages) AS m,
                       (SELECT COALESCE(MAX(id), 0) FROM threads) AS t,
                       (SELECT COUNT(*) FROM agents) AS a
                """
            ).first ?? [:]
        return "\(r["m"] ?? "")|\(r["t"] ?? "")|\(r["a"] ?? "")|\(scalar("PRAGMA data_version"))"
    }

    func agentCount(visibleTo node: String?) -> Int {
        guard let node = node else { return Int(scalar("SELECT COUNT(*) FROM agents")) ?? 0 }
        return Int(
            scalar(
                "SELECT COUNT(*) FROM agents a WHERE \(visibleAgentsWhere)",
                [node, node, node, node, node])) ?? 0
    }

    /// Cheap "is there anything unread?" for the long-poll path — one indexed
    /// lookup instead of the full inbox join, which is what makes a waiter cheap
    /// even when the session has a long history of already-read mail.
    func hasUnread(forAgent agent: String) -> Bool {
        !rows(
            """
            SELECT 1 FROM deliveries
            WHERE agent = ? AND (acked_at IS NULL OR acked_at = '') LIMIT 1
            """, [agent]
        ).isEmpty
    }

    func deliveries(forAgent agent: String, includeAcked: Bool) -> [[String: String]] {
        let sql = """
            SELECT m.id AS id, m.thread_id AS thread, m.created_at AS at, m.sender AS sender,
                   m.repo AS repo, m.subject AS subject, m.body AS body, m.origin AS origin,
                   d.acked_at AS acked
            FROM deliveries d JOIN messages m ON m.id = d.message_id
            WHERE d.agent = ? \(includeAcked ? "" : "AND (d.acked_at IS NULL OR d.acked_at = '')")
            ORDER BY d.message_id DESC LIMIT \(inboxLimit)
            """
        return rows(sql, [agent])
    }

    /// How many deliveries match the same question `deliveries` answers, so a full page can say
    /// what it left out instead of dropping the oldest unread mail without a word.
    ///
    /// No join to `messages`: a delivery row is written in the same transaction as the message it
    /// names and deleted before that message by `--prune`, so there is no orphan to filter, and the
    /// join made SQLite walk a second table for a count `idx_del_unread` can answer alone.
    func deliveryCount(forAgent agent: String, includeAcked: Bool) -> Int {
        Int(
            scalar(
                """
                SELECT COUNT(*) FROM deliveries
                WHERE agent = ? \(includeAcked ? "" : "AND (acked_at IS NULL OR acked_at = '')")
                """, [agent])) ?? 0
    }

    // ---------- who may read what ----------
    //
    // A scoped credential is bound to one machine, and sessions on one machine share an OS user and
    // a filesystem — so the machine, not the session, is the confidentiality boundary. A credential
    // may read the conversations **its machine takes part in** and nothing else. The shared
    // bootstrap credential is the documented exception: whoever holds it holds the database anyway,
    // and an operator needs the whole board.

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
        !rows(
            """
            SELECT 1 FROM messages m
             WHERE m.thread_id = ?
               AND (m.sender IN (SELECT id FROM agents WHERE node = ?)
                    OR m.id IN (SELECT d.message_id FROM deliveries d
                                 WHERE d.node = ?))
             LIMIT 1
            """, [threadId, node, node]
        ).isEmpty
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
        rows(
            """
            SELECT a AS agent FROM (
              SELECT sender AS a FROM messages WHERE thread_id = ?
              UNION
              SELECT d.agent AS a FROM deliveries d JOIN messages m ON m.id = d.message_id
               WHERE m.thread_id = ?
            ) WHERE a IS NOT NULL AND a <> '' ORDER BY a
            """, [id, id]
        ).compactMap { $0["agent"] }
    }

    /// The newest `limit` messages of a thread, in reading order. A conversation has no natural
    /// bound, so an answer that returns all of it is a response whose size the *peer* decides;
    /// the newest are the ones a reader acts on, and the caller says how many were left out.
    func threadPage(_ id: String, limit: Int) -> [[String: String]] {
        rows(
            """
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
