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
        case removed
    }

    @Published var screen: Screen = .connecting
    @Published var state = BlockState()
    @Published var error: String?
    @Published var busy = false
    /// Version of the running service when it differs from this app's (nil: same, or unknown).
    @Published var installedVersion: String?
    @Published var updateAvailable = false
    @Published var showingUninstall = false
    @Published var showingUpdates = false
    @Published var updateCheck: UpdateCheck = .idle

    enum UpdateCheck: Equatable {
        case idle, checking, upToDate, installing
        case available(String)
        case failed(String)
    }

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/AlikhanSharapov01/SiteLock/releases/latest")!
    static let latestDownload = URL(string: "https://github.com/AlikhanSharapov01/SiteLock/releases/latest/download/SiteLock.zip")!

    /// Kept in memory only while unlocked; every daemon request is authenticated with it.
    private var password = ""

    func connect() async {
        screen = .connecting
        error = nil
        do {
            let response = try await send(Request(.hello))
            installedVersion = response.version
            updateAvailable = response.version != SiteLockVersion.current
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

    /// Installs or updates the service from the sitelockd inside this app. macOS shows its
    /// administrator password dialog; the app is blocked while it is open.
    func install() async {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "sitelockd")?.path else {
            error = "sitelockd is missing from SiteLock.app"
            return
        }
        error = nil
        let command = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "' install"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var info: NSDictionary?
        let result = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&info)
        if result == nil {
            if (info?[NSAppleScript.errorNumber] as? Int) == -128 { return } // Cancel in the password dialog
            error = info?[NSAppleScript.errorMessage] as? String ?? "Installation failed"
            return
        }
        await connect()
    }

    /// Removes SiteLock from this Mac (service, Firefox policy keys, password, list).
    /// True when the daemon accepted the SiteLock password and is removing itself.
    func uninstall(password candidate: String) async -> Bool {
        guard await perform(Request(.uninstall, password: candidate)) != nil else { return false }
        password = ""
        state = BlockState()
        updateAvailable = false
        screen = .removed
        return true
    }

    /// Asks GitHub for the latest release and compares it with this app's version.
    func checkForUpdates() async {
        updateCheck = .checking
        struct Release: Decodable { let tag_name: String }
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub did not answer") }
            let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            updateCheck = SiteLockVersion.isNewer(latest, than: SiteLockVersion.current) ? .available(latest) : .upToDate
        } catch {
            updateCheck = .failed("Could not check for updates: \(error)")
        }
    }

    /// Downloads the latest SiteLock.zip, swaps it in for this app (the old copy goes to the
    /// Trash) and relaunches. The relaunched app then offers to update the background service.
    func installUpdate() async {
        updateCheck = .installing
        do {
            let fm = FileManager.default
            let (zip, response) = try await URLSession.shared.download(from: Self.latestDownload)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("download failed") }
            let work = fm.temporaryDirectory.appendingPathComponent("SiteLockUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
                throw UpdateError("could not unpack the download")
            }
            let newApp = work.appendingPathComponent("SiteLock.app")
            guard fm.isExecutableFile(atPath: newApp.appendingPathComponent("Contents/MacOS/SiteLock").path) else {
                throw UpdateError("the download does not contain SiteLock.app")
            }
            let current = Bundle.main.bundleURL
            do {
                try fm.trashItem(at: current, resultingItemURL: nil)
            } catch {
                throw UpdateError("cannot replace \(current.path); move SiteLock to Applications and try again")
            }
            try fm.moveItem(at: newApp, to: current)
            // Reopen the new copy once this process has quit.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
            try relaunch.run()
            NSApplication.shared.terminate(nil)
        } catch {
            updateCheck = .failed("Update failed: \(error)")
        }
    }

    private struct UpdateError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func run(_ tool: String, _ args: [String]) async -> Int32 {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }.value
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

    func setBrowser(_ id: String, enabled: Bool) async {
        var request = Request(.setBrowser, password: password)
        request.browser = id
        request.enabled = enabled
        _ = await change(request)
    }

    /// Browsers installed on this Mac, plus enabled ones that are gone (so they can be turned off).
    var installedBrowsers: [Browser] {
        Browser.catalog.filter { browser in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) != nil
                || state.browsers.contains(browser.id)
        }
    }

    // MARK: - Private

    /// Sends a change. Browsers the daemon had to quit to apply it are reopened if they were running.
    private func change(_ request: Request) async -> Bool {
        let wasRunning = Browser.catalog.map(\.id).filter { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        }
        guard let response = await perform(request) else { return false }
        if let newState = response.state { state = newState }
        let quit = response.quitBrowsers ?? []
        await relaunch(bundleIDs: quit.filter { wasRunning.contains($0) })
        return true
    }

    private func relaunch(bundleIDs: [String]) async {
        guard !bundleIDs.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        for id in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
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
