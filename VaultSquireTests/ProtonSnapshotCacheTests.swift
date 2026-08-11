import CryptoKit
import XCTest
@testable import VaultSquire

final class ProtonSnapshotCacheTests: XCTestCase {
    private let account = AccountID(provider: .protonCLI, rawValue: "VSQ-proton-account")
    private let otherAccount = AccountID(provider: .protonCLI, rawValue: "VSQ-proton-other")

    private func makeCache(key: SymmetricKey) -> (ProtonSnapshotCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquireProtonTests-\(UUID().uuidString)", isDirectory: true)
        let cache = ProtonSnapshotCache(keyProvider: { key }, directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (cache, directory)
    }

    private func makeSnapshot(cliVersion: String = "2.2.4") -> ProtonSnapshot {
        ProtonSnapshot(
            cliVersion: cliVersion,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            vaults: [ProtonVault(shareID: "S1", vaultID: "V1", name: "Personal")],
            items: [
                ProtonItem(
                    itemID: "i1", shareID: "S1", vaultName: "Personal", type: .login,
                    title: "GitHub", username: "octocat", password: "VSQ-secret",
                    totp: "otpauth://x", urls: ["https://github.com"], note: nil
                )
            ]
        )
    }

    func testSaveThenLoadRoundTrips() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        let snapshot = makeSnapshot()
        XCTAssertNil(snapshot.items.first?.password)
        XCTAssertNil(snapshot.items.first?.totp)
        XCTAssertNil(snapshot.items.first?.note)

        XCTAssertFalse(cache.exists(for: account))
        try cache.save(snapshot, for: account)
        XCTAssertTrue(cache.exists(for: account))

        let loaded = try cache.load(for: account)
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded?.lossy, true)
    }

    func testLoadMissingReturnsNil() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        XCTAssertNil(try cache.load(for: account))
    }

    func testSaveIsAccountScoped() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        try cache.save(makeSnapshot(), for: account)
        XCTAssertNil(try cache.load(for: otherAccount))
    }

    func testTamperedFileFailsClosed() throws {
        let (cache, directory) = makeCache(key: SymmetricKey(size: .bits256))
        try cache.save(makeSnapshot(), for: account)

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "protoncache" }
        )
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: file)

        XCTAssertThrowsError(try cache.load(for: account)) { error in
            XCTAssertEqual(error as? ProtonSnapshotCacheError, .corrupt)
        }
    }

    func testOversizedCacheFileIsRejectedBeforeOpening() throws {
        let (cache, directory) = makeCache(key: SymmetricKey(size: .bits256))
        try cache.save(makeSnapshot(), for: account)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "protoncache" }
        )
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(8 * 1024 * 1024 + 1))
        try handle.close()

        XCTAssertThrowsError(try cache.load(for: account)) { error in
            XCTAssertEqual(error as? ProtonSnapshotCacheError, .corrupt)
        }
    }

    func testWrongKeyFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquireProtonTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let writer = ProtonSnapshotCache(keyProvider: { SymmetricKey(size: .bits256) }, directory: directory)
        try writer.save(makeSnapshot(), for: account)

        let reader = ProtonSnapshotCache(keyProvider: { SymmetricKey(size: .bits256) }, directory: directory)
        XCTAssertThrowsError(try reader.load(for: account)) { error in
            XCTAssertEqual(error as? ProtonSnapshotCacheError, .corrupt)
        }
    }

    func testWipeRemovesTheFile() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        try cache.save(makeSnapshot(), for: account)
        XCTAssertTrue(cache.exists(for: account))

        try cache.wipe(for: account)
        XCTAssertFalse(cache.exists(for: account))
        XCTAssertNil(try cache.load(for: account))
    }
}
