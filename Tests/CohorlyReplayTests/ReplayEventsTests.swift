import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

func wireframe(
    _ id: Int, x: Int = 0, y: Int = 0, width: Int = 100, height: Int = 20, type: String = "div",
    text: String? = nil, children: [ReplayWireframe]? = nil
) -> ReplayWireframe {
    var wireframe = ReplayWireframe(id: id, x: x, y: y, width: width, height: height, type: type)
    wireframe.text = text
    wireframe.childWireframes = children
    return wireframe
}

/// The screen used by most tests: a window with a label and a button.
func sampleScreen(label: String = "Hello", extra: [ReplayWireframe] = []) -> [ReplayWireframe] {
    [wireframe(10_000_000, width: 390, height: 844, children: [
        wireframe(10_000_001, x: 16, y: 100, width: 200, height: 20, type: "text", text: label),
        wireframe(10_000_002, x: 16, y: 200, width: 120, height: 44, type: "input")
    ] + extra)].withParentIds()
}

func capture(
    _ wireframes: [ReplayWireframe], session: String = "session-a", href: String = "FormViewController",
    window: Int = 1, timestamp: Int64 = 1_800_000_000_000, forceFull: Bool = false
) -> ReplayScreenCapture {
    ReplayScreenCapture(
        sessionId: session, distinctId: "user-1", timestamp: timestamp, width: 390, height: 844, href: href,
        windowKey: window, wireframes: wireframes, forceFull: forceFull)
}

/// The decoded JSON of `value`, for assertions on the wire shape.
func jsonObject(_ value: ReplayJSON) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func eventTypes(_ events: [ReplayJSON]) -> [Int] { events.compactMap(ReplayEvents.type(of:)) }

final class ReplayEventsTests: XCTestCase {
    // MARK: - Builders

    func testMetaAndFullSnapshotHaveTheDocumentedShape() throws {
        let meta = try jsonObject(ReplayEvents.meta(width: 390, height: 844, href: "CheckoutViewController", timestamp: 42))
        XCTAssertEqual(meta["type"] as? Int, 4)
        XCTAssertEqual(meta["timestamp"] as? Int, 42)
        let metaData = try XCTUnwrap(meta["data"] as? [String: Any])
        XCTAssertEqual(metaData["width"] as? Int, 390)
        XCTAssertEqual(metaData["height"] as? Int, 844)
        XCTAssertEqual(metaData["href"] as? String, "CheckoutViewController")

        let full = try jsonObject(ReplayEvents.fullSnapshot(sampleScreen(), timestamp: 42))
        XCTAssertEqual(full["type"] as? Int, 2)
        let data = try XCTUnwrap(full["data"] as? [String: Any])
        XCTAssertEqual(data["initialOffset"] as? [String: Int], ["top": 0, "left": 0])
        let wireframes = try XCTUnwrap(data["wireframes"] as? [[String: Any]])
        XCTAssertEqual(wireframes.count, 1)
        XCTAssertEqual(wireframes[0]["id"] as? Int, 10_000_000)
        XCTAssertNil(wireframes[0]["parentId"], "parentId is not part of the wireframe")
        let children = try XCTUnwrap(wireframes[0]["childWireframes"] as? [[String: Any]])
        XCTAssertEqual(children.map { $0["type"] as? String }, ["text", "input"])
        XCTAssertEqual(children[0]["text"] as? String, "Hello")
    }

    func testTouchIsAnIncrementalMouseInteractionOnTheScreenRoot() throws {
        let start = try jsonObject(ReplayEvents.touch(.start, x: 12, y: 300, timestamp: 7))
        XCTAssertEqual(start["type"] as? Int, 3)
        let data = try XCTUnwrap(start["data"] as? [String: Int])
        XCTAssertEqual(data, ["source": 2, "type": 7, "id": 0, "x": 12, "y": 300, "pointerType": 2])
        let end = try jsonObject(ReplayEvents.touch(.end, x: 1, y: 2, timestamp: 8))
        XCTAssertEqual((end["data"] as? [String: Int])?["type"], 9)
    }

    func testMutationLeavesOutEmptyListsAndIsNilWhenAllAreEmpty() throws {
        XCTAssertNil(ReplayEvents.mutation(adds: [], updates: [], removes: [], timestamp: 1))
        let added = wireframe(10_000_009, type: "text", text: "New")
        var withParent = added
        withParent.parentId = 10_000_000
        let event = try XCTUnwrap(ReplayEvents.mutation(adds: [withParent], updates: [], removes: [], timestamp: 1))
        let object = try jsonObject(event)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["source", "adds"])
        XCTAssertEqual(data["source"] as? Int, 0)
        let adds = try XCTUnwrap(data["adds"] as? [[String: Any]])
        XCTAssertEqual(adds[0]["parentId"] as? Int, 10_000_000)
        XCTAssertEqual((adds[0]["wireframe"] as? [String: Any])?["id"] as? Int, 10_000_009)
    }

    func testRemovesCarryTheirParentAndIdInTheFinalJSON() throws {
        let status = ReplayWindowStatus()
        _ = status.events(for: capture(sampleScreen()))
        var withoutButton = sampleScreen()
        withoutButton[0].childWireframes?.removeAll { $0.id == 10_000_002 }
        let events = status.events(for: capture(withoutButton))
        XCTAssertEqual(eventTypes(events), [3])
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(events[0])) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["source", "removes"])
        let removes = try XCTUnwrap(data["removes"] as? [[String: Int]])
        XCTAssertEqual(removes, [["parentId": 10_000_000, "id": 10_000_002]])
    }

    // MARK: - Diff

    func testDiffFindsAddsRemovesAndUpdatesByIdWithParents() {
        let old = sampleScreen()
        var new = sampleScreen(label: "Bye", extra: [wireframe(10_000_003, x: 16, y: 400, type: "image")])
        // The button goes away.
        new[0].childWireframes?.removeAll { $0.id == 10_000_002 }
        let diff = replayWireframeDiff(old: old, new: new)
        XCTAssertEqual(diff.adds.map(\.id), [10_000_003])
        XCTAssertEqual(diff.adds.map(\.parentId), [10_000_000])
        XCTAssertEqual(diff.removes.map(\.id), [10_000_002])
        XCTAssertEqual(diff.removes.map(\.parentId), [10_000_000])
        // The window's own fields are the same: only the label is an update.
        XCTAssertEqual(diff.updates.map(\.id), [10_000_001])
        XCTAssertEqual(diff.updates.first?.text, "Bye")
    }

    func testIdenticalScreensHaveAnEmptyDiff() {
        let diff = replayWireframeDiff(old: sampleScreen(), new: sampleScreen())
        XCTAssertTrue(diff.adds.isEmpty && diff.removes.isEmpty && diff.updates.isEmpty)
    }

    // MARK: - Window status

    func testFirstCaptureOfASessionIsMetaThenFullSnapshotThenOnlyChanges() throws {
        let status = ReplayWindowStatus()
        let first = status.events(for: capture(sampleScreen()))
        XCTAssertEqual(eventTypes(first), [4, 2])
        XCTAssertTrue(status.hasFullSnapshot("session-a"))

        XCTAssertEqual(status.events(for: capture(sampleScreen())), [], "nothing changed, no event")

        let changed = status.events(for: capture(sampleScreen(label: "World")))
        XCTAssertEqual(eventTypes(changed), [3])
        let data = try XCTUnwrap(try jsonObject(changed[0])["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["source", "updates"])
        let update = try XCTUnwrap((data["updates"] as? [[String: Any]])?.first)
        XCTAssertEqual(update["parentId"] as? Int, 10_000_000)
        XCTAssertEqual((update["wireframe"] as? [String: Any])?["text"] as? String, "World")
    }

    func testAnAddedViewBecomesAnAddWithItsParent() throws {
        let status = ReplayWindowStatus()
        _ = status.events(for: capture(sampleScreen()))
        let events = status.events(for: capture(sampleScreen(extra: [wireframe(10_000_005, x: 16, y: 600, type: "text", text: "Toast")])))
        XCTAssertEqual(eventTypes(events), [3])
        let data = try XCTUnwrap(try jsonObject(events[0])["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["source", "adds"])
    }

    func testFullSnapshotAgainOnNewSessionWindowScreenForceOrReset() {
        let status = ReplayWindowStatus()
        _ = status.events(for: capture(sampleScreen()))
        XCTAssertEqual(eventTypes(status.events(for: capture(sampleScreen(), session: "session-b"))), [4, 2])
        XCTAssertFalse(status.hasFullSnapshot("session-a"))
        XCTAssertEqual(eventTypes(status.events(for: capture(sampleScreen(), session: "session-b", window: 2))), [4, 2])
        XCTAssertEqual(eventTypes(status.events(for: capture(sampleScreen(), session: "session-b", href: "ListViewController", window: 2))), [4, 2])
        XCTAssertEqual(eventTypes(status.events(for: capture(sampleScreen(), session: "session-b", href: "ListViewController", window: 2, forceFull: true))), [4, 2])
        status.reset()
        XCTAssertEqual(eventTypes(status.events(for: capture(sampleScreen(), session: "session-b", href: "ListViewController", window: 2))), [4, 2])
    }

    func testAViewMovedToAnotherParentOrReorderedIsAFullSnapshot() {
        let status = ReplayWindowStatus()
        let container = wireframe(10_000_010, y: 300, width: 390, height: 200)
        let screen = sampleScreen(extra: [container])
        _ = status.events(for: capture(screen))
        // The label moves into the container.
        var moved = screen
        var label = moved[0].childWireframes!.remove(at: 0)
        label.y = 320
        moved[0].childWireframes![1].childWireframes = [label]
        XCTAssertEqual(eventTypes(status.events(for: capture(moved.withParentIds()))), [4, 2])

        // Same children, other order.
        _ = status.events(for: capture(screen))
        var reordered = screen
        reordered[0].childWireframes!.reverse()
        XCTAssertEqual(eventTypes(status.events(for: capture(reordered.withParentIds()))), [4, 2])
    }

    func testAnUpdatedViewUnderALaterOverlappingSiblingIsAFullSnapshot() {
        let status = ReplayWindowStatus()
        let cover = wireframe(10_000_020, x: 0, y: 90, width: 390, height: 60)
        _ = status.events(for: capture(sampleScreen(extra: [cover])))
        // The label (below the cover, which overlaps it) changes.
        XCTAssertEqual(eventTypes(status.events(for: capture(sampleScreen(label: "Changed", extra: [cover])))), [4, 2])
    }

    // MARK: - No-capture covers

    func testACoverDropsWhatLiesInsideAndEmptiesWhatItTouches() throws {
        var image = wireframe(10_000_004, x: 300, y: 130, width: 60, height: 60, type: "image")
        image.base64 = "data:image/jpeg;base64,AAAA"
        var field = wireframe(10_000_005, x: 0, y: 135, width: 200, height: 30, type: "input")
        field.value = .string("****")
        field.label = "Card number"
        let sticking = wireframe(10_000_006, x: -20, y: 95, width: 500, height: 20, type: "text", text: "IBAN 9876")
        let screen = sampleScreen(extra: [image, field, sticking])
        let cover = wireframe(10_000_030, x: 0, y: 90, width: 390, height: 50, type: "placeholder")

        let masked = screen.masked(under: [cover])
        let byId = Dictionary(uniqueKeysWithValues: masked.flattened().map { ($0.id, $0) })
        XCTAssertNil(byId[10_000_001], "the label lies inside the cover")
        XCTAssertNotNil(byId[10_000_000], "the window only intersects it: its box stays")
        XCTAssertNotNil(byId[10_000_002], "the button does not touch it")
        XCTAssertNil(byId[10_000_004]?.base64)
        XCTAssertNil(byId[10_000_005]?.value)
        XCTAssertNil(byId[10_000_005]?.label)
        XCTAssertEqual(byId[10_000_006]?.width, 500, "the box of a partly covered text stays")
        XCTAssertNil(byId[10_000_006]?.text)
        let json = String(bytes: try JSONEncoder().encode(ReplayEvents.fullSnapshot(masked, timestamp: 1)), encoding: .utf8) ?? ""
        for secret in ["IBAN 9876", "Card number", "AAAA", "Hello"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
        XCTAssertEqual(screen.masked(under: []), screen)
    }

    func testWireframeIdsAndParentsAreSetFromTheTree() {
        let flat = sampleScreen().flattened()
        XCTAssertEqual(flat.map(\.parentId), [5, 10_000_000, 10_000_000])
        XCTAssertTrue(flat.allSatisfy { $0.id >= 10_000_000 })
    }
}
