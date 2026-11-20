import XCTest
@testable import CohorlyCrash

final class MetricKitConverterTests: XCTestCase {
    private let environment = MetricKitEnvironment(
        lib: CrashLibInfo(lib: "react-native", version: "1.2.0"),
        bundleId: "com.example.shop",
        deviceId: "device-now",
        appVersionString: "1.5.0",
        appBuildNumber: "30",
        inAppImageUUIDs: ["74aafb80-37d1-3f51-8f1a-165be39e8122"],
        mainExecutableName: "Shop"
    )
    private let time: Int64 = 1_794_409_842_362

    private func convert(_ name: String, _ kind: MetricKitDiagnosticKind, environment: MetricKitEnvironment? = nil) throws -> ConvertedEvent {
        try ConvertedEvent(MetricKitConverter.convert(
            diagnostic: try Fixture.metricKit(name),
            kind: kind,
            timeMs: time,
            environment: environment ?? self.environment
        ))
    }

    func testCrashDiagnosticBecomesAnErrorLevelExceptionEvent() throws {
        let event = try convert("crash", .crash)

        XCTAssertEqual(event.raw["event"] as? String, "$exception")
        XCTAssertEqual(event["$exception_level"] as? String, "error")
        XCTAssertEqual(event.mechanism["type"] as? String, "metrickit")
        XCTAssertEqual(event.mechanism["handled"] as? Bool, false)
        XCTAssertEqual(event.exception["type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertEqual(event.exception["value"] as? String, "Namespace SIGNAL, Code 11 Segmentation fault: 11")
        XCTAssertEqual(event["time"] as? Int64, time)
        XCTAssertEqual(event["$exception_release"] as? String, "com.example.shop@1.4.0+27")
        XCTAssertNil(event["$exception_dist"])
        XCTAssertEqual(event["$os_version"] as? String, "27.1")
        XCTAssertEqual(event["$model"] as? String, "iPhone16,2")
        XCTAssertEqual(event["$lib"] as? String, "react-native")
        XCTAssertEqual(event["$app_version_string"] as? String, "1.5.0")
    }

    func testIdentityIsTheCurrentDeviceIdNeverAUser() throws {
        let event = try convert("crash", .crash)
        XCTAssertEqual(event["distinct_id"] as? String, "device-now")
        XCTAssertEqual(event["$device_id"] as? String, "device-now")
        XCTAssertNil(event["$user_id"])
    }

    func testCallStackTreeIsFlattenedOldestFirstWithTheAttributedThreadAsTheException() throws {
        let event = try convert("crash", .crash)

        XCTAssertEqual(event.frames.compactMap { $0["module"] as? String }, ["dyld", "UIKitCore", "Shop"])
        let crashing = try XCTUnwrap(event.frames.last)
        XCTAssertEqual(crashing["instruction_addr"] as? String, "0x0000000104d37c8c")
        XCTAssertEqual(crashing["image_addr"] as? String, "0x0000000104d36000")
        XCTAssertEqual(crashing["debug_id"] as? String, "74aafb80-37d1-3f51-8f1a-165be39e8122")
        XCTAssertEqual(crashing["in_app"] as? Bool, true)
        XCTAssertEqual(crashing["platform"] as? String, "native")
        XCTAssertEqual(event.frames.first?["image_addr"] as? String, "0x00000001050ea200")
        XCTAssertEqual(event.frames[1]["in_app"] as? Bool, false)
        XCTAssertTrue(event.frames.allSatisfy { $0["function"] == nil })

        XCTAssertEqual(event.threads.count, 1)
        XCTAssertEqual(event.threads.first?["id"] as? Int, 0)
        XCTAssertEqual(event.threads.first.flatMap { event.threadFrames($0).first?["module"] as? String },
                       "libsystem_kernel.dylib")
    }

    func testInAppFallsBackToTheMainExecutableName() throws {
        var environment = self.environment
        environment.inAppImageUUIDs = []
        let event = try convert("crash", .crash, environment: environment)
        XCTAssertEqual(event.frames.last?["in_app"] as? Bool, true)
        XCTAssertEqual(event.frames.first?["in_app"] as? Bool, false)
    }

    func testHangIsAWarningAlongTheHeaviestBranch() throws {
        let event = try convert("hang", .hang)

        XCTAssertEqual(event["$exception_level"] as? String, "warning")
        XCTAssertEqual(event.mechanism["type"] as? String, "metrickit")
        XCTAssertEqual(event.exception["type"] as? String, "AppHang")
        XCTAssertEqual(event.exception["value"] as? String, "App hang of 4.25 sec")
        // Root (innermost) libsystem_kernel, then its heaviest caller Shop (7 > 2 samples).
        XCTAssertEqual(event.frames.compactMap { $0["module"] as? String }, ["Shop", "libsystem_kernel.dylib"])
        XCTAssertEqual(event.frames.first?["instruction_addr"] as? String, "0x0000000104d383a0")
        // No bundleIdentifier in the metadata: the current bundle id is the prefix.
        XCTAssertEqual(event["$exception_release"] as? String, "com.example.shop@1.4.0+27")
    }

    func testCPUExceptionIsAWarning() throws {
        let event = try convert("cpu", .cpuException)

        XCTAssertEqual(event["$exception_level"] as? String, "warning")
        XCTAssertEqual(event.mechanism["type"] as? String, "metrickit")
        XCTAssertEqual(event.exception["type"] as? String, "CPUException")
        XCTAssertEqual(event.exception["value"] as? String, "90 sec of CPU over 180 sec")
        // The diagnostic's own build, not the running one.
        XCTAssertEqual(event["$exception_release"] as? String, "com.example.shop@1.3.9+26")
    }

    func testMetricKitIsNeverFatal() throws {
        for (name, kind) in [("crash", MetricKitDiagnosticKind.crash), ("hang", .hang), ("cpu", .cpuException)] {
            XCTAssertNotEqual(try convert(name, kind)["$exception_level"] as? String, "fatal", name)
        }
    }

    func testSameDiagnosticGivesTheSameInsertId() throws {
        let first = try convert("crash", .crash)["$insert_id"] as? String
        let second = try convert("crash", .crash)["$insert_id"] as? String
        let hang = try convert("hang", .hang)["$insert_id"] as? String

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, hang)
        XCTAssertNotNil(UUID(uuidString: first ?? ""))
        XCTAssertEqual(first, first?.lowercased())
    }

    func testInsertIdIgnoresKeyOrder() throws {
        let diagnostic = try Fixture.metricKit("cpu")
        let reordered = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: diagnostic, options: [])
        ) as? [String: Any])
        let a = MetricKitConverter.convert(diagnostic: diagnostic, kind: .cpuException, timeMs: 1, environment: environment)
        let b = MetricKitConverter.convert(diagnostic: reordered, kind: .cpuException, timeMs: 2, environment: environment)
        XCTAssertEqual((a?["properties"] as? [String: Any])?["$insert_id"] as? String,
                       (b?["properties"] as? [String: Any])?["$insert_id"] as? String)
    }

    func testDiagnosticWithoutVersionHasAnUnknownRelease() throws {
        var diagnostic = try Fixture.metricKit("cpu")
        diagnostic["diagnosticMetaData"] = [:] as [String: Any]
        let event = try ConvertedEvent(MetricKitConverter.convert(
            diagnostic: diagnostic, kind: .cpuException, timeMs: time, environment: environment
        ))
        XCTAssertEqual(event["$exception_release"] as? String, "ios@unknown")
    }

    func testOsVersionNumber() {
        XCTAssertEqual(MetricKitConverter.osVersionNumber("iPhone OS 17.4 (21E219)"), "17.4")
        XCTAssertEqual(MetricKitConverter.osVersionNumber("iPhone OS 18.0.1 (22A3370)"), "18.0.1")
        XCTAssertNil(MetricKitConverter.osVersionNumber("unknown"))
    }
}
