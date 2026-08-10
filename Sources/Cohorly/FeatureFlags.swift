import Foundation

/// One evaluated feature flag, matching the `/flags/evaluate` response shape:
/// `{ "flags": { "<key>": { enabled, variant, payload, reason } } }`.
public struct FlagResult: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Variant key for a multivariate flag; `nil` for a plain on/off flag.
    public var variant: String?
    /// Arbitrary JSON attached to the flag (or the matched variant).
    public var payload: JSONValue?
    /// Why the server decided this way (e.g. "cohort", "rollout", "override").
    public var reason: String

    public init(enabled: Bool, variant: String? = nil, payload: JSONValue? = nil, reason: String = "") {
        self.enabled = enabled
        self.variant = variant
        self.payload = payload
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case enabled, variant, payload, reason
    }

    /// Tolerant decoding: a missing `enabled`/`reason` falls back to the
    /// default instead of failing the decode. Android's parser and the JS
    /// SDKs are equally lenient; a strict decode here would silently drop
    /// the whole flag map over one omitted field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// Wrapper that turns a malformed flag entry into `nil` instead of failing
/// the surrounding dictionary decode, so one bad entry never discards the
/// rest of the response.
struct FailableFlag: Decodable, Sendable {
    let result: FlagResult?

    init(from decoder: Decoder) throws {
        result = try? FlagResult(from: decoder)
    }
}

/// Fetcher used for feature-flag evaluation: POSTs `body` to
/// `apiHost + path` and returns the raw response data.
///
/// It MUST return `nil` on any failure (network, non-2xx, cancellation) and
/// never throw: a failed evaluation keeps the previously cached flags rather
/// than surfacing an error to the app.
public protocol CohorlyFlagsFetcher: Sendable {
    func fetchFlags(apiHost: String, path: String, body: Data) async -> Data?
}

/// Default fetcher using `URLSession.shared`.
public final class URLSessionFlagsFetcher: CohorlyFlagsFetcher {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? {
        guard let url = URL(string: apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost)?
            .appendingPathComponent(path)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
                !(200...299).contains(httpResponse.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

/// Body for `/flags/evaluate`.
struct FlagsRequest: Codable, Equatable, Sendable {
    var distinctId: String
    var token: String?

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case token
    }
}

/// Response envelope for `/flags/evaluate`.
struct FlagsResponse: Codable, Equatable, Sendable {
    var flags: [String: FlagResult]

    init(flags: [String: FlagResult]) {
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey {
        case flags
    }

    /// Entry-tolerant decode: a malformed entry is skipped, never dropping
    /// the whole map (see `FailableFlag`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: FailableFlag].self, forKey: .flags)
        flags = raw.compactMapValues(\.result)
    }
}

/// Persisted flag cache. `distinctId` scopes the cache: on load it is
/// discarded when it does not match the current distinct id, so one user's
/// flags are never served to another.
struct FlagsCache: Codable, Equatable, Sendable {
    var distinctId: String
    var flags: [String: FlagResult]

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case flags
    }
}
