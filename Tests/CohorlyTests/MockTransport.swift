import Foundation

@testable import Cohorly

struct RecordedRequest {
    let apiHost: String
    let path: String
    let body: Data
}

/// In-memory mock transport for tests. Optionally simulates failures for a
/// configured number of upcoming calls, to exercise retry-on-failure logic.
/// `failureStatus`/`failureRetryAfter` control the simulated error so tests can
/// exercise the full retry contract (429/400/413 + Retry-After).
final class MockTransport: CohorlyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    private var failuresRemaining: Int
    private let failureStatus: Int
    private let failureRetryAfter: TimeInterval?

    init(
        failuresRemaining: Int = 0,
        failureStatus: Int = 500,
        failureRetryAfter: TimeInterval? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.failureStatus = failureStatus
        self.failureRetryAfter = failureRetryAfter
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func post(apiHost: String, path: String, body: Data) async throws {
        lock.lock()
        _requests.append(RecordedRequest(apiHost: apiHost, path: path, body: body))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            let status = failureStatus
            let retryAfter = failureRetryAfter
            lock.unlock()
            throw CohorlyTransportError.httpError(status: status, retryAfter: retryAfter)
        }
        lock.unlock()
    }
}
