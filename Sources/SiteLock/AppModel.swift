import AppKit
import Combine
import SiteLockCore
import UniformTypeIdentifiers

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
    /// Result of the last import, shown under the list until the next change.
    @Published var importSummary: String?
    /// Version of the running service when it differs from this app's (nil: same, or unknown).
    @Published var installedVersion: String?
    @Published var updateAvailable = false
    @Published var showingUninstall = false
    @Published var showingUpdates = false
    @Published var updateCheck: UpdateCheck = .idle
    /// Last answer to the password-free `status` request; nil when the service cannot be reached.
    @Published var status: Status?
    /// False when the last refresh could not reach the service.
    @Published var reachable = true
    /// The service answers but is older than this app.
    @Published var serviceOutdated = false
    @Published var launchAtLoginError: String?

    enum UpdateCheck: Equatable {
        case idle, checking, upToDate, installing
        case available(String)
        case failed(String)
    }

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/AlikhanSharapov01/SiteLock/releases/latest")!
    static let latestDownload = URL(string: "https://github.com/AlikhanSharapov01/SiteLock/releases/latest/download/SiteLock.zip")!

    /// Kept in memory only while unlocked; every daemon request is authenticated with it.
    private var password = ""

    private var refreshTask: Task<Void, Never>?

    init() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshStatus()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    deinit { refreshTask?.cancel() }

    /// Cheap and unauthenticated; feeds the menu bar item. A failed refresh keeps the last good status.
    func refreshStatus() async {
        do {
            if let fresh = try await send(Request(.status)).status {
                status = fresh
                reachable = true
                serviceOutdated = false
                return
            }
        } catch {}
        // A daemon older than 1.4.0 does not know `status`: tell it apart from an unreachable one.
        if let hello = try? await send(Request(.hello)) {
            reachable = true
            serviceOutdated = SiteLockVersion.isNewer(SiteLockVersion.current, than: hello.version ?? "0")
        } else {
            reachable = false
        }
    }

    /// Ends a temporary unblock from the menu bar (no password needed), reopening browsers the daemon quit.
    func reblockNow(_ domain: String) async {
        if await change(Request(.reblockNow, domain: domain)) {
            try? state.reblock(domain) // the response carries no list; keep an open list in step
        }
        await refreshStatus()
    }

    func connect() async {
        password = ""
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
            var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 20)
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
            let (zip, response) = try await URLSession.shared.download(
                for: URLRequest(url: Self.latestDownload, timeoutInterval: 60))
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
            // Quit at once: the new copy is already in place, nothing needs saving, and
            // NSApplication.terminate can be postponed (e.g. while a sheet is open), which left
            // the update stuck on "Downloading and installing…".
            exit(0)
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
        importSummary = nil
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

    /// Asks for a .txt file and adds its entries in one change.
    func importList() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a text file with one site per line"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSummary = nil
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            self.error = "Could not read \(url.lastPathComponent) as UTF-8 text"
            return
        }
        var seen = Set<String>()
        let entries = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
        // One request must fit the wire limit: send the longest prefix that does.
        func size(_ count: Int) -> Int {
            var request = Request(.importDomains, password: password)
            request.domains = Array(entries.prefix(count))
            return (try? Wire.encode(request).count) ?? Int.max
        }
        let limit = Wire.maxMessageBytes - 4096
        var fit = entries.count
        if size(fit) > limit {
            var low = 0, high = entries.count // size(low) fits, size(high) does not
            while high - low > 1 {
                let mid = (low + high) / 2
                if size(mid) <= limit { low = mid } else { high = mid }
            }
            fit = low
        }
        var request = Request(.importDomains, password: password)
        request.domains = Array(entries.prefix(fit))
        guard await change(request) else { return }
        let dropped = entries.count - fit
        if dropped > 0 {
            importSummary = (importSummary ?? "") + " · \(dropped) not imported: file too large"
        }
    }

    /// Saves the loaded list as a text file, one host per line.
    func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "SiteLock blocklist.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (["# SiteLock blocklist"] + state.domains.sorted()).joined(separator: "\n") + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            self.error = "Could not save the list: \(error.localizedDescription)"
        }
    }

    /// Opens the bug report form with the version and macOS version filled in.
    func reportProblem() {
        var components = URLComponents(string: "https://github.com/AlikhanSharapov01/SiteLock/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: SiteLockVersion.current),
            URLQueryItem(name: "macos", value: ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
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
        importSummary = nil
        guard let response = await perform(request) else { return false }
        if let newState = response.state { state = newState }
        if let report = response.importReport {
            var summary = report.summary
            if report.invalid > 0 {
                summary += "\nNot valid: " + report.invalidEntries.joined(separator: ", ")
                    + (report.invalid > report.invalidEntries.count ? " …" : "")
            }
            importSummary = summary
        }
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
        // Changes may wait while the daemon quits browsers (up to 10 s).
        try await Task.detached { try UnixSocket.send(request, timeout: 60) }.value
    }
}
