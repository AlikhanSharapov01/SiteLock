import Foundation
import SiteLockCore

/// Root LaunchDaemon: owns the block state, answers the app over a Unix socket, re-applies the
/// policy every few seconds (tamper repair) and re-blocks when temporary unblocks expire.
/// Everything runs on one serial queue, so no locking is needed.
final class Daemon {
    static let tickInterval: DispatchTimeInterval = .seconds(2)

    private let queue = DispatchQueue(label: "sitelockd")
    /// Client I/O runs here, so a slow or stuck client never blocks the timer on `queue`.
    private let ioQueue = DispatchQueue(label: "sitelockd.io", attributes: .concurrent)
    private let enforcers: [Enforcer]
    private var state = BlockState()
    private var password: PasswordRecord?
    /// auth.json exists but could not be read: never offer first-launch setup (it would overwrite it).
    private var passwordUnreadable = false
    private var throttle = AuthThrottle()
    private var timer: DispatchSourceTimer?
    private var listener: DispatchSourceRead?

    init(enforcers: [Enforcer]) {
        self.enforcers = enforcers
    }

    func start() throws {
        try Storage.ensureDataDirectory()
        do { password = try Storage.load(PasswordRecord.self, from: Paths.passwordFile) }
        catch { log("cannot read password file: \(error)"); passwordUnreadable = true }
        do { state = try Storage.load(BlockState.self, from: Paths.stateFile) ?? BlockState() }
        catch { log("cannot read state file, starting with an empty list: \(error)") }

        let fd = try UnixSocket.listen(path: Paths.socket, mode: 0o666)
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        listener.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self?.ioQueue.async { self?.serve(client) }
        }
        self.listener = listener

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer

        listener.resume()
        timer.resume()
        log("started; \(state.domains.count) domain(s), password \(password == nil ? "not set" : "set")")
    }

    // MARK: - Periodic work

    private func tick() {
        let now = Date()
        // An unblock that expired (also while the Mac slept or the daemon was down) re-blocks now.
        let expired = state.pruneExpired(now: now)
        if expired {
            log("temporary unblock expired; re-blocking")
            persist(state)
        }
        enforce(now: now, changed: expired)
    }

    private func enforce(now: Date, changed: Bool) {
        for enforcer in enforcers { enforcer.enforce(state, now: now, changed: changed) }
    }

    private func persist(_ s: BlockState) {
        do { try Storage.save(s, to: Paths.stateFile) } catch { log("saving state failed: \(error)") }
    }

    // MARK: - Requests

    /// Runs on `ioQueue`; only `handle` touches state, on `queue`.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, 2)
        let response: Response
        if let line = UnixSocket.readLine(fd, deadline: Date().addingTimeInterval(5)),
           let request = try? Wire.decode(Request.self, from: line) {
            response = queue.sync { handle(request) }
        } else {
            response = .failure("Malformed request")
        }
        if let data = try? Wire.encode(response) { _ = UnixSocket.writeAll(fd, data) }
    }

    func handle(_ request: Request) -> Response {
        switch request.command {
        case .hello:
            return Response(ok: true, initialized: password != nil || passwordUnreadable)
        case .setup:
            return setup(request.password ?? "")
        default:
            break
        }
        if let error = authenticate(request.password) { return .failure(error) }
        if request.command == .changePassword { return changePassword(request.newPassword ?? "") }

        let now = Date()
        var next = state
        do {
            let domain = { try Domain.normalize(request.domain ?? "") }
            switch request.command {
            case .list, .hello, .setup, .changePassword: break
            case .add: try next.add(domain())
            case .remove: try next.remove(domain())
            case .unblock: try next.unblock(domain(), minutes: request.minutes ?? 0, now: now)
            case .reblock: try next.reblock(domain())
            }
            if next != state { try Storage.save(next, to: Paths.stateFile) }
        } catch {
            return .failure("\(error)")
        }
        let changed = next.effectiveBlocked(now: now) != state.effectiveBlocked(now: now)
        state = next
        if changed {
            log("\(request.command.rawValue) \(request.domain ?? ""): applying new list")
            enforce(now: now, changed: true)
        }
        return Response(ok: true, state: state, firefoxQuit: changed)
    }

    private func setup(_ newPassword: String) -> Response {
        guard password == nil, !passwordUnreadable else { return .failure("A password is already set") }
        do {
            let record = try PasswordHasher.makeRecord(password: newPassword)
            try Storage.save(record, to: Paths.passwordFile)
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
            let record = try PasswordHasher.makeRecord(password: newPassword)
            try Storage.save(record, to: Paths.passwordFile)
            password = record
            log("password changed")
            return Response(ok: true, state: state)
        } catch {
            return .failure("\(error)")
        }
    }

    /// Nil on success, otherwise a message for the user.
    private func authenticate(_ candidate: String?) -> String? {
        guard let record = password else {
            return passwordUnreadable ? "The password file cannot be read; see /var/log/sitelockd.log" : "No password set yet"
        }
        if let wait = throttle.lockedFor(now: Date()) {
            return "Too many wrong passwords. Try again in \(Int(wait.rounded(.up))) s"
        }
        let ok = (try? PasswordHasher.verify(password: candidate ?? "", against: record)) ?? false
        throttle.record(success: ok, now: Date())
        return ok ? nil : "Wrong password"
    }
}
