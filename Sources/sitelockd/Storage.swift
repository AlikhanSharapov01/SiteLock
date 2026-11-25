import Foundation
import os
import SiteLockCore

private let logger = Logger(subsystem: "local.sitelock", category: "sitelockd")

/// Writes to the macOS unified log (no log file on disk). Read it with:
/// log show --last 1h --predicate 'subsystem == "local.sitelock"'
func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
}

/// Runs a command-line tool and returns its exit status (-1 if it could not start).
@discardableResult
func runTool(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log("\(tool) failed: \(error)"); return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// JSON files under /Library/Application Support/SiteLock (root:wheel, dir 0700, files 0600).
enum Storage {
    static func ensureDataDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Paths.dataDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                             ofItemAtPath: Paths.dataDirectory)
    }

    /// Nil if the file does not exist; throws if it exists but cannot be decoded.
    static func load<T: Decodable>(_ type: T.Type, from path: String) throws -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try Wire.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to path: String) throws {
        try Wire.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
