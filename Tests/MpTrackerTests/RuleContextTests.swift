import XCTest
@testable import MpTracker
final class RuleContextTests: XCTestCase {
    func testAliasesUpdatesAndSnapshots() {
        let context = RuleContext()
        let common = context.replaceCommon(["country_code":"SG", "device_language":"en-US", "channel":"store", "adgroup":"a", "creative":"c", "campaign":"keep"])
        XCTAssertEqual(common["campaign"] as? String, "keep")
        let old = context.snapshot(deviceLanguage:"zh-CN")
        XCTAssertEqual(old["country"], "SG"); XCTAssertEqual(old["adGroup"], "a")
        context.patch(["country":"US", "adGroup":NSNull()])
        XCTAssertEqual(context.snapshot(deviceLanguage:nil)["country"], "US")
        XCTAssertNil(context.snapshot(deviceLanguage:nil)["adGroup"])
        XCTAssertEqual(old["country"], "SG")
        _ = context.replaceCommon([:])
        XCTAssertEqual(context.snapshot(deviceLanguage:"zh-CN"), ["language":"zh-CN", "channel":"organic"])
    }
    func testLateSourceDoesNotRewriteOldSnapshot() {
        let context=RuleContext();let old=context.snapshot(deviceLanguage:nil)
        context.patch(["channel":" meta_ads "]);XCTAssertEqual(context.snapshot(deviceLanguage:nil)["channel"],"meta_ads");XCTAssertEqual(old["channel"],"organic")
        context.patch(["channel":"google_ads"]);XCTAssertEqual(context.snapshot(deviceLanguage:nil)["channel"],"google_ads")
        for alias in ["web","ogannic","ORGANIC"] { context.patch(["channel":alias]);XCTAssertEqual(context.snapshot(deviceLanguage:nil)["channel"],"organic") }
        context.patch(["channel":NSNull()]);XCTAssertEqual(context.snapshot(deviceLanguage:nil)["channel"],"organic")
    }

}
