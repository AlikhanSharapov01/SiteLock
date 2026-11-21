import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
import Security
#endif

/// Stored form of the SiteLock password: only salt + PBKDF2-HMAC-SHA256 output, never the password.
public struct PasswordRecord: Codable, Equatable, Sendable {
    public var algorithm: String
    public var iterations: Int
    public var salt: Data
    public var hash: Data
}

public enum PasswordError: Error, Equatable, CustomStringConvertible {
    case tooShort(Int)
    case unsupportedAlgorithm(String)
    case cryptoFailure(Int32)

    public var description: String {
        switch self {
        case .tooShort(let n): return "Password must be at least \(n) characters"
        case .unsupportedAlgorithm(let a): return "Unsupported password algorithm: \(a)"
        case .cryptoFailure(let c): return "Key derivation failed (status \(c))"
        }
    }
}

#if canImport(CommonCrypto)
public enum PasswordHasher {
    public static let algorithm = "PBKDF2-HMAC-SHA256"
    /// OWASP 2023 recommendation for PBKDF2-HMAC-SHA256.
    public static let defaultIterations = 600_000
    public static let minimumLength = 6
    static let saltLength = 16
    static let keyLength = 32

    public static func makeRecord(password: String, iterations: Int = defaultIterations) throws -> PasswordRecord {
        guard password.count >= minimumLength else { throw PasswordError.tooShort(minimumLength) }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw PasswordError.cryptoFailure(status) }
        let hash = try derive(password: password, salt: salt, iterations: iterations, length: keyLength)
        return PasswordRecord(algorithm: algorithm, iterations: iterations, salt: salt, hash: hash)
    }

    public static func verify(password: String, against record: PasswordRecord) throws -> Bool {
        guard record.algorithm == algorithm else { throw PasswordError.unsupportedAlgorithm(record.algorithm) }
        let candidate = try derive(password: password, salt: record.salt,
                                   iterations: record.iterations, length: record.hash.count)
        return constantTimeEquals(candidate, record.hash)
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto.
    public static func derive(password: String, salt: Data, iterations: Int, length: Int) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    outBuf.bindMemory(to: UInt8.self).baseAddress, length)
            }
        }
        guard status == Int32(kCCSuccess) else { throw PasswordError.cryptoFailure(status) }
        return out
    }
}
#endif

/// Compares without an early exit so timing does not reveal the matching prefix length.
public func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
