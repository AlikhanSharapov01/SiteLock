import Foundation

/// Something that makes the current block state real on this Mac.
///
/// v1 has one implementation, the Firefox policy enforcer in the daemon. App blocking can be
/// added later as another `Enforcer` (e.g. a per-user LaunchAgent that watches
/// `NSWorkspace.didLaunchApplicationNotification` — that notification is only delivered inside
/// a user's GUI session, not to a root LaunchDaemon). `BlockState` would then gain an app list.
public protocol Enforcer {
    /// Applies `state` at `now`. `changed` is true when the effective blocklist differs from
    /// the previous call (e.g. after add/unblock/re-block), false for a periodic re-check.
    func enforce(_ state: BlockState, now: Date, changed: Bool)
}
