import Foundation
import SiteLockCore

// sitelockd run              – the LaunchDaemon (root)
// sitelockd verify-password  – reads a password from stdin; exit 0 if it matches (used by uninstall.sh)
// sitelockd clear-policy     – removes SiteLock's keys from the Firefox policy (used by uninstall.sh)

func requireRoot() {
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("sitelockd: must run as root\n".utf8))
        exit(77)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "run":
    requireRoot()
    signal(SIGPIPE, SIG_IGN)
    let daemon = Daemon(enforcers: [FirefoxEnforcer()])
    do { try daemon.start() } catch { log("failed to start: \(error)"); exit(1) }
    dispatchMain()

case "verify-password":
    requireRoot()
    let record: PasswordRecord?
    do { record = try Storage.load(PasswordRecord.self, from: Paths.passwordFile) }
    catch { log("cannot read password file: \(error)"); exit(1) }
    guard let record else { print("no password set"); exit(2) }
    let input = readLine(strippingNewline: true) ?? ""
    exit(((try? PasswordHasher.verify(password: input, against: record)) ?? false) ? 0 : 1)

case "clear-policy":
    requireRoot()
    FirefoxEnforcer().clear()

default:
    print("usage: sitelockd run | verify-password | clear-policy")
    exit(64)
}
