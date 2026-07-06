import Foundation

/// Network transport abstraction so tests can inject a mock instead of
/// hitting the network.
public protocol CohorlyTransport: Sendable {
    /// POSTs a JSON body to `path` (e.g. "/track") relative to `apiHost`.
    /// Should throw if the request fails or the server responds with a
    /// non-2xx status.
    func post(apiHost: String, path: String, body: Data) async throws
}

public enum CohorlyTransportError: Error {
    case invalidURL
    /// Non-2xx HTTP response. `retryAfter` is the parsed `Retry-After` header
    /// (in seconds) when present, so the client can honor the server's backoff
    /// hint on 429 / quota responses.
    case httpError(status: Int, retryAfter: TimeInterval?)
}

/// Default transport using `URLSession.shared`.
public final class URLSessionTransport: CohorlyTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(apiHost: String, path: String, body: Data) async throws {
        guard let url = URL(string: apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost)?
            .appendingPathComponent(path)
        else {
            throw CohorlyTransportError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let retryAfter = URLSessionTransport.parseRetryAfter(
                httpResponse.value(forHTTPHeaderField: "Retry-After")
            )
            throw CohorlyTransportError.httpError(
                status: httpResponse.statusCode, retryAfter: retryAfter)
        }
    }

    /// Parses a `Retry-After` header into seconds. Supports the delta-seconds
    /// form (an integer, per the server contract); returns nil otherwise.
    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
            !header.isEmpty
        else { return nil }
        if let seconds = Double(header) { return max(0, seconds) }
        return nil
    }
}
