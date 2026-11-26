import XCTest
@testable import SiteLockCore

final class BrowserTests: XCTestCase {
    func testCatalogIDsAreUnique() {
        let ids = Browser.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "org.mozilla.firefox")
        XCTAssertEqual(Browser.byID("com.google.Chrome")?.processName, "Google Chrome")
        XCTAssertNil(Browser.byID("nope"))
        XCTAssertTrue(Browser.byID("com.google.Chrome")!.isSupported)
        XCTAssertTrue(Browser.byID("com.apple.Safari")!.isSupported)
        XCTAssertFalse(Browser.byID("com.operasoftware.Opera")!.isSupported)
        XCTAssertFalse(Browser.byID("company.thebrowser.Browser")!.isSupported)
    }

    func testOldStateWithoutBrowsersDefaultsToFirefox() throws {
        let json = Data(#"{"domains":["b.com","a.com"],"unblocks":{}}"#.utf8)
        let state = try Wire.decode(BlockState.self, from: json)
        XCTAssertEqual(state.browsers, ["org.mozilla.firefox"])
        XCTAssertEqual(state.domains, ["b.com", "a.com"])
    }

    func testStateRoundTripKeepsBrowsers() throws {
        var state = BlockState(domains: ["a.com"])
        try state.setBrowser("com.google.Chrome", enabled: true)
        let decoded = try Wire.decode(BlockState.self, from: Wire.encode(state).dropLast())
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.browsers, ["com.google.Chrome", "org.mozilla.firefox"])
    }

    func testSetBrowser() throws {
        var state = BlockState()
        XCTAssertEqual(state.browsers, ["org.mozilla.firefox"])
        try state.setBrowser("com.google.Chrome", enabled: true)
        XCTAssertEqual(state.browsers, ["com.google.Chrome", "org.mozilla.firefox"])
        try state.setBrowser("com.google.Chrome", enabled: true)
        XCTAssertEqual(state.browsers.count, 2, "enabling twice is a no-op")
        try state.setBrowser("org.mozilla.firefox", enabled: false)
        XCTAssertEqual(state.browsers, ["com.google.Chrome"])
        try state.setBrowser("org.mozilla.firefox", enabled: false)
        XCTAssertEqual(state.browsers, ["com.google.Chrome"], "disabling twice is a no-op")
    }

    func testSetBrowserRejectsUnsupportedAndUnknown() {
        var state = BlockState()
        XCTAssertThrowsError(try state.setBrowser("com.operasoftware.Opera", enabled: true)) {
            XCTAssertEqual($0 as? BlockStateError, .unsupportedBrowser("com.operasoftware.Opera"))
        }
        XCTAssertThrowsError(try state.setBrowser("com.example.Nope", enabled: true))
        XCTAssertEqual(state.browsers, ["org.mozilla.firefox"])
    }

    func testChromiumPolicyValues() {
        let policy = ChromiumPolicy(blockedDomains: ["youtube.com", "www.a.com"])
        XCTAssertEqual(policy.values["URLBlocklist"] as? [String], ["www.a.com", "youtube.com"])
        XCTAssertEqual(ChromiumPolicy.managedKeys, ["URLBlocklist"])
        XCTAssertEqual(ChromiumPolicy.plistPath(for: "com.google.Chrome"),
                       "/Library/Managed Preferences/com.google.Chrome.plist")
    }

    func testChromiumPolicyDetectsTampering() {
        let policy = ChromiumPolicy(blockedDomains: ["a.com", "b.com"])
        XCTAssertTrue(policy.isSatisfied(by: policy.values))
        XCTAssertTrue(policy.isSatisfied(by: policy.values.merging(["Other": 1]) { a, _ in a }))
        XCTAssertFalse(policy.isSatisfied(by: nil), "missing file")
        XCTAssertFalse(policy.isSatisfied(by: ["URLBlocklist": ["a.com"]]), "edited list")
        XCTAssertFalse(policy.isSatisfied(by: ["Other": 1]), "missing key")
        XCTAssertFalse(policy.isSatisfied(by: [:]))
    }

    func testBrowserFieldsRoundTrip() throws {
        var request = Request(.setBrowser, password: "p")
        request.browser = "com.google.Chrome"
        request.enabled = true
        let decoded = try Wire.decode(Request.self, from: Wire.encode(request).dropLast())
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.browser, "com.google.Chrome")
        XCTAssertEqual(decoded.enabled, true)
    }

    func testQuitBrowsersRoundTrip() throws {
        let response = Response(ok: true, state: BlockState(), quitBrowsers: ["org.mozilla.firefox"])
        let decoded = try Wire.decode(Response.self, from: Wire.encode(response).dropLast())
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.quitBrowsers, ["org.mozilla.firefox"])
    }
}
