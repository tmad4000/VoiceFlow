import Foundation
import Combine
import CoreGraphics

/// Main application state management
@MainActor
class AppState: ObservableObject {
    @Published var microphoneMode: MicrophoneMode = .off
    @Published var currentTranscript: String = ""
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var apiKey: String = ""
    @Published var voiceCommands: [VoiceCommand] = VoiceCommand.defaults

    private var audioCaptureManager: AudioCaptureManager?
    private var assemblyAIService: AssemblyAIService?
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadAPIKey()
        loadVoiceCommands()
    }

    func setMode(_ mode: MicrophoneMode) {
        let previousMode = microphoneMode
        microphoneMode = mode

        switch mode {
        case .off:
            stopListening()
        case .on:
            if previousMode == .off {
                startListening(transcribeMode: true)
            } else {
                assemblyAIService?.setTranscribeMode(true)
            }
        case .wake:
            if previousMode == .off {
                startListening(transcribeMode: false)
            } else {
                assemblyAIService?.setTranscribeMode(false)
            }
        }
    }

    private func startListening(transcribeMode: Bool) {
        guard !apiKey.isEmpty else {
            errorMessage = "Please set your AssemblyAI API key in Settings"
            return
        }

        errorMessage = nil

        // Initialize services
        assemblyAIService = AssemblyAIService(apiKey: apiKey)
        audioCaptureManager = AudioCaptureManager()

        // Set up bindings
        assemblyAIService?.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
            }
            .store(in: &cancellables)

        assemblyAIService?.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.handleTranscript(transcript)
            }
            .store(in: &cancellables)

        assemblyAIService?.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error
            }
            .store(in: &cancellables)

        // Connect audio output to WebSocket
        audioCaptureManager?.onAudioData = { [weak self] data in
            self?.assemblyAIService?.sendAudio(data)
        }

        // Start services
        assemblyAIService?.setTranscribeMode(transcribeMode)
        assemblyAIService?.connect()
        audioCaptureManager?.startCapture()
    }

    private func stopListening() {
        audioCaptureManager?.stopCapture()
        assemblyAIService?.disconnect()
        audioCaptureManager = nil
        assemblyAIService = nil
        cancellables.removeAll()
        isConnected = false
    }

    private func handleTranscript(_ transcript: String) {
        guard !transcript.isEmpty else { return }

        if microphoneMode == .wake {
            // In wake mode, check for voice commands
            processVoiceCommand(transcript)
        } else if microphoneMode == .on {
            // In on mode, update transcript and type it out
            currentTranscript = transcript
            typeText(transcript)
        }
    }

    private func processVoiceCommand(_ transcript: String) {
        let lowercased = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for built-in mode commands
        if lowercased.contains("microphone on") || lowercased.contains("start dictation") {
            setMode(.on)
            return
        }

        if lowercased.contains("microphone off") || lowercased.contains("stop dictation") {
            setMode(.off)
            return
        }

        // Check custom voice commands
        for command in voiceCommands {
            if lowercased.contains(command.phrase.lowercased()) {
                executeKeyboardShortcut(command.shortcut)
                return
            }
        }

        // Show unrecognized command briefly
        currentTranscript = "Command: \(transcript)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.currentTranscript == "Command: \(transcript)" {
                self?.currentTranscript = ""
            }
        }
    }

    private func typeText(_ text: String) {
        // Use CGEvent to type text into the active application
        let source = CGEventSource(stateID: .hidSystemState)

        for char in text + " " {
            if let unicodeScalar = char.unicodeScalars.first {
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)

                var unichar = UniChar(unicodeScalar.value)
                keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
                keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)

                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    private func executeKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        let source = CGEventSource(stateID: .hidSystemState)

        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)

        keyDown?.flags = flags
        keyUp?.flags = flags

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Persistence

    private func loadAPIKey() {
        apiKey = UserDefaults.standard.string(forKey: "assemblyai_api_key") ?? ""
    }

    func saveAPIKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: "assemblyai_api_key")
    }

    private func loadVoiceCommands() {
        if let data = UserDefaults.standard.data(forKey: "voice_commands"),
           let commands = try? JSONDecoder().decode([VoiceCommand].self, from: data) {
            voiceCommands = commands
        }
    }

    func saveVoiceCommands() {
        if let data = try? JSONEncoder().encode(voiceCommands) {
            UserDefaults.standard.set(data, forKey: "voice_commands")
        }
    }
}
