import XCTest
@testable import SiteLockCore

final class HostsPolicyTests: XCTestCase {
    private let macHosts = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

    private let begin = HostsPolicy.beginMarker
    private let end = HostsPolicy.endMarker

    func testBlockContents() {
        let policy = HostsPolicy(blockedDomains: ["m.reddit.com", "instagram.com", "instagram.com", "www.a.com"])
        XCTAssertEqual(policy.hosts,
                       ["instagram.com", "m.instagram.com", "m.reddit.com", "www.a.com", "www.instagram.com"])
        XCTAssertEqual(policy.blockLines, [
            begin,
            "0.0.0.0 instagram.com", ":: instagram.com",
            "0.0.0.0 m.instagram.com", ":: m.instagram.com",
            "0.0.0.0 m.reddit.com", ":: m.reddit.com",
            "0.0.0.0 www.a.com", ":: www.a.com",
            "0.0.0.0 www.instagram.com", ":: www.instagram.com",
            end,
        ])
    }

    func testInsertIntoTypicalHostsFile() {
        let result = HostsPolicy(blockedDomains: ["instagram.com"]).apply(to: macHosts)
        XCTAssertEqual(result, macHosts + """
        \(begin)
        0.0.0.0 instagram.com
        :: instagram.com
        0.0.0.0 m.instagram.com
        :: m.instagram.com
        0.0.0.0 www.instagram.com
        :: www.instagram.com
        \(end)

        """)
    }

    func testAppendAddsMissingTrailingNewline() {
        let result = HostsPolicy(blockedDomains: ["a.com"]).apply(to: "127.0.0.1 localhost")
        XCTAssertTrue(result.hasPrefix("127.0.0.1 localhost\n\(begin)\n"))
        XCTAssertTrue(result.hasSuffix("\(end)\n"))
    }

    func testReplaceExistingBlockInPlace() {
        let old = HostsPolicy(blockedDomains: ["old.com"]).apply(to: macHosts) + "10.0.0.1 after\n"
        let result = HostsPolicy(blockedDomains: ["new.com"]).apply(to: old)
        XCTAssertFalse(result.contains("old.com"))
        XCTAssertTrue(result.contains("0.0.0.0 new.com\n"))
        XCTAssertTrue(result.hasSuffix("\(end)\n10.0.0.1 after\n"))
        XCTAssertEqual(HostsPolicy.strip(result), macHosts + "10.0.0.1 after\n")
    }

    func testStripRemovesOnlyTheBlock() {
        let withBlock = HostsPolicy(blockedDomains: ["a.com"]).apply(to: macHosts)
        XCTAssertEqual(HostsPolicy.strip(withBlock), macHosts)
        XCTAssertEqual(HostsPolicy.strip(macHosts), macHosts)
        XCTAssertTrue(HostsPolicy.hasBlock(withBlock))
        XCTAssertFalse(HostsPolicy.hasBlock(macHosts))
    }

    func testIdempotent() {
        let policy = HostsPolicy(blockedDomains: ["a.com", "b.org"])
        let once = policy.apply(to: macHosts)
        XCTAssertEqual(policy.apply(to: once), once)
        XCTAssertTrue(policy.isSatisfied(by: once))
        XCTAssertFalse(policy.isSatisfied(by: macHosts))
    }

    func testForeignLinesUntouched() {
        let odd = "# mine\n10.0.0.5\tnas.local   # tab\r\n\n\n  ::1 x\n"
        let result = HostsPolicy(blockedDomains: ["a.com"]).apply(to: odd)
        XCTAssertTrue(result.hasPrefix(odd))
        XCTAssertEqual(HostsPolicy.strip(result), odd)
    }

    func testEmptyListRemovesBlock() {
        let withBlock = HostsPolicy(blockedDomains: ["a.com"]).apply(to: macHosts)
        let empty = HostsPolicy(blockedDomains: [])
        XCTAssertEqual(empty.apply(to: withBlock), macHosts)
        XCTAssertEqual(empty.apply(to: macHosts), macHosts)
        XCTAssertTrue(empty.isSatisfied(by: macHosts))
        XCTAssertFalse(empty.isSatisfied(by: withBlock))
    }

    func testHandEditedBlockIsDetectedAndRepaired() {
        let policy = HostsPolicy(blockedDomains: ["a.com"])
        let good = policy.apply(to: macHosts)
        let edited = good.replacingOccurrences(of: "0.0.0.0 a.com\n", with: "")
        XCTAssertFalse(policy.isSatisfied(by: edited))
        XCTAssertEqual(policy.apply(to: edited), good)

        let added = good.replacingOccurrences(of: end, with: "127.0.0.1 a.com\n\(end)")
        XCTAssertFalse(policy.isSatisfied(by: added))
        XCTAssertEqual(policy.apply(to: added), good)

        let noEnd = good.replacingOccurrences(of: "\(end)\n", with: "")
        XCTAssertFalse(policy.isSatisfied(by: noEnd))
    }

    func testStrayBeginKeepsForeignLines() {
        let text = "a\n\(begin)\nforeign\n" + HostsPolicy(blockedDomains: ["x.com"]).blockLines.joined(separator: "\n") + "\nz\n"
        let stripped = HostsPolicy.strip(text)
        XCTAssertEqual(stripped, "a\n\(begin)\nforeign\nz\n")
        let applied = HostsPolicy(blockedDomains: ["x.com"]).apply(to: text)
        XCTAssertTrue(applied.contains("\nforeign\n"))
        XCTAssertTrue(applied.hasPrefix("a\n\(begin)\nforeign\n\(begin)\n0.0.0.0 m.x.com"))
    }

    func testEndWithoutBeginIsKept() {
        let text = "a\n\(end)\nb\n"
        XCTAssertEqual(HostsPolicy.strip(text), text)
        XCTAssertFalse(HostsPolicy.hasBlock(text))
    }

    func testTrailingNewlineAndCRLFPreserved() {
        let policy = HostsPolicy(blockedDomains: ["a.com"])
        let crlf = "127.0.0.1 localhost\r\n10.0.0.1 x\r\n"
        XCTAssertEqual(HostsPolicy.strip(policy.apply(to: crlf)), crlf)
        let noNewline = "127.0.0.1 localhost\n\(begin)\n0.0.0.0 a.com\n\(end)"
        XCTAssertEqual(HostsPolicy.strip(noNewline), "127.0.0.1 localhost")
        XCTAssertEqual(HostsPolicy.strip("x"), "x")
        XCTAssertEqual(HostsPolicy(blockedDomains: []).apply(to: "x"), "x")
    }

    func testInvalidHostsAreDropped() {
        let policy = HostsPolicy(blockedDomains: ["a.com\n127.0.0.1 evil", "bad host.com", "ok.com"])
        XCTAssertEqual(policy.hosts, ["m.ok.com", "ok.com", "www.ok.com"])
    }
}
