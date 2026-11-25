import AppKit
import Combine
import SiteLockCore

@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case connecting
        case unreachable(String)
        case setup
        case locked
        case unlocked
    }

    static let firefoxBundleID = "org.mozilla.firefox"

    @Published var screen: Screen = .connecting
    @Published var state = BlockState()
    @Published var error: String?
    @Published var busy = false

    /// Kept in memory only while unlocked; every daemon request is authenticated with it.
    private var password = ""

    func connect() async {
        screen = .connecting
        error = nil
        do {
            let response = try await send(Request(.hello))
            screen = response.initialized == true ? .locked : .setup
        } catch {
            screen = .unreachable("\(error)")
        }
    }

    func setup(password newPassword: String, confirmation: String) async {
        guard newPassword == confirmation else { error = "The passwords do not match"; return }
        guard let response = await perform(Request(.setup, password: newPassword)) else { return }
        password = newPassword
        state = response.state ?? BlockState()
        screen = .unlocked
    }

    func unlock(password candidate: String) async {
        guard let response = await perform(Request(.list, password: candidate)) else { return }
        password = candidate
        state = response.state ?? BlockState()
        screen = .unlocked
    }

    /// True when the daemon accepted the new password.
    func changePassword(current: String, new newPassword: String, confirmation: String) async -> Bool {
        guard newPassword == confirmation else { error = "The new passwords do not match"; return false }
        guard await perform(Request(.changePassword, password: current, newPassword: newPassword)) != nil else {
            return false
        }
        password = newPassword
        return true
    }

    func lock() {
        password = ""
        state = BlockState()
        error = nil
        screen = .locked
    }

    func add(_ domain: String) async -> Bool {
        await change(Request(.add, password: password, domain: domain))
    }

    func remove(_ domain: String) async {
        _ = await change(Request(.remove, password: password, domain: domain))
    }

    func unblock(_ domain: String, minutes: Int) async {
        _ = await change(Request(.unblock, password: password, domain: domain, minutes: minutes))
    }

    /// True when the daemon accepted the edit.
    func edit(_ domain: String, to newDomain: String) async -> Bool {
        var request = Request(.edit, password: password, domain: domain)
        request.newDomain = newDomain
        return await change(request)
    }

    func reblock(_ domain: String) async {
        _ = await change(Request(.reblock, password: password, domain: domain))
    }

    // MARK: - Private

    /// Sends a change. If the daemon had to quit Firefox to apply it, reopen Firefox.
    private func change(_ request: Request) async -> Bool {
        let firefoxWasRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.firefoxBundleID).isEmpty
        guard let response = await perform(request) else { return false }
        if let newState = response.state { state = newState }
        if response.firefoxQuit == true && firefoxWasRunning { await relaunchFirefox() }
        return true
    }

    private func relaunchFirefox() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.firefoxBundleID) else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Runs a request, showing failures in `error`. Nil when it failed.
    private func perform(_ request: Request) async -> Response? {
        guard !busy else { return nil } // e.g. Return fired both onSubmit and the default button
        busy = true
        error = nil
        defer { busy = false }
        do {
            let response = try await send(request)
            guard response.ok else { error = response.error ?? "Request failed"; return nil }
            return response
        } catch {
            self.error = "\(error)"
            return nil
        }
    }

    private func send(_ request: Request) async throws -> Response {
        try await Task.detached { try UnixSocket.send(request) }.value
    }
}
