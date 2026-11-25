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

    func testRenameReplacesEntryAndKeepsListSorted() throws {
        var s = BlockState(domains: ["a.com", "m.com", "z.com"])
        try s.rename("z.com", to: "b.com")
        XCTAssertEqual(s.domains, ["a.com", "b.com", "m.com"])
        XCTAssertNoThrow(try s.rename("a.com", to: "a.com"), "unchanged name is a no-op")
        XCTAssertEqual(s.domains, ["a.com", "b.com", "m.com"])
    }

    func testRenameRejectsMissingOldAndDuplicateNew() {
        var s = BlockState(domains: ["a.com", "b.com"])
        XCTAssertThrowsError(try s.rename("x.com", to: "y.com")) { XCTAssertEqual($0 as? BlockStateError, .notInList("x.com")) }
        XCTAssertThrowsError(try s.rename("a.com", to: "b.com")) { XCTAssertEqual($0 as? BlockStateError, .alreadyBlocked("b.com")) }
        XCTAssertEqual(s.domains, ["a.com", "b.com"], "a failed edit changes nothing")
    }

    func testRenamedEntryStartsBlocked() throws {
        var s = BlockState(domains: ["youtube.com"])
        try s.unblock("youtube.com", minutes: 30, now: t0)
        try s.rename("youtube.com", to: "www.youtube.com")
        XCTAssertTrue(s.unblocks.isEmpty)
        XCTAssertEqual(s.effectiveBlocked(now: t0), ["www.youtube.com"])
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
        th.record(uid: 1, success: false, now: t0)
        th.record(uid: 1, success: false, now: t0)
        XCTAssertNil(th.lockedFor(uid: 1, now: t0))
        th.record(uid: 1, success: false, now: t0)
        XCTAssertEqual(th.lockedFor(uid: 1, now: t0 + 10), 50)
        XCTAssertNil(th.lockedFor(uid: 1, now: t0 + 60))
    }

    func testLockoutGrowsIsCappedAndResetsPerUid() {
        var th = AuthThrottle()
        var now = t0
        for expected in [60.0, 120, 240, 480, 960, 1920, 3600, 3600] {
            for _ in 0..<5 { th.record(uid: 7, success: false, now: now) }
            XCTAssertEqual(th.lockedFor(uid: 7, now: now), expected)
            XCTAssertNil(th.lockedFor(uid: 8, now: now))
            now += expected
            XCTAssertNil(th.lockedFor(uid: 7, now: now))
        }
        th.record(uid: 7, success: true, now: now)
        for _ in 0..<5 { th.record(uid: 7, success: false, now: now) }
        XCTAssertEqual(th.lockedFor(uid: 7, now: now), 60)
    }

    func testMessageUsesMinutesFromTwoMinutes() {
        XCTAssertEqual(AuthThrottle.message(waiting: 59.2), "Too many wrong passwords. Try again in 60 s")
        XCTAssertEqual(AuthThrottle.message(waiting: 120), "Too many wrong passwords. Try again in 2 min")
        XCTAssertEqual(AuthThrottle.message(waiting: 3600), "Too many wrong passwords. Try again in 60 min")
    }

    func testSuccessResetsFailureCount() {
        var th = AuthThrottle(maxFailures: 2, lockout: 60)
        th.record(uid: 1, success: false, now: t0)
        th.record(uid: 1, success: true, now: t0)
        th.record(uid: 1, success: false, now: t0)
        XCTAssertNil(th.lockedFor(uid: 1, now: t0))
    }
}

final class EditRequestTests: XCTestCase {
    func testEditRequestCarriesNewDomain() throws {
        var request = Request(.edit, password: "p", domain: "youtube.com")
        request.newDomain = "www.youtube.com"
        let decoded = try Wire.decode(Request.self, from: Wire.encode(request).dropLast())
        XCTAssertEqual(decoded.command, .edit)
        XCTAssertEqual(decoded.newDomain, "www.youtube.com")
        XCTAssertNil(try Wire.decode(Request.self, from: Data(#"{"command":"list"}"#.utf8)).newDomain)
    }
}
