import AppKit
import SwiftUI

/// A menu key equivalent: one key plus the modifiers held with it.
///
/// The key is always the character that key produces with *no* modifiers
/// applied, lowercased. That is the AppKit menu convention: an item whose
/// chord includes Shift carries the unshifted character and `.shift` in its
/// modifier mask, never the shifted character, because an uppercase key
/// equivalent makes AppKit supply Shift by itself. Storing "@" for Shift-2
/// would ask for Shift twice and match nothing.
///
/// `Equatable` but not `Sendable`: nothing crosses an isolation boundary with
/// one, and the recorder's monitor returns only a `Bool` for that reason.
struct QuickSearchShortcut: Equatable {
    let key: Character
    let modifiers: NSEvent.ModifierFlags

    /// The only modifiers a chord may carry. Caps Lock, Fn and the numeric-pad
    /// flag are stripped rather than refused: they are state bits AppKit
    /// reports on unrelated presses, not parts of a chord a menu can match.
    static let allowedModifiers: NSEvent.ModifierFlags =
        [.command, .shift, .option, .control]

    /// Command-Shift-Space — the chord this replaced, unchanged.
    static let `default` = QuickSearchShortcut(unchecked: " ", modifiers: [.command, .shift])

    private init(unchecked key: Character, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The only way to build one from outside, and the whole of the validation.
    /// A value of this type is by construction a chord the app is willing to
    /// run, which is what lets the store trust anything that survives a read
    /// without a second check.
    init?(key: Character, modifiers: NSEvent.ModifierFlags) {
        let lowered = String(key).lowercased()
        guard lowered.unicodeScalars.count == 1, let normalized = lowered.first else { return nil }
        let cleaned = modifiers.intersection(Self.allowedModifiers)
        guard Self.refusal(forKey: normalized, modifiers: cleaned) == nil else { return nil }
        self.init(unchecked: normalized, modifiers: cleaned)
    }
}

// MARK: - Refusal rules

extension QuickSearchShortcut {
    /// A chord that is already spoken for, and by what. `owner` completes
    /// "… is already <owner>."
    struct ReservedChord {
        let key: Character
        let modifiers: NSEvent.ModifierFlags
        let owner: String
    }

    /// Why a chord cannot be used, in the words the recorder shows verbatim;
    /// `nil` means it is accepted. One function so the recorder's message and
    /// the read-time validation can never disagree about what is allowed.
    static func refusal(forKey key: Character, modifiers: NSEvent.ModifierFlags) -> String? {
        let modifiers = modifiers.intersection(allowedModifiers)
        let lowered = String(key).lowercased()
        guard lowered.unicodeScalars.count == 1,
              let normalized = lowered.first,
              let scalar = normalized.unicodeScalars.first
        else { return "That key can't be used as a shortcut." }

        // Keys another owner holds outright, whatever is held with them.
        switch scalar.value {
        case 0x09:
            return "Tab belongs to the system — Command-Tab switches applications and never reaches VaultSquire — and to Full Keyboard Access."
        case 0x1B:
            return "Escape closes Quick Search and cancels every VaultSquire sheet, so it can't also open it."
        case 0x0D, 0x03:
            return "Return is the default button in every VaultSquire dialog."
        default:
            break
        }

        // Everything typable, plus the AppKit function-key range that `NSEvent`
        // reports for arrows, Home/End, page keys and F1…F31, plus the two
        // delete characters. Everything else below U+0020 is a control code no
        // key produces on its own.
        guard scalar.value == 0x08 || scalar.value >= 0x20 else {
            return "That key can't be used as a shortcut."
        }

        guard !modifiers.isEmpty else {
            return "A shortcut needs Command, otherwise ordinary typing would trigger it."
        }
        guard modifiers.contains(.command) else {
            return "A shortcut needs Command. Shift, Option and Control on their own produce characters VaultSquire's own text fields have to receive."
        }

        if let reserved = reserved.first(where: {
            $0.key == normalized && $0.modifiers == modifiers
        }) {
            return "That shortcut is already \(reserved.owner)."
        }
        return nil
    }

    /// Chords the recorder's live main-menu scan cannot find, and the ones it
    /// can but which must also be refused at *read* time, when no menu exists
    /// yet — a hand-edited Command-Q has to be rejected on launch, not on the
    /// next visit to Settings.
    ///
    /// Three groups. VaultSquire's own commands come from the source: they are
    /// view-level `.keyboardShortcut` modifiers, not menu items, so no scan of
    /// `NSApp.mainMenu` will ever see them. The standard menu chords are listed
    /// because `CommandGroup(replacing: .newItem)` replaces only File ▸ New —
    /// every other default group is still installed. The system chords are
    /// mostly never delivered to the app at all; they are listed so the
    /// recorder can say why nothing happened rather than appearing broken.
    static let reserved: [ReservedChord] = [
        // VaultSquire's own — see VaultSquireApp.swift:54,
        // VaultBrowserView.swift:787/800/817/829, LockedShellView.swift:140,
        // VaultItemDetailView.swift:376/383.
        .init(key: "l", modifiers: [.command, .shift], owner: "Lock Vault"),
        .init(key: "n", modifiers: [.command], owner: "Add Item and Add Account"),
        .init(key: "e", modifiers: [.command], owner: "Edit Item"),
        .init(key: "r", modifiers: [.command], owner: "Sync"),
        .init(key: "c", modifiers: [.command, .option], owner: "Copy Username"),
        .init(key: "c", modifiers: [.command, .shift], owner: "Copy Password"),

        // Standard application, File, Edit, View, Window and Help items.
        .init(key: ",", modifiers: [.command], owner: "Settings"),
        .init(key: "h", modifiers: [.command], owner: "Hide VaultSquire"),
        .init(key: "h", modifiers: [.command, .option], owner: "Hide Others"),
        .init(key: "q", modifiers: [.command], owner: "Quit VaultSquire"),
        .init(key: "w", modifiers: [.command], owner: "Close Window"),
        .init(key: "w", modifiers: [.command, .option], owner: "Close All"),
        .init(key: "p", modifiers: [.command], owner: "Print"),
        .init(key: "z", modifiers: [.command], owner: "Undo"),
        .init(key: "z", modifiers: [.command, .shift], owner: "Redo"),
        .init(key: "x", modifiers: [.command], owner: "Cut"),
        .init(key: "c", modifiers: [.command], owner: "Copy"),
        .init(key: "v", modifiers: [.command], owner: "Paste"),
        .init(key: "v", modifiers: [.command, .option, .shift], owner: "Paste and Match Style"),
        .init(key: "a", modifiers: [.command], owner: "Select All"),
        .init(key: "f", modifiers: [.command], owner: "Find"),
        .init(key: "g", modifiers: [.command], owner: "Find Next"),
        .init(key: "g", modifiers: [.command, .shift], owner: "Find Previous"),
        .init(key: ":", modifiers: [.command], owner: "Show Spelling and Grammar"),
        .init(key: ";", modifiers: [.command], owner: "Check Document Now"),
        .init(key: "f", modifiers: [.command, .control], owner: "Enter Full Screen"),
        .init(key: "t", modifiers: [.command, .option], owner: "Show Toolbar"),
        .init(key: "s", modifiers: [.command, .control], owner: "Show Sidebar"),
        .init(key: "m", modifiers: [.command], owner: "Minimize"),
        .init(key: "`", modifiers: [.command], owner: "Cycle Through Windows"),
        // Help is "?" in the menu, which is Shift-slash on a US layout; both
        // spellings are listed because a non-US layout may report either.
        .init(key: "/", modifiers: [.command, .shift], owner: "VaultSquire Help"),
        .init(key: "?", modifiers: [.command, .shift], owner: "VaultSquire Help"),

        // System-owned. macOS consumes these before the app sees them.
        .init(key: " ", modifiers: [.command], owner: "Spotlight, which macOS handles before VaultSquire"),
        .init(key: " ", modifiers: [.command, .option], owner: "the Finder search window, which macOS handles before VaultSquire"),
        .init(key: " ", modifiers: [.command, .control], owner: "the Character Viewer, which macOS handles before VaultSquire"),
        .init(key: "q", modifiers: [.command, .control], owner: "Lock Screen"),
        .init(key: "q", modifiers: [.command, .shift], owner: "Log Out"),
        .init(key: "3", modifiers: [.command, .shift], owner: "the system screenshot shortcut"),
        .init(key: "4", modifiers: [.command, .shift], owner: "the system screenshot shortcut"),
        .init(key: "5", modifiers: [.command, .shift], owner: "the system screenshot shortcut"),
        .init(key: "d", modifiers: [.command, .control], owner: "Look Up"),
    ]
}

// MARK: - SwiftUI and display

extension QuickSearchShortcut {
    /// `KeyEquivalent` is a `Character` wrapper and its named constants are
    /// that same character — `.space` is `" "`, the arrows and Home/End are
    /// the AppKit function-key scalars `NSEvent` already reports. So the stored
    /// character passes straight through and no mapping table is needed for
    /// the space bar or the non-printable keys. `VaultSquireApp.swift:44`
    /// already relied on this for Space.
    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    /// Words, not glyphs, matching the strings already in Settings:
    /// "Command-Shift-Space", "Command-Shift-L".
    var displayName: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(Self.keyName(key))
        return parts.joined(separator: "-")
    }

    static func keyName(_ key: Character) -> String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        switch scalar.value {
        case 0x20: return "Space"
        case 0x08, 0x7F: return "Delete"
        case 0xF728: return "Forward Delete"
        case 0xF700: return "Up Arrow"
        case 0xF701: return "Down Arrow"
        case 0xF702: return "Left Arrow"
        case 0xF703: return "Right Arrow"
        case 0xF729: return "Home"
        case 0xF72B: return "End"
        case 0xF72C: return "Page Up"
        case 0xF72D: return "Page Down"
        case 0xF704...0xF722: return "F\(scalar.value - 0xF703)"  // NSF1FunctionKey = 0xF704
        case 0xF723...0xF8FF: return String(format: "Key U+%04X", scalar.value)
        default: return String(key).uppercased()
        }
    }
}

// MARK: - Capture

extension QuickSearchShortcut {
    enum Capture {
        case accepted(QuickSearchShortcut)
        case refused(String)
        /// Escape with nothing held: the user backed out of recording.
        case cancelled
    }

    /// The chord a key-down describes.
    ///
    /// `characters(byApplyingModifiers: [])` rather than
    /// `charactersIgnoringModifiers` is what makes the Shift rule work:
    /// "ignoring modifiers" ignores Command and Option but *not* Shift, so on a
    /// US layout Shift-2 arrives as "@" and would be stored as a chord nobody
    /// can type. Applying an empty modifier set asks the current keyboard
    /// layout for the unshifted character instead, and still returns the
    /// function-key scalars unchanged for the arrows, Home/End and F-keys.
    static func captured(from event: NSEvent) -> Capture {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(allowedModifiers)
        let text = (event.characters(byApplyingModifiers: [])
            ?? event.charactersIgnoringModifiers
            ?? "").lowercased()

        guard text.unicodeScalars.count == 1, let key = text.first else {
            // A dead key or an input method mid-composition.
            return .refused("That key can't be used as a shortcut.")
        }
        if key.unicodeScalars.first?.value == 0x1B, modifiers.isEmpty {
            return .cancelled
        }
        if let reason = refusal(forKey: key, modifiers: modifiers) {
            return .refused(reason)
        }
        guard let shortcut = QuickSearchShortcut(key: key, modifiers: modifiers) else {
            return .refused("That key can't be used as a shortcut.")
        }
        return .accepted(shortcut)
    }
}
