import Foundation

/// The Firefox enterprise policy SiteLock enforces.
///
/// Delivered on macOS through the system preferences domain
/// `/Library/Preferences/org.mozilla.firefox.plist` (see README, "How it works").
/// SiteLock owns only the keys listed in `managedKeys`; other keys in that file are left alone.
public struct FirefoxPolicy: Equatable, Sendable {
    public static let preferencesDomain = "org.mozilla.firefox"
    public static let plistPath = "/Library/Preferences/org.mozilla.firefox.plist"
    public static let managedKeys = ["EnterprisePoliciesEnabled", "WebsiteFilter", "BlockAboutConfig"]

    public let blockPatterns: [String]

    public init(blockedDomains: [String]) {
        blockPatterns = blockedDomains.sorted().map(Domain.blockPattern(for:))
    }

    /// Key/value pairs to write into the preferences domain (property-list types only).
    public var values: [String: Any] {
        [
            "EnterprisePoliciesEnabled": true,
            "WebsiteFilter": ["Block": blockPatterns, "Exceptions": [String]()],
            "BlockAboutConfig": true,
        ]
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
