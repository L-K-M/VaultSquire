import XCTest
@testable import VaultSquire

final class PasswordGeneratorTests: XCTestCase {
    func testGeneratedPasswordHonoursLengthAndEveryEnabledClass() {
        let options = PasswordGenerator.Options(length: 24)
        for _ in 0..<100 {
            let password = PasswordGenerator.generate(options: options)
            XCTAssertEqual(password.count, 24)
            XCTAssertTrue(password.contains(where: \.isLowercase), "lowercase present")
            XCTAssertTrue(password.contains(where: \.isUppercase), "uppercase present")
            XCTAssertTrue(password.contains(where: \.isNumber), "digit present")
            XCTAssertTrue(password.contains(where: { !$0.isLetter && !$0.isNumber }), "symbol present")
        }
    }

    func testDisabledClassesNeverAppear() {
        var options = PasswordGenerator.Options(length: 32)
        options.includeDigits = false
        options.includeSymbols = false
        for _ in 0..<100 {
            let password = PasswordGenerator.generate(options: options)
            XCTAssertTrue(password.allSatisfy(\.isLetter))
        }
    }

    func testAllClassesDisabledFallsBackToAlphanumeric() {
        var options = PasswordGenerator.Options(length: 16)
        options.includeUppercase = false
        options.includeLowercase = false
        options.includeDigits = false
        options.includeSymbols = false
        let password = PasswordGenerator.generate(options: options)
        XCTAssertEqual(password.count, 16)
        XCTAssertFalse(password.isEmpty)
        XCTAssertTrue(password.allSatisfy(\.isLetter) || password.allSatisfy(\.isHexDigit))
    }

    func testLengthIsClampedToTheSupportedRange() {
        let short = PasswordGenerator.generate(options: .init(length: 1))
        XCTAssertGreaterThanOrEqual(short.count, PasswordGenerator.Options.minimumLength)

        let long = PasswordGenerator.generate(options: .init(length: 500))
        XCTAssertEqual(long.count, PasswordGenerator.Options.maximumLength)
    }

    func testSuccessivePasswordsDiffer() {
        let options = PasswordGenerator.Options()
        let first = PasswordGenerator.generate(options: options)
        let second = PasswordGenerator.generate(options: options)
        XCTAssertNotEqual(first, second)
    }
}
