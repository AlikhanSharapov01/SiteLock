import Foundation
import SiteLockCore

/// Enforces the block state in Firefox through the system-wide preferences domain
/// /Library/Preferences/org.mozilla.firefox.plist (outside the app bundle, so it survives
/// Firefox updates; Firefox's macOS policy provider ranks it above policies.json).
final class FirefoxEnforcer: Enforcer {
    private let domain = FirefoxPolicy.preferencesDomain as CFString

    let bundleID = Browser.firefoxID
    private let writeFailure = FailureLog()

    func enforce(_ state: BlockState, now: Date, changed: Bool) -> [String] {
        guard state.browsers.contains(bundleID) else {
            // Not enforcing here: make sure none of our keys are left behind.
            let file = readFile() ?? [:]
            if FirefoxPolicy.managedKeys.contains(where: { file[$0] != nil }) || !readPreferences().isEmpty {
                clear()
            }
            return []
        }
        let policy = FirefoxPolicy(blockedDomains: state.effectiveBlocked(now: now))
        if !policy.isSatisfied(by: readFile()) || !policy.isSatisfied(by: readPreferences()) {
            if !changed { log("Firefox policy missing or modified; re-applying") }
            write(policy)
        }
        // Firefox reads WebsiteFilter only at startup, so a new list needs a Firefox restart.
        return changed ? [bundleID] : []
    }

    /// Removes the keys SiteLock manages (used by uninstall).
    func clear() {
        for key in FirefoxPolicy.managedKeys {
            CFPreferencesSetValue(key as CFString, nil, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)

        // cfprefsd can skip the removal when its cache disagrees with the file; edit the file directly.
        guard var current = readFile(), FirefoxPolicy.managedKeys.contains(where: { current[$0] != nil }) else { return }
        for key in FirefoxPolicy.managedKeys { current[key] = nil }
        if current.isEmpty {
            try? FileManager.default.removeItem(atPath: FirefoxPolicy.plistPath)
        } else {
            saveFile(current)
        }
    }

    private func saveFile(_ values: [String: Any]) {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: FirefoxPolicy.plistPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                                  ofItemAtPath: FirefoxPolicy.plistPath)
            writeFailure.succeeded()
        } catch {
            writeFailure.failed("writing \(FirefoxPolicy.plistPath) failed: \(error)")
        }
    }

    private func readFile() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: FirefoxPolicy.plistPath) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// What cfprefsd (and therefore Firefox) currently serves for the system domain.
    private func readPreferences() -> [String: Any] {
        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        var values: [String: Any] = [:]
        for key in FirefoxPolicy.managedKeys {
            if let v = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) {
                values[key] = v
            }
        }
        return values
    }

    private func write(_ policy: FirefoxPolicy) {
        // Write through cfprefsd so its cache and the file agree.
        for (key, value) in policy.values {
            CFPreferencesSetValue(key as CFString, value as AnyObject, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        if !CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) {
            writeFailure.failed("CFPreferencesSynchronize failed")
        }
        guard !policy.isSatisfied(by: readFile()) else { return }

        // cfprefsd skips the write when its cache already holds these values but the file was
        // deleted or replaced behind its back. Write the file directly, keeping foreign keys.
        var merged = readFile() ?? [:]
        for (key, value) in policy.values { merged[key] = value }
        saveFile(merged)
    }
}

enum BrowserProcess {
    /// Sends SIGTERM to every main process of the given browsers (all users) at once, waits up to
    /// 10 s in total, then SIGKILLs leftovers. Returns the process names that were running.
    /// The browsers restore their session on next launch per the user's settings.
    static func quit(processNames: [String]) -> [String] {
        let running = processNames.filter { runTool("/usr/bin/pkill", ["-TERM", "-x", $0]) == 0 } // 1 = none running
        guard !running.isEmpty else { return [] }
        log("quit \(running.joined(separator: ", ")) so they reload the policy")
        var left = running
        for _ in 0..<20 {
            left = left.filter { runTool("/usr/bin/pgrep", ["-x", $0]) == 0 }
            if left.isEmpty { return running }
            Thread.sleep(forTimeInterval: 0.5)
        }
        for name in left { _ = runTool("/usr/bin/pkill", ["-KILL", "-x", name]) }
        return running
    }
}
