// chatbox-mcp.swift — a stateless MCP server for chatbox.
//
// An MCP host (DeepSeek Harness, Claude Desktop, …) launches this, speaks JSON-RPC 2.0 over
// stdio, and gets the board's operations as native tools. It holds **no state and no routing
// logic**: every call is turned into one HTTP request against the chatbox API, so the server
// remains the only place the semantics live and the two cannot drift.
//
// Build: xcrun swiftc -O chatbox-mcp.swift -o chatbox-mcp
// Run:   CHATBOX_URL=http://127.0.0.1:8787 CHATBOX_TOKEN=<secret> ./chatbox-mcp
//
// MCP stdio framing is one JSON object per line, in both directions. Nothing is written to
// stdout except protocol messages: anything a human needs to see goes to stderr.

import Foundation
import Synchronization

let configURL = ProcessInfo.processInfo.environment["CHATBOX_URL"] ?? "http://127.0.0.1:8787"
let configToken = ProcessInfo.processInfo.environment["CHATBOX_TOKEN"] ?? ""
let protocolVersion = "2024-11-05"

func note(_ line: String) {
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          var text = String(data: data, encoding: .utf8) else { return }
    text += "\n"
    FileHandle.standardOutput.write(text.data(using: .utf8)!)
}

/// What one HTTP call reported. See the note in `call`: a completion handler is `@Sendable`.
final class HTTPOutcome: Sendable {
    private let state = Mutex<(status: Int, body: String)>((0, ""))

    func store(status: Int, body: String) { state.withLock { $0 = (status, body) } }

    var value: (status: Int, body: String) { state.withLock { $0 } }
}

func reply(id: Any?, _ result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
}

func fail(id: Any?, code: Int, _ message: String) {
    emit(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
}

// ---------------------------------------------------------------- the HTTP door
//
// One request per tool call, with the token in the query string (the API accepts it there and as
// a bearer header). The client's own `curl` dependency is deliberately not used: an MCP server is
// launched by an application that may have a different PATH.

/// One field of a query string. `URLComponents.queryItems` leaves `+` raw, and this server decodes
/// `+` as a space — which is what form encoding says a `+` in a query means — so every argument
/// containing one arrived with a space in it, silently, on every tool. Everything outside the
/// unreserved set is escaped here instead.
func queryEncode(_ s: String) -> String {
    var out = ""
    for byte in Array(s.utf8) {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            out.append(Character(UnicodeScalar(byte)))
        default:
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

func call(_ method: String, _ path: String, _ params: [String: String]) -> (status: Int, body: String) {
    var fields: [(String, String)] = []
    for (k, v) in params where !v.isEmpty { fields.append((k, v)) }
    if !configToken.isEmpty { fields.append(("token", configToken)) }
    let query = fields.map { "\(queryEncode($0.0))=\(queryEncode($0.1))" }.joined(separator: "&")
    guard let url = URL(string: query.isEmpty ? configURL + path : configURL + path + "?" + query) else {
        return (0, "error: CHATBOX_URL is not a usable URL")
    }
    // A long poll is meant to be held open: the server sends nothing at all until it has something
    // to report, so the client's own deadline has to outlast the wait it asked for. A flat 60s turned
    // every advertised wait over a minute (`wait` is documented up to 300) into a transport error
    // that looked like a dead server. Sized like the CLI's transport timeout: the wait plus a margin.
    let waitSeconds = Int(params["wait"] ?? "") ?? 0
    let deadline = waitSeconds > 0 ? TimeInterval(waitSeconds + 20) : 60
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = deadline
    let sem = DispatchSemaphore(value: 0)
    // The completion is `@Sendable` and cannot write into captured `var`s; a `Mutex`-guarded box is
    // `Sendable` because its contents are, so the two values cross without an unsafe annotation.
    let outcome = HTTPOutcome()
    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        var status = 0
        var body = ""
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        if let data = data, let text = String(data: data, encoding: .utf8) { body = text }
        if let error = error { body = "error: \(error.localizedDescription)" }
        outcome.store(status: status, body: body)
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + deadline + 10) == .timedOut {
        task.cancel()
        return (0, "error: the chatbox server did not answer within \(Int(deadline))s")
    }
    return outcome.value
}

// ---------------------------------------------------------------- the tools
//
// Every tool is `name`, `description` and a flat object of string properties, and every call
// becomes one request. A tool's `required` list is the server's own requirement, named once.

struct Tool {
    let name: String
    let description: String
    let method: String
    let path: String
    let properties: [(String, String)]
    let required: [String]
    /// The argument the API wants as its `from`/`id`: passed through unchanged, listed here so the
    /// schema is complete rather than implied.
    var schema: [String: Any] {
        var props: [String: Any] = [:]
        for (name, description) in properties {
            props[name] = ["type": "string", "description": description]
        }
        return ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
}

let tools: [Tool] = [
    Tool(name: "register",
         description: "Register this session on the board: who you are, which machine, and which repos you own.",
         method: "POST", path: "/register",
         properties: [("id", "your stable handle, e.g. mac1-dsh"), ("node", "the machine you are on"),
                      ("agent", "the agent product: dsh, claude, codex, …"), ("harness", "the product's name"),
                      ("session", "your own session id"), ("ip", "an address peers could reach you on"),
                      ("repos", "comma-separated repo keys you own"), ("note", "free text")],
         required: ["id"]),
    Tool(name: "say",
         description: "Send a plain-text message: to every owner of a repo key, to explicit recipients, or into an existing thread.",
         method: "POST", path: "/message",
         properties: [("from", "your id"), ("repo", "route to every owner of this repo key"),
                      ("to", "comma-separated recipient ids"), ("subject", "thread subject (new threads only)"),
                      ("body", "the message text"), ("thread", "reply into this existing thread id"),
                      ("reply_to", "the message id being answered")],
         required: ["from"]),
    Tool(name: "inbox",
         description: "Read messages addressed to you, newest first. `wait` holds the request until one arrives.",
         method: "GET", path: "/inbox",
         properties: [("id", "your id"), ("all", "1 to include messages you have already read"),
                      ("wait", "seconds to hold the request open (max 300)")],
         required: ["id"]),
    Tool(name: "thread",
         description: "Read one conversation: every message in order, with its sender and recipients.",
         method: "GET", path: "/thread",
         properties: [("id", "the thread id"), ("json", "1 for JSON")],
         required: ["id"]),
    Tool(name: "ack",
         description: "Mark messages read: one message id, a whole thread id, or `all`=1 for everything unread.",
         method: "POST", path: "/ack",
         properties: [("id", "your id"), ("message", "the message id to acknowledge"),
                      ("thread", "acknowledge every message in this thread"), ("all", "1 for everything unread")],
         required: ["id"]),
    Tool(name: "peers",
         description: "The sessions on the board, the repos they own, and whether each is active or stale.",
         method: "GET", path: "/peers",
         properties: [("json", "1 for JSON")],
         required: []),
]

func toolResult(_ id: Any?, status: Int, body: String) {
    let ok = status >= 200 && status < 300
    reply(id: id, ["content": [["type": "text", "text": body]],
                   "isError": !ok])
}

func handleToolCall(_ id: Any?, _ params: [String: Any]) {
    guard let name = params["name"] as? String else {
        fail(id: id, code: -32602, "tools/call needs a name")
        return
    }
    guard let tool = tools.first(where: { $0.name == name }) else {
        fail(id: id, code: -32602, "unknown tool '\(name)'")
        return
    }
    var args: [String: String] = [:]
    if let raw = params["arguments"] as? [String: Any] {
        for (k, v) in raw {
            if let s = v as? String { args[k] = s }
            else if let n = v as? NSNumber { args[k] = n.stringValue }
        }
    }
    for required in tool.required where (args[required] ?? "").isEmpty {
        toolResult(id, status: 400, body: "error: '\(required)' is required for \(name)\n")
        return
    }
    let (status, body) = call(tool.method, tool.path, args)
    toolResult(id, status: status, body: body)
}

// ---------------------------------------------------------------- the protocol
//
// MCP over stdio is newline-delimited JSON-RPC 2.0. A request has an id and gets exactly one
// reply; a notification has none and gets none.

// A note for whoever is watching the host's log: stderr, because stdout is the protocol stream.
note("chatbox-mcp: forwarding to \(configURL)")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }
    guard let data = trimmed.data(using: .utf8),
          let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail(id: nil, code: -32700, "parse error")
        continue
    }
    let id = message["id"]
    let isNotification = id == nil
    guard let method = message["method"] as? String else {
        if !isNotification { fail(id: id, code: -32600, "not a request: no method") }
        continue
    }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        // A notification has no id and gets no reply: JSON-RPC 2.0 says the server MUST NOT reply to
        // one, and MCP inherits that. `reply` with a nil id would emit `"id":null`, which a strict
        // host reads as a response it never asked for — the id-keyed stream is polluted, and the
        // adapter's own comment above states the rule these branches used to break.
        if !isNotification {
            reply(id: id, [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "chatbox", "version": "1.0"],
            ])
        }
    case "notifications/initialized", "notifications/cancelled", "initialized":
        break
    case "ping":
        if !isNotification { reply(id: id, [:]) }
    case "tools/list":
        if !isNotification {
            reply(id: id, ["tools": tools.map { tool in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.schema]
            }])
        }
    case "tools/call":
        // An id-less `tools/call` is a client bug — MCP defines it as a request — and it is neither
        // answered nor executed: the caller cannot be told the outcome, and a board change made
        // behind its back, with no reply to fail, is worse than a no-op.
        if !isNotification { handleToolCall(id, params) }
    default:
        if !isNotification { fail(id: id, code: -32601, "method not found: \(method)") }
    }
    fflush(stdout)
}
