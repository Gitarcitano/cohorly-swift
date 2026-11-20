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

/// How flag assignments are sourced and persisted (Mixpanel's
/// `variantLookupPolicy` equivalent, "Flag Persistence" in the feature-flags
/// docs). The three modes and their names are shared verbatim across all
/// Cohorly client SDKs (sdk-core, sdk-web, sdk-react-native, Android).
public enum FlagPersistenceMode: String, Sendable {
    /// Never reads nor writes the persisted cache: flags only ever come from
    /// a `/flags/evaluate` response received this session. A failed
    /// evaluation leaves nothing to serve, so reads resolve to the fallback.
    case networkOnly
    /// Prefers the network; a valid persisted cache (inside the TTL, same
    /// distinct id) is served whenever an evaluation fails or none has
    /// succeeded yet, and the cache is still written on every success.
    /// Strict about freshness: a cache past the TTL is dropped, never
    /// served (unlike `persistenceUntilNetworkSuccess`, which tolerates
    /// staleness). Because this API's getters are synchronous - they cannot
    /// await a response the way Mixpanel's async lookups do - a valid cache
    /// is adopted immediately, like `persistenceUntilNetworkSuccess`.
    case networkFirst
    /// Serves the persisted cache immediately so startup doesn't flicker;
    /// the first successful evaluation takes over and re-persists. A failed
    /// evaluation keeps the cached values serving. This is the default: it
    /// preserves the pre-policy behavior of always restoring the cache.
    /// Trades freshness for offline availability: a cache past the TTL still
    /// serves while inside `Cohorly.flagCacheMaxStale` (7 days), and a
    /// legacy cache without `stored_at` serves indefinitely.
    case persistenceUntilNetworkSuccess
}

/// Where a served flag value came from. The raw values are the wire strings
/// shared with the other SDKs (reported as `$feature_flag_source` on
/// `$feature_flag_called`).
public enum FlagSource: String, Sendable {
    /// From a `/flags/evaluate` response received this session.
    case network
    /// From the persisted cache (same distinct id, usable under the active
    /// `FlagPersistenceMode`).
    case persistence
    /// The flag is unknown or unloaded, so the caller's fallback was served.
    case fallback
}

/// The full result of a flag lookup: the value plus its provenance, so a
/// caller can tell a fresh assignment apart from a persisted or fallback one.
public struct FlagDetails: Equatable, Sendable {
    /// The flag key this result describes.
    public var key: String
    /// The flag's variant when it has one, else its enabled boolean; the
    /// caller's fallback when the flag is unknown or unloaded.
    public var value: JSONValue
    /// The flag's enabled boolean. When the flag is unknown this is the
    /// truthiness of the fallback (`.bool(true)` or a non-empty `.string`),
    /// matching what `isFeatureEnabled(key, fallback:)` would return.
    public var enabled: Bool
    /// The JSON payload attached to the flag, or `nil` when it has none or
    /// the flag is unknown.
    public var payload: JSONValue?
    public var source: FlagSource
    /// Epoch ms when the served flag set was written to the cache; non-nil
    /// only when `source == .persistence` AND the cache carries `stored_at`
    /// (a legacy cache has no provable age, so this stays `nil`).
    public var persistedAt: Int?
    /// The configured cache TTL in ms; non-nil only when
    /// `source == .persistence`.
    public var ttlMs: Int?

    public init(
        key: String,
        value: JSONValue,
        enabled: Bool,
        payload: JSONValue? = nil,
        source: FlagSource,
        persistedAt: Int? = nil,
        ttlMs: Int? = nil
    ) {
        self.key = key
        self.value = value
        self.enabled = enabled
        self.payload = payload
        self.source = source
        self.persistedAt = persistedAt
        self.ttlMs = ttlMs
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
/// flags are never served to another. `storedAt` (epoch ms) bounds its age
/// per the active `FlagPersistenceMode`. Caches written by pre-TTL SDK
/// versions carry no `storedAt`; their age cannot be proven, so they are
/// served rather than expired - the graceful-upgrade path preserving the
/// pre-feature behavior (the cache was served indefinitely).
struct FlagsCache: Codable, Equatable, Sendable {
    var distinctId: String
    var flags: [String: FlagResult]
    var storedAt: Int?

    init(distinctId: String, flags: [String: FlagResult], storedAt: Int? = nil) {
        self.distinctId = distinctId
        self.flags = flags
        self.storedAt = storedAt
    }

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case flags
        case storedAt = "stored_at"
    }
}
