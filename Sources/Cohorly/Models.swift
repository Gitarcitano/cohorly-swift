import Foundation

/// A single analytics event, matching the Cohorly `/track` ingestion contract:
/// `{ event, properties: { distinct_id, time, $insert_id, $lib, ...custom } }`.
public struct TrackEvent: Codable, Equatable, Sendable {
    public var event: String
    public var properties: Properties

    public init(event: String, properties: Properties) {
        self.event = event
        self.properties = properties
    }
}

/// A profile update, matching the Cohorly `/engage` ingestion contract.
public struct EngagePayload: Codable, Equatable, Sendable {
    public var distinctId: String
    public var set: Properties?
    public var setOnce: Properties?
    public var add: Properties?
    public var unset: [String]?
    public var delete: Bool?
    /// Project token, stamped server-side by `Cohorly.initialize(apiHost:token:)`
    /// so the server can resolve this update to a project.
    public var token: String?

    public init(
        distinctId: String,
        set: Properties? = nil,
        setOnce: Properties? = nil,
        add: Properties? = nil,
        unset: [String]? = nil,
        delete: Bool? = nil,
        token: String? = nil
    ) {
        self.distinctId = distinctId
        self.set = set
        self.setOnce = setOnce
        self.add = add
        self.unset = unset
        self.delete = delete
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case set = "$set"
        case setOnce = "$set_once"
        case add = "$add"
        case unset = "$unset"
        case delete = "$delete"
        case token
    }
}
