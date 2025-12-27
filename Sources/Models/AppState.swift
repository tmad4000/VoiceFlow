import Foundation
import Combine
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.voiceflow", category: "app")

/// Utterance detection mode presets
enum UtteranceMode: String, CaseIterable, Codable {
    case quick = "quick"
    case balanced = "balanced"
    case patient = "patient"
    case dictation = "dictation"
    case extraLong = "extra_long"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .balanced: return "Balanced"
        case .patient: return "Patient"
        case .dictation: return "Dictation"
        case .extraLong: return "Extra Long"
        case .custom: return "Custom"
        }
    }

    var description: String {
        switch self {
        case .quick: return "Fast responses, may cut off"
        case .balanced: return "Good for most uses"
        case .patient: return "Allows natural pauses"
        case .dictation: return "Long-form with thinking pauses"
        case .extraLong: return "Maximum pause length for deep dictation"
        case .custom: return "Manual configuration"
        }
    }

    /// End-of-turn confidence threshold (0.0 - 1.0)
    var confidenceThreshold: Double {
        switch self {
        case .quick: return 0.5
        case .balanced: return 0.7
        case .patient: return 0.8
        case .dictation: return 0.85
        case .extraLong: return 0.95
        case .custom: return 0.7
        }
    }

    /// Minimum silence after confident end-of-turn (milliseconds)
    var silenceThresholdMs: Int {
        switch self {
        case .quick: return 100
        case .balanced: return 160
        case .patient: return 400
        case .dictation: return 560
        case .extraLong: return 2000
        case .custom: return 160
        }
    }
}

/// Main application state management
@MainActor
class AppState: ObservableObject {
    @Published var microphoneMode: MicrophoneMode = .off
    @Published var currentTranscript: String = ""
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var apiKey: String = ""
    @Published var voiceCommands: [VoiceCommand] = VoiceCommand.defaults
    @Published var isPanelVisible: Bool = true
    @Published var currentWords: [TranscriptWord] = []
    @Published var commandDelayMs: Double = 0
    @Published var liveDictationEnabled: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var isAccessibilityGranted: Bool = false
    @Published var isMicrophoneGranted: Bool = false
    @Published var utteranceMode: UtteranceMode = .balanced
    @Published var customConfidenceThreshold: Double = 0.7
    @Published var customSilenceThresholdMs: Int = 160

    var panelVisibilityHandler: ((Bool) -> Void)?

    private var audioCaptureManager: AudioCaptureManager?
    private var assemblyAIService: AssemblyAIService?
    private var cancellables = Set<AnyCancellable>()
    private var lastExecutedEndWordIndexByCommand: [String: Int] = [:]
    private var currentUtteranceHadCommand = false
    private let commandPrefixToken = "voiceflow"
    private let expectsFormattedTurns = true
    private var pendingCommandExecutions = Set<PendingExecutionKey>()
    private var lastCommandExecutionTime: Date?
    private let cancelWindowSeconds: TimeInterval = 2
    private let undoShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])
    private var typedFinalWordCount = 0
    private var forceEndPending = false
    private var forceEndRequestedAt: Date?
    private let forceEndTimeoutSeconds: TimeInterval = 2.0
    private var lastTypedTurnOrder = -1

    /// Effective confidence threshold based on mode
    var effectiveConfidenceThreshold: Double {
        utteranceMode == .custom ? customConfidenceThreshold : utteranceMode.confidenceThreshold
    }

    /// Effective silence threshold based on mode
    var effectiveSilenceThresholdMs: Int {
        utteranceMode == .custom ? customSilenceThresholdMs : utteranceMode.silenceThresholdMs
    }

    init() {
        loadAPIKey()
        loadVoiceCommands()
        loadCommandDelay()
        loadLiveDictationEnabled()
        loadUtteranceSettings()
        checkAccessibilityPermission(silent: true)
        checkMicrophonePermission()
    }

    func checkAccessibilityPermission(silent: Bool = true) {
        if silent {
            let trusted = AXIsProcessTrusted()
            isAccessibilityGranted = trusted
            logger.info("Accessibility permission (silent check): \(trusted ? "GRANTED" : "NOT GRANTED")")
        } else {
            // Use AXIsProcessTrustedWithOptions to prompt user if not trusted
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            isAccessibilityGranted = trusted
            logger.info("Accessibility permission (prompted): \(trusted ? "GRANTED" : "NOT GRANTED")")

            if !trusted {
                logger.warning("CGEvent typing will not work without accessibility permission!")
                // Show our custom alert after the system prompt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if self?.isAccessibilityGranted == false {
                        self?.showRestartPrompt()
                    }
                }
            }
        }
    }

    func recheckAccessibilityPermission() {
        checkAccessibilityPermission(silent: true)
    }

    func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[VoiceFlow] Microphone auth status: \(status.rawValue)")
        switch status {
        case .authorized:
            isMicrophoneGranted = true
            print("[VoiceFlow] Microphone permission: granted")
        case .notDetermined:
            isMicrophoneGranted = false
            print("[VoiceFlow] Microphone permission: not determined")
        case .denied, .restricted:
            isMicrophoneGranted = false
            print("[VoiceFlow] Microphone permission: denied or restricted")
        @unknown default:
            isMicrophoneGranted = false
            print("[VoiceFlow] Microphone permission: unknown")
        }
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.isMicrophoneGranted = granted
                logger.info("Microphone permission request result: \(granted ? "granted" : "denied")")
            }
        }
    }

    var microphoneAuthStatusRaw: Int {
        AVCaptureDevice.authorizationStatus(for: .audio).rawValue
    }

    var microphoneAuthStatusDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return "Not Determined (0)"
        case .restricted: return "Restricted (1)"
        case .denied: return "Denied (2)"
        case .authorized: return "Authorized (3)"
        @unknown default: return "Unknown"
        }
    }

    var accessibilityStatusDescription: String {
        AXIsProcessTrusted() ? "Trusted" : "Not Trusted"
    }

    private func showRestartPrompt() {
        let alert = NSAlert()
        alert.messageText = "App Restart Required"
        alert.informativeText = "VoiceFlow needs to restart to detect the new permissions. Please click 'Restart App' after you have granted permission in System Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart App")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            restartApp()
        }
    }

    private func restartApp() {
        let executablePath = Bundle.main.executablePath!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = []

        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            logger.error("Failed to restart: \(error.localizedDescription)")
        }
    }

    func setMode(_ mode: MicrophoneMode) {
        // Check permissions before enabling active modes
        if (mode == .on || mode == .wake) && !isAccessibilityGranted {
             checkAccessibilityPermission(silent: false)
             // If still not granted (user hit cancel or system denied), do we switch?
             // We can switch, but maybe show a warning?
             // For now, let's let them switch but the prompt will have appeared.
        }

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
        forceEndPending = false
        forceEndRequestedAt = nil
        lastTypedTurnOrder = -1

        // Initialize services
        assemblyAIService = AssemblyAIService(apiKey: apiKey)
        audioCaptureManager = AudioCaptureManager()

        // Configure utterance detection
        let utteranceConfig = UtteranceConfig(
            confidenceThreshold: effectiveConfidenceThreshold,
            silenceThresholdMs: effectiveSilenceThresholdMs
        )
        assemblyAIService?.setUtteranceConfig(utteranceConfig)

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

        // Connect audio level for visualization
        audioCaptureManager?.onAudioLevel = { [weak self] level in
            self?.audioLevel = level
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
        audioLevel = 0.0
    }

    private func handleTurn(_ turn: TranscriptTurn) {
        let fallbackTranscript = turn.transcript.isEmpty ? (turn.utterance ?? "") : turn.transcript
        if !turn.words.isEmpty {
            currentWords = turn.words
            if !fallbackTranscript.isEmpty {
                currentTranscript = fallbackTranscript
            } else {
                currentTranscript = assembleDisplayText(from: turn.words)
            }
        } else if !fallbackTranscript.isEmpty {
            currentWords = []
            currentTranscript = fallbackTranscript
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
        logger.info("handleDictationTurn: isFormatted=\(turn.isFormatted), endOfTurn=\(turn.endOfTurn), transcript=\"\(turn.transcript.prefix(50))...\"")

        if forceEndPending, let requestedAt = forceEndRequestedAt,
           Date().timeIntervalSince(requestedAt) > forceEndTimeoutSeconds {
            logger.info("Force end request expired without end-of-turn")
            forceEndPending = false
            forceEndRequestedAt = nil
        }

        guard !currentUtteranceHadCommand else {
            logger.debug("Skipping - utterance had command")
            return
        }
        if liveDictationEnabled {
            handleLiveDictationTurn(turn)
            return
        }

        let isForceEndTurn = forceEndPending && turn.endOfTurn
        let shouldType = turn.isFormatted || (!expectsFormattedTurns && turn.endOfTurn) || isForceEndTurn
        var textToType = turn.transcript
        if textToType.isEmpty, isForceEndTurn {
            textToType = turn.utterance ?? assembleDisplayText(from: turn.words)
        }
        logger.info("shouldType=\(shouldType) (isFormatted=\(turn.isFormatted), expectsFormattedTurns=\(self.expectsFormattedTurns), endOfTurn=\(turn.endOfTurn), forceEnd=\(isForceEndTurn))")

        if let turnOrder = turn.turnOrder, turnOrder <= lastTypedTurnOrder {
            logger.debug("Skipping duplicate turn order \(turnOrder)")
            return
        }

        guard shouldType, !textToType.isEmpty else {
            logger.debug("Not typing: shouldType=\(shouldType), isEmpty=\(textToType.isEmpty)")
            return
        }

        if isForceEndTurn, turn.transcript.isEmpty {
            logger.info("Force end typing unformatted utterance")
        }

        typeText(textToType, appendSpace: true)
        if let turnOrder = turn.turnOrder {
            lastTypedTurnOrder = turnOrder
        }
        if isForceEndTurn {
            forceEndPending = false
            forceEndRequestedAt = nil
        }
    }

    private func handleLiveDictationTurn(_ turn: TranscriptTurn) {
        guard !turn.isFormatted else {
            if turn.endOfTurn {
                typeText(" ", appendSpace: false)
            }
            return
        }

        let finalWords = turn.words.filter { $0.isFinal == true }.map { $0.text }
        guard finalWords.count > typedFinalWordCount else { return }
        let newWords = finalWords[typedFinalWordCount...]
        let prefix = typedFinalWordCount > 0 ? " " : ""
        typeText(prefix + newWords.joined(separator: " "), appendSpace: false)
        typedFinalWordCount = finalWords.count
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

    private struct PendingExecutionKey: Hashable {
        let key: String
        let endWordIndex: Int
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
            ("stop dictation", "system.stop_dictation", true, { [weak self] in self?.setMode(.off) }),
            ("cancel that", "system.cancel_command", true, { [weak self] in self?.cancelLastCommandIfRecent() }),
            ("no wait", "system.cancel_command", true, { [weak self] in self?.cancelLastCommandIfRecent() }),
            ("send that", "system.force_end_utterance", false, { [weak self] in self?.forceEndUtterance() }),
            ("done", "system.force_end_utterance", false, { [weak self] in self?.forceEndUtterance() })
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

            if match.isPrefixed || match.haltsProcessing || commandDelayMs <= 0 {
                executeMatch(match)
                if match.haltsProcessing {
                    break
                }
            } else {
                scheduleMatch(match)
            }
        }
    }

    private func resetUtteranceState() {
        lastExecutedEndWordIndexByCommand.removeAll()
        currentUtteranceHadCommand = false
        pendingCommandExecutions.removeAll()
        typedFinalWordCount = 0
        forceEndPending = false
        forceEndRequestedAt = nil
    }

    private func executeMatch(_ match: PendingCommandMatch) {
        match.action()
        lastExecutedEndWordIndexByCommand[match.key] = match.endWordIndex
        currentUtteranceHadCommand = true
        if match.key.hasPrefix("user.") {
            lastCommandExecutionTime = Date()
        }
    }

    private func scheduleMatch(_ match: PendingCommandMatch) {
        let pendingKey = PendingExecutionKey(key: match.key, endWordIndex: match.endWordIndex)
        guard !pendingCommandExecutions.contains(pendingKey) else { return }
        pendingCommandExecutions.insert(pendingKey)

        let delaySeconds = commandDelayMs / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self else { return }
            self.pendingCommandExecutions.remove(pendingKey)

            let lastEndIndex = self.lastExecutedEndWordIndexByCommand[match.key] ?? -1
            guard match.endWordIndex > lastEndIndex else { return }
            self.executeMatch(match)
        }
    }

    private func cancelLastCommandIfRecent() {
        guard let lastExecution = lastCommandExecutionTime,
              Date().timeIntervalSince(lastExecution) <= cancelWindowSeconds else {
            return
        }
        executeKeyboardShortcut(undoShortcut)
    }

    func showPanelWindow() {
        isPanelVisible = true
        panelVisibilityHandler?(true)
    }

    func hidePanelWindow() {
        isPanelVisible = false
        panelVisibilityHandler?(false)
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

    private func typeText(_ text: String, appendSpace: Bool) {
        // Check accessibility first
        guard AXIsProcessTrusted() else {
            logger.error("Cannot type - accessibility permission not granted")
            return
        }

        let output = appendSpace ? text + " " : text
        logger.info("Typing: \"\(output)\"")

        let source = CGEventSource(stateID: .hidSystemState)
        for char in output {
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

    private func loadCommandDelay() {
        let stored = UserDefaults.standard.double(forKey: "command_delay_ms")
        commandDelayMs = stored
    }

    func saveCommandDelay(_ value: Double) {
        commandDelayMs = value
        UserDefaults.standard.set(value, forKey: "command_delay_ms")
    }

    private func loadLiveDictationEnabled() {
        liveDictationEnabled = UserDefaults.standard.bool(forKey: "live_dictation_enabled")
    }

    func saveLiveDictationEnabled(_ value: Bool) {
        liveDictationEnabled = value
        UserDefaults.standard.set(value, forKey: "live_dictation_enabled")
    }

    private func loadUtteranceSettings() {
        if let modeString = UserDefaults.standard.string(forKey: "utterance_mode"),
           let mode = UtteranceMode(rawValue: modeString) {
            utteranceMode = mode
        }
        let storedConfidence = UserDefaults.standard.double(forKey: "custom_confidence_threshold")
        if storedConfidence > 0 {
            customConfidenceThreshold = storedConfidence
        }
        let storedSilence = UserDefaults.standard.integer(forKey: "custom_silence_threshold_ms")
        if storedSilence > 0 {
            customSilenceThresholdMs = storedSilence
        }
    }

    func saveUtteranceMode(_ mode: UtteranceMode) {
        utteranceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "utterance_mode")
    }

    func saveCustomConfidenceThreshold(_ value: Double) {
        customConfidenceThreshold = value
        UserDefaults.standard.set(value, forKey: "custom_confidence_threshold")
        // Auto-switch to custom mode when manually adjusting
        if utteranceMode != .custom {
            saveUtteranceMode(.custom)
        }
    }

    func saveCustomSilenceThreshold(_ value: Int) {
        customSilenceThresholdMs = value
        UserDefaults.standard.set(value, forKey: "custom_silence_threshold_ms")
        // Auto-switch to custom mode when manually adjusting
        if utteranceMode != .custom {
            saveUtteranceMode(.custom)
        }
    }

    /// Force end of current utterance immediately
    func forceEndUtterance() {
        logger.info("Force end utterance requested (connected=\(self.isConnected ? "true" : "false"))")
        forceEndPending = true
        forceEndRequestedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + forceEndTimeoutSeconds) { [weak self] in
            guard let self else { return }
            if self.forceEndPending, let requestedAt = self.forceEndRequestedAt,
               Date().timeIntervalSince(requestedAt) >= self.forceEndTimeoutSeconds {
                logger.info("Force end request timed out without end-of-turn")
                self.forceEndPending = false
                self.forceEndRequestedAt = nil
            }
        }
        assemblyAIService?.forceEndUtterance()
    }
}
