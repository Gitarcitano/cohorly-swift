import XCTest
@testable import CohorlyCrash

final class CrashReportConverterTests: XCTestCase {
    private func convert(_ report: [String: Any]) throws -> ConvertedEvent {
        try ConvertedEvent(CrashReportConverter.convert(report: report, sending: Fixture.sending))
    }

    func testSegvBecomesAFatalMachExceptionEvent() throws {
        let event = try convert(try Fixture.kscrash("segv"))

        XCTAssertEqual(event.raw["event"] as? String, "$exception")
        XCTAssertEqual(event["$exception_level"] as? String, "fatal")
        XCTAssertEqual(event.exception["type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertEqual(event.exception["value"] as? String, "KERN_INVALID_ADDRESS at 0x00000000ffffffff (SIGSEGV)")
        XCTAssertEqual(event.mechanism["type"] as? String, "mach")
        XCTAssertEqual(event.mechanism["handled"] as? Bool, false)
        // report.timestamp "2026-11-11T14:44:49.914280Z"
        XCTAssertEqual(event["time"] as? Int64, 1_794_408_289_914)
        XCTAssertEqual(event["$insert_id"] as? String, "7ba1bd2f-c0c1-491d-9574-2ba7b5089cff")
        XCTAssertEqual(event["$os"] as? String, "iOS")
        XCTAssertEqual(event["$lib"] as? String, "ios")
        XCTAssertEqual(event["$lib_version"] as? String, "9.9.9")
        // $app_version_string / $app_build_number describe the SENDING launch.
        XCTAssertEqual(event["$app_version_string"] as? String, "2.0.0")
        XCTAssertEqual(event["$app_build_number"] as? String, "31")
    }

    func testCrashedThreadIsTheExceptionAndFramesAreOldestFirst() throws {
        let event = try convert(try Fixture.kscrash("segv"))

        // 16 frames, KSCrash's innermost (the crashing one) ends up last.
        XCTAssertEqual(event.frames.count, 16)
        let crashing = try XCTUnwrap(event.frames.last)
        XCTAssertEqual(crashing["instruction_addr"] as? String, "0x000000000005b720")
        XCTAssertEqual(crashing["image_addr"] as? String, "0x0000000000054000")
        XCTAssertEqual(crashing["debug_id"] as? String, "5425b875-d142-3832-be8c-3b7dd8130813")
        XCTAssertEqual(crashing["module"] as? String, "Crash-Tester")
        XCTAssertEqual(crashing["platform"] as? String, "native")
        XCTAssertEqual(crashing["in_app"] as? Bool, true)

        // The other threads, minus KSCrash's own handler threads (6 and 7).
        XCTAssertEqual(event.threads.compactMap { $0["id"] as? Int }, [1, 2, 3, 4, 5])
        XCTAssertEqual(event.threads.first { $0["id"] as? Int == 2 }?["name"] as? String, "apple.libdispatch-manager")
        XCTAssertEqual(event.threads.first { $0["id"] as? Int == 4 }?["name"] as? String, "WebThread")
    }

    func testCrashedThreadIsFoundWhereverItIs() throws {
        var report = try Fixture.kscrash("segv")
        var crash = try XCTUnwrap(report["crash"] as? [String: Any])
        var threads = try XCTUnwrap(crash["threads"] as? [[String: Any]])
        threads[0]["crashed"] = false
        threads[4]["crashed"] = true // WebThread
        crash["threads"] = threads
        report["crash"] = crash

        let event = try convert(report)
        let webThreadBacktrace = try XCTUnwrap(threads[4]["backtrace"] as? [String: Any])
        let webThreadTop = try XCTUnwrap(webThreadBacktrace["contents"] as? [[String: Any]])[0]
        XCTAssertEqual(event.frames.last?["instruction_addr"] as? String,
                       CrashPayload.hex(CrashPayload.uint(webThreadTop["instruction_addr"])!))
        XCTAssertEqual(event.threads.compactMap { $0["id"] as? Int }, [0, 1, 2, 3, 5])
    }

    func testInAppFramesNeverCarryAFunction() throws {
        let event = try convert(try Fixture.kscrash("segv"))
        let all = event.frames + event.threads.flatMap(event.threadFrames)

        let inApp = all.filter { $0["in_app"] as? Bool == true }
        XCTAssertFalse(inApp.isEmpty)
        XCTAssertTrue(inApp.allSatisfy { $0["function"] == nil })
        // System frames keep the runtime's symbol.
        let uikit = try XCTUnwrap(event.frames.first { $0["module"] as? String == "UIKit" })
        XCTAssertEqual(uikit["in_app"] as? Bool, false)
        XCTAssertNotNil(uikit["function"] as? String)
    }

    func testAddressesAreSixteenLowercaseHexDigits() throws {
        let event = try convert(try Fixture.kscrash("abort"))
        let pattern = try NSRegularExpression(pattern: "^0x[0-9a-f]{16}$")
        for frame in event.frames + event.threads.flatMap(event.threadFrames) {
            for key in ["instruction_addr", "image_addr"] {
                let value = try XCTUnwrap(frame[key] as? String)
                XCTAssertEqual(pattern.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value)), 1, value)
            }
            let debugId = try XCTUnwrap(frame["debug_id"] as? String)
            XCTAssertEqual(debugId, debugId.lowercased())
        }
    }

    func testNSExceptionUsesTheThrowSiteStack() throws {
        let event = try convert(try Fixture.kscrash("nsexception"))

        XCTAssertEqual(event.exception["type"] as? String, "NSInvalidArgumentException")
        XCTAssertEqual(event.exception["value"] as? String,
                       "-[__NSArrayI objectForKey:]: unrecognized selector sent to instance 0x1e59bc50")
        XCTAssertEqual(event.mechanism["type"] as? String, "nsexception")
        // last_exception_backtrace has 21 frames; its innermost is last.
        XCTAssertEqual(event.frames.count, 21)
        XCTAssertEqual(event.frames.last?["instruction_addr"] as? String, "0x00000000315821bf")
        XCTAssertEqual(event.frames.last?["function"] as? String, "-[NSObject(NSObject) doesNotRecognizeSelector:]")
    }

    func testAbortIsASignal() throws {
        let event = try convert(try Fixture.kscrash("abort"))
        XCTAssertEqual(event.exception["type"] as? String, "EXC_CRASH")
        XCTAssertEqual(event.exception["value"] as? String, "SIGABRT")
        XCTAssertEqual(event.mechanism["type"] as? String, "signal")
    }

    func testCppExceptionKeepsItsTypeAndWhat() throws {
        let event = try convert(try Fixture.kscrash("cpp"))
        XCTAssertEqual(event.exception["type"] as? String, "std::runtime_error")
        XCTAssertEqual(event.exception["value"] as? String, "inventory index out of range")
        XCTAssertEqual(event.mechanism["type"] as? String, "cpp_exception")
    }

    func testALinkRegisterEqualToThePCIsOneFrame() throws {
        var report = try Fixture.kscrash("segv")
        var crash = try XCTUnwrap(report["crash"] as? [String: Any])
        var threads = try XCTUnwrap(crash["threads"] as? [[String: Any]])
        var backtrace = try XCTUnwrap(threads[0]["backtrace"] as? [String: Any])
        var contents = try XCTUnwrap(backtrace["contents"] as? [[String: Any]])
        let original = contents.count
        contents.insert(contents[0], at: 1)
        backtrace["contents"] = contents
        threads[0]["backtrace"] = backtrace
        crash["threads"] = threads
        report["crash"] = crash

        let event = try convert(report)
        XCTAssertEqual(event.frames.count, original)
        let addrs = event.frames.compactMap { $0["instruction_addr"] as? String }
        XCTAssertNotEqual(addrs[addrs.count - 1], addrs[addrs.count - 2])
    }

    func testSwiftFatalErrorMessageIsAppendedToTheValue() throws {
        let event = try convert(try Fixture.kscrash("fatal"))
        XCTAssertEqual(event.exception["type"] as? String, "EXC_BREAKPOINT")
        XCTAssertEqual(event.exception["value"] as? String,
                       "SIGTRAP: Example/AppDelegate.swift:86: Fatal error: checkout total was negative")
        XCTAssertEqual(event.mechanism["type"] as? String, "mach")
    }

    func testReleaseAndIdentityComeFromTheCrashUserInfo() throws {
        let event = try convert(try Fixture.kscrash("segv"))
        XCTAssertEqual(event["$exception_release"] as? String, "com.cohorly.example@1.4.0+27")
        XCTAssertEqual(event["$exception_dist"] as? String, "4f1b2a9e-1d1c-4f7a-9a51-3a3a2f0c9e11")
        XCTAssertEqual(event["distinct_id"] as? String, "user-42")
        XCTAssertEqual(event["$device_id"] as? String, "8c3f6f8e-0d7b-4a51-9a6b-0b1f0f3c2e10")
        XCTAssertEqual(event["$user_id"] as? String, "user-42")
        XCTAssertEqual(event["$os_version"] as? String, "4.3.3")
        XCTAssertEqual(event["$model"] as? String, "iPhone3,1")
    }

    func testSessionIdFromTheCrashUserInfoBecomesSessionIdProperty() throws {
        var report = try Fixture.kscrash("segv")
        var user = try XCTUnwrap(report["user"] as? [String: Any])
        user["session_id"] = "5f0c1d2e3a4b4c5d9e8f7a6b5c4d3e2f" // the key KSCrash stores
        report["user"] = user

        let event = try convert(report)
        XCTAssertEqual(event["$session_id"] as? String, "5f0c1d2e3a4b4c5d9e8f7a6b5c4d3e2f")
    }

    func testCrashWithoutSessionIdHasNoSessionIdProperty() throws {
        let event = try convert(try Fixture.kscrash("segv"))
        XCTAssertNil(event["$session_id"])
    }

    func testMissingReleaseIsUnknownAndDistinctIdFallsBackToTheCrashDeviceId() throws {
        var report = try Fixture.kscrash("segv")
        report["user"] = ["device_id": "device-at-crash"]

        let event = try convert(report)
        XCTAssertEqual(event["$exception_release"] as? String, "ios@unknown")
        XCTAssertEqual(event["distinct_id"] as? String, "device-at-crash")
        XCTAssertEqual(event["$device_id"] as? String, "device-at-crash")
        XCTAssertNil(event["$exception_dist"])
        XCTAssertNil(event["$user_id"])
    }

    func testNoUserInfoNeverBorrowsTheSendingLaunchValues() throws {
        var report = try Fixture.kscrash("segv")
        report.removeValue(forKey: "user")

        let event = try convert(report)
        XCTAssertEqual(event["$exception_release"] as? String, "ios@unknown")
        XCTAssertNil(event["distinct_id"])
        XCTAssertNil(event["$device_id"])
    }

    func testCapsKeepTwentyThreadsAndTheCrashingEndOfEachStack() throws {
        var report = try Fixture.kscrash("segv")
        var crash = try XCTUnwrap(report["crash"] as? [String: Any])
        // 150 frames, innermost first as KSCrash writes them: 0x1000 is the crashing one.
        let deep: [[String: Any]] = (0..<150).map { i in
            ["instruction_addr": 0x1000 + i, "object_addr": 344_064, "object_name": "Crash-Tester"]
        }
        var threads: [[String: Any]] = [["index": 0, "crashed": true, "backtrace": ["contents": deep]]]
        for index in 1...30 {
            threads.append(["index": index, "crashed": false, "backtrace": ["contents": deep]])
        }
        crash["threads"] = threads
        report["crash"] = crash

        let event = try convert(report)
        XCTAssertEqual(event.frames.count, 100)
        XCTAssertEqual(event.frames.last?["instruction_addr"] as? String, "0x0000000000001000")
        // The oldest 50 calls (0x1000 + 149 ... + 100) were dropped.
        XCTAssertEqual(event.frames.first?["instruction_addr"] as? String, CrashPayload.hex(0x1000 + 99))
        XCTAssertEqual(event.threads.count, 20)
        XCTAssertEqual(event.threads.compactMap { $0["id"] as? Int }, Array(1...20))
        XCTAssertTrue(event.threads.allSatisfy { event.threadFrames($0).count == 100 })
        XCTAssertEqual(event.threads.first.flatMap { event.threadFrames($0).last?["instruction_addr"] as? String },
                       "0x0000000000001000")
    }

    func testReportWithoutCrashTimeIsNotConverted() throws {
        var report = try Fixture.kscrash("segv")
        var info = try XCTUnwrap(report["report"] as? [String: Any])
        info.removeValue(forKey: "timestamp")
        report["report"] = info
        XCTAssertNil(CrashReportConverter.convert(report: report, sending: Fixture.sending))
    }

    func testReportWithoutIdGetsAStableInsertId() throws {
        var report = try Fixture.kscrash("segv")
        var info = try XCTUnwrap(report["report"] as? [String: Any])
        info.removeValue(forKey: "id")
        report["report"] = info

        let first = try convert(report)["$insert_id"] as? String
        let second = try convert(report)["$insert_id"] as? String
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testCrashTimeParsing() {
        XCTAssertEqual(CrashReportConverter.crashTimeMs("2026-11-11T14:44:49.914280Z"), 1_794_408_289_914)
        XCTAssertEqual(CrashReportConverter.crashTimeMs("2026-11-11T14:44:49Z"), 1_794_408_289_000)
        XCTAssertEqual(CrashReportConverter.crashTimeMs("2026-11-11T14:44:49.5Z"), 1_794_408_289_500)
        XCTAssertEqual(CrashReportConverter.crashTimeMs(NSNumber(value: 1_794_408_289_914_280)), 1_794_408_289_914)
        XCTAssertNil(CrashReportConverter.crashTimeMs("not a date"))
        XCTAssertNil(CrashReportConverter.crashTimeMs(nil))
    }

    func testInAppPathRules() {
        XCTAssertTrue(CrashPayload.isInApp(path: "/private/var/containers/Bundle/Application/X/Shop.app/Shop"))
        XCTAssertTrue(CrashPayload.isInApp(path: "/var/containers/Bundle/Application/X/Shop.app/Frameworks/Lib.framework/Lib"))
        XCTAssertFalse(CrashPayload.isInApp(path: "/System/Library/Frameworks/UIKit.framework/UIKit"))
        XCTAssertFalse(CrashPayload.isInApp(path: "/usr/lib/libobjc.A.dylib"))
        XCTAssertFalse(CrashPayload.isInApp(
            path: "/Library/Developer/CoreSimulator/Volumes/iOS_24B/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/Applications/Preferences.app/Preferences"))
        XCTAssertFalse(CrashPayload.isInApp(path: ""))
    }
}
