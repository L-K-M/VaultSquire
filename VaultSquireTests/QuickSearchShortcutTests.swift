import AppKit
import XCTest
@testable import VaultSquire

/// The chord rules: what is refused, and what a corrupt preference reads as.
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

    func testAChordWithNoModifiersIsRefused() {
        XCTAssertNil(QuickSearchShortcut(key: "k", modifiers: []))
        XCTAssertNil(QuickSearchShortcut(key: "k", modifiers: [.shift]))
        XCTAssertNil(QuickSearchShortcut(key: "k", modifiers: [.option]),
                     "Option-k types a character a text field has to receive")
        XCTAssertNotNil(QuickSearchShortcut(key: "k", modifiers: [.command]))
    }

    func testSystemAndAppOwnedChordsAreRefused() {
        XCTAssertNil(QuickSearchShortcut(key: "q", modifiers: [.command]), "Quit")
        XCTAssertNil(QuickSearchShortcut(key: "w", modifiers: [.command]), "Close Window")
        XCTAssertNil(QuickSearchShortcut(key: "\t", modifiers: [.command]), "Command-Tab")
        XCTAssertNil(QuickSearchShortcut(key: "\u{1B}", modifiers: [.command]), "Escape")
        XCTAssertNil(QuickSearchShortcut(key: "l", modifiers: [.command, .shift]), "Lock Vault")
        XCTAssertNil(QuickSearchShortcut(key: "n", modifiers: [.command]), "Add Item")
        XCTAssertNil(QuickSearchShortcut(key: "c", modifiers: [.command, .shift]), "Copy Password")
        XCTAssertNil(QuickSearchShortcut(key: "c", modifiers: [.command, .option]), "Copy Username")
    }

    func testTheKeyIsNormalisedToItsUnshiftedLowercaseForm() {
        // An uppercase key equivalent makes AppKit imply Shift; storing "K"
        // alongside an explicit .shift would ask for Shift twice.
        let shortcut = QuickSearchShortcut(key: "K", modifiers: [.command, .shift])
        XCTAssertEqual(shortcut?.key, "k")
        XCTAssertEqual(shortcut?.displayName, "Command-Shift-K")
    }

    func testStrayModifierStateBitsAreStrippedRatherThanRefused() {
        let shortcut = QuickSearchShortcut(key: "k", modifiers: [.command, .capsLock, .function])
        XCTAssertEqual(shortcut?.modifiers, [.command])
    }

    func testACorruptStoredValueReadsAsTheDefaultAndSaysSo() {
        for (key, modifiers) in [
            ("kk", ["command"]),        // more than one scalar
            ("k", [] as [String]),      // no modifiers
            ("k", ["shift"]),           // no Command
            ("k", ["comand"]),          // misspelled name
            ("q", ["command"]),         // Quit
        ] {
            let defaults = makeDefaults()
            defaults.set(key, forKey: QuickSearchShortcutStore.keyDefaultsKey)
            defaults.set(modifiers, forKey: QuickSearchShortcutStore.modifiersDefaultsKey)
            let read = QuickSearchShortcutStore.read(from: defaults)
            XCTAssertEqual(read.shortcut, .default, "\(key) \(modifiers)")
            XCTAssertTrue(read.wasRejected, "\(key) \(modifiers)")
        }
    }

    func testAStoredChordRoundTrips() {
        let defaults = makeDefaults()
        let store = QuickSearchShortcutStore(defaults: defaults)
        let chord = QuickSearchShortcut(key: "k", modifiers: [.command, .control])!
        store.set(chord)

        let reread = QuickSearchShortcutStore(defaults: defaults)
        XCTAssertEqual(reread.shortcut, chord)
        XCTAssertFalse(reread.storedValueWasRejected)
        XCTAssertEqual(reread.shortcut.displayName, "Command-Control-K")

        reread.resetToDefault()
        XCTAssertNil(defaults.object(forKey: QuickSearchShortcutStore.keyDefaultsKey))
        XCTAssertEqual(QuickSearchShortcutStore(defaults: defaults).shortcut, .default)
    }

    func testNonPrintableKeysKeepTheirAppKitScalarAndGetAName() {
        let up = QuickSearchShortcut(key: "\u{F700}", modifiers: [.command, .shift])
        XCTAssertEqual(up?.displayName, "Command-Shift-Up Arrow")
        XCTAssertEqual(up?.keyEquivalent.character, "\u{F700}")
        XCTAssertEqual(QuickSearchShortcut.keyName("\u{F704}"), "F1")
        XCTAssertEqual(QuickSearchShortcut.keyName(" "), "Space")
    }
}
