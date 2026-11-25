import Foundation

/// Password hashing as the service needs it. The daemon passes an adapter over `PasswordHasher`
/// (CommonCrypto, macOS only); tests pass a fake.
public protocol PasswordHashing {
    func makeRecord(password: String) throws -> PasswordRecord
    func verify(password: String, against record: PasswordRecord) throws -> Bool
}

/// Who is talking to the daemon: the uid of the socket peer and whether it is an administrator
/// of the Mac (the daemon only determines that for `setup`).
public struct Client: Equatable, Sendable {
    public var uid: UInt32
    public var isAdmin: Bool

    public init(uid: UInt32, isAdmin: Bool) {
        self.uid = uid
        self.isAdmin = isAdmin
    }
}

/// The daemon's request handling and periodic work, free of sockets, files, browsers and
/// timers: all of those are injected. Not thread-safe; the caller serializes every call.
public final class SiteLockService {
    /// Applies the state in the browsers and returns the bundle ids that were quit.
    /// `onlyBrowser` limits it to one browser; together with `changed == false` it means that
    /// browser was just switched off, and it is quit if it is running.
    public typealias Enforce = (_ changed: Bool, _ onlyBrowser: String?) -> [String]

    public private(set) var state: BlockState
    private var password: PasswordRecord?
    /// auth.json exists but could not be read: never offer first-launch setup (it would overwrite it).
    private let passwordUnreadable: Bool
    private var throttle = AuthThrottle()

    private let hasher: PasswordHashing
    private let saveState: (BlockState) throws -> Void
    private let savePassword: (PasswordRecord) throws -> Void
    private let enforce: Enforce
    private let uninstall: () -> Void
    private let log: (String) -> Void

    public init(state: BlockState = BlockState(), password: PasswordRecord? = nil, passwordUnreadable: Bool = false,
                hasher: PasswordHashing,
                saveState: @escaping (BlockState) throws -> Void,
                savePassword: @escaping (PasswordRecord) throws -> Void,
                enforce: @escaping Enforce,
                uninstall: @escaping () -> Void,
                log: @escaping (String) -> Void = { _ in }) {
        self.state = state
        self.password = password
        self.passwordUnreadable = passwordUnreadable
        self.hasher = hasher
        self.saveState = saveState
        self.savePassword = savePassword
        self.enforce = enforce
        self.uninstall = uninstall
        self.log = log
    }

    public var hasPassword: Bool { password != nil }

    // MARK: - Periodic work

    /// An unblock that expired (also while the Mac slept or the daemon was down) re-blocks now.
    public func tick(now: Date) {
        let expired = state.pruneExpired(now: now)
        if expired {
            log("temporary unblock expired; re-blocking")
            do { try saveState(state) } catch { log("saving state failed: \(error)") }
        }
        _ = enforce(expired, nil)
    }

    // MARK: - Requests

    public func handle(_ request: Request, from client: Client, now: Date) -> Response {
        switch request.command {
        case .hello:
            var response = Response(ok: true, initialized: password != nil || passwordUnreadable)
            response.version = SiteLockVersion.current
            return response
        case .setup:
            guard client.isAdmin else {
                return .failure("Only an administrator of this Mac can set the SiteLock password.")
            }
            return setup(request.password ?? "")
        default:
            break
        }
        if let error = authenticate(request.password, uid: client.uid, now: now) { return .failure(error) }
        if request.command == .uninstall {
            log("uninstall requested from the app")
            uninstall()
            return Response(ok: true)
        }
        if request.command == .changePassword { return changePassword(request.newPassword ?? "") }
        if request.command == .setBrowser { return setBrowser(request) }

        var next = state
        do {
            let domain = { try Domain.normalize(request.domain ?? "") }
            switch request.command {
            case .list, .hello, .setup, .changePassword, .uninstall, .setBrowser: break
            case .add: try next.add(domain())
            case .remove: try next.remove(domain())
            case .unblock: try next.unblock(domain(), minutes: request.minutes ?? 0, now: now)
            case .reblock: try next.reblock(domain())
            case .edit: try next.rename(domain(), to: Domain.normalize(request.newDomain ?? ""))
            }
            if next != state { try saveState(next) }
        } catch {
            return .failure("\(error)")
        }
        let changed = next.effectiveBlocked(now: now) != state.effectiveBlocked(now: now)
        state = next
        var quitIDs: [String] = []
        if changed {
            log("\(request.command.rawValue) \(request.domain ?? ""): applying new list")
            quitIDs = enforce(true, nil)
        }
        return Response(ok: true, state: state, quitBrowsers: quitIDs)
    }

    /// The caller is authenticated. Turns enforcement in one browser on or off and restarts that
    /// browser so it picks up (or drops) the policy.
    private func setBrowser(_ request: Request) -> Response {
        let id = request.browser ?? ""
        var next = state
        do {
            try next.setBrowser(id, enabled: request.enabled ?? false)
            if next != state { try saveState(next) }
        } catch {
            return .failure("\(error)")
        }
        guard next != state else { return Response(ok: true, state: state, quitBrowsers: []) }
        state = next
        log("\(id): enforcement \(request.enabled == true ? "on" : "off")")
        let quitIDs = enforce(request.enabled == true, id)
        return Response(ok: true, state: state, quitBrowsers: quitIDs)
    }

    private func setup(_ newPassword: String) -> Response {
        guard password == nil, !passwordUnreadable else { return .failure("A password is already set") }
        do {
            let record = try hasher.makeRecord(password: newPassword)
            try savePassword(record)
            password = record
            log("password set")
            return Response(ok: true, initialized: true, state: state)
        } catch {
            return .failure("\(error)")
        }
    }

    /// The caller is already authenticated with the current password.
    private func changePassword(_ newPassword: String) -> Response {
        do {
            let record = try hasher.makeRecord(password: newPassword)
            try savePassword(record)
            password = record
            log("password changed")
            return Response(ok: true, state: state)
        } catch {
            return .failure("\(error)")
        }
    }

    /// Nil on success, otherwise a message for the user.
    private func authenticate(_ candidate: String?, uid: UInt32, now: Date) -> String? {
        guard let record = password else {
            return passwordUnreadable ? "The password file cannot be read; see the system log (subsystem local.sitelock)" : "No password set yet"
        }
        if let wait = throttle.lockedFor(uid: uid, now: now) {
            return AuthThrottle.message(waiting: wait)
        }
        let ok = (try? hasher.verify(password: candidate ?? "", against: record)) ?? false
        throttle.record(uid: uid, success: ok, now: now)
        return ok ? nil : "Wrong password"
    }
}
