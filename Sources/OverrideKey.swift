import AppKit
import CoreGraphics

/// A key the user recorded to act as their override, in place of one of the standard modifiers.
struct CustomOverrideKey: Codable, Equatable, Hashable, Sendable {
    /// The hardware key code, which stays the same whatever keyboard layout is active.
    var keyCode: UInt16
    /// What to call the key in the interface, captured when it was recorded.
    var label: String

    /// Whether holding this key does something of its own (types a character, moves the
    /// insertion point), as opposed to a modifier or a function key.
    var doesSomethingWhenHeld: Bool {
        !KeyNames.isModifier(keyCode) && !KeyNames.isFunctionKey(keyCode)
    }
}

/// What the user holds to let the Dock move freely.
enum OverrideTrigger: Equatable, Sendable {
    case none
    /// One of the standard modifiers, either side of the keyboard.
    case modifier(ModifierOption)
    /// One specific key.
    case key(CustomOverrideKey)

    /// Whether the trigger is held, judged from a mouse event on its way through the event tap.
    func isActive(for event: CGEvent) -> Bool {
        switch self {
        case .none:
            return false
        case .modifier(let modifier):
            guard let flag = modifier.cgFlag else { return false }
            return event.flags.contains(flag)
        case .key(let key):
            return CGEventSource.keyState(.combinedSessionState, key: key.keyCode)
        }
    }

    /// Whether the trigger is held right now.
    var isDown: Bool {
        switch self {
        case .none:
            return false
        case .modifier(let modifier):
            guard let flag = modifier.cgFlag else { return false }
            return CGEventSource.flagsState(.combinedSessionState).contains(flag)
        case .key(let key):
            return CGEventSource.keyState(.combinedSessionState, key: key.keyCode)
        }
    }
}

extension DockProfile {
    var overrideTrigger: OverrideTrigger {
        if let customOverrideKey { return .key(customOverrideKey) }
        return overrideModifier == .none ? .none : .modifier(overrideModifier)
    }
}

/// Names for keys, by hardware key code.
enum KeyNames {
    private static let modifiers: [UInt16: String] = [
        54: "Right Command (⌘)", 55: "Left Command (⌘)",
        56: "Left Shift (⇧)", 60: "Right Shift (⇧)",
        58: "Left Option (⌥)", 61: "Right Option (⌥)",
        59: "Left Control (⌃)", 62: "Right Control (⌃)",
        57: "Caps Lock (⇪)", 63: "Fn (Globe)",
    ]

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let named: [UInt16: String] = [
        36: "Return (↩)", 48: "Tab (⇥)", 49: "Space", 51: "Delete (⌫)", 53: "Escape (⎋)",
        117: "Forward Delete (⌦)", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "Left Arrow (←)", 124: "Right Arrow (→)", 125: "Down Arrow (↓)", 126: "Up Arrow (↑)",
        114: "Help", 71: "Clear", 76: "Keypad Enter",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
    ]

    static func isModifier(_ keyCode: UInt16) -> Bool {
        modifiers[keyCode] != nil
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys[keyCode] != nil
    }

    /// The modifier flag a modifier key sets while it's down, used to tell a press from a release.
    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 57: return .capsLock
        case 63: return .function
        default: return nil
        }
    }

    /// A name for a key. `characters` is what the key produced when it was pressed, used for
    /// ordinary character keys, whose meaning depends on the keyboard layout.
    static func label(keyCode: UInt16, characters: String? = nil) -> String {
        if let name = modifiers[keyCode] ?? functionKeys[keyCode] ?? named[keyCode] {
            return name
        }
        let typed = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        // Keys without a character of their own report control codes or private-use
        // placeholders (AppKit's function-key range), which would show as an empty box.
        let unprintable: Set<Unicode.GeneralCategory> = [.control, .format, .privateUse, .unassigned, .surrogate]
        if !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !unprintable.contains($0.properties.generalCategory) }) {
            return typed
        }
        return "Key \(keyCode)"
    }
}
