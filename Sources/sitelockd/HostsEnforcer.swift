import Foundation
import SiteLockCore

/// Enforces the block state for Safari, which has no policy mechanism, by keeping a managed
/// block in /etc/hosts. That blocks the hosts for the whole Mac, not only Safari.
final class HostsEnforcer: Enforcer {
    let bundleID = "com.apple.Safari"
    private let writeFailure = FailureLog()

    func enforce(_ state: BlockState, now: Date, changed: Bool) -> [String] {
        guard state.browsers.contains(bundleID) else {
            clear()
            return []
        }
        let policy = HostsPolicy(blockedDomains: state.effectiveBlocked(now: now))
        guard let current = readFile() else { return [] }
        if !policy.isSatisfied(by: current) {
            if !changed { log("\(HostsPolicy.path) block missing or modified; re-applying") }
            write(policy.apply(to: current))
        }
        // Safari keeps resolved addresses for a while, so restart it on a change.
        return changed ? [bundleID] : []
    }

    /// Removes the SiteLock block; does nothing when it is not there.
    func clear() {
        guard let current = readFile(), HostsPolicy.hasBlock(current) else { return }
        write(HostsPolicy.strip(current))
    }

    /// The file as text; "" if it does not exist; nil (logged once) if it is not valid UTF-8,
    /// in which case it is left alone.
    private func readFile() -> String? {
        guard let data = FileManager.default.contents(atPath: HostsPolicy.path) else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            writeFailure.failed("\(HostsPolicy.path) is not valid UTF-8; leaving it alone")
            return nil
        }
        return text
    }

    private func write(_ text: String) {
        do {
            // Temp file in /etc with the final mode and owner, then rename(2) over /etc/hosts, so
            // the file is never briefly unreadable.
            let temp = HostsPolicy.path + ".sitelock.tmp"
            try Data(text.utf8).write(to: URL(fileURLWithPath: temp))
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                                      ofItemAtPath: temp)
                guard rename(temp, HostsPolicy.path) == 0 else {
                    throw InstallError(description: String(cString: strerror(errno)))
                }
            } catch {
                try? FileManager.default.removeItem(atPath: temp)
                throw error
            }
            writeFailure.succeeded()
            runTool("/usr/bin/dscacheutil", ["-flushcache"])
            runTool("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        } catch {
            writeFailure.failed("writing \(HostsPolicy.path) failed: \(error)")
        }
    }
}
