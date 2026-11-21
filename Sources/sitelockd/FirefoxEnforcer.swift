import Foundation
import SiteLockCore

/// Enforces the block state in Firefox through the system-wide preferences domain
/// /Library/Preferences/org.mozilla.firefox.plist (outside the app bundle, so it survives
/// Firefox updates; Firefox's macOS policy provider ranks it above policies.json).
final class FirefoxEnforcer: Enforcer {
    private let domain = FirefoxPolicy.preferencesDomain as CFString

    func enforce(_ state: BlockState, now: Date, changed: Bool) {
        let policy = FirefoxPolicy(blockedDomains: state.effectiveBlocked(now: now))
        if !policy.isSatisfied(by: readFile()) || !policy.isSatisfied(by: readPreferences()) {
            if !changed { log("Firefox policy missing or modified; re-applying") }
            write(policy)
        }
        // Firefox reads WebsiteFilter only at startup, so a new list needs a Firefox restart.
        if changed { FirefoxProcess.quitAll() }
    }

    /// Removes the keys SiteLock manages (used by uninstall).
    func clear() {
        for key in FirefoxPolicy.managedKeys {
            CFPreferencesSetValue(key as CFString, nil, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
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
            CFPreferencesSetValue(key as CFString, value as CFPropertyList, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        if !CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) {
            log("CFPreferencesSynchronize failed")
        }
        guard !policy.isSatisfied(by: readFile()) else { return }

        // cfprefsd skips the write when its cache already holds these values but the file was
        // deleted or replaced behind its back. Write the file directly, keeping foreign keys.
        var merged = readFile() ?? [:]
        for (key, value) in policy.values { merged[key] = value }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: FirefoxPolicy.plistPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                                  ofItemAtPath: FirefoxPolicy.plistPath)
        } catch {
            log("writing \(FirefoxPolicy.plistPath) failed: \(error)")
        }
    }
}

enum FirefoxProcess {
    /// Sends SIGTERM to every Firefox main process (all users), waits up to 10 s, then SIGKILLs
    /// leftovers. Firefox restores the session on next launch per the user's Firefox settings.
    static func quitAll() {
        guard run("/usr/bin/pkill", ["-TERM", "-x", "firefox"]) == 0 else { return } // 1 = none running
        log("quit Firefox so it reloads the policy")
        for _ in 0..<20 {
            if run("/usr/bin/pgrep", ["-x", "firefox"]) != 0 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        _ = run("/usr/bin/pkill", ["-KILL", "-x", "firefox"])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("\(tool) failed: \(error)"); return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
