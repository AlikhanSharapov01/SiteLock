import Foundation
import SiteLockCore

/// Root LaunchDaemon: answers the app over a Unix socket and drives `SiteLockService` (which owns
/// the block state) every few seconds to repair tampering and re-block when temporary unblocks
/// expire. Everything touching the service runs on one serial queue, so no locking is needed.
final class Daemon {
    static let tickInterval: DispatchTimeInterval = .seconds(2)

    private let queue = DispatchQueue(label: "sitelockd")
    /// Client I/O runs here, so a slow or stuck client never blocks the timer on `queue`.
    private let ioQueue = DispatchQueue(label: "sitelockd.io", attributes: .concurrent)
    private let enforcers: [Enforcer]
    private var service: SiteLockService!
    private var timer: DispatchSourceTimer?
    private var listener: DispatchSourceRead?

    init(enforcers: [Enforcer]) {
        self.enforcers = enforcers
    }

    func start() throws {
        try Storage.ensureDataDirectory()
        var password: PasswordRecord?
        var passwordUnreadable = false
        do { password = try Storage.load(PasswordRecord.self, from: Paths.passwordFile) }
        catch { log("cannot read password file: \(error)"); passwordUnreadable = true }
        var state = BlockState()
        do { state = try Storage.load(BlockState.self, from: Paths.stateFile) ?? BlockState() }
        catch { log("cannot read state file, starting with an empty list: \(error)") }

        let service = SiteLockService(
            state: state, password: password, passwordUnreadable: passwordUnreadable,
            hasher: SystemPasswordHasher(),
            saveState: { try Storage.save($0, to: Paths.stateFile) },
            savePassword: { try Storage.save($0, to: Paths.passwordFile) },
            enforce: { [unowned self] changed, only in self.enforce(changed: changed, only: only) },
            uninstall: { [unowned self] in self.beginUninstall() },
            log: { log($0) })
        self.service = service

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
        timer.setEventHandler { service.tick(now: Date()) }
        self.timer = timer

        listener.resume()
        timer.resume()
        log("started; \(state.domains.count) domain(s), password \(password == nil ? "not set" : "set")")
    }

    // MARK: - Wiring for the service

    /// Applies the state in every browser (or only `bundleID`). Returns the bundle ids of the
    /// browsers that were quit, all of them in one pass. With `bundleID` and `changed == false`
    /// the browser was just switched off: it is quit so it drops the policy.
    private func enforce(changed: Bool, only bundleID: String?) -> [String] {
        let now = Date()
        var toQuit: [String] = []
        for enforcer in enforcers where bundleID == nil || enforcer.bundleID == bundleID {
            toQuit += enforcer.enforce(service.state, now: now, changed: changed)
        }
        if let bundleID, !changed { toQuit = [bundleID] }
        return quit(toQuit)
    }

    /// Quits the given browsers together; returns the bundle ids that were running.
    private func quit(_ bundleIDs: [String]) -> [String] {
        let browsers = bundleIDs.compactMap { Browser.byID($0) }
        let names = Set(BrowserProcess.quit(processNames: browsers.map(\.processName)))
        return browsers.filter { names.contains($0.processName) }.map(\.id)
    }

    /// The service answers first; then this stops enforcing, removes everything
    /// (Installer.removeFiles) and unloads this LaunchDaemon, which ends this process.
    private func beginUninstall() {
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            timer?.cancel()
            listener?.cancel()
            Installer.removeFiles()
            runTool("/bin/launchctl", ["bootout", "system/\(Paths.launchDaemonLabel)"])
            exit(0)
        }
    }

    // MARK: - Requests

    /// Runs on `ioQueue`; only the service touches state, on `queue`.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, 2)
        let response: Response
        if let line = UnixSocket.readLine(fd, deadline: Date().addingTimeInterval(5)),
           let request = try? Wire.decode(Request.self, from: line) {
            // Only `setup` needs to know whether the caller is an admin (it spawns a tool).
            let client = Self.client(of: fd, needsAdmin: request.command == .setup)
            response = queue.sync { service.handle(request, from: client, now: Date()) }
        } else {
            response = .failure("Malformed request")
        }
        if let data = try? Wire.encode(response) { _ = UnixSocket.writeAll(fd, data) }
    }
}

extension Daemon {
    /// The peer of the connected socket `fd`. If its uid cannot be read, it is uid `UInt32.max`
    /// and not an admin.
    static func client(of fd: Int32, needsAdmin: Bool) -> Client {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return Client(uid: UInt32.max, isAdmin: false) }
        return Client(uid: uid, isAdmin: needsAdmin && isAdmin(uid: uid))
    }

    /// Root, or a member of the `admin` group.
    static func isAdmin(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return false }
        let output = runToolOutput("/usr/bin/dsmemberutil",
                                   ["checkmembership", "-U", String(cString: name), "-G", "admin"])
        return output?.contains("user is a member of the group") ?? false
    }
}

/// `PasswordHasher` (CommonCrypto) behind the core's password protocol.
private struct SystemPasswordHasher: PasswordHashing {
    func makeRecord(password: String) throws -> PasswordRecord {
        try PasswordHasher.makeRecord(password: password)
    }

    func verify(password: String, against record: PasswordRecord) throws -> Bool {
        try PasswordHasher.verify(password: password, against: record)
    }
}
