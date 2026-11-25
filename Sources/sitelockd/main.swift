import Foundation
import SiteLockCore

// sitelockd lives inside SiteLock.app (Contents/MacOS/sitelockd).
//   sitelockd run        – the LaunchDaemon itself (started by launchd)
//   sitelockd install    – install or update the LaunchDaemon from this binary (root)
//   sitelockd uninstall  – remove SiteLock; asks for the SiteLock password (root)
//   sitelockd version    – print the version

func requireRoot() {
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("sitelockd: run this with sudo\n".utf8))
        exit(77)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sitelockd: \(message)\n".utf8))
    exit(1)
}

/// The absolute path of this executable.
func ownPath() -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(CommandLine.arguments[0], &buf) != nil else { fail("cannot resolve own path") }
    return String(cString: buf)
}

/// Reads the password without echo from the terminal, or a line from stdin when piped.
func readPassword() -> String {
    if isatty(STDIN_FILENO) != 0, let p = getpass("SiteLock password: ") { return String(cString: p) }
    return readLine(strippingNewline: true) ?? ""
}

switch CommandLine.arguments.dropFirst().first {
case "run":
    requireRoot()
    signal(SIGPIPE, SIG_IGN)
    let daemon = Daemon(enforcers: [FirefoxEnforcer()])
    do { try daemon.start() } catch { log("failed to start: \(error)"); exit(1) }
    dispatchMain()

case "install":
    requireRoot()
    do { try Installer.install(from: ownPath()) } catch { fail("\(error)") }
    print("SiteLock \(SiteLockVersion.current) is installed and running. Open SiteLock.app to set your password.")

case "uninstall":
    requireRoot()
    if FileManager.default.fileExists(atPath: Paths.passwordFile) {
        guard let record = try? Storage.load(PasswordRecord.self, from: Paths.passwordFile) else {
            fail("cannot read \(Paths.passwordFile); nothing was removed")
        }
        guard (try? PasswordHasher.verify(password: readPassword(), against: record)) == true else {
            fail("wrong password; nothing was removed")
        }
    }
    Installer.stopService()
    Installer.removeFiles()
    print("SiteLock removed. Restart Firefox so it drops the blocklist, then move SiteLock.app to the Trash.")

case "version":
    print(SiteLockVersion.current)

default:
    print("usage: sitelockd install | uninstall | version | run")
    exit(64)
}
