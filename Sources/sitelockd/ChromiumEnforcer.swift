import Foundation
import SiteLockCore

/// Enforces the block state in one Chromium-based browser through the mandatory managed
/// preferences file /Library/Managed Preferences/<bundle id>.plist (key URLBlocklist).
final class ChromiumEnforcer: Enforcer {
    private let browser: Browser
    private let path: String
    private let writeFailure = FailureLog()

    var bundleID: String { browser.id }

    init(browser: Browser) {
        self.browser = browser
        self.path = ChromiumPolicy.plistPath(for: browser.id)
    }

    func enforce(_ state: BlockState, now: Date, changed: Bool) -> [String] {
        guard state.browsers.contains(browser.id) else {
            clear()
            return []
        }
        let policy = ChromiumPolicy(blockedDomains: state.effectiveBlocked(now: now))
        if !policy.isSatisfied(by: readFile()) {
            if !changed { log("\(browser.name) policy missing or modified; re-applying") }
            write(policy)
        }
        // Chromium reads policies at startup (and on its own schedule), so restart it on a change.
        return changed ? [browser.id] : []
    }

    /// Removes the keys SiteLock manages, and the file if nothing else is in it.
    /// Does nothing when they are not there.
    func clear() {
        guard var current = readFile(), ChromiumPolicy.managedKeys.contains(where: { current[$0] != nil }) else { return }
        for key in ChromiumPolicy.managedKeys { current[key] = nil }
        if current.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            reloadPreferencesCache()
        } else {
            save(current)
        }
    }

    private func readFile() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func write(_ policy: ChromiumPolicy) {
        var merged = readFile() ?? [:]
        if merged.isEmpty, FileManager.default.fileExists(atPath: path) {
            // Unparseable (or empty): we own URLBlocklist and a corrupt file is unusable, so replace it.
            writeFailure.failed("\(path) is unreadable; replacing it")
        }
        for (key, value) in policy.values { merged[key] = value }
        save(merged)
    }

    private func save(_ values: [String: Any]) {
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        do {
            if !fm.fileExists(atPath: directory) {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
            }
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: path)
            writeFailure.succeeded()
            reloadPreferencesCache()
        } catch {
            writeFailure.failed("writing \(path) failed: \(error)")
        }
    }
}
