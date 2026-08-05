import XCTest
@testable import VaultSquire

/// Deterministic SplitMix64 generator so the bounded PR fuzz smoke is
/// reproducible: a failing input can be recovered from its iteration index.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Bounded fuzz smoke for the pull-request lane (SECURITY_AND_TESTING.md
/// fuzz targets: base64 and encrypted-string parser; KDF parameter decoder
/// and arithmetic). Extended fuzzing belongs to a scheduled lane, not here.
final class VaultwardenCryptoFuzzTests: XCTestCase {
    func testEncStringParserSurvivesRandomInputs() {
        var generator = SplitMix64(seed: 0x5153_4652_555A_5A31)
        // Structural characters, the base64 alphabet, and hostile scalars: a
        // NUL, a multi-byte letter, and a replacement character. The last three
        // are written as escapes so they cannot be mistaken for mojibake, and
        // so a future editor cannot silently normalize them away.
        let alphabet = Array(
            "0123456789.|+/=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz%"
                + "\u{0}\u{E9}\u{FFFD}FF"
        )

        for _ in 0..<8_000 {
            let length = Int(generator.next() % 120)
            var input = ""
            for _ in 0..<length {
                let index = Int(generator.next() % UInt64(alphabet.count))
                input.append(alphabet[index])
            }

            do {
                _ = try VaultwardenEncString.parse(input)
            } catch let error as VaultwardenCryptoError {
                switch error {
                case .integrityFailure, .unsupportedEncryptionType,
                     .legacyEncryptionDetected:
                    continue
                case .argon2idUnavailable, .invalidKDFParameters,
                     .invalidKeyMaterial:
                    XCTFail("parser threw a non-parser error for \(input)")
                }
            } catch {
                XCTFail("parser threw an untyped error for \(input)")
            }
        }
    }

    func testEncStringParserSurvivesMutatedValidInputs() {
        var generator = SplitMix64(seed: 0x5153_4652_555A_5A32)
        let valid = VaultwardenCryptoFixtures.itemEncString

        for _ in 0..<4_000 {
            var characters = Array(valid)
            let mutations = 1 + Int(generator.next() % 4)
            for _ in 0..<mutations {
                let index = Int(generator.next() % UInt64(characters.count))
                let replacement = Character(
                    UnicodeScalar(UInt8(33 + generator.next() % 90))
                )
                characters[index] = replacement
            }

            do {
                _ = try VaultwardenEncString.parse(String(characters))
            } catch let error as VaultwardenCryptoError {
                switch error {
                case .integrityFailure, .unsupportedEncryptionType,
                     .legacyEncryptionDetected:
                    continue
                default:
                    XCTFail("unexpected error case for mutated input")
                }
            } catch {
                XCTFail("untyped error for mutated input")
            }
        }
    }

    func testKDFParameterArithmeticNeverTraps() {
        var generator = SplitMix64(seed: 0x5153_4652_555A_5A33)
        var extremes: [Int] = [
            Int.min, Int.min + 1, -1, 0, 1,
            4_999, 5_000, 600_000, 2_000_000, 2_000_001,
            Int.max - 1, Int.max,
        ]
        for _ in 0..<200 {
            extremes.append(Int(bitPattern: UInt(truncatingIfNeeded: generator.next())))
        }

        for iterations in extremes {
            for memory in extremes.shuffled(using: &generator).prefix(8) {
                for parallelism in extremes.shuffled(using: &generator).prefix(4) {
                    let configuration = VaultwardenKDFConfiguration.argon2id(
                        iterations: iterations,
                        memoryMiB: memory,
                        parallelism: parallelism
                    )
                    do {
                        try configuration.validate()
                    } catch let error as VaultwardenCryptoError {
                        guard case .invalidKDFParameters = error else {
                            return XCTFail("unexpected error \(error)")
                        }
                    } catch {
                        return XCTFail("untyped validation error")
                    }
                }
            }
            do {
                try VaultwardenKDFConfiguration
                    .pbkdf2SHA256(iterations: iterations)
                    .validate()
            } catch let error as VaultwardenCryptoError {
                guard case .invalidKDFParameters = error else {
                    return XCTFail("unexpected error \(error)")
                }
            } catch {
                return XCTFail("untyped validation error")
            }
        }
    }
}
