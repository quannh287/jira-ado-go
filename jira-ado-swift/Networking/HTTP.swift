import Foundation

/// A non-2xx response, or ADO's 203 sign-in page; the body is kept for the report.
struct HTTPStatusError: LocalizedError {
    let method: String, url: String, status: Int, body: Data
    var isAuth: Bool { status == 401 || status == 203 }
    var errorDescription: String? {
        if isAuth { return "\(method) \(url): HTTP \(status): credentials rejected — the PAT or API token is wrong, expired or revoked. Sign out and sign in with a new one." }
        return "\(method) \(url): HTTP \(status): \(truncate(body, 300))"
    }
}

/// A completed exchange, also returned alongside errors so callers can log it.
struct HTTPResponse {
    var status = 0
    var body = Data()
    var retries = 0
    var duration: TimeInterval = 0
}

/// JSON over HTTP relative to base with a fixed Authorization header; retries 429, 5xx and network errors.
final class HTTPClient {
    let base: String
    private let auth: String
    var retries = 3
    var baseDelay = HTTPClient.retryDelay
    /// The first retry's delay, doubled each time; tests set it to 0.
    static var retryDelay: TimeInterval = 0.5
    private static let maxBody = 32 << 20  // larger responses are refused
    /// Tests swap in a session whose protocol classes stub the network.
    static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil  // an invalid PAT is redirected to a sign-in page that sets cookies
        return URLSession(configuration: c)
    }()

    init(base: String, auth: String) {
        self.base = base.hasSuffix("/") ? String(base.dropLast()) : base
        self.auth = auth
    }

    /// Sends body (nil for none) with exponential backoff on transient failures; other 4xx fail at once.
    func send(_ method: String, _ path: String, contentType: String = "", body: Data? = nil) async -> (HTTPResponse, Error?) {
        let url = path.hasPrefix("http://") || path.hasPrefix("https://") ? path : base + path
        let start = Date()
        for attempt in 0... {
            var resp = HTTPResponse(retries: attempt)
            var err: Error?
            do {
                (resp.status, resp.body) = try await once(method, url, contentType, body)
                // ADO answers a rejected PAT with 203 and an HTML sign-in page instead of 401.
                if resp.status >= 300 || resp.status == 203 { err = HTTPStatusError(method: method, url: url, status: resp.status, body: resp.body) }
            } catch { err = error }
            resp.duration = Date().timeIntervalSince(start)
            guard let e = err else { return (resp, nil) }
            if attempt >= retries || !transient(resp.status, e) {
                // Only the URL and status: bodies and headers can hold work item data or credentials.
                AppLog.warn("http request failed", ["method": method, "url": url, "status": resp.status, "retries": attempt,
                                                    "elapsed": fmtDuration(resp.duration), "err": String(describe(e).prefix(500))])
                return (resp, e)
            }
            let delay = baseDelay * Double(1 << attempt)
            AppLog.info("http retry", ["method": method, "url": url, "status": resp.status, "attempt": attempt + 1, "delay": delay])
            do { try await Task.sleep(for: .seconds(delay)) } catch { return (resp, error) }
        }
        fatalError("unreachable")
    }

    private func once(_ method: String, _ url: String, _ contentType: String, _ body: Data?) async throws -> (Int, Data) {
        guard let u = URL(string: url) else { throw Failure("invalid URL \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.httpBody = body
        if !auth.isEmpty { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !contentType.isEmpty { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, res) = try await Self.session.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if data.count > Self.maxBody { throw Failure("\(method) \(url): response larger than \(Self.maxBody) bytes") }
        return (status, data)
    }

    private func transient(_ status: Int, _ err: Error) -> Bool {
        if Task.isCancelled || err is CancellationError { return false }
        if err is HTTPStatusError { return status == 429 || status >= 500 }
        if let u = err as? URLError { return u.code != .cancelled }  // timeout, reset, DNS
        return false
    }
}

func basicAuth(_ user: String, _ password: String) -> String {
    "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
}

func truncate(_ b: Data, _ n: Int) -> String {
    let s = String(decoding: b, as: UTF8.self)
    return s.count > n ? s.prefix(n) + "…" : s
}

/// JSON helpers for the dynamic payloads of Jira and ADO.
typealias JSONObject = [String: Any]

func parseJSON(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

func jsonData(_ v: Any, pretty: Bool = false) -> Data {
    var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
    if pretty { opts.insert(.prettyPrinted) }
    return (try? JSONSerialization.data(withJSONObject: v, options: opts)) ?? Data("null".utf8)
}

/// Percent-encodes one path segment.
func pathEscape(_ s: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func queryEscape(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
