import Foundation

/// Version of the app and the daemon (kept equal to CFBundleShortVersionString in Resources/Info.plist).
public enum SiteLockVersion {
    public static let current = "1.3.1"

    /// True if `candidate` (e.g. "1.10.0" or "v1.10.0") is a later version than `base`.
    /// Compares dot-separated numbers; missing parts count as 0.
    public static func isNewer(_ candidate: String, than base: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
            return trimmed.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(base)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Fixed paths shared by the daemon and the app.
public enum Paths {
    public static let launchDaemonLabel = "local.sitelock.daemon"
    /// The installed daemon: a root-owned copy of SiteLock.app/Contents/MacOS/sitelockd.
    public static let helper = "/Library/PrivilegedHelperTools/sitelockd"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"
    public static let socket = "/var/run/sitelockd.sock"
    public static let dataDirectory = "/Library/Application Support/SiteLock"
    public static let passwordFile = dataDirectory + "/auth.json"
    public static let stateFile = dataDirectory + "/state.json"
}

/// One request per connection: a single JSON object terminated by "\n".
/// Every command except `hello` and `setup` must carry the SiteLock password.
public struct Request: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case hello      // -> initialized flag, no auth
        case setup      // first launch: set the password (only while none is stored)
        case list       // -> domains + unblocks
        case edit           // rename `domain` to `newDomain`
        case add, remove, unblock, reblock
        case uninstall      // remove the service, policy keys and data (asked from the app)
        case changePassword // `password` is the current one, `newPassword` replaces it
        case setBrowser     // turn enforcement in `browser` (bundle id) on or off (`enabled`)
        case importDomains  // add the raw entries in `domains` in one change
    }

    public var command: Command
    public var password: String?
    public var domain: String?
    /// Only for `edit`: the replacement for `domain`.
    public var newDomain: String? = nil
    /// Only for `setBrowser`.
    public var browser: String? = nil
    public var enabled: Bool? = nil
    /// Only for `importDomains`: raw lines of an exported list.
    public var domains: [String]? = nil
    public var minutes: Int?
    public var newPassword: String?

    public init(_ command: Command, password: String? = nil, domain: String? = nil, minutes: Int? = nil,
                newPassword: String? = nil) {
        self.command = command
        self.password = password
        self.domain = domain
        self.minutes = minutes
        self.newPassword = newPassword
    }
}

public struct Response: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var initialized: Bool?
    public var state: BlockState?
    /// Bundle ids of the browsers the daemon quit to apply the change (policies are only read
    /// at browser startup). The app may relaunch them.
    public var quitBrowsers: [String]? = nil
    /// The daemon's version, sent with `hello` (nil from daemons older than 1.1.0).
    public var version: String? = nil
    /// Only for `importDomains`.
    public var importReport: ImportReport? = nil

    public init(ok: Bool, error: String? = nil, initialized: Bool? = nil, state: BlockState? = nil,
                quitBrowsers: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.initialized = initialized
        self.state = state
        self.quitBrowsers = quitBrowsers
    }

    public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
}

public enum Wire {
    public static let maxMessageBytes = 64 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value) + Data([0x0A])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// Slows down password guessing over the world-connectable socket, separately per client uid
/// (one user cannot lock another out). After `maxFailures` wrong passwords in a row a uid is
/// refused for `lockout`; every further lockout without a success in between doubles that, up to
/// `maxLockout`. A correct password resets the uid.
public struct AuthThrottle: Sendable {
    public let maxFailures: Int
    public let lockout: TimeInterval
    public let maxLockout: TimeInterval

    private struct Entry: Sendable {
        var failures = 0
        var lockouts = 0
        var lockedUntil: Date?
    }
    private var entries: [UInt32: Entry] = [:]

    public init(maxFailures: Int = 5, lockout: TimeInterval = 60, maxLockout: TimeInterval = 3600) {
        self.maxFailures = maxFailures
        self.lockout = lockout
        self.maxLockout = maxLockout
    }

    /// Seconds left in the lockout of `uid`, or nil if an attempt is allowed.
    public func lockedFor(uid: UInt32, now: Date) -> TimeInterval? {
        guard let until = entries[uid]?.lockedUntil, until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    public mutating func record(uid: UInt32, success: Bool, now: Date) {
        if success {
            entries[uid] = nil
            return
        }
        var entry = entries[uid] ?? Entry()
        entry.failures += 1
        if entry.failures >= maxFailures {
            var duration = lockout
            for _ in 0..<entry.lockouts where duration < maxLockout { duration *= 2 }
            entry.failures = 0
            entry.lockouts += 1
            entry.lockedUntil = now.addingTimeInterval(min(duration, maxLockout))
        }
        entries[uid] = entry
    }

    /// "Too many wrong passwords. Try again in 45 s" (in minutes from 120 s on).
    public static func message(waiting seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let amount = s >= 120 ? "\((s + 59) / 60) min" : "\(s) s"
        return "Too many wrong passwords. Try again in \(amount)"
    }
}
