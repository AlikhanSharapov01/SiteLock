import XCTest
@testable import SiteLockCore

final class BlockStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAddRemoveKeepsSortedUniqueList() throws {
        var s = BlockState()
        try s.add("youtube.com")
        try s.add("instagram.com")
        XCTAssertEqual(s.domains, ["instagram.com", "youtube.com"])
        XCTAssertThrowsError(try s.add("instagram.com")) { XCTAssertEqual($0 as? BlockStateError, .alreadyBlocked("instagram.com")) }
        try s.remove("instagram.com")
        XCTAssertEqual(s.domains, ["youtube.com"])
        XCTAssertThrowsError(try s.remove("instagram.com"))
    }

    func testTemporaryUnblockExpiresExactlyAfterNMinutes() throws {
        var s = BlockState(domains: ["linkedin.com", "x.com"])
        try s.unblock("linkedin.com", minutes: 15, now: t0)

        XCTAssertEqual(s.effectiveBlocked(now: t0), ["x.com"])
        XCTAssertEqual(s.effectiveBlocked(now: t0 + 15 * 60 - 1), ["x.com"])
        // At the expiry instant the domain is blocked again.
        XCTAssertEqual(s.effectiveBlocked(now: t0 + 15 * 60), ["linkedin.com", "x.com"])
        XCTAssertEqual(s.nextExpiry(now: t0), t0 + 15 * 60)
        XCTAssertNil(s.nextExpiry(now: t0 + 15 * 60))
    }

    func testPruneDropsOnlyExpiredUnblocks() throws {
        var s = BlockState(domains: ["a.com", "b.com"])
        try s.unblock("a.com", minutes: 5, now: t0)
        try s.unblock("b.com", minutes: 30, now: t0)

        XCTAssertFalse(s.pruneExpired(now: t0 + 60))
        XCTAssertTrue(s.pruneExpired(now: t0 + 5 * 60))
        XCTAssertEqual(Array(s.unblocks.keys), ["b.com"])
        XCTAssertEqual(s.nextExpiry(now: t0 + 5 * 60), t0 + 30 * 60)
        XCTAssertTrue(s.pruneExpired(now: t0 + 31 * 60))
        XCTAssertTrue(s.unblocks.isEmpty)
    }

    func testExpiryIsWallClockSoSleepOrRestartPastItReblocks() throws {
        // The daemon may be asleep or restarted past the expiry; state loaded later must block.
        var s = BlockState(domains: ["linkedin.com"])
        try s.unblock("linkedin.com", minutes: 10, now: t0)
        let reloaded = try Wire.decode(BlockState.self, from: Wire.encode(s))
        XCTAssertEqual(reloaded.effectiveBlocked(now: t0 + 3 * 3600), ["linkedin.com"])
    }

    func testUnblockAgainReplacesExpiry() throws {
        var s = BlockState(domains: ["a.com"])
        try s.unblock("a.com", minutes: 60, now: t0)
        try s.unblock("a.com", minutes: 5, now: t0)
        XCTAssertEqual(s.unblocks["a.com"], t0 + 5 * 60)
    }

    func testUnblockValidation() {
        var s = BlockState(domains: ["a.com"])
        XCTAssertThrowsError(try s.unblock("b.com", minutes: 5, now: t0)) { XCTAssertEqual($0 as? BlockStateError, .notInList("b.com")) }
        XCTAssertThrowsError(try s.unblock("a.com", minutes: 0, now: t0)) { XCTAssertEqual($0 as? BlockStateError, .invalidDuration(0)) }
        XCTAssertThrowsError(try s.unblock("a.com", minutes: BlockState.maxUnblockMinutes + 1, now: t0))
        XCTAssertNoThrow(try s.unblock("a.com", minutes: BlockState.maxUnblockMinutes, now: t0))
    }

    func testReblockEndsUnblockEarly() throws {
        var s = BlockState(domains: ["a.com"])
        try s.unblock("a.com", minutes: 30, now: t0)
        try s.reblock("a.com")
        XCTAssertEqual(s.effectiveBlocked(now: t0), ["a.com"])
        XCTAssertThrowsError(try s.reblock("a.com")) { XCTAssertEqual($0 as? BlockStateError, .notUnblocked("a.com")) }
    }

    func testRemovingDomainClearsItsUnblock() throws {
        var s = BlockState(domains: ["a.com"])
        try s.unblock("a.com", minutes: 30, now: t0)
        try s.remove("a.com")
        XCTAssertTrue(s.unblocks.isEmpty)
    }

    func testDomainLimitMatchesFirefox() throws {
        var s = BlockState(domains: (0..<BlockState.maxDomains).map { "d\($0).com" })
        XCTAssertThrowsError(try s.add("one-too-many.com")) { XCTAssertEqual($0 as? BlockStateError, .tooManyDomains(1000)) }
    }
}

final class AuthThrottleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testLocksAfterRepeatedFailuresAndUnlocksAfterTimeout() {
        var th = AuthThrottle(maxFailures: 3, lockout: 60)
        th.record(success: false, now: t0)
        th.record(success: false, now: t0)
        XCTAssertNil(th.lockedFor(now: t0))
        th.record(success: false, now: t0)
        XCTAssertEqual(th.lockedFor(now: t0 + 10), 50)
        XCTAssertNil(th.lockedFor(now: t0 + 60))
    }

    func testSuccessResetsFailureCount() {
        var th = AuthThrottle(maxFailures: 2, lockout: 60)
        th.record(success: false, now: t0)
        th.record(success: true, now: t0)
        th.record(success: false, now: t0)
        XCTAssertNil(th.lockedFor(now: t0))
    }
}
