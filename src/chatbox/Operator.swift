// Operator.swift — flags, argument readers, backup/verify helpers and operator modes.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

let valueFlags: Set<String> = [
    "--port", "--db", "--token", "--token-file", "--stale-after",
    "--max-body", "--tls-identity", "--tls-password-file", "--prune",
    "--backup", "--verify-backup", "--idle-timeout", "--max-connections",
    "--max-rows", "--server-id", "--peer", "--peer-token", "--peer-token-file",
    "--max-hops"
]
/// Flags that are their own value. A boolean flag at the end of the line is complete, and one
/// that is handed a value is a mistake worth naming.
/// `--help` and `--version` are their own value (none): they are answered before anything binds, and
/// a value handed to either is a mistake worth naming like any other.
let boolFlags: Set<String> = ["--prune-dry-run", "--help", "--version"]
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
            FileHandle.standardError.write(
                Data("chatbox: unknown flag '\(name)' — refusing to start rather than ignore it\n".utf8))
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
        let n = attrs[.size] as? NSNumber
    else { return false }
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

/// Open a board file read-only and prove it *is* a board: the same open both readers below use, so
/// the immutable-snapshot rule and the integrity rule cannot drift apart. Returns the reason it is
/// not a board, or nil with `db` set for the caller to close - and it closes the handle itself on
/// every failure, so a caller never touches a half-open one.
func openBoard(_ path: String, _ db: inout OpaquePointer?) -> String? {
    let pending = hasPendingWAL(path)
    let target = pending ? path : "file:\(uriPath(path))?immutable=1"
    let flags = pending ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK else {
        let why = String(cString: sqlite3_errmsg(db))
        sqlite3_close(db)
        return "cannot be opened (\(why))"
    }
    // Integrity first: a half-copied file can open and still be unreadable.
    guard let integrity = sqliteText(db, "PRAGMA integrity_check") else {
        let why = "cannot be read (\(String(cString: sqlite3_errmsg(db))))"
        sqlite3_close(db)
        return why
    }
    guard integrity == "ok" else {
        sqlite3_close(db)
        return "fails its integrity check (\(integrity))"
    }
    return nil
}

func boardCounts(_ path: String) -> BoardRead {
    var db: OpaquePointer?
    if let why = openBoard(path, &db) { return .problem(why) }
    defer { sqlite3_close(db) }
    var out: [String: Int] = [:]
    for table in boardTables {
        guard let n = sqliteText(db, "SELECT COUNT(*) FROM \(table)") else {
            return .problem("has no usable `\(table)` table (\(String(cString: sqlite3_errmsg(db))))")
        }
        out[table] = Int(n)
    }
    return .counts(out)
}

/// The same read as `boardCounts`, but per table it returns *rows, the highest rowid and the sum of
/// the rowids*. `COUNT(*)` alone lets a copy that lost a row and gained another verify as current -
/// a pruned message replaced by a newer one has the same total - which is the one thing
/// `--verify-backup` exists to catch. The reason a file is not a board is carried out in the same
/// sentence-producing shape as `boardCounts`, so the caller can print it unchanged.
func boardFingerprints(_ path: String) -> (prints: [String: String]?, why: String?) {
    var db: OpaquePointer?
    if let why = openBoard(path, &db) { return (nil, why) }
    defer { sqlite3_close(db) }
    var out: [String: String] = [:]
    for table in boardTables {
        let sql = "SELECT COUNT(*) || ':' || IFNULL(MAX(rowid), 0) || ':' || IFNULL(TOTAL(rowid), 0) FROM \(table)"
        guard let v = sqliteText(db, sql) else {
            return (nil, "has no usable `\(table)` table (\(String(cString: sqlite3_errmsg(db))))")
        }
        out[table] = v
    }
    return (out, nil)
}

/// The `agents=3 threads=5 …` line, shared by both modes so the two outputs cannot drift.
func boardCountsLine(_ counts: [String: Int]) -> String {
    boardTables.map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
}

/// Bytes on disk, or `?` when the file cannot be measured. The size is reported because the
/// whole trap is a copy whose size looked plausible.
func fileSize(_ path: String) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
        let n = attrs[.size] as? NSNumber
    else { return "?" }
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
    let read = boardFingerprints(shown)
    if let why = read.why { return why }
    let prints = read.prints ?? [:]
    let sourceRead = boardFingerprints(source)
    if let why = sourceRead.why { return "\(why), so there is nothing to compare \(shown) with" }
    let sourcePrints = sourceRead.prints ?? [:]
    let differing = boardTables.filter { prints[$0] != sourcePrints[$0] }
    if !differing.isEmpty {
        // Rows:max(rowid):sum(rowid) per table, so an operator can see *how* the copy differs and not
        // only that it does.
        let detail = differing.map {
            "\($0): \(prints[$0] ?? "?") in the copy, \(sourcePrints[$0] ?? "?") in \(source)"
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

let operatorModes = [("--backup", backupRaw), ("--verify-backup", verifyRaw), ("--prune", pruneRaw)]
    .filter { !$0.1.isEmpty }.map { $0.0 }
// The window has to stay expressible. `isoDaysAgo` renders an ISO string, and past the year
// 9999 the formatter drops the sign and the cutoff lands in the *future* — where `created_at <
// cutoff` is true for everything, so a typo would prune every acknowledged message regardless
// of age. 100 years is past the life of any board.
let pruneCeiling = 36500
func runOperatorModeIfRequested(verifyRaw: String, backupRaw: String, pruneRaw: String, dbPath: String) {
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
            FileHandle.standardError.write(
                Data("chatbox: --backup needs an explicit --db <path> — refusing to guess which board to copy\n".utf8))
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
            FileHandle.standardError.write(
                Data("chatbox: the copy to \(destPath) failed: \(reason) — nothing was verified\n".utf8))
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
    if !pruneRaw.isEmpty {
        guard let pruneDays = Int(pruneRaw), pruneDays >= 0, pruneDays <= pruneCeiling else {
            FileHandle.standardError.write(
                Data(
                    "chatbox: --prune needs a number of days between 0 and \(pruneCeiling) (0 means every acknowledged message, whatever its age) — got '\(pruneRaw)'\n"
                        .utf8))
            exit(2)
        }
        // An explicit --db, because the default is `~/chatbox.sqlite` and a prune aimed at the
        // wrong board is indistinguishable from one that found nothing to do.
        guard argPresent("--db") else {
            FileHandle.standardError.write(
                Data("chatbox: --prune needs an explicit --db <path> — refusing to guess which board to prune\n".utf8))
            exit(2)
        }
        let prunePath = NSString(string: dbPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: prunePath) else {
            FileHandle.standardError.write(
                Data("chatbox: \(prunePath) does not exist — refusing to create a board to prune\n".utf8))
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
            FileHandle.standardError.write(
                Data("chatbox: the prune failed and was rolled back — nothing was changed\n".utf8))
            exit(1)
        }
        print("database: \(dbPath)")
        print(
            "\(dryRun ? "would prune" : "pruned"): \(result.messages) message(s), \(result.threads) thread(s), \(result.deliveries) delivery(ies)"
        )
        print("window: delivered and fully acknowledged, older than \(pruneDays) day(s)")
        print("never pruned: any message with an unacknowledged delivery, and any message nobody was sent")
        if dryRun { print("nothing was removed — drop --prune-dry-run to do it") }
        exit(0)
    }

    // A cap that is too small to hold a request line and its headers would refuse every
    // request, which looks like a broken server rather than a configured one, so it is
    // refused at startup instead. 512 is comfortably above the ~300 bytes a request with a
    // bearer token needs.
}
