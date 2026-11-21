import Foundation
import SiteLockCore

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) sitelockd: \(message)\n".utf8))
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
