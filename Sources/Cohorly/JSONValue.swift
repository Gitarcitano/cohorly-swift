import Foundation

/// A type-erased, `Codable`-friendly JSON value. Lets the public API accept
/// plain `[String: Any]` property dictionaries (converted internally) while
/// still being able to encode/decode/persist events with `Codable`.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Best-effort conversion from a loosely-typed value (as you'd get from
    /// an `[String: Any]` properties dictionary) into a `JSONValue`.
    /// Unsupported types are dropped to `.null` rather than throwing, so a
    /// single bad property never breaks tracking of the whole event.
    public init(any value: Any) {
        switch value {
        case let value as JSONValue:
            self = value
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as Float:
            self = .double(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if value.doubleValue.truncatingRemainder(dividingBy: 1) == 0,
                let intValue = Int(exactly: value)
            {
                self = .int(intValue)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as [Any]:
            self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// Converts back to a loosely-typed value suitable for `JSONSerialization`.
    public var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map { $0.anyValue }
        case .object(let value): return value.mapValues { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

public typealias Properties = [String: JSONValue]

extension Dictionary where Key == String, Value == Any {
    /// Converts a loosely-typed `[String: Any]` dictionary into `Properties`.
    public func toCohorlyProperties() -> Properties {
        mapValues { JSONValue(any: $0) }
    }
}
