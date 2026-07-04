import Foundation

@testable import Cohorly

struct RecordedRequest {
    let apiHost: String
    let path: String
    let body: Data
}

/// In-memory mock transport for tests. Optionally simulates failures for a
/// configured number of upcoming calls, to exercise retry-on-failure logic.
final class MockTransport: CohorlyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
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
            lock.unlock()
            throw CohorlyTransportError.httpError(status: 500)
        }
        lock.unlock()
    }
}
