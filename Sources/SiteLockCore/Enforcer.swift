import Foundation

/// Something that makes the current block state real on this Mac.
///
/// There is one implementation per browser engine in the daemon (Firefox, Chromium). App blocking can be
/// added later as another `Enforcer` (e.g. a per-user LaunchAgent that watches
/// `NSWorkspace.didLaunchApplicationNotification` — that notification is only delivered inside
/// a user's GUI session, not to a root LaunchDaemon). `BlockState` would then gain an app list.
public protocol Enforcer {
    /// The bundle id of the browser this enforcer handles.
    var bundleID: String { get }

    /// Applies `state` at `now`. `changed` is true when the effective blocklist differs from
    /// the previous call (e.g. after add/unblock/re-block), false for a periodic re-check.
    /// Returns the bundle ids of the browsers that must be quit (and reopened) to load the new
    /// policy; the caller quits them. Only Firefox needs this; Chromium applies policy changes live.
    func enforce(_ state: BlockState, now: Date, changed: Bool) -> [String]
}
