import CryptoKit
import XCTest
@testable import VaultSquire

final class OnePasswordSnapshotCacheTests: XCTestCase {
    private let account = OnePasswordAccountService.accountID
    private let key = SymmetricKey(size: .bits256)

    private func makeCache() -> OnePasswordSnapshotCache {
        let sealingKey = key
        return OnePasswordSnapshotCache(keyProvider: { sealingKey }, directory: makeDirectory())
    }

    /// A fresh temporary directory, removed when the test finishes.
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquire1PCache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeSnapshot() -> OnePasswordSnapshot {
        OnePasswordSnapshot(
            cliVersion: "2.38.1",
            accountIdentifier: "ACCOUNT1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            vaults: [OnePasswordVault(vaultID: "VAULT1", name: "Private")],
            items: [
                OnePasswordItem(
                    itemID: "ITEM1",
                    vaultID: "VAULT1",
                    vaultName: "Private",
                    category: .login,
                    title: "Example Service",
                    username: "squire@example.com",
                    additionalInformation: nil,
                    urls: ["https://example.com"]
                )
            ]
        )
    }

    func testRoundTripsASealedSnapshot() throws {
        let cache = makeCache()
        let snapshot = makeSnapshot()
        try cache.save(snapshot, for: account)
        XCTAssertTrue(cache.exists(for: account))
        XCTAssertEqual(try cache.load(for: account), snapshot)
    }

    func testReportsNoSnapshotBeforeAnythingIsSaved() throws {
        let cache = makeCache()
        XCTAssertFalse(cache.exists(for: account))
        XCTAssertNil(try cache.load(for: account))
    }

    func testASnapshotIsAlwaysMarkedLossy() throws {
        let cache = makeCache()
        try cache.save(makeSnapshot(), for: account)
        XCTAssertTrue(try XCTUnwrap(cache.load(for: account)).lossy)
    }

    /// The seal is bound to a device key, so another device's key cannot open
    /// the blob — it fails closed rather than returning partial content.
    func testAnotherKeyCannotOpenTheSeal() throws {
        let directory = makeDirectory()

        let mine = SymmetricKey(size: .bits256)
        let theirs = SymmetricKey(size: .bits256)
        try OnePasswordSnapshotCache(keyProvider: { mine }, directory: directory)
            .save(makeSnapshot(), for: account)

        let foreign = OnePasswordSnapshotCache(keyProvider: { theirs }, directory: directory)
        XCTAssertThrowsError(try foreign.load(for: account)) { error in
            XCTAssertEqual(error as? OnePasswordSnapshotCacheError, .corrupt)
        }
    }

    /// The seal authenticates the account identity, so a blob moved into
    /// another account's slot cannot be opened as that account's data.
    func testASnapshotSealedForAnotherAccountFailsClosed() throws {
        let directory = makeDirectory()

        let sealingKey = key
        let cache = OnePasswordSnapshotCache(keyProvider: { sealingKey }, directory: directory)
        let other = AccountID(provider: .onePasswordCLI, rawValue: "other-account")

        try cache.save(makeSnapshot(), for: other)
        let otherFile = try XCTUnwrap(Self.files(in: directory).first)
        let otherBytes = try Data(contentsOf: otherFile)

        try cache.save(makeSnapshot(), for: account)
        let mySlot = try XCTUnwrap(Self.files(in: directory).first { $0 != otherFile })

        // Drop the other account's sealed blob into this account's slot.
        try otherBytes.write(to: mySlot)

        XCTAssertThrowsError(try cache.load(for: account)) { error in
            XCTAssertEqual(error as? OnePasswordSnapshotCacheError, .corrupt)
        }
    }

    func testTamperedBytesFailClosed() throws {
        let directory = makeDirectory()
        let sealingKey = key
        let cache = OnePasswordSnapshotCache(keyProvider: { sealingKey }, directory: directory)
        try cache.save(makeSnapshot(), for: account)

        let file = try XCTUnwrap(Self.files(in: directory).first)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: file)

        XCTAssertThrowsError(try cache.load(for: account)) { error in
            XCTAssertEqual(error as? OnePasswordSnapshotCacheError, .corrupt)
        }
    }

    /// The payload must never rest as readable JSON: only the sealed envelope
    /// reaches disk.
    func testNothingReadableReachesDisk() throws {
        let directory = makeDirectory()
        let sealingKey = key
        let cache = OnePasswordSnapshotCache(keyProvider: { sealingKey }, directory: directory)
        try cache.save(makeSnapshot(), for: account)

        let file = try XCTUnwrap(Self.files(in: directory).first)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(text.contains("Example Service"))
        XCTAssertFalse(text.contains("squire@example.com"))
        XCTAssertFalse(text.contains("example.com"))
        // The filename is a hash of the account identity, leaking nothing.
        XCTAssertFalse(file.lastPathComponent.contains("onepassword-cli-primary"))
    }

    func testWipeRemovesTheSnapshot() throws {
        let cache = makeCache()
        try cache.save(makeSnapshot(), for: account)
        try cache.wipe(for: account)
        XCTAssertFalse(cache.exists(for: account))
        XCTAssertNil(try cache.load(for: account))
    }

    func testWipingWhenNothingIsStoredIsHarmless() throws {
        XCTAssertNoThrow(try makeCache().wipe(for: account))
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
    }
}
