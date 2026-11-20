import Foundation
import XCTest
@testable import CohorlyCrash

/// Loads the JSON fixtures under Fixtures/ (see Fixtures/README.md for their origin).
enum Fixture {
    static func json(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let base = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let data = try Data(contentsOf: base.appendingPathComponent(path))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    static func kscrash(_ name: String) throws -> [String: Any] { try json("kscrash/\(name).json") }
    static func metricKit(_ name: String) throws -> [String: Any] { try json("metrickit/\(name).json") }

    static let sending = CrashSendingLaunch(
        lib: CrashLibInfo(lib: "ios", version: "9.9.9"),
        appVersionString: "2.0.0",
        appBuildNumber: "31"
    )
}

/// Typed access to a converted event.
struct ConvertedEvent {
    let raw: [String: Any]

    init(_ raw: [String: Any]?, file: StaticString = #filePath, line: UInt = #line) throws {
        self.raw = try XCTUnwrap(raw, "conversion returned nil", file: file, line: line)
    }

    var properties: [String: Any] { raw["properties"] as? [String: Any] ?? [:] }
    subscript(key: String) -> Any? { properties[key] }

    var exception: [String: Any] { (properties["$exception_list"] as? [[String: Any]])?.first ?? [:] }
    var mechanism: [String: Any] { exception["mechanism"] as? [String: Any] ?? [:] }
    var frames: [[String: Any]] { (exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? [] }
    var threads: [[String: Any]] { properties["$exception_threads"] as? [[String: Any]] ?? [] }

    func threadFrames(_ thread: [String: Any]) -> [[String: Any]] {
        (thread["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? []
    }
}
