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
}
