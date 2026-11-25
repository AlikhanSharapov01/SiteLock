import Foundation

/// Version of the app and the daemon (kept equal to CFBundleShortVersionString in Resources/Info.plist).
public enum SiteLockVersion {
    public static let current = "1.1.0"
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
        case changePassword // `password` is the current one, `newPassword` replaces it
    }

    public var command: Command
    public var password: String?
    public var domain: String?
    /// Only for `edit`: the replacement for `domain`.
    public var newDomain: String? = nil
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
    /// True when the request changed what Firefox blocks, so the daemon quit Firefox
    /// (policies are only read at Firefox startup). The app may then relaunch it.
    public var firefoxQuit: Bool?

    public init(ok: Bool, error: String? = nil, initialized: Bool? = nil, state: BlockState? = nil,
                firefoxQuit: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.initialized = initialized
        self.state = state
        self.firefoxQuit = firefoxQuit
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

/// Slows down password guessing over the world-connectable socket:
/// after `maxFailures` wrong passwords in a row, all attempts are refused for `lockout`.
public struct AuthThrottle: Sendable {
    public let maxFailures: Int
    public let lockout: TimeInterval
    private var failures = 0
    private var lockedUntil: Date?

    public init(maxFailures: Int = 5, lockout: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.lockout = lockout
    }

    /// Seconds left in the lockout, or nil if an attempt is allowed.
    public func lockedFor(now: Date) -> TimeInterval? {
        guard let until = lockedUntil, until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    public mutating func record(success: Bool, now: Date) {
        if success {
            failures = 0
            lockedUntil = nil
            return
        }
        failures += 1
        if failures >= maxFailures {
            failures = 0
            lockedUntil = now.addingTimeInterval(lockout)
        }
    }
}
