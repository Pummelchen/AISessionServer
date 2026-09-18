// HTTP.swift — request value types, form parsing and the forward session.
// Part of the chatbox server; built with `xcrun swiftc -O src/chatbox/*.swift -o chatbox`.
import CryptoKit
import Foundation
import Network
import SQLite3
import Synchronization

struct Request {
    var method = "GET"
    var path = "/"
    var params: [String: String] = [:]
    var token: String?
    /// Set when ?token= and Authorization: Bearer disagree.
    var tokenConflicts = false
    /// Set when the request asks for chunked framing. This server reads a body by its
    /// `Content-Length` and nothing else, so a chunked body is refused rather than
    /// half-read: the alternative is storing the framing itself as the message.
    var chunked = false
    /// The peer address, when the server could determine it. Used to warn when a
    /// freshly issued secret crosses a network in the clear.
    var peer = ""
    /// Who the request was served as, rendered once by `dispatch` so every log line can name it:
    /// `bootstrap`, `denied`, or the node and credential id behind a scoped token. Never a secret -
    /// the id is what the credential listing already shows.
    var principal = ""

    func p(_ key: String, _ def: String = "") -> String {
        (params[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? def)
    }

    /// A flag parameter: true when it is present and not one of the spellings of false. It used to be
    /// "true for any non-empty value", so `all=0` included the messages the caller had already read
    /// and `json=0` answered JSON — the opposite of what was written. Absent is false.
    func flag(_ key: String) -> Bool {
        let v = p(key).lowercased()
        return !(v.isEmpty || v == "0" || v == "false" || v == "no" || v == "off")
    }
}

func percentDecode(_ s: String) -> String {
    s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
}

func parseForm(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if kv.count == 2 {
            out[percentDecode(String(kv[0]))] = percentDecode(String(kv[1]))
        } else if kv.count == 1 {
            out[percentDecode(String(kv[0]))] = ""
        }
    }
    return out
}

/// Form encoding of one field, for the body of a forward. `URLComponents`' query items leave `+`
/// alone, and the receiver decodes `+` as a space — which is what form encoding says it should do —
/// so a message containing `+` sent that way would arrive with a space in it. Everything outside
/// the unreserved set is escaped here instead.
func formEncode(_ s: String) -> String {
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

/// The forward session's delegate. It does the two things `URLSession` will not do on its own.
///
/// It **refuses a redirect**: `URLSession` follows them by default, so a peer behind an
/// http→https redirect would answer this board's `POST` with a `GET` somewhere else, and a final 2xx
/// is what this board reports as `forwarded_to … (ok)` — a silent loss announced as a delivery. With
/// the redirect refused, the 3xx comes back as the answer it is.
///
/// It also **caps the answer it buffers**. Only the peer's first line is ever read (the chatbox
/// success line, or its refusal), but a completion-handler data task buffers the whole body first,
/// and the peer — or whatever `--peer` actually points at — chooses how many bytes that is. A data
/// delegate that counts as it reads lets the task be cancelled once the answer is longer than a
/// chatbox answer can be, so the allocation is bounded by this constant rather than by the peer.
///
/// The task is therefore created with `dataTask(with:)` and **no completion handler**: when the
/// session has a `URLSessionDataDelegate`, data is delivered to the delegate, not to a completion
/// handler, and the first cut of this class used both — the completion's `data` was nil and the
/// delegate never accumulated, so every forward looked like an empty answer.
final class ForwardSessionDelegate: NSObject, URLSessionDataDelegate {
    /// Generous for a first line: a chatbox answer is a few hundred bytes at most.
    static let maxAnswerBytes = 64 * 1024
    let state = Mutex<(status: Int, location: String, body: Data, truncated: Bool, error: String)>(
        (0, "", Data(), false, ""))
    /// Signalled once, when the task completes (success, failure, or the cap's cancel).
    let finished = DispatchSemaphore(value: 0)

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            state.withLock {
                $0.status = http.statusCode
                $0.location = http.value(forHTTPHeaderField: "Location") ?? ""
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The whole `withLock` result decides the cancel: `dataTask.cancel()` must not be called
        // while the lock is held, and a chunk arriving after the cap (or after a cancel) is
        // dropped without touching `body`.
        let over = state.withLock { s -> Bool in
            if s.truncated { return true }
            if s.body.count + data.count > Self.maxAnswerBytes {
                s.truncated = true
                return true
            }
            s.body.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error {
            state.withLock { if $0.error.isEmpty { $0.error = err.localizedDescription } }
        }
        finished.signal()
    }

    /// Wait for the task. `true` means it did not finish within the deadline.
    func wait(timeout: DispatchTime) -> Bool { finished.wait(timeout: timeout) == .timedOut }

    /// The answer to report: the peer's body, or the reason there is none.
    var result: (status: Int, body: String, location: String) {
        state.withLock { s in
            if s.truncated {
                return (s.status, "error: the peer's answer was longer than \(Self.maxAnswerBytes) bytes", s.location)
            }
            if s.body.isEmpty, !s.error.isEmpty { return (s.status, "error: \(s.error)", s.location) }
            return (s.status, String(data: s.body, encoding: .utf8) ?? "", s.location)
        }
    }
}

/// A message that is stored here and still has to be told to the peer, because the repo it names
/// has no owner on this board. Built by `message` — which is the only place that knows the send was
/// accepted — and carried out by `forwardMessage` off the serial queue.
struct ForwardPlan {
    var from: String
    var repo: String
    var subject: String
    var body: String
    /// The row this message got here, so the log line names something an operator can look up.
    var msgID: Int64
}

/// One route's answer. `forward` is set only by `POST /message`, and only when the message was
/// stored here *and* a peer still has to be told about it. The answer is owed either way; it is
/// just sent after the peer has answered rather than while it is being asked.
struct Reply {
    var status: Int
    var body: String
    var forward: ForwardPlan?
    /// Extra response headers. Used by the inbox to say *which* messages it rendered, so a client
    /// can acknowledge what it was handed instead of "everything unread" — a header is structural,
    /// so a peer's message body can never add an id to it.
    var headers: [String: String]

    init(
        _ status: Int, _ body: String, forward: ForwardPlan? = nil,
        headers: [String: String] = [:]
    ) {
        self.status = status
        self.body = body
        self.forward = forward
        self.headers = headers
    }
}

// MARK: - Server
