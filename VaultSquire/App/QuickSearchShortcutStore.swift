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

    /// Two keys, both hand-editable. The key is one Unicode scalar; the
    /// modifiers are names, not a raw `NSEvent.ModifierFlags` integer, because
    /// a bit mask spelled `1179648` is precisely the kind of value someone
    /// mis-edits and the kind this must fail closed on.
    static let keyDefaultsKey = "VaultSquire.quickSearchShortcutKey"
    static let modifiersDefaultsKey = "VaultSquire.quickSearchShortcutModifiers"

    /// The menu item this store keeps in step, matched by title.
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

        guard let text = defaults.string(forKey: keyDefaultsKey),
              text.unicodeScalars.count == 1,
              let key = text.first,
              let names = defaults.stringArray(forKey: modifiersDefaultsKey),
              let modifiers = decodeModifiers(names),
              let shortcut = QuickSearchShortcut(key: key, modifiers: modifiers)
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
    func set(_ shortcut: QuickSearchShortcut) {
        defaults.set(String(shortcut.key), forKey: Self.keyDefaultsKey)
        defaults.set(
            Self.modifierNames.filter { shortcut.modifiers.contains($0.flag) }.map(\.name),
            forKey: Self.modifiersDefaultsKey
        )
        self.shortcut = shortcut
        storedValueWasRejected = false
        MainMenuShortcuts.apply(shortcut, toItemTitled: Self.menuItemTitle)
    }

    /// Back to Command-Shift-Space, forgetting the stored chord entirely so a
    /// later change of default is picked up rather than pinned.
    func resetToDefault() {
        defaults.removeObject(forKey: Self.keyDefaultsKey)
        defaults.removeObject(forKey: Self.modifiersDefaultsKey)
        shortcut = .default
        storedValueWasRejected = false
        MainMenuShortcuts.apply(.default, toItemTitled: Self.menuItemTitle)
    }
}

/// Direct access to the `NSMenuItem` SwiftUI built for the Quick Search command.
///
/// Two jobs, both belt-and-braces around things SwiftUI does not promise.
///
/// `apply` exists because whether SwiftUI re-applies a changed
/// `.keyboardShortcut` to an already-installed `NSMenuItem` when observed state
/// changes is not contractual. What *is* reliable is the AppKit side: a menu
/// item's key equivalent is resolved from the live `NSMenuItem` at each
/// key-down, so writing it takes effect on the next keystroke with no relaunch.
/// The menu item declares the same stored chord this writes, so the two can
/// only ever agree — if SwiftUI does re-apply it, this is a no-op writing the
/// value that is already there.
///
/// `owner(ofKey:modifiers:excluding:)` walks what SwiftUI and AppKit actually
/// installed. `CommandGroup(replacing: .newItem)` replaces only File ▸ New;
/// every other standard group is still there, and a source-derived list of them
/// is a guess. This catches whatever is really in the menu bar.
@MainActor
enum MainMenuShortcuts {
    static func apply(_ shortcut: QuickSearchShortcut, toItemTitled title: String) {
        guard let mainMenu = NSApplication.shared.mainMenu,
              let item = firstItem(titled: title, in: mainMenu)
        else { return }
        // Lowercase character plus an explicit `.shift`. An uppercase key
        // equivalent makes AppKit imply Shift, which would double it — the same
        // convention `QuickSearchShortcut` normalises to on the way in.
        item.keyEquivalent = String(shortcut.key)
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    /// The title of a live menu item that already owns this chord, if any.
    static func owner(
        ofKey key: Character,
        modifiers: NSEvent.ModifierFlags,
        excludingItemTitled excluded: String
    ) -> String? {
        guard let mainMenu = NSApplication.shared.mainMenu else { return nil }
        var found: String?
        walk(mainMenu) { item in
            guard found == nil,
                  item.title != excluded,
                  !item.keyEquivalent.isEmpty
            else { return }
            let lowered = item.keyEquivalent.lowercased()
            guard lowered.unicodeScalars.count == 1, let itemKey = lowered.first else { return }
            var mask = item.keyEquivalentModifierMask
                .intersection(QuickSearchShortcut.allowedModifiers)
            // An uppercase key equivalent means AppKit supplies Shift itself.
            if item.keyEquivalent != lowered { mask.insert(.shift) }
            if itemKey == key, mask == modifiers, !item.title.isEmpty {
                found = item.title
            }
        }
        return found
    }

    private static func firstItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        var found: NSMenuItem?
        walk(menu) { item in
            if found == nil, item.title == title { found = item }
        }
        return found
    }

    private static func walk(_ menu: NSMenu, _ body: (NSMenuItem) -> Void) {
        for item in menu.items {
            body(item)
            if let submenu = item.submenu { walk(submenu, body) }
        }
    }
}
