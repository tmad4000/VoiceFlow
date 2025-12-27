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
    private var lastExecutedEndWordIndexByCommand: [String: Int] = [:]
    private var currentUtteranceHadCommand = false
    private let commandPrefixToken = "voiceflow"
    private let expectsFormattedTurns = true

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

        assemblyAIService?.$latestTurn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turn in
                guard let turn else { return }
                self?.handleTurn(turn)
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

    private func handleTurn(_ turn: TranscriptTurn) {
        if !turn.words.isEmpty {
            currentTranscript = assembleDisplayText(from: turn.words)
        } else if !turn.transcript.isEmpty {
            currentTranscript = turn.transcript
        }

        if microphoneMode == .wake, !turn.isFormatted {
            processVoiceCommands(turn)
        } else if microphoneMode == .on {
            handleDictationTurn(turn)
        }

        if turn.endOfTurn {
            resetUtteranceState()
        }
    }

    private func handleDictationTurn(_ turn: TranscriptTurn) {
        guard !currentUtteranceHadCommand else { return }

        let shouldType = turn.isFormatted || (!expectsFormattedTurns && turn.endOfTurn)
        guard shouldType, !turn.transcript.isEmpty else { return }
        typeText(turn.transcript)
    }

    private struct PendingCommandMatch {
        let key: String
        let startWordIndex: Int
        let endWordIndex: Int
        let isPrefixed: Bool
        let isStable: Bool
        let haltsProcessing: Bool
        let action: () -> Void
    }

    private func processVoiceCommands(_ turn: TranscriptTurn) {
        let normalizedTokens = normalizedWordTokens(from: turn.words)
        guard !normalizedTokens.isEmpty else { return }
        let tokenStrings = normalizedTokens.map { $0.token }

        var matches: [PendingCommandMatch] = []

        let systemCommands: [(phrase: String, key: String, haltsProcessing: Bool, action: () -> Void)] = [
            ("microphone on", "system.microphone_on", true, { [weak self] in self?.setMode(.on) }),
            ("start dictation", "system.start_dictation", true, { [weak self] in self?.setMode(.on) }),
            ("microphone off", "system.microphone_off", true, { [weak self] in self?.setMode(.off) }),
            ("stop dictation", "system.stop_dictation", true, { [weak self] in self?.setMode(.off) })
        ]

        for systemCommand in systemCommands {
            let phraseTokens = tokenizePhrase(systemCommand.phrase)
            for range in findMatches(phraseTokens: phraseTokens, in: tokenStrings) {
                let startTokenIndex = range.lowerBound
                let endTokenIndex = range.upperBound - 1
                let startWordIndex = normalizedTokens[startTokenIndex].wordIndex
                let endWordIndex = normalizedTokens[endTokenIndex].wordIndex
                let isPrefixed = startTokenIndex > 0 && normalizedTokens[startTokenIndex - 1].token == commandPrefixToken
                let wordIndices = normalizedTokens[range].map { $0.wordIndex }
                let isStable = isPrefixed || isStableMatch(words: turn.words, wordIndices: wordIndices)
                matches.append(PendingCommandMatch(
                    key: systemCommand.key,
                    startWordIndex: startWordIndex,
                    endWordIndex: endWordIndex,
                    isPrefixed: isPrefixed,
                    isStable: isStable,
                    haltsProcessing: systemCommand.haltsProcessing,
                    action: systemCommand.action
                ))
            }
        }

        for command in voiceCommands where command.isEnabled {
            let phraseTokens = tokenizePhrase(command.phrase)
            for range in findMatches(phraseTokens: phraseTokens, in: tokenStrings) {
                let startTokenIndex = range.lowerBound
                let endTokenIndex = range.upperBound - 1
                let startWordIndex = normalizedTokens[startTokenIndex].wordIndex
                let endWordIndex = normalizedTokens[endTokenIndex].wordIndex
                let isPrefixed = startTokenIndex > 0 && normalizedTokens[startTokenIndex - 1].token == commandPrefixToken
                let wordIndices = normalizedTokens[range].map { $0.wordIndex }
                let isStable = isPrefixed || isStableMatch(words: turn.words, wordIndices: wordIndices)
                let key = "user.\(command.id.uuidString)"
                matches.append(PendingCommandMatch(
                    key: key,
                    startWordIndex: startWordIndex,
                    endWordIndex: endWordIndex,
                    isPrefixed: isPrefixed,
                    isStable: isStable,
                    haltsProcessing: false,
                    action: { [weak self] in self?.executeKeyboardShortcut(command.shortcut) }
                ))
            }
        }

        matches.sort {
            if $0.startWordIndex == $1.startWordIndex {
                return $0.endWordIndex > $1.endWordIndex
            }
            return $0.startWordIndex < $1.startWordIndex
        }

        for match in matches {
            guard match.isStable else { continue }
            let lastEndIndex = lastExecutedEndWordIndexByCommand[match.key] ?? -1
            guard match.endWordIndex > lastEndIndex else { continue }

            match.action()
            lastExecutedEndWordIndexByCommand[match.key] = match.endWordIndex
            currentUtteranceHadCommand = true

            if match.haltsProcessing {
                break
            }
        }
    }

    private func resetUtteranceState() {
        lastExecutedEndWordIndexByCommand.removeAll()
        currentUtteranceHadCommand = false
    }

    private func assembleDisplayText(from words: [TranscriptWord]) -> String {
        words.map { $0.text }.joined(separator: " ")
    }

    private func normalizeToken(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private struct NormalizedToken {
        let token: String
        let wordIndex: Int
    }

    private func normalizedWordTokens(from words: [TranscriptWord]) -> [NormalizedToken] {
        var tokens: [NormalizedToken] = []
        tokens.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            let token = normalizeToken(word.text)
            guard !token.isEmpty else { continue }
            tokens.append(NormalizedToken(token: token, wordIndex: index))
        }
        return tokens
    }

    private func tokenizePhrase(_ phrase: String) -> [String] {
        phrase.split(whereSeparator: { $0.isWhitespace })
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func isStableMatch(words: [TranscriptWord], wordIndices: [Int]) -> Bool {
        for index in wordIndices {
            if words.indices.contains(index), words[index].isFinal == false {
                return false
            }
        }
        return true
    }

    private func findMatches(phraseTokens: [String], in tokens: [String]) -> [Range<Int>] {
        guard !phraseTokens.isEmpty, tokens.count >= phraseTokens.count else { return [] }
        var ranges: [Range<Int>] = []
        let lastStart = tokens.count - phraseTokens.count
        for startIndex in 0...lastStart {
            let window = tokens[startIndex..<(startIndex + phraseTokens.count)]
            if Array(window) == phraseTokens {
                ranges.append(startIndex..<(startIndex + phraseTokens.count))
            }
        }
        return ranges
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
