import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VaultSquire

/// The chord rules: what is refused, and what a corrupt preference reads as.
///
/// Registration itself is not exercised here — `RegisterEventHotKey` claims a
/// chord system-wide, and a test process that grabbed Command-Shift-Space from
/// the machine running CI would be a poor citizen. What is testable without a
/// window server is the validation and the round trip, which is where the rules
/// live.
@MainActor
final class QuickSearchShortcutTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "VSQ-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAbsentPreferenceReadsAsTheDefaultAndIsNotARejection() {
        let read = QuickSearchShortcutStore.read(from: makeDefaults())
        XCTAssertEqual(read.shortcut, .default)
        XCTAssertFalse(read.wasRejected, "a never-configured install is not a fault")
        XCTAssertEqual(read.shortcut.displayName, "Command-Shift-Space")
    }

    /// The one refusal that matters more for a global chord than it did for a
    /// menu shortcut: without a modifier it would swallow that key in every
    /// application on the Mac.
    func testAChordThatWouldSwallowOrdinaryTypingIsRefused() {
        let k = UInt32(kVK_ANSI_K)
        XCTAssertNil(QuickSearchShortcut(keyCode: k, modifiers: []))
        XCTAssertNil(QuickSearchShortcut(keyCode: k, modifiers: [.shift]),
                     "Shift alone still types a character")
        XCTAssertNotNil(QuickSearchShortcut(keyCode: k, modifiers: [.command]))
        XCTAssertNotNil(QuickSearchShortcut(keyCode: k, modifiers: [.control, .option]))
        XCTAssertNotNil(QuickSearchShortcut(keyCode: k, modifiers: [.option, .shift]))
    }

    func testKeysThatBelongToSomethingElseAreRefused() {
        for keyCode in [kVK_Escape, kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter] {
            XCTAssertNil(
                QuickSearchShortcut(keyCode: UInt32(keyCode), modifiers: [.command, .option]),
                "\(keyCode)"
            )
        }
    }

    /// A global chord does not collide with another app's menu — the system
    /// refuses the registration instead — but it does collide with ours.
    func testVaultSquiresOwnChordsAreRefused() {
        XCTAssertNil(QuickSearchShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: [.command, .shift]))
        XCTAssertNil(QuickSearchShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command]))
        XCTAssertNil(QuickSearchShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: [.command, .shift]))
        XCTAssertNil(QuickSearchShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command]))
        // Same key, different chord: only the exact combination is taken.
        XCTAssertNotNil(QuickSearchShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: [.command, .option]))
    }

    func testStrayModifierStateBitsAreStrippedRatherThanRefused() {
        let shortcut = QuickSearchShortcut(
            keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .capsLock, .function]
        )
        XCTAssertEqual(shortcut?.modifiers, [.command])
    }

    /// Carbon's modifier mask uses different bit positions from Cocoa's, and
    /// registering with the wrong one silently claims the wrong chord.
    func testCarbonModifiersAreTranslatedNotReused() {
        let shortcut = QuickSearchShortcut(
            keyCode: UInt32(kVK_Space), modifiers: [.command, .shift]
        )
        XCTAssertEqual(shortcut?.carbonModifiers, UInt32(cmdKey | shiftKey))

        let all = QuickSearchShortcut(
            keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .control, .option, .shift]
        )
        XCTAssertEqual(all?.carbonModifiers, UInt32(cmdKey | controlKey | optionKey | shiftKey))
    }

    func testACorruptStoredValueReadsAsTheDefaultAndSaysSo() {
        let cases: [(Any, [String])] = [
            (0, ["command"]),                          // no key code
            (999, ["command"]),                        // not a virtual key code
            (Int(kVK_ANSI_K), []),                     // no modifiers
            (Int(kVK_ANSI_K), ["shift"]),              // shift alone
            (Int(kVK_ANSI_K), ["comand"]),             // misspelled name
            (Int(kVK_Escape), ["command", "option"]),  // a key that is spoken for
        ]
        for (keyCode, modifiers) in cases {
            let defaults = makeDefaults()
            defaults.set(keyCode, forKey: QuickSearchShortcutStore.keyDefaultsKey)
            defaults.set(modifiers, forKey: QuickSearchShortcutStore.modifiersDefaultsKey)
            let read = QuickSearchShortcutStore.read(from: defaults)
            XCTAssertEqual(read.shortcut, .default, "\(keyCode) \(modifiers)")
            XCTAssertTrue(read.wasRejected, "\(keyCode) \(modifiers)")
        }
    }

    /// The stored form is a key code and modifier names, both hand-editable —
    /// a bit mask spelled `1179648` is the kind of value someone mis-edits.
    func testAStoredChordRoundTripsThroughItsWrittenForm() {
        let defaults = makeDefaults()
        let chord = QuickSearchShortcut(
            keyCode: UInt32(kVK_ANSI_K), modifiers: [.control, .option]
        )!
        defaults.set(Int(chord.keyCode), forKey: QuickSearchShortcutStore.keyDefaultsKey)
        defaults.set(["control", "option"], forKey: QuickSearchShortcutStore.modifiersDefaultsKey)

        let read = QuickSearchShortcutStore.read(from: defaults)
        XCTAssertEqual(read.shortcut, chord)
        XCTAssertFalse(read.wasRejected)
        XCTAssertEqual(read.shortcut.displayName, "Control-Option-K")
    }

    /// The default is deliberately not the chord the author's other menu-bar
    /// app registers: two apps racing for one chord is a bad first run for
    /// whichever loses.
    func testTheDefaultIsNotTheSiblingApplicationsChord() {
        XCTAssertNotEqual(
            QuickSearchShortcut.default,
            QuickSearchShortcut(keyCode: UInt32(kVK_Space), modifiers: [.control, .option])
        )
        XCTAssertEqual(QuickSearchShortcut.default.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(QuickSearchShortcut.default.modifiers, [.command, .shift])
    }

    func testNamedKeysAreSpelledOut() {
        XCTAssertEqual(QuickSearchShortcut.keyName(UInt32(kVK_Space)), "Space")
        XCTAssertEqual(QuickSearchShortcut.keyName(UInt32(kVK_F1)), "F1")
        XCTAssertEqual(QuickSearchShortcut.keyName(UInt32(kVK_UpArrow)), "Up Arrow")
    }
}
