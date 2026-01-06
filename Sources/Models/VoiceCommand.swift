import Foundation
import Carbon.HIToolbox

/// A voice command that maps a spoken phrase to a keyboard shortcut or text replacement
struct VoiceCommand: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var phrase: String
    var shortcut: KeyboardShortcut?
    var replacementText: String?
    var isEnabled: Bool = true
    var requiresPause: Bool = false

    var isSnippet: Bool {
        replacementText != nil && !replacementText!.isEmpty
    }

    static let defaults: [VoiceCommand] = [
        VoiceCommand(phrase: "tab back", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.control, .shift])),
        VoiceCommand(phrase: "tab forward", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_Tab), modifiers: [.control])),
        VoiceCommand(phrase: "new tab", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command])),
        VoiceCommand(phrase: "tab new", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command])),
        VoiceCommand(phrase: "undo that", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]), requiresPause: true),
        VoiceCommand(phrase: "redo that", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift]), requiresPause: true),
        VoiceCommand(phrase: "copy that", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command])),
        VoiceCommand(phrase: "paste that", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command])),
        VoiceCommand(phrase: "cut that", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_X), modifiers: [.command])),
        VoiceCommand(phrase: "select all", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command])),
        VoiceCommand(phrase: "save that", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command])),
        VoiceCommand(phrase: "go back", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [.command])),
        VoiceCommand(phrase: "go forward", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: [.command])),
        VoiceCommand(phrase: "page up", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_PageUp), modifiers: [])),
        VoiceCommand(phrase: "page down", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_PageDown), modifiers: [])),
        VoiceCommand(phrase: "scroll up", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_UpArrow), modifiers: [])),
        VoiceCommand(phrase: "scroll down", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_DownArrow), modifiers: [])),
        VoiceCommand(phrase: "press escape", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_Escape), modifiers: [])),
        VoiceCommand(phrase: "press enter", shortcut: KeyboardShortcut(keyCode: UInt16(kVK_Return), modifiers: [])),
    ]
}

/// Modifier keys for keyboard shortcuts
struct KeyboardModifiers: OptionSet, Codable, Equatable, Hashable {
    let rawValue: Int

    static let control = KeyboardModifiers(rawValue: 1 << 0)
    static let option = KeyboardModifiers(rawValue: 1 << 1)
    static let shift = KeyboardModifiers(rawValue: 1 << 2)
    static let command = KeyboardModifiers(rawValue: 1 << 3)

    var description: String {
        var parts: [String] = []
        if contains(.control) { parts.append("^") }
        if contains(.option) { parts.append("") }
        if contains(.shift) { parts.append("") }
        if contains(.command) { parts.append("") }
        return parts.joined()
    }
}

/// A keyboard shortcut with key code and modifiers
struct KeyboardShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: KeyboardModifiers

    var description: String {
        let keyName = KeyboardShortcut.keyCodeToString(keyCode)
        if modifiers.rawValue == 0 {
            return keyName
        }
        return "\(modifiers.description)\(keyName)"
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Grave: return "`"
        default: return "?"
        }
    }
}
