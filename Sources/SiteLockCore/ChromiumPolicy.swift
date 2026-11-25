import Foundation

/// The Chromium enterprise policy SiteLock enforces (Chrome, Edge, Brave, Vivaldi, Chromium).
///
/// Delivered on macOS as a mandatory managed preferences file,
/// `/Library/Managed Preferences/<bundle id>.plist`. SiteLock owns only the keys in
/// `managedKeys`; other keys in that file are left alone. URLBlocklist entries use the same
/// semantics as our domains: "youtube.com" covers the domain and its subdomains,
/// "www.youtube.com" that host and its subdomains.
public struct ChromiumPolicy: Equatable, Sendable {
    public static let managedKeys = ["URLBlocklist"]

    public static func plistPath(for bundleID: String) -> String {
        "/Library/Managed Preferences/\(bundleID).plist"
    }

    public let hosts: [String]

    public init(blockedDomains: [String]) {
        hosts = blockedDomains.sorted()
    }

    public var values: [String: Any] {
        ["URLBlocklist": hosts]
    }

    /// True if `current` (e.g. the plist read from disk) holds exactly our values for every
    /// managed key. Other keys are ignored.
    public func isSatisfied(by current: [String: Any]?) -> Bool {
        guard let current else { return false }
        let want = values
        return Self.managedKeys.allSatisfy { key in
            guard let have = current[key], let expected = want[key] else { return false }
            return NSDictionary(dictionary: ["v": have]).isEqual(to: ["v": expected])
        }
    }
}
