import XCTest
@testable import MpTracker

final class StartupEventStoreTests: XCTestCase {
    func testBindsOnlySelectedAnonymousDefaultsAndPreservesTheirFacts() {
        let suite = "mp.startup.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EventStore(defaults: defaults)
        store.add(["event_id":"old", "event_time":1, "common_fields":[:]])
        store.add(["event_id":"current", "event_time":2, "common_fields":["custom":"kept"]])
        store.add(["event_id":"bound", "event_time":3, "common_fields":["user_id":"first"]])
        store.bindStartup(["current","bound"], userId: "guest")
        let events = store.peek(10)
        XCTAssertNil((events[0]["common_fields"] as? [String:Any])?["user_id"])
        XCTAssertEqual((events[1]["common_fields"] as? [String:Any])?["user_id"] as? String, "guest")
        XCTAssertEqual((events[1]["common_fields"] as? [String:Any])?["custom"] as? String, "kept")
        XCTAssertEqual(events[1]["event_time"] as? Int, 2)
        XCTAssertEqual(events[1]["event_id"] as? String, "current")
        XCTAssertEqual((events[2]["common_fields"] as? [String:Any])?["user_id"] as? String, "first")
        store.bindStartup(["current"], userId: "other")
        XCTAssertEqual((store.peek(10)[1]["common_fields"] as? [String:Any])?["user_id"] as? String, "guest")
    }
}
