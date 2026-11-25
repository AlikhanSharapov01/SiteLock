import XCTest
@testable import SiteLockCore

final class ImportTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testMixedInput() {
        var s = BlockState(domains: ["youtube.com"])
        let report = s.importDomains([
            "# SiteLock blocklist", "", "  ",
            "https://www.Instagram.com/feed", "*.reddit.com", "x.com.",
            "youtube.com", "reddit.com", "not a domain", "localhost",
        ])
        XCTAssertEqual(s.domains, ["reddit.com", "www.instagram.com", "x.com", "youtube.com"])
        XCTAssertEqual(report.added, 3)
        XCTAssertEqual(report.alreadyInList, 2) // youtube.com, and reddit.com twice in the import
        XCTAssertEqual(report.invalid, 2)
        XCTAssertEqual(report.invalidEntries, ["not a domain", "localhost"])
        XCTAssertEqual(report.summary, "Added 3 · 2 already in the list · 2 invalid")
    }

    func testInvalidEntriesListedAtMostTwenty() {
        var s = BlockState()
        let report = s.importDomains((0..<30).map { "bad\($0)" })
        XCTAssertEqual(report.invalid, 30)
        XCTAssertEqual(report.invalidEntries.count, 20)
    }

    func testFullListHitsLimit() {
        var s = BlockState(domains: (0..<(BlockState.maxDomains - 1)).map { "site\($0).com" })
        let report = s.importDomains(["a.com", "b.com", "c.com"])
        XCTAssertEqual(s.domains.count, BlockState.maxDomains)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.overLimit, 2)
    }

    private func run(_ request: Request, state: BlockState = BlockState(), password: String = "secret1")
        -> (response: Response, h: ImportHarness) {
        let h = ImportHarness(state: state)
        let response = h.service.handle(request, from: Client(uid: 501, isAdmin: true), now: t0)
        return (response, h)
    }

    private func importRequest(_ domains: [String], password: String = "secret1") -> Request {
        var request = Request(.importDomains, password: password)
        request.domains = domains
        return request
    }

    func testOneSaveAndOneEnforcement() {
        let r = run(importRequest(["a.com", "b.com", "c.com"]))
        XCTAssertTrue(r.response.ok)
        XCTAssertEqual(r.h.saves, 1)
        XCTAssertEqual(r.h.enforces, [true])
        XCTAssertEqual(r.response.importReport?.added, 3)
        XCTAssertEqual(r.response.quitBrowsers, ["org.mozilla.firefox"])
        XCTAssertEqual(r.response.state?.domains, ["a.com", "b.com", "c.com"])
    }

    func testNothingNewMeansNoSaveOrEnforcement() {
        let r = run(importRequest(["a.com", "oops"]), state: BlockState(domains: ["a.com"]))
        XCTAssertTrue(r.response.ok)
        XCTAssertEqual(r.h.saves, 0)
        XCTAssertTrue(r.h.enforces.isEmpty)
        XCTAssertEqual(r.response.importReport?.invalid, 1)
    }

    func testWrongPasswordRejected() {
        let r = run(importRequest(["a.com"], password: "wrong11"))
        XCTAssertFalse(r.response.ok)
        XCTAssertEqual(r.response.error, "Wrong password")
        XCTAssertEqual(r.h.saves, 0)
        XCTAssertTrue(r.h.enforces.isEmpty)
        XCTAssertNil(r.response.state)
    }

    func testDuplicateOfOverLimitEntryCountsAsOverLimit() {
        var s = BlockState(domains: (0..<BlockState.maxDomains).map { "site\($0).com" })
        let report = s.importDomains(["new.com", "new.com", "site1.com"])
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.overLimit, 2)
        XCTAssertEqual(report.alreadyInList, 1)
    }

    func testFailingSaveLeavesStateUnchanged() {
        let h = ImportHarness(state: BlockState(domains: ["a.com"]))
        h.failSaves = true
        let response = h.service.handle(importRequest(["b.com"]), from: Client(uid: 501, isAdmin: true), now: t0)
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(h.service.state.domains, ["a.com"])
        XCTAssertTrue(h.enforces.isEmpty)
    }

    func testOldJSONWithoutNewKeysStillDecodes() throws {
        let request = try Wire.decode(Request.self, from: Data(#"{"command":"add","domain":"a.com","password":"x"}"#.utf8))
        XCTAssertNil(request.domains)
        let response = try Wire.decode(Response.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(response.importReport)
    }

    func testRequestRoundTrip() throws {
        var request = Request(.importDomains, password: "pw")
        request.domains = ["a.com"]
        XCTAssertEqual(try Wire.decode(Request.self, from: Wire.encode(request)), request)
    }
}

private struct ImportHasher: PasswordHashing {
    func makeRecord(password: String) throws -> PasswordRecord {
        PasswordRecord(algorithm: "fake", iterations: 1, salt: Data(), hash: Data(password.utf8))
    }

    func verify(password: String, against record: PasswordRecord) throws -> Bool {
        record.hash == Data(password.utf8)
    }
}

private struct ImportDiskFull: Error {}

private final class ImportHarness {
    var saves = 0
    var failSaves = false
    var enforces: [Bool] = []
    private(set) var service: SiteLockService!

    init(state: BlockState) {
        let record = try? ImportHasher().makeRecord(password: "secret1")
        service = SiteLockService(
            state: state, password: record, hasher: ImportHasher(),
            saveState: { [unowned self] _ in
                if failSaves { throw ImportDiskFull() }
                saves += 1
            },
            savePassword: { _ in },
            enforce: { [unowned self] changed, _ in enforces.append(changed); return ["org.mozilla.firefox"] },
            uninstall: {})
    }
}
