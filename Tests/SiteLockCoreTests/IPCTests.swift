import XCTest
@testable import SiteLockCore

final class IPCTests: XCTestCase {
    func testChangePasswordRequestRoundTrip() throws {
        let request = Request(.changePassword, password: "old secret", newPassword: "new secret")
        let wire = try Wire.encode(request)
        XCTAssertEqual(wire.last, 0x0A, "one JSON object per line")
        let decoded = try Wire.decode(Request.self, from: wire.dropLast())
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.command, .changePassword)
        XCTAssertEqual(decoded.newPassword, "new secret")
    }

    func testOlderRequestsWithoutNewPasswordStillDecode() throws {
        let json = Data(#"{"command":"add","password":"p","domain":"x.com"}"#.utf8)
        let decoded = try Wire.decode(Request.self, from: json)
        XCTAssertEqual(decoded, Request(.add, password: "p", domain: "x.com"))
        XCTAssertNil(decoded.newPassword)
    }
}

final class VersionTests: XCTestCase {
    /// The app bundle's version and the daemon's version must not drift apart.
    func testInfoPlistVersionMatchesCode() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, SiteLockVersion.current)
    }

    func testVersionComparison() {
        XCTAssertTrue(SiteLockVersion.isNewer("1.2.0", than: "1.1.0"))
        XCTAssertTrue(SiteLockVersion.isNewer("v1.10.0", than: "1.9.9"), "numeric, not text, and a leading v is ignored")
        XCTAssertTrue(SiteLockVersion.isNewer("2.0", than: "1.99.99"))
        XCTAssertTrue(SiteLockVersion.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(SiteLockVersion.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(SiteLockVersion.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(SiteLockVersion.isNewer("1.1.9", than: "1.2.0"))
    }
}
