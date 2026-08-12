import AppKit
import Carbon.HIToolbox

/// The chord that summons Quick Search from anywhere.
///
/// A virtual key code rather than a character, because that is what
/// `RegisterEventHotKey` takes and because a key code is what a chord actually
/// is: the physical key, independent of the layout that decides which character
/// it produces. The display name is derived from the current layout instead, so
/// the same stored value reads correctly on a US, German or Dvorak keyboard
/// where a stored character would not.
struct QuickSearchShortcut: Equatable, Sendable {
    /// A `kVK_*` virtual key code.
    let keyCode: UInt32
    /// Cocoa modifier flags, which is what the recorder captures and what the
    /// display name is built from. Translated to Carbon's mask on the way to
    /// registration.
    let modifiers: NSEvent.ModifierFlags

    /// The only modifiers a chord may carry. Caps Lock, Fn and the numeric-pad
    /// flag are stripped rather than refused: they are state bits AppKit
    /// reports on unrelated presses, not parts of a chord.
    static let allowedModifiers: NSEvent.ModifierFlags =
        [.command, .shift, .option, .control]

    /// Command-Shift-Space.
    ///
    /// Unchanged from when this was a menu shortcut, so nobody's chord moves
    /// under them. It is also a safe *global* default: macOS itself takes
    /// Command-Space, Control-Command-Space and Option-Command-Space, but not
    /// this one. Deliberately not Control-Option-Space, which is what the
    /// author's other menu-bar app registers — two apps racing for one chord is
    /// a bad first run for whichever loses.
    static let `default` = QuickSearchShortcut(
        unchecked: UInt32(kVK_Space), modifiers: [.command, .shift]
    )

    private init(unchecked keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The only way to build one from outside, and the whole of the validation.
    /// A value of this type is by construction a chord this app is willing to
    /// ask the system for.
    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        let cleaned = modifiers.intersection(Self.allowedModifiers)
        guard Self.refusal(forKeyCode: keyCode, modifiers: cleaned) == nil else { return nil }
        self.init(unchecked: keyCode, modifiers: cleaned)
    }

    /// Carbon's modifier mask, which is what `RegisterEventHotKey` expects and
    /// is a different set of bit positions from Cocoa's.
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

// MARK: - Refusal rules

extension QuickSearchShortcut {
    /// A chord this app holds itself, and what holds it.
    struct ReservedChord {
        let keyCode: UInt32
        let modifiers: NSEvent.ModifierFlags
        let owner: String
    }

    /// Why a chord cannot be used, in the words Settings shows verbatim; `nil`
    /// means it is accepted.
    ///
    /// Deliberately short. When this was a menu key equivalent the app had to
    /// predict every chord the system and the standard menus might own, from a
    /// static table that was a guess. A global registration does not need that
    /// guess: `RegisterEventHotKey` fails outright when the system or another
    /// application already holds the chord, and that answer is authoritative
    /// where a table is not. What is left here is the two things registration
    /// would happily accept and the user would regret.
    static func refusal(forKeyCode keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String? {
        let modifiers = modifiers.intersection(allowedModifiers)

        switch Int(keyCode) {
        case kVK_Escape:
            return "Escape closes Quick Search and cancels every VaultSquire sheet, so it can't also open it."
        case kVK_Tab:
            return "Tab belongs to the system and to Full Keyboard Access."
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return "Return is the default button in every VaultSquire dialog."
        default:
            break
        }

        // A global chord with no modifier — or with only Shift — would swallow
        // that key in every application on the Mac, including whatever the user
        // is typing into right now. This is the one refusal that matters more
        // for a global hotkey than it did for a menu shortcut.
        guard !modifiers.isEmpty else {
            return "A global shortcut needs a modifier, or it would swallow that key in every app."
        }
        guard !modifiers.subtracting(.shift).isEmpty else {
            return "Shift on its own still types a character. Add Command, Control or Option."
        }

        if let reserved = reserved.first(where: {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        }) {
            return "VaultSquire already uses that shortcut for \(reserved.owner)."
        }
        return nil
    }

    /// VaultSquire's own commands. A global hotkey does not collide with
    /// another application's menu, but it does collide with ours: registering
    /// Command-E globally would make Command-E ambiguous inside the window that
    /// already uses it for Edit Item. These are view-level `.keyboardShortcut`
    /// modifiers rather than menu items, so no scan of the menu bar would find
    /// them — see VaultSquireApp, VaultBrowserView, LockedShellView and
    /// VaultItemDetailView.
    static let reserved: [ReservedChord] = [
        .init(keyCode: UInt32(kVK_ANSI_L), modifiers: [.command, .shift], owner: "Lock Vault"),
        .init(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command], owner: "Add Item"),
        .init(keyCode: UInt32(kVK_ANSI_E), modifiers: [.command], owner: "Edit Item"),
        .init(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command], owner: "Sync"),
        .init(keyCode: UInt32(kVK_ANSI_C), modifiers: [.command, .option], owner: "Copy Username"),
        .init(keyCode: UInt32(kVK_ANSI_C), modifiers: [.command, .shift], owner: "Copy Password"),
        .init(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command], owner: "Settings"),
    ]
}

// MARK: - Display

extension QuickSearchShortcut {
    /// Words rather than glyphs, matching the strings already in Settings:
    /// "Command-Shift-Space", "Command-Shift-L".
    var displayName: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(Self.keyName(keyCode))
        return parts.joined(separator: "-")
    }

    /// A name for a virtual key code. The named keys are spelled out; anything
    /// else is asked of the current keyboard layout, so a stored code reads as
    /// the key the user actually presses rather than as the character a US
    /// layout would have produced.
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "Left Arrow"
        case kVK_RightArrow: return "Right Arrow"
        case kVK_UpArrow: return "Up Arrow"
        case kVK_DownArrow: return "Down Arrow"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    /// What the current layout says this key produces, unshifted and with dead
    /// keys resolved to nothing.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let pointer = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                pointer, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

// MARK: - Capture

extension QuickSearchShortcut {
    enum Capture: Equatable {
        case accepted(QuickSearchShortcut)
        case refused(String)
        /// Escape with nothing held: the user backed out of recording.
        case cancelled
    }

    /// The chord a key-down describes. Read from `keyCode`, so no layout,
    /// dead key or input method can turn a press into a character this cannot
    /// store or the user cannot press again.
    static func captured(from event: NSEvent) -> Capture {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(allowedModifiers)
        let keyCode = UInt32(event.keyCode)

        if Int(keyCode) == kVK_Escape, modifiers.isEmpty {
            return .cancelled
        }
        if let reason = refusal(forKeyCode: keyCode, modifiers: modifiers) {
            return .refused(reason)
        }
        guard let shortcut = QuickSearchShortcut(keyCode: keyCode, modifiers: modifiers) else {
            return .refused("That key can't be used as a shortcut.")
        }
        return .accepted(shortcut)
    }
}
