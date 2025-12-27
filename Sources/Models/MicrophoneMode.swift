import Foundation

/// The three microphone modes for RSI-friendly voice control
enum MicrophoneMode: String, CaseIterable, Identifiable {
    /// Microphone is completely off - no listening, no response to anything
    case off = "Off"

    /// Microphone is on and actively transcribing speech to text
    case on = "On"

    /// Microphone is listening for wake word/voice commands only
    case wake = "Wake"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .off: return "mic.slash.fill"
        case .on: return "mic.fill"
        case .wake: return "waveform"
        }
    }

    var color: String {
        switch self {
        case .off: return "gray"
        case .on: return "green"
        case .wake: return "orange"
        }
    }

    var description: String {
        switch self {
        case .off: return "Microphone off - not listening"
        case .on: return "Transcribing speech to text"
        case .wake: return "Listening for voice commands"
        }
    }
}
