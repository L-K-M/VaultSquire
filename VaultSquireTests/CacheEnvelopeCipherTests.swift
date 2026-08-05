import CryptoKit
import XCTest
@testable import VaultSquire

final class CacheEnvelopeCipherTests: XCTestCase {
    private let account = AccountID(provider: .protonCLI, rawValue: "VSQ-Canary-proton")
    private let plaintext = Data("VSQ-Canary-lossy-cli-json-do-not-persist-in-clear".utf8)

    private func context(
        account: AccountID? = nil,
        schemaVersion: Int = 1
    ) -> CacheEnvelopeContext {
        CacheEnvelopeContext(account: account ?? self.account, schemaVersion: schemaVersion)
    }

    func testSealOpenRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        let opened = try CacheEnvelopeCipher.open(sealed, key: key, context: context())
        XCTAssertEqual(opened, plaintext)
    }

    func testSealedOutputContainsNoPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        // The distinctive canary plaintext must not survive anywhere in the
        // sealed bytes: the payload rests encrypted, never in the clear.
        XCTAssertNil(sealed.range(of: plaintext))
    }

    func testDistinctNoncesDefeatDeterministicOutput() throws {
        let key = SymmetricKey(size: .bits256)
        let first = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        let second = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        // Same key, same context, same payload — a random nonce makes the sealed
        // bytes differ, so a repeated snapshot is not fingerprintable.
        XCTAssertNotEqual(first, second)
        // Both still open to the same plaintext.
        XCTAssertEqual(try CacheEnvelopeCipher.open(first, key: key, context: context()), plaintext)
        XCTAssertEqual(try CacheEnvelopeCipher.open(second, key: key, context: context()), plaintext)
    }

    func testWrongKeyFailsClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let otherKey = SymmetricKey(size: .bits256)
        let sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        XCTAssertThrowsError(try CacheEnvelopeCipher.open(sealed, key: otherKey, context: context())) { error in
            XCTAssertEqual(error as? CacheEnvelopeCipherError, .openFailed)
        }
    }

    func testTamperedCiphertextFailsClosed() throws {
        let key = SymmetricKey(size: .bits256)
        var sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        // Flip the final byte (part of the authentication tag).
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try CacheEnvelopeCipher.open(sealed, key: key, context: context())) { error in
            XCTAssertEqual(error as? CacheEnvelopeCipherError, .openFailed)
        }
    }

    func testMismatchedSchemaVersionFailsClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context(schemaVersion: 1))
        XCTAssertThrowsError(
            try CacheEnvelopeCipher.open(sealed, key: key, context: context(schemaVersion: 2))
        ) { error in
            XCTAssertEqual(error as? CacheEnvelopeCipherError, .openFailed)
        }
    }

    func testMismatchedAccountFailsClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        let otherAccount = AccountID(provider: .protonCLI, rawValue: "VSQ-Canary-other")
        XCTAssertThrowsError(
            try CacheEnvelopeCipher.open(sealed, key: key, context: context(account: otherAccount))
        ) { error in
            XCTAssertEqual(error as? CacheEnvelopeCipherError, .openFailed)
        }
    }

    func testMismatchedProviderFailsClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try CacheEnvelopeCipher.seal(plaintext, key: key, context: context())
        // Same raw account identifier, different provider namespace.
        let crossProvider = AccountID(provider: .vaultwarden, rawValue: account.rawValue)
        XCTAssertThrowsError(
            try CacheEnvelopeCipher.open(sealed, key: key, context: context(account: crossProvider))
        ) { error in
            XCTAssertEqual(error as? CacheEnvelopeCipherError, .openFailed)
        }
    }

    // MARK: DatabaseKey

    func testDatabaseKeyGeneratesDistinctFullWidthKeys() {
        let first = DatabaseKey.generated()
        let second = DatabaseKey.generated()
        XCTAssertEqual(first.rawKey.count, DatabaseKey.rawKeyByteCount)
        XCTAssertEqual(second.rawKey.count, DatabaseKey.rawKeyByteCount)
        XCTAssertNotEqual(first.rawKey, second.rawKey)
    }

    func testDatabaseKeyRejectsWrongWidth() {
        XCTAssertNil(DatabaseKey(rawKey: Data()))
        XCTAssertNil(DatabaseKey(rawKey: Data(repeating: 0, count: DatabaseKey.rawKeyByteCount - 1)))
        XCTAssertNil(DatabaseKey(rawKey: Data(repeating: 0, count: DatabaseKey.rawKeyByteCount + 1)))
        XCTAssertNotNil(DatabaseKey(rawKey: Data(repeating: 0, count: DatabaseKey.rawKeyByteCount)))
    }
}
