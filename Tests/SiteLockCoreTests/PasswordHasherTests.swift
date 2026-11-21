import XCTest
@testable import SiteLockCore

final class ConstantTimeEqualsTests: XCTestCase {
    func testEqualAndUnequal() {
        XCTAssertTrue(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        XCTAssertTrue(constantTimeEquals(Data(), Data()))
    }
}

#if canImport(CommonCrypto)
final class PasswordHasherTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // Expected values computed independently with Python's hashlib.pbkdf2_hmac("sha256", ...).
    func testKnownVectors() throws {
        let salt = Data("salt".utf8)
        XCTAssertEqual(hex(try PasswordHasher.derive(password: "password", salt: salt, iterations: 1, length: 32)),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(try PasswordHasher.derive(password: "password", salt: salt, iterations: 2, length: 32)),
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(hex(try PasswordHasher.derive(password: "password", salt: salt, iterations: 4096, length: 32)),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(hex(try PasswordHasher.derive(password: "passwordPASSWORDpassword",
                                                     salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8),
                                                     iterations: 4096, length: 40)),
                       "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
        XCTAssertEqual(hex(try PasswordHasher.derive(password: "pässwörd", salt: salt, iterations: 1000, length: 32)),
                       "cf2d684cc373233b60f2331556aa47cb35abe3ae19e7c461380769577b523a22")
    }

    func testRecordVerifiesOnlyTheRightPassword() throws {
        let record = try PasswordHasher.makeRecord(password: "correct horse", iterations: 1000)
        XCTAssertEqual(record.algorithm, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(record.salt.count, 16)
        XCTAssertEqual(record.hash.count, 32)
        XCTAssertTrue(try PasswordHasher.verify(password: "correct horse", against: record))
        XCTAssertFalse(try PasswordHasher.verify(password: "correct horsE", against: record))
        XCTAssertFalse(try PasswordHasher.verify(password: "", against: record))
    }

    func testSaltIsRandomPerRecord() throws {
        let a = try PasswordHasher.makeRecord(password: "same password", iterations: 1000)
        let b = try PasswordHasher.makeRecord(password: "same password", iterations: 1000)
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testDefaultsAndMinimumLength() throws {
        XCTAssertGreaterThanOrEqual(PasswordHasher.defaultIterations, 600_000)
        XCTAssertThrowsError(try PasswordHasher.makeRecord(password: "12345")) {
            XCTAssertEqual($0 as? PasswordError, .tooShort(6))
        }
    }

    func testRecordRoundTripsThroughJSONAndHasNoPlaintext() throws {
        let record = try PasswordHasher.makeRecord(password: "hunter22", iterations: 1000)
        let json = try Wire.encode(record)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("hunter22"))
        let decoded = try Wire.decode(PasswordRecord.self, from: json)
        XCTAssertTrue(try PasswordHasher.verify(password: "hunter22", against: decoded))
    }

    func testRejectsUnknownAlgorithm() throws {
        var record = try PasswordHasher.makeRecord(password: "hunter22", iterations: 1000)
        record.algorithm = "MD5"
        XCTAssertThrowsError(try PasswordHasher.verify(password: "hunter22", against: record))
    }
}
#endif
