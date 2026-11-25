import XCTest
@testable import SiteLockCore

private struct FakeHasher: PasswordHashing {
    func makeRecord(password: String) throws -> PasswordRecord {
        guard password.count >= 6 else { throw PasswordError.tooShort(6) }
        return PasswordRecord(algorithm: "fake", iterations: 1, salt: Data(), hash: Data(password.utf8))
    }

    func verify(password: String, against record: PasswordRecord) throws -> Bool {
        record.hash == Data(password.utf8)
    }
}

private struct DiskFull: Error {}

private final class Harness {
    var savedStates: [BlockState] = []
    var savedPasswords: [PasswordRecord] = []
    var enforceCalls: [(changed: Bool, only: String?)] = []
    var quitResult: [String] = []
    var failSaves = false
    var uninstalls = 0
    private(set) var service: SiteLockService!

    init(state: BlockState = BlockState(), password: String? = "secret1", passwordUnreadable: Bool = false) {
        var record: PasswordRecord?
        if let password { record = try? FakeHasher().makeRecord(password: password) }
        service = SiteLockService(
            state: state, password: record, passwordUnreadable: passwordUnreadable,
            hasher: FakeHasher(),
            saveState: { [unowned self] s in
                if failSaves { throw DiskFull() }
                savedStates.append(s)
            },
            savePassword: { [unowned self] r in
                if failSaves { throw DiskFull() }
                savedPasswords.append(r)
            },
            enforce: { [unowned self] changed, only in
                enforceCalls.append((changed, only))
                return quitResult
            },
            uninstall: { [unowned self] in uninstalls += 1 })
    }
}

final class ServiceTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let pw = "secret1"
    let chrome = "com.google.Chrome"

    private func send(_ h: Harness, _ command: Request.Command, domain: String? = nil, minutes: Int? = nil,
                      password: String? = "secret1", now: Date? = nil) -> Response {
        h.service.handle(Request(command, password: password, domain: domain, minutes: minutes), now: now ?? t0)
    }

    private func setBrowser(_ h: Harness, _ id: String, enabled: Bool) -> Response {
        var request = Request(.setBrowser, password: pw)
        request.browser = id
        request.enabled = enabled
        return h.service.handle(request, now: t0)
    }

    func testHelloBeforeAndAfterSetup() {
        let h = Harness(password: nil)
        let before = send(h, .hello, password: nil)
        XCTAssertTrue(before.ok)
        XCTAssertEqual(before.initialized, false)
        XCTAssertEqual(before.version, SiteLockVersion.current)
        XCTAssertTrue(send(h, .setup, password: "secret1").ok)
        XCTAssertEqual(send(h, .hello, password: nil).initialized, true)
    }

    func testUnreadablePasswordCountsAsInitializedAndBlocksSetup() {
        let h = Harness(password: nil, passwordUnreadable: true)
        XCTAssertEqual(send(h, .hello, password: nil).initialized, true)
        XCTAssertFalse(send(h, .setup, password: "secret1").ok)
        XCTAssertFalse(send(h, .list).ok)
    }

    func testSetupOnlyOnceAndMinimumLength() {
        let h = Harness(password: nil)
        let short = send(h, .setup, password: "abc")
        XCTAssertFalse(short.ok)
        XCTAssertEqual(short.error, "\(PasswordError.tooShort(6))")
        XCTAssertTrue(h.savedPasswords.isEmpty)
        let ok = send(h, .setup, password: "secret1")
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.initialized, true)
        XCTAssertEqual(h.savedPasswords.count, 1)
        XCTAssertEqual(send(h, .setup, password: "another1").error, "A password is already set")
        XCTAssertEqual(h.savedPasswords.count, 1)
    }

    func testEveryCommandNeedsThePassword() {
        let commands: [Request.Command] = [.list, .add, .remove, .unblock, .reblock, .edit, .setBrowser,
                                           .changePassword, .uninstall]
        for command in commands {
            let h = Harness(state: BlockState(domains: ["a.com"]))
            XCTAssertEqual(send(h, command, domain: "a.com", minutes: 5, password: nil).error, "Wrong password", "\(command)")
            XCTAssertEqual(send(h, command, domain: "a.com", minutes: 5, password: "nope").error, "Wrong password", "\(command)")
            XCTAssertTrue(h.savedStates.isEmpty)
            XCTAssertTrue(h.savedPasswords.isEmpty)
            XCTAssertTrue(h.enforceCalls.isEmpty)
            XCTAssertEqual(h.uninstalls, 0)
        }
        XCTAssertEqual(send(Harness(password: nil), .list).error, "No password set yet")
    }

    func testLockoutAfterFiveWrongPasswordsAndSuccessResets() {
        let h = Harness()
        for _ in 0..<4 { XCTAssertEqual(send(h, .list, password: "bad").error, "Wrong password") }
        XCTAssertTrue(send(h, .list).ok)  // success resets the failure count
        for _ in 0..<5 { XCTAssertEqual(send(h, .list, password: "bad").error, "Wrong password") }
        let locked = send(h, .list)  // even the right password is refused now
        XCTAssertTrue(locked.error?.hasPrefix("Too many wrong passwords") == true)
        XCTAssertTrue(send(h, .list, now: t0.addingTimeInterval(61)).ok)
    }

    func testAddEditRemoveChangeStatePersistAndEnforce() {
        let h = Harness()
        let added = send(h, .add, domain: "https://YouTube.com/watch")
        XCTAssertTrue(added.ok)
        XCTAssertEqual(added.state?.domains, ["youtube.com"])
        XCTAssertEqual(h.savedStates.last?.domains, ["youtube.com"])
        XCTAssertEqual(h.enforceCalls.count, 1)
        XCTAssertTrue(h.enforceCalls[0].changed)
        XCTAssertNil(h.enforceCalls[0].only)

        var editRequest = Request(.edit, password: pw, domain: "youtube.com")
        editRequest.newDomain = "x.com"
        let edit = h.service.handle(editRequest, now: t0)
        XCTAssertEqual(edit.state?.domains, ["x.com"])
        XCTAssertEqual(h.savedStates.last?.domains, ["x.com"])
        XCTAssertEqual(h.enforceCalls.count, 2)
        XCTAssertTrue(h.enforceCalls[1].changed)

        let removed = send(h, .remove, domain: "x.com")
        XCTAssertEqual(removed.state?.domains, [])
        XCTAssertEqual(h.savedStates.last?.domains, [])
        XCTAssertEqual(h.enforceCalls.count, 3)
    }

    func testListAndFailedCommandsDoNotEnforceOrSave() {
        let h = Harness(state: BlockState(domains: ["a.com"]))
        XCTAssertEqual(send(h, .list).state?.domains, ["a.com"])
        XCTAssertFalse(send(h, .add, domain: "a.com").ok)
        XCTAssertFalse(send(h, .remove, domain: "b.com").ok)
        XCTAssertFalse(send(h, .reblock, domain: "a.com").ok)
        XCTAssertTrue(h.savedStates.isEmpty)
        XCTAssertTrue(h.enforceCalls.isEmpty)
    }

    func testUnblockAndReblockEnforceOnlyWhenEffectiveListChanges() {
        let h = Harness(state: BlockState(domains: ["a.com", "b.com"]))
        let unblocked = send(h, .unblock, domain: "a.com", minutes: 10)
        XCTAssertEqual(unblocked.state?.unblocks["a.com"], t0.addingTimeInterval(600))
        XCTAssertEqual(h.savedStates.count, 1)
        XCTAssertEqual(h.enforceCalls.count, 1)
        XCTAssertTrue(h.enforceCalls[0].changed)

        // Extending an unblock saves the new expiry but the effective list stays the same.
        XCTAssertTrue(send(h, .unblock, domain: "a.com", minutes: 20).ok)
        XCTAssertEqual(h.savedStates.count, 2)
        XCTAssertEqual(h.enforceCalls.count, 1)

        let reblocked = send(h, .reblock, domain: "a.com")
        XCTAssertEqual(reblocked.state?.unblocks, [:])
        XCTAssertEqual(h.enforceCalls.count, 2)
        XCTAssertTrue(h.enforceCalls[1].changed)
    }

    func testSetBrowserEnforcesOnlyThatBrowser() {
        let h = Harness()
        let on = setBrowser(h, chrome, enabled: true)
        XCTAssertEqual(on.state?.browsers.contains(chrome), true)
        XCTAssertEqual(h.savedStates.count, 1)
        XCTAssertEqual(h.enforceCalls.count, 1)
        XCTAssertTrue(h.enforceCalls[0].changed)
        XCTAssertEqual(h.enforceCalls[0].only, chrome)

        // Already on: nothing changes.
        XCTAssertTrue(setBrowser(h, chrome, enabled: true).ok)
        XCTAssertEqual(h.savedStates.count, 1)
        XCTAssertEqual(h.enforceCalls.count, 1)

        let off = setBrowser(h, chrome, enabled: false)
        XCTAssertEqual(off.state?.browsers.contains(chrome), false)
        XCTAssertEqual(h.savedStates.count, 2)
        XCTAssertEqual(h.enforceCalls.count, 2)
        XCTAssertFalse(h.enforceCalls[1].changed)
        XCTAssertEqual(h.enforceCalls[1].only, chrome)

        XCTAssertFalse(setBrowser(h, "com.apple.Safari", enabled: true).ok)
        XCTAssertEqual(h.enforceCalls.count, 2)
    }

    func testQuitBrowsersComeFromEnforcement() {
        let h = Harness()
        h.quitResult = [Browser.firefoxID]
        XCTAssertEqual(send(h, .add, domain: "a.com").quitBrowsers, [Browser.firefoxID])
        XCTAssertEqual(send(h, .list).quitBrowsers, [])
        h.quitResult = [chrome]
        XCTAssertEqual(setBrowser(h, chrome, enabled: true).quitBrowsers, [chrome])
    }

    func testFailingSaveLeavesStateUnchanged() {
        let h = Harness(state: BlockState(domains: ["a.com"]))
        h.failSaves = true
        let response = send(h, .add, domain: "b.com")
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(h.service.state.domains, ["a.com"])
        XCTAssertFalse(setBrowser(h, chrome, enabled: true).ok)
        XCTAssertEqual(h.service.state.browsers, [Browser.firefoxID])
        XCTAssertTrue(h.enforceCalls.isEmpty)
        h.failSaves = false
        XCTAssertTrue(send(h, .add, domain: "b.com").ok)
        XCTAssertEqual(h.service.state.domains, ["a.com", "b.com"])
    }

    func testChangePasswordReplacesThePassword() {
        let h = Harness()
        let changed = h.service.handle(Request(.changePassword, password: pw, newPassword: "newsecret"), now: t0)
        XCTAssertTrue(changed.ok)
        XCTAssertEqual(h.savedPasswords.count, 1)
        XCTAssertEqual(send(h, .list).error, "Wrong password")
        XCTAssertTrue(send(h, .list, password: "newsecret").ok)

        let short = h.service.handle(Request(.changePassword, password: "newsecret", newPassword: "x"), now: t0)
        XCTAssertFalse(short.ok)
        XCTAssertTrue(send(h, .list, password: "newsecret").ok)
    }

    func testFailingPasswordSaveKeepsOldPassword() {
        let h = Harness()
        h.failSaves = true
        let response = h.service.handle(Request(.changePassword, password: pw, newPassword: "newsecret"), now: t0)
        XCTAssertFalse(response.ok)
        h.failSaves = false
        XCTAssertTrue(send(h, .list).ok)
        XCTAssertEqual(send(h, .list, password: "newsecret").error, "Wrong password")
    }

    func testUninstallRepliesOkAndCallsCallback() {
        let h = Harness()
        let response = send(h, .uninstall)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(h.uninstalls, 1)
    }

    func testTickPrunesExpiredUnblockAndEnforcesChanged() {
        var state = BlockState(domains: ["a.com"])
        try? state.unblock("a.com", minutes: 5, now: t0)
        let h = Harness(state: state)

        h.service.tick(now: t0.addingTimeInterval(60))  // still unblocked: periodic re-check only
        XCTAssertEqual(h.enforceCalls.count, 1)
        XCTAssertFalse(h.enforceCalls[0].changed)
        XCTAssertTrue(h.savedStates.isEmpty)

        h.service.tick(now: t0.addingTimeInterval(300))  // expired
        XCTAssertEqual(h.service.state.unblocks, [:])
        XCTAssertEqual(h.savedStates.count, 1)
        XCTAssertEqual(h.enforceCalls.count, 2)
        XCTAssertTrue(h.enforceCalls[1].changed)

        h.service.tick(now: t0.addingTimeInterval(302))
        XCTAssertEqual(h.enforceCalls.count, 3)
        XCTAssertFalse(h.enforceCalls[2].changed)
        XCTAssertEqual(h.savedStates.count, 1)
    }
}
