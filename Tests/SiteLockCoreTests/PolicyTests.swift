import XCTest
@testable import SiteLockCore

final class DomainTests: XCTestCase {
    func testNormalizesUserInput() throws {
        XCTAssertEqual(try Domain.normalize("instagram.com"), "instagram.com")
        XCTAssertEqual(try Domain.normalize("  https://www.Instagram.com/explore?x=1 "), "instagram.com")
        XCTAssertEqual(try Domain.normalize("http://user@m.facebook.com:8080/"), "m.facebook.com")
        XCTAssertEqual(try Domain.normalize("*.reddit.com"), "reddit.com")
        XCTAssertEqual(try Domain.normalize("news.ycombinator.com."), "news.ycombinator.com")
        XCTAssertEqual(try Domain.normalize("x.com"), "x.com")
        XCTAssertEqual(try Domain.normalize("*://*.x.com/*"), "x.com", "a pasted match pattern")
    }

    func testRejectsInvalidInput() {
        for bad in ["", "   ", "localhost", "insta gram.com", "-bad.com", "bad-.com", "a..com",
                    "192.168.0.1", "ïnstagram.com", "exa_mple.com"] {
            XCTAssertThrowsError(try Domain.normalize(bad), "should reject \(bad)")
        }
    }

    func testBlockPatternCoversSubdomainsAndAllSchemes() {
        XCTAssertEqual(Domain.blockPattern(for: "instagram.com"), "*://*.instagram.com/*")
    }
}

final class FirefoxPolicyTests: XCTestCase {
    func testValuesForBlockedDomains() throws {
        let policy = FirefoxPolicy(blockedDomains: ["youtube.com", "instagram.com"])
        let v = policy.values
        XCTAssertEqual(v["EnterprisePoliciesEnabled"] as? Bool, true)
        XCTAssertEqual(v["BlockAboutConfig"] as? Bool, true)
        let filter = try XCTUnwrap(v["WebsiteFilter"] as? [String: [String]])
        XCTAssertEqual(filter["Block"], ["*://*.instagram.com/*", "*://*.youtube.com/*"])
        XCTAssertEqual(filter["Exceptions"], [])
        XCTAssertEqual(Set(v.keys), Set(FirefoxPolicy.managedKeys))
    }

    func testEmptyListStillEnablesPoliciesAndLocksAboutConfig() throws {
        let v = FirefoxPolicy(blockedDomains: []).values
        XCTAssertEqual(v["EnterprisePoliciesEnabled"] as? Bool, true)
        XCTAssertEqual((v["WebsiteFilter"] as? [String: [String]])?["Block"], [])
    }

    func testTemporarilyUnblockedDomainIsLeftOutOfPolicy() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var s = BlockState(domains: ["instagram.com", "linkedin.com"])
        try s.unblock("linkedin.com", minutes: 10, now: t0)
        XCTAssertEqual(FirefoxPolicy(blockedDomains: s.effectiveBlocked(now: t0)).blockPatterns,
                       ["*://*.instagram.com/*"])
        XCTAssertEqual(FirefoxPolicy(blockedDomains: s.effectiveBlocked(now: t0 + 600)).blockPatterns,
                       ["*://*.instagram.com/*", "*://*.linkedin.com/*"])
    }

    /// The policy must survive a round trip through the binary/XML plist format macOS stores.
    func testPlistRoundTripIsSatisfied() throws {
        let policy = FirefoxPolicy(blockedDomains: ["instagram.com"])
        var onDisk = policy.values
        onDisk["SomeOtherAdminPolicy"] = "kept"
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: onDisk, format: format, options: 0)
            let read = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            XCTAssertTrue(policy.isSatisfied(by: read), "format \(format.rawValue)")
        }
    }

    func testTamperingIsDetected() throws {
        let policy = FirefoxPolicy(blockedDomains: ["instagram.com"])
        XCTAssertFalse(policy.isSatisfied(by: nil), "deleted file")
        XCTAssertFalse(policy.isSatisfied(by: [:]), "emptied file")

        var edited = policy.values
        edited["WebsiteFilter"] = ["Block": [String](), "Exceptions": [String]()]
        XCTAssertFalse(policy.isSatisfied(by: edited), "pattern removed")

        edited = policy.values
        edited["WebsiteFilter"] = ["Block": ["*://*.instagram.com/*"], "Exceptions": ["<all_urls>"]]
        XCTAssertFalse(policy.isSatisfied(by: edited), "exception added")

        edited = policy.values
        edited["EnterprisePoliciesEnabled"] = false
        XCTAssertFalse(policy.isSatisfied(by: edited), "policies disabled")

        edited = policy.values
        edited["BlockAboutConfig"] = nil
        XCTAssertFalse(policy.isSatisfied(by: edited), "about:config unlocked")
    }

    func testPolicyMatchesMozillaPlistExampleShape() throws {
        // Shape from mozilla/policy-templates mac/org.mozilla.firefox.plist:
        // WebsiteFilter is a dict with "Block" and "Exceptions" string arrays; BlockAboutConfig is a bool.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>EnterprisePoliciesEnabled</key><true/>
          <key>BlockAboutConfig</key><true/>
          <key>WebsiteFilter</key><dict>
            <key>Block</key><array><string>*://*.instagram.com/*</string></array>
            <key>Exceptions</key><array/>
          </dict>
        </dict></plist>
        """
        let read = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
        XCTAssertTrue(FirefoxPolicy(blockedDomains: ["instagram.com"]).isSatisfied(by: read))
    }
}
