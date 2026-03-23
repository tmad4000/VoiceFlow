import Foundation

/// The three microphone modes for RSI-friendly voice control
enum MicrophoneMode: String, CaseIterable, Identifiable {
    /// Microphone is completely off - no listening, no response to anything
    case off = "Off"

    /// Microphone is listening for wake word only
    case sleep = "Sleep"

    /// Microphone is on and actively processing commands and/or dictation
    case on = "On"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .off: return "waveform.slash"
        case .sleep: return "waveform"
        case .on: return "waveform"
        }
    }

    var color: String {
        switch self {
        case .off: return "gray"
        case .sleep: return "orange"
        case .on: return "green"
        }
    }

    var description: String {
        switch self {
        case .off: return "Microphone off"
        case .sleep: return "Listening for 'Speech on'"
        case .on: return "Active"
        }
    }

    /// Voice command hint shown in dropdown
    var voiceCommandHint: String {
        switch self {
        case .off: return "\"microphone off\""
        case .sleep: return "\"go to sleep\""
        case .on: return "\"speech on\""
        }
    }

    /// Keyboard shortcut for this mode
    var keyboardShortcut: String {
        switch self {
        case .off: return "⌃⌥⌘0"
        case .on: return "⌃⌥⌘1"
        case .sleep: return "⌃⌥⌘2"
        }
    }
}

/// Behaviors for the 'On' microphone mode
enum ActiveBehavior: String, CaseIterable, Identifiable, Codable {
    /// Both commands and dictation are active (commands take priority)
    case mixed = "Mixed"
    
    /// Only dictation is active (commands are ignored)
    case dictation = "Dictation"
    
    /// Only commands are active (nothing is typed)
    case command = "Command"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .mixed: return "square.grid.2x2.fill"
        case .dictation: return "text.quote"
        case .command: return "command"
        }
    }
}
