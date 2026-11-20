import Foundation

/// What the replay sender needs from a response. Any HTTP status is a
/// response; only a failure to get one (network) throws.
struct ReplayHTTPResponse: Sendable, Equatable {
    var status: Int
    /// `Retry-After` in seconds, when the header is a number.
    var retryAfter: TimeInterval?
    var body: Data
}

/// `POST` of one chunk. Unlike `CohorlyTransport` it takes headers
/// (`Content-Encoding`, `X-Cohorly-Token`) and hands back every status.
protocol ReplayTransport: Sendable {
    func send(url: URL, headers: [String: String], body: Data) async throws -> ReplayHTTPResponse
    /// `GET` of the remote replay settings (`/replay/config`, built by
    /// `ReplayRemoteConfigLoader.configRequest`), without credentials: no
    /// cookie, no header, the token only in the query.
    func get(request: URLRequest) async throws -> ReplayHTTPResponse
}

struct URLSessionReplayTransport: ReplayTransport {
    var session: URLSession = .shared
    /// The remote settings' session: nothing stored, no cookie, no
    /// credential, no cache, so the app's credentials never reach the
    /// request (`credentials: "omit"` of the web SDK).
    var configSession: URLSession = Self.sharedConfigSession

    static let sharedConfigSession = makeConfigSession()

    static func makeConfigSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = TimeInterval(ReplayRemoteConfigLoader.abortMs) / 1000
        return URLSession(configuration: configuration, delegate: ReplayConfigSessionDelegate(), delegateQueue: nil)
    }

    func send(url: URL, headers: [String: String], body: Data) async throws -> ReplayHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return ReplayHTTPResponse(
            status: http.statusCode,
            retryAfter: Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")),
            body: data)
    }

    func get(request: URLRequest) async throws -> ReplayHTTPResponse {
        var request = request
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (data, response) = try await configSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return ReplayHTTPResponse(status: http.statusCode, retryAfter: nil, body: data)
    }

    /// Delta-seconds only (the server never sends an HTTP date).
    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), let seconds = Double(value),
              seconds.isFinite
        else { return nil }
        return max(0, seconds)
    }
}

/// Cancels every request for credentials of the remote settings' session
/// (HTTP Basic, Digest, NTLM, Negotiate, a client certificate), so none is
/// ever sent: the request fails, like any other failure. Only the server's
/// certificate is checked, the system's way.
final class ReplayConfigSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func disposition(for authenticationMethod: String) -> URLSession.AuthChallengeDisposition {
        authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (Self.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (Self.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }
}
