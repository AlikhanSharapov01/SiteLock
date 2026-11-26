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
        let current = readFile() ?? ""
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

    private func readFile() -> String? {
        guard let data = FileManager.default.contents(atPath: HostsPolicy.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String) {
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: HostsPolicy.path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                                  ofItemAtPath: HostsPolicy.path)
            writeFailure.succeeded()
            runTool("/usr/bin/dscacheutil", ["-flushcache"])
            runTool("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        } catch {
            writeFailure.failed("writing \(HostsPolicy.path) failed: \(error)")
        }
    }
}
