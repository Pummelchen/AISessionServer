// Store.swift — the SQLite store: schema, opening, statements and credentials.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

final class Store: @unchecked Sendable {
    var db: OpaquePointer?
    /// The queue this store may be touched on. See the note on `chatboxQueue`: every entry point
    /// below asserts it.
    let queue: DispatchQueue
    /// The file this store was opened on, kept for the messages that have to name it.
    let path: String

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
        exec(
            """
            CREATE TABLE IF NOT EXISTS agents (
              id TEXT PRIMARY KEY, node TEXT, agent TEXT, harness TEXT, session TEXT,
              ip TEXT, repos TEXT, note TEXT, registered_at TEXT, last_seen TEXT);
            """)
        exec(
            """
            CREATE TABLE IF NOT EXISTS threads (
              id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, subject TEXT,
              created_at TEXT, created_by TEXT, last_at TEXT);
            """)
        exec(
            """
            CREATE TABLE IF NOT EXISTS messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id INTEGER, created_at TEXT,
              sender TEXT, repo TEXT, subject TEXT, body TEXT, reply_to INTEGER, recipients TEXT,
              origin TEXT);
            """)
        exec(
            """
            CREATE TABLE IF NOT EXISTS deliveries (
              message_id INTEGER, agent TEXT, created_at TEXT, acked_at TEXT, node TEXT,
              PRIMARY KEY (message_id, agent));
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_del ON deliveries(agent);")
        // The long-poll path only asks "is there anything unread?", so give that
        // question an index that does not have to scan a long history of read rows.
        exec("CREATE INDEX IF NOT EXISTS idx_del_unread ON deliveries(agent, acked_at);")
        // The inbox listing is `agent = ?` ordered by message id DESC LIMIT n. `idx_del_unread`
        // filters but does not order, so SQLite sorted the whole matching backlog in a temp b-tree
        // on every poll — including every 0.25 s long-poll tick. This index provides the order, so
        // the query reads the newest 200 rows and stops. (The query orders by `d.message_id`, which
        // is the joined `m.id`, because SQLite cannot see that a join preserves order.)
        exec("CREATE INDEX IF NOT EXISTS idx_del_inbox ON deliveries(agent, message_id DESC);")
        exec(
            """
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
        // The backfill's result is checked, not just logged: this is a write to the fastest-growing
        // table, and a board that came up without it would report every delivery's machine as
        // unknown. It is also the first write after the schema, so a write lock held by another
        // process (a restart overlap, an operator's `--prune`) surfaces here as "database is locked"
        // and the board refuses instead of serving a board it could not prepare.
        let backfilled = exec(
            """
            UPDATE deliveries SET node = COALESCE((SELECT a.node FROM agents a WHERE a.id = deliveries.agent), '')
             WHERE node IS NULL;
            """)
        if backfilled != SQLITE_OK {
            FileHandle.standardError.write(
                Data(
                    "chatbox: \(path) could not backfill deliveries.node — refusing to serve a board it could not prepare\n"
                        .utf8))
            exit(1)
        }
        // A credential may carry an expiry. A board that predates the column gets it here: the
        // alter is idempotent, so a restart neither fails nor rewrites anything.
        addColumn("tokens", "expires_at", "TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_tokens_hash ON tokens(hash);")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_thread ON messages(thread_id);")
        // `--prune` clears a deleted message's replies with `UPDATE messages SET reply_to=0 WHERE
        // reply_to=?`, once per pruned message. Without this the statement is a full scan of the
        // fastest-growing table, run once per candidate, so pruning is O(messages x pruned) and an
        // operator abandons it. Measured: 1,000 such updates against 500k messages took 25.7 s.
        exec("CREATE INDEX IF NOT EXISTS idx_msg_reply ON messages(reply_to);")
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
        let have = Set(
            rows("SELECT name FROM sqlite_master WHERE name IN ('agents','threads','messages','deliveries','tokens')")
                .compactMap { $0["name"] })
        let missing = wanted.filter { !have.contains($0) }
        if !missing.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "chatbox: \(path) has no \(missing.joined(separator: ", ")) — refusing to start on a store it could not prepare\n"
                        .utf8))
            exit(1)
        }
        if !readOnly {
            let journal = scalar("PRAGMA journal_mode;")
            if journal != "wal" {
                FileHandle.standardError.write(
                    Data(
                        "chatbox: \(path) is in journal mode '\(journal)', not WAL — refusing to start (a board without WAL cannot be backed up as documented)\n"
                            .utf8))
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
            FileHandle.standardError.write(
                Data("chatbox: sql error: \(String(cString: sqlite3_errmsg(db))) — in \(oneLine(sql))\n".utf8))
        }
        return rc
    }

    func prepare(_ sql: String, _ binds: [String?]) -> OpaquePointer? {
        dispatchPrecondition(condition: .onQueue(queue))
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            FileHandle.standardError.write(Data("chatbox: sql error: \(String(cString: sqlite3_errmsg(db)))\n".utf8))
            return nil
        }
        for (i, v) in binds.enumerated() {
            // The byte count, not -1: a negative length means "up to the first NUL", so a value with
            // an embedded NUL (`%00` decodes to one) was silently truncated on the way in.
            if let v = v {
                sqlite3_bind_text(st, Int32(i + 1), v, Int32(v.utf8.count), transientDestructor())
            } else {
                sqlite3_bind_null(st, Int32(i + 1))
            }
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
                    } else {
                        row[name] = ""
                    }
                }
                out.append(row)
                continue
            }
            if step != SQLITE_DONE {
                // BUSY, IOERR, CORRUPT, NOMEM, or anything else: the rows collected so far are a
                // *partial* answer, and a partial answer that looks complete is worse than an error.
                readFailed = true
                FileHandle.standardError.write(
                    Data(
                        "chatbox: read failed after \(out.count) row(s): \(String(cString: sqlite3_errmsg(db)))\n".utf8)
                )
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
            FileHandle.standardError.write(
                Data(
                    "chatbox: scalar() needs a one-column query — got \(row.count) columns from \(oneLine(sql))\n".utf8)
            )
            return ""
        }
        return only
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
    func addColumn(_ table: String, _ column: String, _ decl: String) {
        if rows("PRAGMA table_info(\(table))").compactMap({ $0["name"] }).contains(column) { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl);")
        // The alter is not retried: if it did not take — a read-only file, a lock held past the
        // busy timeout — the board is now missing a column that authorization reads, and every
        // scoped credential would fail with "unknown token" while the bootstrap credential kept
        // working. A server that cannot migrate must not start.
        if !rows("PRAGMA table_info(\(table))").compactMap({ $0["name"] }).contains(column) {
            FileHandle.standardError.write(
                Data(
                    "chatbox: cannot add \(table).\(column) to \(path) — refusing to serve a half-migrated board\n".utf8
                ))
            exit(1)
        }
    }

    func tokenByHash(_ hash: String) -> [String: String]? {
        rows(
            """
            SELECT id, node, namespaces, last_used, revoked_at, expires_at FROM tokens WHERE hash = ? LIMIT 1
            """, [hash]
        ).first
    }

    /// Re-check a credential the request was already authorized under, by its id instead of by
    /// re-hashing the presented secret. `nil` means it is still valid; otherwise the refusal body is
    /// returned, with the same wording `authorize` uses, so a held long poll ends for exactly the
    /// same reason a fresh request would be refused. It is one primary-key lookup — no SHA-256, no
    /// `touchToken` write — which is what makes a waiter's periodic re-check cheap.
    func tokenValidity(_ id: String) -> String? {
        guard let row = rows("SELECT revoked_at, expires_at FROM tokens WHERE id = ? LIMIT 1", [id]).first else {
            return "unauthorized: unknown token\n"
        }
        if !(row["revoked_at"] ?? "").isEmpty {
            return "unauthorized: this credential has been revoked\n"
        }
        let expiresAt = row["expires_at"] ?? ""
        if !expiresAt.isEmpty {
            let canonical = expiresAt.count == 20 && expiresAt.hasSuffix("Z")
            if !canonical {
                return
                    "unauthorized: this credential's expiry ('\(oneLine(expiresAt))') cannot be read — issue another\n"
            }
            if expiresAt <= nowISO() {
                return "unauthorized: this credential expired at \(expiresAt) — issue another\n"
            }
        }
        return nil
    }

    /// Add a credential, and report what the store did. A route that prints a secret it did not
    /// store has handed the operator a credential that can never authenticate, with nothing in the
    /// answer to say so.
    @discardableResult
    func addToken(
        id: String, hash: String, node: String, namespaces: String, note: String,
        at: String, expiresAt: String
    ) -> (rc: Int32, changes: Int32) {
        let r = runReporting(
            "INSERT INTO tokens (id,hash,node,namespaces,note,created_at,expires_at) VALUES (?,?,?,?,?,?,?)",
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
        let r = runReporting(
            "UPDATE tokens SET revoked_at=? WHERE id=? AND (revoked_at IS NULL OR revoked_at='')", [at, id])
        return (r.rc, r.changes)
    }

    func touchToken(_ id: String, at: String) {
        run("UPDATE tokens SET last_used=? WHERE id=?", [at, id])
    }

    func tokensListing(limit: Int) -> [[String: String]] {
        rows(
            """
            SELECT id, node, namespaces, note, created_at, last_used, revoked_at, expires_at
            FROM tokens ORDER BY created_at, id LIMIT \(limit)
            """)
    }

    func tokenCount() -> Int { Int(scalar("SELECT COUNT(*) FROM tokens")) ?? 0 }

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
}
