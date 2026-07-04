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
    case httpError(status: Int)
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
            throw CohorlyTransportError.httpError(status: httpResponse.statusCode)
        }
    }
}
