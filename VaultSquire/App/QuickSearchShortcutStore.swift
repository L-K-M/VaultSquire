import AppKit
import SwiftUI

/// The stored Quick Search chord.
///
/// Observable, unlike `AutoLockController`, and for a reason: the idle timeout
/// only has to be right the next time the clock arms, so Settings can read it
/// once into `@State`. This has to redraw the menu bar, so the menu command
/// observes it. `SiteIconStore` is the in-repo precedent for a UserDefaults
/// preference on an observable that must take effect now rather than at the
/// next launch.
@MainActor
final class QuickSearchShortcutStore: ObservableObject {
    static let shared = QuickSearchShortcutStore()

    /// Two keys. The key code is the small integer Carbon registers — a
    /// virtual key code, not a character, because a character depends on the
    /// keyboard layout and the physical key does not. The modifiers are names
    /// rather than a raw `NSEvent.ModifierFlags` integer, because a bit mask
    /// spelled `1179648` is precisely the kind of value someone mis-edits and
    /// the kind this must fail closed on.
    static let keyDefaultsKey = "VaultSquire.quickSearchShortcutKeyCode"
    static let modifiersDefaultsKey = "VaultSquire.quickSearchShortcutModifiers"

    /// The menu item's title. The item has no key equivalent of its own any
    /// more — the chord is registered system-wide, so it already works while
    /// VaultSquire is frontmost and a second claim on it would be ambiguous.
    static let menuItemTitle = "Quick Search"

    private static let modifierNames: [(name: String, flag: NSEvent.ModifierFlags)] = [
        ("command", .command), ("shift", .shift), ("option", .option), ("control", .control)
    ]

    private let defaults: UserDefaults

    @Published private(set) var shortcut: QuickSearchShortcut

    /// Something was stored and did not survive validation: a hand edit, or a
    /// chord this app began reserving after it was set. Settings says so rather
    /// than showing the default as though the user had chosen it.
    @Published private(set) var storedValueWasRejected: Bool

    /// The chord is stored and valid, but the system would not give it to us —
    /// another application registered it first. Settings says so, because the
    /// symptom otherwise is a shortcut that simply does nothing.
    @Published private(set) var isUnavailable = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let read = Self.read(from: defaults)
        self.shortcut = read.shortcut
        self.storedValueWasRejected = read.wasRejected
    }

    /// Validation on read. Absent means the default and is not a rejection —
    /// the `object(forKey:) != nil` presence test is `AutoLockController`'s, for
    /// the same reason: a never-configured install must report what it is
    /// actually running, not a fault. Anything present that does not survive
    /// `QuickSearchShortcut.init?` reads as the default *and* is flagged, so a
    /// corrupt preference can never leave Quick Search with a chord that has no
    /// modifiers, cannot be pressed, or belongs to another command.
    ///
    /// Nothing is written back. Following `AutoLockController`'s precedent, a
    /// value set out of band is not silently rewritten; it is reported.
    static func read(
        from defaults: UserDefaults
    ) -> (shortcut: QuickSearchShortcut, wasRejected: Bool) {
        let hasKey = defaults.object(forKey: keyDefaultsKey) != nil
        let hasModifiers = defaults.object(forKey: modifiersDefaultsKey) != nil
        guard hasKey || hasModifiers else { return (.default, false) }

        let rawKeyCode = defaults.integer(forKey: keyDefaultsKey)
        guard rawKeyCode > 0, rawKeyCode <= 0x7F,
              let names = defaults.stringArray(forKey: modifiersDefaultsKey),
              let modifiers = decodeModifiers(names),
              let shortcut = QuickSearchShortcut(
                  keyCode: UInt32(rawKeyCode), modifiers: modifiers
              )
        else {
            return (.default, true)
        }
        return (shortcut, false)
    }

    /// An unrecognised name fails the whole read rather than being skipped:
    /// dropping "comand" from `["comand", "shift"]` would silently install
    /// Shift-something, which `init?` would then refuse anyway — but by way of
    /// a confusing intermediate value rather than an honest "unreadable".
    private static func decodeModifiers(_ names: [String]) -> NSEvent.ModifierFlags? {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            guard let match = modifierNames.first(where: { $0.name == name.lowercased() })
            else { return nil }
            flags.insert(match.flag)
        }
        return flags
    }

    /// Stores a chord and makes it live. Only a validated `QuickSearchShortcut`
    /// can be passed, and this is the only writer, so what a later launch reads
    /// back is always something this build was willing to run.
    @discardableResult
    func set(_ shortcut: QuickSearchShortcut) -> Bool {
        // Claimed before it is stored. A chord the system will not give us is
        // not a preference worth keeping: the user would restart into a
        // shortcut that silently does nothing.
        guard activate(shortcut) else {
            isUnavailable = true
            return false
        }
        defaults.set(Int(shortcut.keyCode), forKey: Self.keyDefaultsKey)
        defaults.set(
            Self.modifierNames.filter { shortcut.modifiers.contains($0.flag) }.map(\.name),
            forKey: Self.modifiersDefaultsKey
        )
        self.shortcut = shortcut
        storedValueWasRejected = false
        isUnavailable = false
        return true
    }

    /// Back to Command-Shift-Space, forgetting the stored chord entirely so a
    /// later change of default is picked up rather than pinned.
    func resetToDefault() {
        defaults.removeObject(forKey: Self.keyDefaultsKey)
        defaults.removeObject(forKey: Self.modifiersDefaultsKey)
        shortcut = .default
        storedValueWasRejected = false
        isUnavailable = !activate(.default)
    }

    /// Claims the stored chord. Called once at launch and again on every
    /// change, so the registration and the preference cannot drift apart.
    @discardableResult
    func activate(_ shortcut: QuickSearchShortcut? = nil) -> Bool {
        let claimed = GlobalHotkey.register(shortcut ?? self.shortcut) {
            ApplicationCoordinator.shared.toggleQuickSearch()
        }
        if shortcut == nil { isUnavailable = !claimed }
        return claimed
    }
}
