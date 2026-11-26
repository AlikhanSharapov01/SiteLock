import Foundation
import SiteLockCore

struct InstallError: Error, CustomStringConvertible {
    let description: String
}

/// Installs and removes the LaunchDaemon. Runs as root.
///
/// Installed footprint: the helper binary, the LaunchDaemon plist and the data directory.
/// Logging goes to the unified log, so there is no log file.
enum Installer {
    /// Written by v1.0's install script; removed on install/uninstall.
    static let legacyLogFile = "/var/log/sitelockd.log"

    /// Copies `source` (normally SiteLock.app/Contents/MacOS/sitelockd) to the root-owned helper
    /// path, writes the LaunchDaemon plist and starts the service. Replaces an older version in
    /// place; the password and the list are kept.
    static func install(from source: String) throws {
        let fm = FileManager.default
        stopService()

        if source != Paths.helper {
            try fm.createDirectory(atPath: (Paths.helper as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            let staged = Paths.helper + ".new"
            try? fm.removeItem(atPath: staged)
            try fm.copyItem(atPath: source, toPath: staged)
            // A copy of a downloaded app keeps its quarantine flag; launchd must not see it.
            removexattr(staged, "com.apple.quarantine", 0)
            try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                 ofItemAtPath: staged)
            guard rename(staged, Paths.helper) == 0 else {
                throw InstallError(description: "cannot move \(staged) into place: \(String(cString: strerror(errno)))")
            }
        }

        let plist: [String: Any] = [
            "Label": Paths.launchDaemonLabel,
            "ProgramArguments": [Paths.helper, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: Paths.launchDaemonPlist), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                             ofItemAtPath: Paths.launchDaemonPlist)
        try? fm.removeItem(atPath: legacyLogFile)

        unlink(Paths.socket)
        runTool("/bin/launchctl", ["enable", "system/\(Paths.launchDaemonLabel)"])
        guard runTool("/bin/launchctl", ["bootstrap", "system", Paths.launchDaemonPlist]) == 0 else {
            throw InstallError(description: "launchctl bootstrap failed")
        }
        guard waitUntil(seconds: 10, { fm.fileExists(atPath: Paths.socket) }) else {
            throw InstallError(description: "sitelockd did not start; see: log show --last 5m --predicate 'subsystem == \"local.sitelock\"'")
        }
    }

    /// Unloads the LaunchDaemon if it is loaded and waits until launchd has stopped it.
    static func stopService() {
        let target = "system/\(Paths.launchDaemonLabel)"
        guard runTool("/bin/launchctl", ["print", target]) == 0 else { return }
        runTool("/bin/launchctl", ["bootout", target])
        _ = waitUntil(seconds: 5) { runTool("/bin/launchctl", ["print", target]) != 0 }
    }

    /// Removes SiteLock's policy keys in every catalog browser, the helper, the plist and all data.
    /// The caller stops the service (before, or after when the service removes itself).
    static func removeFiles() {
        FirefoxEnforcer().clear()
        for browser in Browser.catalog {
            if case .chromium = browser.engine { ChromiumEnforcer(browser: browser).clear() }
        }
        HostsEnforcer().clear()
        let fm = FileManager.default
        for path in [Paths.launchDaemonPlist, Paths.helper, Paths.socket, Paths.dataDirectory, legacyLogFile] {
            try? fm.removeItem(atPath: path)
        }
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}
