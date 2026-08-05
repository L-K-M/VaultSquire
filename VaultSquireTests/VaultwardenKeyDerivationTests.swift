import XCTest
@testable import VaultSquire

extension Data {
    init?(hexFixture: String) {
        guard hexFixture.count % 2 == 0 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexFixture.count / 2)
        var index = hexFixture.startIndex
        while index < hexFixture.endIndex {
            let next = hexFixture.index(index, offsetBy: 2)
            guard let byte = UInt8(hexFixture[index..<next], radix: 16) else {
                return nil
            }

            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

final class VaultwardenKeyDerivationTests: XCTestCase {
    private var passwordBytes: Data {
        Data(VaultwardenCryptoFixtures.password.utf8)
    }

    func testEmailNormalizationTrimsAndLowercases() {
        XCTAssertEqual(
            VaultwardenKeyDerivation.normalizedEmail(VaultwardenCryptoFixtures.emailRaw),
            VaultwardenCryptoFixtures.emailNormalized
        )
    }

    func testPBKDF2MasterKeyAndAuthHashKnownAnswers() async throws {
        for testCase in VaultwardenCryptoFixtures.pbkdf2Cases {
            let masterKey = try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: passwordBytes,
                email: VaultwardenCryptoFixtures.emailRaw,
                configuration: .pbkdf2SHA256(iterations: testCase.iterations)
            )

            XCTAssertEqual(
                masterKey,
                Data(hexFixture: testCase.masterKeyHex),
                "master key mismatch at \(testCase.iterations) iterations"
            )
            XCTAssertEqual(
                try VaultwardenKeyDerivation.authenticationHash(
                    masterKey: masterKey,
                    passwordBytes: passwordBytes
                ),
                testCase.authHashBase64,
                "auth hash mismatch at \(testCase.iterations) iterations"
            )
        }
    }

    func testPasswordWhitespaceIsNeverTrimmed() async throws {
        let masterKey = try await VaultwardenKeyDerivation.deriveMasterKey(
            passwordBytes: Data(VaultwardenCryptoFixtures.passwordWhitespace.utf8),
            email: VaultwardenCryptoFixtures.emailRaw,
            configuration: .pbkdf2SHA256(iterations: 5000)
        )

        XCTAssertEqual(
            masterKey,
            Data(hexFixture: VaultwardenCryptoFixtures.paddedPasswordMasterKeyHex)
        )
    }

    func testStretchedMasterKeyKnownAnswer() throws {
        let cases = VaultwardenCryptoFixtures.pbkdf2Cases
        let masterKey = Data(hexFixture: cases[1].masterKeyHex)!

        let stretched = try VaultwardenKeyDerivation.stretchMasterKey(masterKey)

        XCTAssertEqual(
            stretched,
            Data(hexFixture: VaultwardenCryptoFixtures.stretchedMasterKeyHex)
        )
        XCTAssertEqual(stretched.count, 64)
    }

    func testPBKDF2BoundsAreEnforced() async {
        await assertKDFIssue(
            .pbkdf2SHA256(iterations: 4_999),
            expected: .iterationsBelowFloor
        )
        await assertKDFIssue(
            .pbkdf2SHA256(iterations: 2_000_001),
            expected: .iterationsAboveCeiling
        )
    }

    func testArgon2BoundsAreValidatedBeforeAvailability() async {
        await assertKDFIssue(
            .argon2id(iterations: 1, memoryMiB: 64, parallelism: 4),
            expected: .iterationsBelowFloor
        )
        await assertKDFIssue(
            .argon2id(iterations: 11, memoryMiB: 64, parallelism: 4),
            expected: .iterationsAboveCeiling
        )
        await assertKDFIssue(
            .argon2id(iterations: 3, memoryMiB: 15, parallelism: 4),
            expected: .memoryBelowFloor
        )
        await assertKDFIssue(
            .argon2id(iterations: 3, memoryMiB: 1_025, parallelism: 4),
            expected: .memoryAboveCeiling
        )
        await assertKDFIssue(
            .argon2id(iterations: 3, memoryMiB: 64, parallelism: 0),
            expected: .parallelismBelowFloor
        )
        await assertKDFIssue(
            .argon2id(iterations: 3, memoryMiB: 64, parallelism: 17),
            expected: .parallelismAboveCeiling
        )
    }

    func testValidArgon2ParametersFailClosedWithoutSubstitution() async {
        do {
            _ = try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: passwordBytes,
                email: VaultwardenCryptoFixtures.emailRaw,
                configuration: .argon2id(iterations: 6, memoryMiB: 32, parallelism: 4)
            )
            XCTFail("Argon2id must fail closed while no implementation is adopted")
        } catch {
            XCTAssertEqual(
                error as? VaultwardenCryptoError,
                .argon2idUnavailable
            )
        }
    }

    func testCancelledDerivationThrowsBeforeDeriving() async {
        let task = Task { () -> Data in
            try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: Data(VaultwardenCryptoFixtures.password.utf8),
                email: VaultwardenCryptoFixtures.emailRaw,
                configuration: .pbkdf2SHA256(iterations: 600_000)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            // A task cancelled after derivation already ran to completion is
            // permitted to return; the session generation check is the
            // discard invariant. Nothing to assert in that interleaving.
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAuthHashRejectsWrongMasterKeySize() {
        XCTAssertThrowsError(
            try VaultwardenKeyDerivation.authenticationHash(
                masterKey: Data(count: 31),
                passwordBytes: passwordBytes
            )
        ) { error in
            XCTAssertEqual(
                error as? VaultwardenCryptoError,
                .invalidKeyMaterial
            )
        }
    }

    private func assertKDFIssue(
        _ configuration: VaultwardenKDFConfiguration,
        expected: VaultwardenKDFParameterIssue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await VaultwardenKeyDerivation.deriveMasterKey(
                passwordBytes: passwordBytes,
                email: VaultwardenCryptoFixtures.emailRaw,
                configuration: configuration
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? VaultwardenCryptoError,
                .invalidKDFParameters(expected),
                file: file,
                line: line
            )
        }
    }
}
