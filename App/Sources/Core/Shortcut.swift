import AppKit
import Carbon.HIToolbox

/// Side-specific modifier keys, built from the device-dependent bits that both
/// `CGEventFlags` and `NSEvent.ModifierFlags` carry in their raw value.
nonisolated struct ModifierKeys: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt16

    static let leftControl  = ModifierKeys(rawValue: 1 << 0)
    static let rightControl = ModifierKeys(rawValue: 1 << 1)
    static let leftShift    = ModifierKeys(rawValue: 1 << 2)
    static let rightShift   = ModifierKeys(rawValue: 1 << 3)
    static let leftOption   = ModifierKeys(rawValue: 1 << 4)
    static let rightOption  = ModifierKeys(rawValue: 1 << 5)
    static let leftCommand  = ModifierKeys(rawValue: 1 << 6)
    static let rightCommand = ModifierKeys(rawValue: 1 << 7)
    static let function     = ModifierKeys(rawValue: 1 << 8)

    // IOKit NX_DEVICE* masks (device-dependent, side-specific).
    private static let deviceMasks: [(UInt64, ModifierKeys)] = [
        (0x0000_0001, .leftControl),
        (0x0000_2000, .rightControl),
        (0x0000_0002, .leftShift),
        (0x0000_0004, .rightShift),
        (0x0000_0020, .leftOption),
        (0x0000_0040, .rightOption),
        (0x0000_0008, .leftCommand),
        (0x0000_0010, .rightCommand),
        (0x0080_0000, .function), // NX_SECONDARYFNMASK
    ]

    /// Builds the held-modifier set from raw event flags
    /// (`CGEventFlags.rawValue` or `NSEvent.ModifierFlags.rawValue`).
    init(eventFlags raw: UInt64) {
        var keys: ModifierKeys = []
        for (mask, key) in Self.deviceMasks where raw & mask != 0 { keys.insert(key) }
        self = keys
    }

    init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Collapses left/right into a side-agnostic form (left bit set) for combo matching.
    var sideAgnostic: ModifierKeys {
        var out: ModifierKeys = []
        if !intersection([.leftControl, .rightControl]).isEmpty { out.insert(.leftControl) }
        if !intersection([.leftShift, .rightShift]).isEmpty { out.insert(.leftShift) }
        if !intersection([.leftOption, .rightOption]).isEmpty { out.insert(.leftOption) }
        if !intersection([.leftCommand, .rightCommand]).isEmpty { out.insert(.leftCommand) }
        if contains(.function) { out.insert(.function) }
        return out
    }

    /// Modifier key codes (kVK_*) mapped to their side-specific flag.
    static func forModifierKeyCode(_ keyCode: UInt16) -> ModifierKeys? {
        switch Int(keyCode) {
        case kVK_Control: return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Shift: return .leftShift
        case kVK_RightShift: return .rightShift
        case kVK_Option: return .leftOption
        case kVK_RightOption: return .rightOption
        case kVK_Command: return .leftCommand
        case 0x36: return .rightCommand // kVK_RightCommand
        case kVK_Function: return .function
        default: return nil
        }
    }

    /// Human readable, in Apple's canonical order (fn ⌃ ⌥ ⇧ ⌘).
    func displayParts(sideSpecific: Bool) -> [String] {
        var parts: [String] = []
        func add(_ left: ModifierKeys, _ right: ModifierKeys, _ symbol: String) {
            let l = contains(left), r = contains(right)
            guard l || r else { return }
            if sideSpecific && !(l && r) {
                parts.append(l ? "\(symbol) sinistro" : "\(symbol) destro")
            } else {
                parts.append(symbol)
            }
        }
        if contains(.function) { parts.append("fn") }
        add(.leftControl, .rightControl, "⌃")
        add(.leftOption, .rightOption, "⌥")
        add(.leftShift, .rightShift, "⇧")
        add(.leftCommand, .rightCommand, "⌘")
        return parts
    }
}

/// A global shortcut: either modifier-only (e.g. `fn`, `⌥ destro`) or a key
/// with optional modifiers (e.g. `fn + Spazio`).
nonisolated struct Shortcut: Codable, Hashable, Sendable {
    /// `nil` for modifier-only shortcuts.
    var keyCode: UInt16?
    var modifiers: ModifierKeys

    var isModifierOnly: Bool { keyCode == nil }
    var isEmpty: Bool { keyCode == nil && modifiers.isEmpty }

    static let holdDefault = Shortcut(keyCode: nil, modifiers: .function)
    static let lockDefault = Shortcut(keyCode: UInt16(kVK_Space), modifiers: .function)

    /// Whether a key-down of `keyCode` with `held` modifiers triggers this combo.
    func matchesKeyDown(keyCode code: UInt16, held: ModifierKeys) -> Bool {
        guard let keyCode, keyCode == code else { return false }
        return held.sideAgnostic == modifiers.sideAgnostic
    }

    /// Whether exactly this modifier-only shortcut is held.
    func matchesModifiers(_ held: ModifierKeys) -> Bool {
        isModifierOnly && !modifiers.isEmpty && held == modifiers
    }

    var displayString: String {
        if isEmpty { return "Nessuna" }
        var parts = modifiers.displayParts(sideSpecific: isModifierOnly)
        if let keyCode { parts.append(Shortcut.keyName(for: keyCode)) }
        return parts.joined(separator: " + ")
    }

    /// Individual key caps for rendering (e.g. ["fn", "Spazio"]).
    var keyCaps: [String] {
        if isEmpty { return [] }
        var parts = modifiers.displayParts(sideSpecific: isModifierOnly)
        if let keyCode { parts.append(Shortcut.keyName(for: keyCode)) }
        return parts
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Spazio"
        case kVK_Return: return "Invio"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "Fine"
        case kVK_PageUp: return "Pag ↑"
        case kVK_PageDown: return "Pag ↓"
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
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default:
            return characterForKeyCode(keyCode)?.uppercased() ?? "Tasto \(keyCode)"
        }
    }

    private static func characterForKeyCode(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }
}

nonisolated extension Shortcut {
    /// Builds a shortcut from an `NSEvent` seen by a shortcut recorder.
    /// - `.keyDown` → key combo with the currently held modifiers.
    /// - `.flagsChanged` → modifier-only candidate (the held set *before* release).
    static func fromKeyDown(_ event: NSEvent) -> Shortcut {
        let held = ModifierKeys(eventFlags: UInt64(event.modifierFlags.rawValue))
        // Arrow/function keys report the fn flag even when fn is not physically held.
        var mods = held
        if isFnImplicitKey(event.keyCode) { mods.remove(.function) }
        return Shortcut(keyCode: event.keyCode, modifiers: mods)
    }

    static func isFnImplicitKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
             kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
             kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
             kVK_F18, kVK_F19, kVK_F20:
            return true
        default:
            return false
        }
    }
}
