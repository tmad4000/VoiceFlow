import Foundation
import Combine
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import AVFoundation
import Speech
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
        case .extraLong: return 3000
        case .custom: return 160
        }
    }

    /// Maximum silence allowed during a turn regardless of confidence (milliseconds)
    var maxTurnSilenceMs: Int {
        switch self {
        case .extraLong: return 5000
        default: return 1280 // Default AssemblyAI value
        }
    }
}

/// Dictation provider options
enum DictationProvider: String, CaseIterable, Codable, Identifiable {
    case auto = "auto"
    case online = "online"
    case offline = "offline"

    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return "Auto (Network Aware)"
        case .online: return "Online (AssemblyAI)"
        case .offline: return "Offline (Mac Speech)"
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
    @Published var isSpeechGranted: Bool = false
    @Published var utteranceMode: UtteranceMode = .balanced
    @Published var customConfidenceThreshold: Double = 0.7
    @Published var customSilenceThresholdMs: Int = 160
    @Published var activeBehavior: ActiveBehavior = .mixed
    @Published var lastCommandName: String? = nil
    @Published var isCommandFlashActive: Bool = false
    @Published var debugLog: [String] = []
    @Published var dictationHistory: [String] = []
    @Published var vocabularyPrompt: String = ""
    @Published var autoPopulateVocabulary: Bool = true  // Auto-add commands to vocabulary
    @Published var ideaFlowShortcut: KeyboardShortcut? = nil
    @Published var ideaFlowURL: String = ""
    @Published var isOffline: Bool = false
    @Published var dictationProvider: DictationProvider = .auto
    @Published var sleepTimerEnabled: Bool = false
    @Published var sleepTimerMinutes: Double = 15
    @Published var launchMode: MicrophoneMode = .sleep

    /// Built-in system commands for reference in UI
    static let systemCommandList: [(phrase: String, description: String)] = [
        ("wake up", "Switch to On mode"),
        ("microphone on", "Switch to On mode"),
        ("flow on", "Switch to On mode"),
        ("go to sleep", "Switch to Sleep mode"),
        ("flow sleep", "Switch to Sleep mode"),
        ("flow off", "Turn microphone completely Off"),
        ("microphone off", "Turn microphone completely Off"),
        ("stop dictation", "Turn microphone completely Off"),
        ("cancel that", "Undo last keyboard command"),
        ("no wait", "Undo last keyboard command"),
        ("submit dictation", "Force finalize and type current speech"),
        ("send dictation", "Force finalize and type current speech"),
        ("window recent", "Switch to previous application"),
        ("window recent 2", "Switch to 2nd most recent application"),
        ("window next", "Cycle to next window in same app (⌘`)"),
        ("window previous", "Cycle to previous window in same app (⌘⇧`)"),
        ("focus [app]", "Switch to a running application by name"),
        ("spell [text]", "Type characters one-by-one without spaces"),
        ("save to idea flow", "Copy last dictation and open Idea Flow")
    ]

    var panelVisibilityHandler: ((Bool) -> Void)?

    private var audioCaptureManager: AudioCaptureManager?
    private var assemblyAIService: AssemblyAIService?
    private var appleSpeechService: AppleSpeechService?
    private var networkMonitor = NetworkMonitor()
    private var windowManager = WindowManager()
    private var cancellables = Set<AnyCancellable>()
    private var sleepTimer: Timer?
    private var lastExecutedEndWordIndexByCommand: [String: Int] = [:]
    private var currentUtteranceHadCommand = false
    private var wakeUpTime: Date?
    private let wakeUpGracePeriod: TimeInterval = 0.8  // Don't type for 0.8s after waking
    private let commandPrefixToken = "voiceflow"
    private let expectsFormattedTurns = true
    private var pendingCommandExecutions = Set<PendingExecutionKey>()
    private var lastCommandExecutionTime: Date?
    private let cancelWindowSeconds: TimeInterval = 2
    private let undoShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])
    private var typedFinalWordCount = 0
    private var didTypeDictationThisUtterance = false
    private var hasTypedInSession = false  // Tracks if we've typed anything since going On
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

    /// Whether the app should use the offline provider based on settings and connectivity
    var effectiveIsOffline: Bool {
        switch dictationProvider {
        case .auto: return isOffline
        case .online: return false
        case .offline: return true
        }
    }

    init() {
        loadAPIKey()
        loadVoiceCommands()
        loadCommandDelay()
        loadLiveDictationEnabled()
        loadUtteranceSettings()
        loadActiveBehavior()
        loadLaunchMode()
        loadDictationProvider()
        loadDictationHistory()
        loadVocabularyPrompt()
        loadIdeaFlowSettings()
        loadSleepTimerSettings()
        checkAccessibilityPermission(silent: true)
        checkMicrophonePermission()
        checkSpeechPermission()
        
        // Monitor network status
        networkMonitor.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                let wasEffectiveOffline = self.effectiveIsOffline
                self.isOffline = !connected
                
                if wasEffectiveOffline != self.effectiveIsOffline {
                    if self.effectiveIsOffline {
                        self.logDebug("Network change: Switching to Mac Speech Model")
                    } else {
                        self.logDebug("Network change: AssemblyAI available")
                    }
                    
                    // If we are currently listening, we need to restart to switch services
                    if self.microphoneMode != .off {
                        let currentMode = self.microphoneMode
                        self.logDebug("Restarting services due to network change")
                        self.stopListening()
                        self.setMode(currentMode)
                    }
                }
            }
            .store(in: &cancellables)

        // Start in the preferred launch mode
        let initialMode = launchMode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setMode(initialMode)
        }
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

    func checkSpeechPermission() {
        let status = SFSpeechRecognizer.authorizationStatus()
        print("[VoiceFlow] Speech recognition auth status: \(status.rawValue)")
        switch status {
        case .authorized:
            isSpeechGranted = true
        default:
            isSpeechGranted = false
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

    func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isSpeechGranted = status == .authorized
                logger.info("Speech permission request result: \(status.rawValue)")
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

    func logDebug(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debugLog.insert(entry, at: 0)
            if self.debugLog.count > 100 {
                self.debugLog.removeLast()
            }
        }
        logger.info("\(message)")
    }

    func clearDebugLog() {
        debugLog.removeAll()
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
        // Check and request permissions before enabling active modes
        if mode == .on || mode == .sleep {
            if !isAccessibilityGranted {
                checkAccessibilityPermission(silent: false)
            }
            if !isMicrophoneGranted {
                requestMicrophonePermission()
            }
            if !isSpeechGranted {
                requestSpeechPermission()
            }
        }

        let previousMode = microphoneMode
        microphoneMode = mode
        logDebug("Mode changed: \(previousMode.rawValue) -> \(mode.rawValue)")

        if mode == .on {
            resetSleepTimer()
        } else {
            stopSleepTimer()
        }

        // Clear UI state when waking up or switching active modes
        if previousMode == .sleep && mode == .on {
            currentTranscript = ""
            currentWords = []
            // Mark that we just woke up to prevent the "wake up" phrase from typing
            currentUtteranceHadCommand = true
            wakeUpTime = Date()  // Grace period to ignore residual wake word audio
        }

        // Reset session typing state when leaving On mode or starting fresh
        if mode != .on {
            hasTypedInSession = false
        } else if previousMode == .off {
            hasTypedInSession = false
        }

        switch mode {
        case .off:
            // If we are currently in an utterance, we might want to wait a bit
            // but for now, let's just stop.
            // IMPROVEMENT: The system command caller will handle the delay if needed.
            stopListening()
        case .on:
            if previousMode == .off {
                startListening(transcribeMode: true)
            } else {
                assemblyAIService?.setTranscribeMode(true)
                appleSpeechService?.setTranscribeMode(true)
            }
        case .sleep:
            if previousMode == .off {
                startListening(transcribeMode: false)
            } else {
                assemblyAIService?.setTranscribeMode(false)
                appleSpeechService?.setTranscribeMode(false)
            }
        }
    }

    private func startListening(transcribeMode: Bool) {
        logDebug("Starting services (transcribeMode: \(transcribeMode))")
        
        // Always need AudioCaptureManager
        audioCaptureManager = AudioCaptureManager()
        
        if effectiveIsOffline {
            startAppleSpeech(transcribeMode: transcribeMode)
        } else {
            startAssemblyAI(transcribeMode: transcribeMode)
        }
    }

    private func startAssemblyAI(transcribeMode: Bool) {
        guard !apiKey.isEmpty else {
            errorMessage = "Please set your AssemblyAI API key in Settings"
            logDebug("Error: API key missing")
            return
        }

        errorMessage = nil
        forceEndPending = false
        forceEndRequestedAt = nil
        lastTypedTurnOrder = -1

        // Initialize service
        assemblyAIService = AssemblyAIService(apiKey: apiKey)

        // Configure utterance detection
        let utteranceConfig = UtteranceConfig(
            confidenceThreshold: effectiveConfidenceThreshold,
            silenceThresholdMs: effectiveSilenceThresholdMs,
            maxTurnSilenceMs: utteranceMode.maxTurnSilenceMs
        )
        assemblyAIService?.setUtteranceConfig(utteranceConfig)

        // Set up bindings
        assemblyAIService?.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
                self?.logDebug(connected ? "Connected to AssemblyAI" : "Disconnected from AssemblyAI")
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
                if let error = error {
                    self?.logDebug("API Error: \(error)")
                }
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
        assemblyAIService?.setFormatTurns(!liveDictationEnabled)
        assemblyAIService?.setVocabularyPrompt(effectiveVocabularyPrompt)
        logDebug("Vocabulary: \(effectiveVocabularyPrompt.prefix(100))...")
        assemblyAIService?.connect()
        audioCaptureManager?.startCapture()
    }

    private func startAppleSpeech(transcribeMode: Bool) {
        logDebug("Using Apple Speech Recognition (Offline Mode)")
        errorMessage = nil
        forceEndPending = false
        forceEndRequestedAt = nil
        lastTypedTurnOrder = -1

        appleSpeechService = AppleSpeechService()
        
        appleSpeechService?.$latestTurn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turn in
                guard let turn else { return }
                self?.handleTurn(turn)
            }
            .store(in: &cancellables)

        appleSpeechService?.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error
                if let error = error {
                    self?.logDebug("Apple Speech Error: \(error)")
                }
            }
            .store(in: &cancellables)

        // Connect audio output to Apple Speech Service
        audioCaptureManager?.onAudioData = { [weak self] data in
            self?.appleSpeechService?.sendAudio(data)
        }

        // Connect audio level for visualization
                audioCaptureManager?.onAudioLevel = { [weak self] level in
                    self?.audioLevel = level
                }
                
                appleSpeechService?.setTranscribeMode(transcribeMode)
                appleSpeechService?.startRecognition(addsPunctuation: !liveDictationEnabled)
                audioCaptureManager?.startCapture()
                // For Apple speech, we consider it "connected" if the manager is capturing
        isConnected = true 
    }

    private func stopListening() {
        logDebug("Stopping services")
        audioCaptureManager?.stopCapture()
        assemblyAIService?.disconnect()
        appleSpeechService?.disconnect()
        audioCaptureManager = nil
        assemblyAIService = nil
        appleSpeechService = nil
        cancellables.removeAll()
        isConnected = false
        audioLevel = 0.0
    }

    private func handleTurn(_ turn: TranscriptTurn) {
        // Reset sleep timer on any speech detection
        if microphoneMode == .on {
            resetSleepTimer()
        }
        
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

        switch microphoneMode {
        case .sleep:
            processVoiceCommands(turn)
        case .on:
            // Always check for commands if behavior allows
            if activeBehavior != .dictation {
                processVoiceCommands(turn)
            }
            
            // Handle dictation if behavior allows
            if activeBehavior != .command {
                if liveDictationEnabled {
                    handleLiveDictationTurn(turn)
                } else {
                    handleDictationTurn(turn)
                }
            }
        case .off:
            break
        }

        if turn.endOfTurn {
            if !expectsFormattedTurns || turn.isFormatted {
                resetUtteranceState()
            }
        }
    }

    private func handleDictationTurn(_ turn: TranscriptTurn) {
        logger.info("handleDictationTurn: isFormatted=\(turn.isFormatted), endOfTurn=\(turn.endOfTurn), transcript=\"\(turn.transcript.prefix(50))...\"")

        // Skip typing during wake-up grace period to avoid typing residual wake word audio
        if let wakeTime = wakeUpTime, Date().timeIntervalSince(wakeTime) < wakeUpGracePeriod {
            logger.debug("Skipping dictation during wake-up grace period")
            return
        }

        if forceEndPending, let requestedAt = forceEndRequestedAt,
           Date().timeIntervalSince(requestedAt) > forceEndTimeoutSeconds {
            logger.info("Force end request expired without end-of-turn")
            forceEndPending = false
            forceEndRequestedAt = nil
        }

        let isForceEndTurn = forceEndPending && turn.endOfTurn

        let rawTranscript: String
        if let utterance = turn.utterance, utterance.count > turn.transcript.count {
            rawTranscript = utterance
        } else if turn.transcript.isEmpty {
            rawTranscript = turn.utterance ?? ""
        } else {
            rawTranscript = turn.transcript
        }

        var textToType = rawTranscript
        
        // If utterance had a command, we might have already flushed the prefix.
        // We only want to type what came AFTER the commands.
        if currentUtteranceHadCommand && !isForceEndTurn {
            let lastCommandEndIndex = lastExecutedEndWordIndexByCommand.values.max() ?? -1
            if lastCommandEndIndex >= 0 && lastCommandEndIndex < turn.words.count - 1 {
                let wordsAfter = turn.words[(lastCommandEndIndex + 1)...]
                // Filter out punctuation-only words that often trail commands
                let filteredWords = wordsAfter.filter { word in
                    let stripped = word.text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                    return !stripped.isEmpty
                }
                textToType = assembleDisplayText(from: Array(filteredWords))
                logDebug("Utterance had command: typing only remaining words: \"\(textToType)\"")
            } else {
                // Command was at the end or covers everything, nothing more to type
                logger.debug("Command was at end of utterance")
                if didTypeDictationThisUtterance {
                    return
                }
            }
        }
        
        let shouldType = turn.isFormatted || (!expectsFormattedTurns && turn.endOfTurn) || isForceEndTurn
        
        if textToType.isEmpty, isForceEndTurn {
            textToType = turn.utterance ?? assembleDisplayText(from: turn.words)
            logger.info("Force end: using fallback text \"\(textToType)\"")
        }
        
        logger.info("handleDictationTurn logic: isFormatted=\(turn.isFormatted), endOfTurn=\(turn.endOfTurn), forceEnd=\(isForceEndTurn), shouldType=\(shouldType), textToType=\"\(textToType)\"")

        if let turnOrder = turn.turnOrder, turnOrder <= lastTypedTurnOrder {
            logger.debug("Skipping duplicate turn order \(turnOrder)")
            return
        }

        guard shouldType, !textToType.isEmpty else {
            logger.debug("Not typing: shouldType=\(shouldType), isEmpty=\(textToType.isEmpty)")
            if shouldType && textToType.isEmpty {
                logDebug("Skipping type: text is empty")
            }
            return
        }

        if isForceEndTurn, turn.transcript.isEmpty {
            logger.info("Force end typing unformatted utterance")
        }

        let processedText = preprocessDictation(textToType)
        logDebug("Initiating type action for turn \(turn.turnOrder ?? -1): \"\(processedText.prefix(20))...\"")
        typeText(processedText, appendSpace: true)
        if !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            didTypeDictationThisUtterance = true
            hasTypedInSession = true
        }
        
        if let turnOrder = turn.turnOrder {
            lastTypedTurnOrder = turnOrder
        }
        if isForceEndTurn {
            forceEndPending = false
            forceEndRequestedAt = nil
        }
    }

    private func preprocessDictation(_ text: String) -> String {
        var processed = text
        
        // 1. Handle "say" prefix (escape mode)
        // Use regex to find "say" at the beginning, ignoring optional trailing punctuation and whitespace
        var isLiteral = false
        let sayPattern = "^say[\\.,?!]?\\s*"
        if let regex = try? NSRegularExpression(pattern: sayPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: processed, options: [], range: NSRange(location: 0, length: processed.utf16.count)) {
            isLiteral = true
            // Remove the "say" prefix and the following whitespace/punctuation
            processed = (processed as NSString).substring(from: match.range.length)
        } else if processed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "say" {
            isLiteral = true
            processed = ""
        }
        
        // 1b. Handle "spell" prefix
        if !isLiteral && processed.lowercased().hasPrefix("spell ") {
            return "" // Handled by processVoiceCommands
        }
        
        if !isLiteral && processed.lowercased().hasPrefix("focus ") {
            return "" // Handled by processVoiceCommands
        }
        
        if !isLiteral && processed.lowercased().hasPrefix("save to idea flow") {
            return "" // Handled by processVoiceCommands
        }

        // 1c. Strip wake-up phrases that might leak through after mode switch
        let wakeUpPhrases = ["wake up", "microphone on", "flow on"]
        for phrase in wakeUpPhrases {
            if processed.lowercased().hasPrefix(phrase) {
                processed = String(processed.dropFirst(phrase.count))
                processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 2. Handle trailing mode-switch commands if they are at the very end
        // This allows "Hello world microphone off" to just type "Hello world"
        if !isLiteral {
            let trailingCommands = ["microphone off", "flow off", "stop dictation", "go to sleep", "flow sleep", "submit dictation", "send dictation"]
            for cmd in trailingCommands {
                if processed.lowercased().hasSuffix(cmd) {
                    processed = String(processed.prefix(processed.count - cmd.count))
                    processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        // 3. Handle inline text replacements (only if not literal)
        if !isLiteral {
            // Replace various forms of "new line" (case-insensitive)
            let newlinePatterns = ["new line", "newline"]
            for pattern in newlinePatterns {
                let range = NSRange(processed.startIndex..<processed.endIndex, in: processed)
                let regex = try? NSRegularExpression(pattern: "(?i)\(pattern)", options: [])
                processed = regex?.stringByReplacingMatches(in: processed, options: [], range: range, withTemplate: "\n") ?? processed
            }
            
            // Replace various forms of "spacebar" (case-insensitive)
            let spacePatterns = ["spacebar", "space bar"]
            for pattern in spacePatterns {
                let range = NSRange(processed.startIndex..<processed.endIndex, in: processed)
                let regex = try? NSRegularExpression(pattern: "(?i)\(pattern)", options: [])
                processed = regex?.stringByReplacingMatches(in: processed, options: [], range: range, withTemplate: " ") ?? processed
            }
            
            // 4. (REMOVED) Strip trailing punctuation
            // User requested to keep this for now to avoid unnecessary complexity.
        }
        
        return processed
    }



    private func handleLiveDictationTurn(_ turn: TranscriptTurn) {
        // Skip typing during wake-up grace period to avoid typing residual wake word audio
        if let wakeTime = wakeUpTime, Date().timeIntervalSince(wakeTime) < wakeUpGracePeriod {
            return
        }

        // If utterance had a command, we only care about words AFTER the command
        let lastCommandEndIndex = lastExecutedEndWordIndexByCommand.values.max() ?? -1
        let startIndex = max(typedFinalWordCount, lastCommandEndIndex + 1)

        // Helper to filter out punctuation-only words
        let filterPunctuation: (String) -> Bool = { word in
            !word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty
        }

        // Helper to process inline replacements (new line, spacebar, etc.)
        let processInlineReplacements: (String) -> String = { text in
            var result = text
            // Replace "new line" / "newline" with actual newline
            let newlinePatterns = ["new line", "newline"]
            for pattern in newlinePatterns {
                if let regex = try? NSRegularExpression(pattern: "(?i)\(pattern)", options: []) {
                    let range = NSRange(result.startIndex..<result.endIndex, in: result)
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
                }
            }
            // Replace "spacebar" / "space bar" with space
            let spacePatterns = ["spacebar", "space bar"]
            for pattern in spacePatterns {
                if let regex = try? NSRegularExpression(pattern: "(?i)\(pattern)", options: []) {
                    let range = NSRange(result.startIndex..<result.endIndex, in: result)
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
                }
            }
            // Strip system command phrases that might leak through (with optional trailing punctuation)
            let systemCommandPhrases = [
                "window recent two", "window recent 2", "window recent",
                "window previous", "window next",
                "cancel that", "no wait",
                "submit dictation", "send dictation",
                "save to idea flow",
                "copy that", "paste that", "cut that", "undo that", "redo that",
                "select all", "save that", "find that"
            ]
            for phrase in systemCommandPhrases {
                // Match phrase with optional trailing punctuation
                if let regex = try? NSRegularExpression(pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: phrase))[.,!?]?\\b?", options: []) {
                    let range = NSRange(result.startIndex..<result.endIndex, in: result)
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
                }
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If it's a formatted turn (Cloud model with formatting ON), we use word-level isFinal
        if turn.isFormatted {
            let finalWords = turn.words.filter { $0.isFinal == true }.map { $0.text }
            guard finalWords.count > startIndex else { return }
            let newWords = finalWords[startIndex...].filter(filterPunctuation)
            guard !newWords.isEmpty else { return }
            // Add space if continuing within utterance OR if we've typed before in this session
            let needsSpace = startIndex > 0 || hasTypedInSession
            let prefix = needsSpace ? " " : ""
            let rawText = prefix + newWords.joined(separator: " ")
            let textToType = processInlineReplacements(rawText)
            logDebug("Live typing delta (formatted): \"\(textToType)\"")
            typeText(textToType, appendSpace: false)
            if !textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didTypeDictationThisUtterance = true
                hasTypedInSession = true
            }
            typedFinalWordCount = finalWords.count
            return
        }

        // If it's unformatted (Live Dictation mode), the turn itself signals finality
        if turn.endOfTurn {
            // This is a FinalTranscript
            let allWords = turn.words.map { $0.text }
            guard allWords.count > startIndex else {
                typedFinalWordCount = 0 // Reset for next utterance
                return
            }
            let newWords = allWords[startIndex...].filter(filterPunctuation)
            guard !newWords.isEmpty else {
                typedFinalWordCount = 0
                return
            }
            // Add space if continuing within utterance OR if we've typed before in this session
            let needsSpace = startIndex > 0 || hasTypedInSession
            let prefix = needsSpace ? " " : ""
            let rawText = prefix + newWords.joined(separator: " ")
            let textToType = processInlineReplacements(rawText)
            logDebug("Live typing delta (final): \"\(textToType)\"")
            typeText(textToType, appendSpace: false)
            if !textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didTypeDictationThisUtterance = true
                hasTypedInSession = true
            }
            typedFinalWordCount = 0 // Reset after final
        } else {
            // PartialTranscript...
        }
    }

    private struct PendingCommandMatch {
        let key: String
        let startWordIndex: Int
        let endWordIndex: Int
        let isPrefixed: Bool
        let isStable: Bool
        let haltsProcessing: Bool
        let turn: TranscriptTurn
        let action: () -> Void
    }

    private struct PendingExecutionKey: Hashable {
        let key: String
        let endWordIndex: Int
    }

    private func processVoiceCommands(_ turn: TranscriptTurn) {
        let normalizedTokens = normalizedWordTokens(from: turn.words)
        guard !normalizedTokens.isEmpty else { return }
        
        // If the first word is "say", skip command processing for this utterance
        // Also check if the transcript starts with "say" (robustly with regex)
        let firstToken = normalizedTokens.first?.token
        let sayPattern = "^say[\\.,?!]?(\\s|$)"
        let regex = try? NSRegularExpression(pattern: sayPattern, options: [.caseInsensitive])
        let transcript = turn.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSayMatch = regex?.firstMatch(in: transcript, options: [], range: NSRange(location: 0, length: transcript.utf16.count)) != nil
                                     
        if firstToken == "say" || isSayMatch {
            logger.debug("Utterance starts with 'say', skipping command processing")
            return
        }

        // Voice Spelling Mode
        let lowerTranscript = turn.transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerTranscript.hasPrefix("spell ") {
            let textToSpell = String(turn.transcript.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if !textToSpell.isEmpty && turn.endOfTurn {
                logDebug("Voice Spelling: \"\(textToSpell)\"")
                // Type character by character without adding spaces
                typeText(textToSpell.replacingOccurrences(of: " ", with: ""), appendSpace: false)
                triggerCommandFlash(name: "Spell")
                return
            }
        }

        // Voice App Focusing
        if lowerTranscript.hasPrefix("focus ") {
            let appName = String(turn.transcript.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && turn.endOfTurn {
                logDebug("Focusing App: \"\(appName)\"")
                windowManager.focusApp(named: appName)
                triggerCommandFlash(name: "Focus")
                return
            }
        }

        let tokenStrings = normalizedTokens.map { $0.token }

        var matches: [PendingCommandMatch] = []

        // System commands based on current mode
        var systemCommands: [(phrase: String, key: String, name: String, haltsProcessing: Bool, action: () -> Void)] = []
        
        if microphoneMode == .sleep {
            systemCommands.append(contentsOf: [
                (phrase: "wake up", key: "system.wake_up", name: "On", haltsProcessing: true, action: { [weak self] in self?.setMode(.on) } as () -> Void),
                (phrase: "microphone on", key: "system.wake_up", name: "On", haltsProcessing: true, action: { [weak self] in self?.setMode(.on) } as () -> Void),
                (phrase: "flow on", key: "system.wake_up", name: "On", haltsProcessing: true, action: { [weak self] in self?.setMode(.on) } as () -> Void),
                // Also allow turning off from sleep mode
                (phrase: "microphone off", key: "system.microphone_off", name: "Off", haltsProcessing: true, action: { [weak self] in self?.setMode(.off) } as () -> Void),
                (phrase: "flow off", key: "system.microphone_off", name: "Off", haltsProcessing: true, action: { [weak self] in self?.setMode(.off) } as () -> Void),
                (phrase: "stop dictation", key: "system.microphone_off", name: "Off", haltsProcessing: true, action: { [weak self] in self?.setMode(.off) } as () -> Void)
            ])
        } else if microphoneMode == .on {
            systemCommands.append(contentsOf: [
                (phrase: "go to sleep", key: "system.go_to_sleep", name: "Sleep", haltsProcessing: true, action: { [weak self] in
                    // Delay slightly to allow any preceding dictation in the same utterance to type
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.setMode(.sleep)
                    }
                } as () -> Void),
                (phrase: "flow sleep", key: "system.go_to_sleep", name: "Sleep", haltsProcessing: true, action: { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.setMode(.sleep)
                    }
                } as () -> Void),
                (phrase: "microphone off", key: "system.microphone_off", name: "Off", haltsProcessing: true, action: { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.setMode(.off)
                    }
                } as () -> Void),
                (phrase: "flow off", key: "system.microphone_off", name: "Off", haltsProcessing: true, action: { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.setMode(.off)
                    }
                } as () -> Void),
                (phrase: "stop dictation", key: "system.microphone_off", name: "Off", haltsProcessing: true, action: { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.setMode(.off)
                    }
                } as () -> Void),
                (phrase: "cancel that", key: "system.cancel_command", name: "Cancel", haltsProcessing: true, action: { [weak self] in self?.cancelLastCommandIfRecent() } as () -> Void),
                (phrase: "no wait", key: "system.cancel_command", name: "Cancel", haltsProcessing: true, action: { [weak self] in self?.cancelLastCommandIfRecent() } as () -> Void),
                (phrase: "submit dictation", key: "system.force_end_utterance", name: "Submit", haltsProcessing: false, action: { [weak self] in self?.forceEndUtterance() } as () -> Void),
                (phrase: "send dictation", key: "system.force_end_utterance", name: "Send", haltsProcessing: false, action: { [weak self] in self?.forceEndUtterance() } as () -> Void),
                (phrase: "window recent", key: "system.window_recent", name: "Previous Window", haltsProcessing: true, action: { [weak self] in self?.windowManager.switchToRecent(index: 1) } as () -> Void),
                (phrase: "window recent 2", key: "system.window_recent_2", name: "Previous Window 2", haltsProcessing: true, action: { [weak self] in self?.windowManager.switchToRecent(index: 2) } as () -> Void),
                (phrase: "window recent two", key: "system.window_recent_2", name: "Previous Window 2", haltsProcessing: true, action: { [weak self] in self?.windowManager.switchToRecent(index: 2) } as () -> Void),
                // Window cycling within same app (Cmd+` and Cmd+Shift+`)
                (phrase: "window next", key: "system.window_next", name: "Next Window", haltsProcessing: true, action: { [weak self] in
                    self?.executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command]))
                } as () -> Void),
                (phrase: "window previous", key: "system.window_previous", name: "Previous Window", haltsProcessing: true, action: { [weak self] in
                    self?.executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command, .shift]))
                } as () -> Void),
                (phrase: "save to idea flow", key: "system.save_ideaflow", name: "Idea Flow", haltsProcessing: true, action: { [weak self] in self?.saveToIdeaFlow() } as () -> Void)
            ])
        }

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
                    turn: turn,
                    action: { [weak self] in
                        systemCommand.action()
                        self?.triggerCommandFlash(name: systemCommand.name)
                    }
                ))
            }
        }

        // User voice commands only in On mode (or if we want them in sleep? Usually just On)
        if microphoneMode == .on {
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
                        turn: turn,
                        action: { [weak self] in
                            if let text = command.replacementText, !text.isEmpty {
                                self?.typeText(text, appendSpace: true)
                            } else if let shortcut = command.shortcut {
                                self?.executeKeyboardShortcut(shortcut)
                            }
                            self?.triggerCommandFlash(name: command.phrase)
                        }
                    ))
                }
            }
        }

        matches.sort {
            if $0.startWordIndex == $1.startWordIndex {
                return $0.endWordIndex > $1.endWordIndex
            }
            return $0.startWordIndex < $1.startWordIndex
        }

        for (index, match) in matches.enumerated() {
            guard match.isStable else { continue }
            let lastEndIndex = lastExecutedEndWordIndexByCommand[match.key] ?? -1
            guard match.endWordIndex > lastEndIndex else { continue }

            // Check if there's another command immediately following this one
            let hasFollowingCommand = matches.dropFirst(index + 1).contains { nextMatch in
                nextMatch.isStable && nextMatch.startWordIndex == match.endWordIndex + 1
            }

            // Skip delay if: prefixed, halts processing, delay is 0, OR followed by another command
            if match.isPrefixed || match.haltsProcessing || commandDelayMs <= 0 || hasFollowingCommand {
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
        logger.info("resetUtteranceState called")
        lastExecutedEndWordIndexByCommand.removeAll()
        currentUtteranceHadCommand = false
        pendingCommandExecutions.removeAll()
        typedFinalWordCount = 0
        didTypeDictationThisUtterance = false
        forceEndPending = false
        forceEndRequestedAt = nil
    }

    private func executeMatch(_ match: PendingCommandMatch) {
        logDebug("Executing command: \(match.key)")
        
        // Pre-emptive Flush: Type any words BEFORE the command phrase
        if microphoneMode == .on && activeBehavior != .command {
            let wordsBefore = match.turn.words.prefix(match.startWordIndex)
            if !wordsBefore.isEmpty {
                // Determine what has already been typed
                let untypedWords: [String]
                if liveDictationEnabled {
                    // In live mode, we track by count
                    if wordsBefore.count > typedFinalWordCount {
                        untypedWords = wordsBefore[typedFinalWordCount...].map { $0.text }
                        typedFinalWordCount = wordsBefore.count
                    } else {
                        untypedWords = []
                    }
                } else {
                    // In turn-based mode, if we are in the middle of a turn that hasn't typed yet
                    // we type the preceding words now.
                    // However, turn-based usually waits for end-of-turn. 
                    // If a command is detected MID-turn, we should flush the prefix.
                    untypedWords = wordsBefore.map { $0.text }
                }
                
                if !untypedWords.isEmpty {
                    let textToFlush = untypedWords.joined(separator: " ")
                    logDebug("Pre-emptive flush: \"\(textToFlush)\"")
                    typeText(textToFlush, appendSpace: true)
                    if !textToFlush.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        didTypeDictationThisUtterance = true
                    }
                }
            }
        }

        match.action()
        
        // Add to dictation history with a command marker
        // Try to find a human-readable name for the command
        let commandName: String
        if match.key.hasPrefix("system.") {
            commandName = match.key.replacingOccurrences(of: "system.", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        } else {
            // For user commands, find the phrase
            if let command = voiceCommands.first(where: { "user.\($0.id.uuidString)" == match.key }) {
                commandName = command.phrase
            } else {
                commandName = "User Command"
            }
        }
        
        let historyEntry = "[Command] \(commandName)"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dictationHistory.insert(historyEntry, at: 0)
            if self.dictationHistory.count > 100 {
                self.dictationHistory.removeLast()
            }
            self.saveDictationHistory()
        }

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

    private func triggerCommandFlash(name: String) {
        lastCommandName = name
        isCommandFlashActive = true
        
        // Reset flash after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isCommandFlashActive = false
        }
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
            let msg = "Cannot type - Accessibility permission NOT granted"
            logger.error("\(msg)")
            logDebug("Error: \(msg)")
            return
        }

        let output = appendSpace ? text + " " : text
        logDebug("Posting CGKEvents for: \"\(output.replacingOccurrences(of: "\n", with: "\\n"))\" (\(output.count) chars)")

        // Add to history (only non-empty text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.dictationHistory.insert(trimmed, at: 0)
                if self.dictationHistory.count > 100 {
                    self.dictationHistory.removeLast()
                }
                self.saveDictationHistory()
            }
        }

        let source = CGEventSource(stateID: .hidSystemState)
        var eventsPosted = 0
        for char in output {
            if char == "\n" {
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
                continue
            }
            
            if let unicodeScalar = char.unicodeScalars.first {
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)

                var unichar = UniChar(unicodeScalar.value)
                keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
                keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)

                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
                eventsPosted += 1
            }
        }
        logger.debug("Successfully posted \(eventsPosted) character events")
    }

    private func executeKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        let source = CGEventSource(stateID: .hidSystemState)

        var flags: CGEventFlags = []
        var flagNames: [String] = []
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl); flagNames.append("Control") }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate); flagNames.append("Option") }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift); flagNames.append("Shift") }
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand); flagNames.append("Command") }

        let keyName = KeyboardShortcut.keyCodeToString(shortcut.keyCode)
        logDebug("Sending Event: \(flagNames.joined(separator: "+")) + \(keyName) (code: \(shortcut.keyCode))")

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
        let previous = apiKey
        apiKey = key
        UserDefaults.standard.set(key, forKey: "assemblyai_api_key")
        
        if previous != key && microphoneMode != .off {
            logDebug("API Key changed: Restarting services")
            restartServicesIfActive()
        }
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
        let previousValue = liveDictationEnabled
        liveDictationEnabled = value
        UserDefaults.standard.set(value, forKey: "live_dictation_enabled")
        
        if previousValue != value && microphoneMode != .off {
            logDebug("Live dictation changed: Restarting services")
            restartServicesIfActive()
        }
    }

    private func restartServicesIfActive() {
        guard microphoneMode != .off else { return }
        let currentMode = microphoneMode
        stopListening()
        startListening(transcribeMode: currentMode == .on)
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
        
        // When switching to a preset, update custom values to match the preset
        // This provides a good starting point for customization
        if mode != .custom {
            customConfidenceThreshold = mode.confidenceThreshold
            customSilenceThresholdMs = mode.silenceThresholdMs
            UserDefaults.standard.set(customConfidenceThreshold, forKey: "custom_confidence_threshold")
            UserDefaults.standard.set(customSilenceThresholdMs, forKey: "custom_silence_threshold_ms")
        }
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

    private func loadActiveBehavior() {
        if let behaviorString = UserDefaults.standard.string(forKey: "active_behavior"),
           let behavior = ActiveBehavior(rawValue: behaviorString) {
            activeBehavior = behavior
        }
    }

    func saveActiveBehavior(_ behavior: ActiveBehavior) {
        activeBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: "active_behavior")
    }

    private func loadDictationProvider() {
        if let providerString = UserDefaults.standard.string(forKey: "dictation_provider"),
           let provider = DictationProvider(rawValue: providerString) {
            dictationProvider = provider
        }
    }

    func saveDictationProvider(_ provider: DictationProvider) {
        let previous = dictationProvider
        dictationProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "dictation_provider")
        
        if previous != provider && microphoneMode != .off {
            logDebug("Dictation provider changed: \(previous.rawValue) -> \(provider.rawValue)")
            restartServicesIfActive()
        }
    }

    private func loadSleepTimerSettings() {
        sleepTimerEnabled = UserDefaults.standard.object(forKey: "sleep_timer_enabled") as? Bool ?? false
        let storedMinutes = UserDefaults.standard.double(forKey: "sleep_timer_minutes")
        if storedMinutes > 0 {
            sleepTimerMinutes = storedMinutes
        }
    }

    func saveSleepTimerEnabled(_ value: Bool) {
        sleepTimerEnabled = value
        UserDefaults.standard.set(value, forKey: "sleep_timer_enabled")
        if value {
            resetSleepTimer()
        } else {
            stopSleepTimer()
        }
    }

    func saveSleepTimerMinutes(_ value: Double) {
        sleepTimerMinutes = value
        UserDefaults.standard.set(value, forKey: "sleep_timer_minutes")
        if sleepTimerEnabled {
            resetSleepTimer()
        }
    }

    private func resetSleepTimer() {
        stopSleepTimer()
        guard sleepTimerEnabled && microphoneMode == .on else { return }
        
        let seconds = sleepTimerMinutes * 60
        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleSleepTimerTimeout()
            }
        }
    }

    private func stopSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    private func handleSleepTimerTimeout() {
        guard microphoneMode == .on else { return }
        logDebug("Inactivity timeout: Switching to Sleep mode")
        setMode(.sleep)
    }

    private func loadDictationHistory() {
        if let history = UserDefaults.standard.stringArray(forKey: "dictation_history") {
            dictationHistory = history
        }
    }

    func saveDictationHistory() {
        UserDefaults.standard.set(dictationHistory, forKey: "dictation_history")
    }

    private func loadVocabularyPrompt() {
        vocabularyPrompt = UserDefaults.standard.string(forKey: "vocabulary_prompt") ?? ""
        autoPopulateVocabulary = UserDefaults.standard.object(forKey: "auto_populate_vocabulary") as? Bool ?? true
    }

    func saveVocabularyPrompt(_ value: String) {
        let previous = vocabularyPrompt
        vocabularyPrompt = value
        UserDefaults.standard.set(value, forKey: "vocabulary_prompt")

        if previous != value && microphoneMode != .off && !effectiveIsOffline {
            logDebug("Vocabulary prompt changed: Restarting services")
            restartServicesIfActive()
        }
    }

    func saveAutoPopulateVocabulary(_ value: Bool) {
        autoPopulateVocabulary = value
        UserDefaults.standard.set(value, forKey: "auto_populate_vocabulary")
    }

    /// Generates the effective vocabulary prompt combining user prompt + command phrases
    var effectiveVocabularyPrompt: String {
        var terms: [String] = []

        // Add user-specified vocabulary (split by comma or newline)
        if !vocabularyPrompt.isEmpty {
            let userTerms = vocabularyPrompt
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            terms.append(contentsOf: userTerms)
        }

        // Auto-populate with command phrases if enabled
        if autoPopulateVocabulary {
            // System command phrases
            let systemPhrases = Self.systemCommandList.map { $0.phrase }
            terms.append(contentsOf: systemPhrases)

            // User voice command phrases
            let userCommandPhrases = voiceCommands.filter { $0.isEnabled }.map { $0.phrase }
            terms.append(contentsOf: userCommandPhrases)

            // Wake/sleep phrases
            terms.append(contentsOf: ["flow on", "flow off", "flow sleep", "wake up", "go to sleep"])
        }

        // Remove duplicates and limit to 100 terms (AssemblyAI limit)
        let uniqueTerms = Array(Set(terms)).prefix(100)

        // Format as JSON array for keyterms_prompt
        if let jsonData = try? JSONSerialization.data(withJSONObject: Array(uniqueTerms)),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return ""
    }

    private func loadIdeaFlowSettings() {
        if let data = UserDefaults.standard.data(forKey: "ideaflow_shortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            ideaFlowShortcut = shortcut
        }
        ideaFlowURL = UserDefaults.standard.string(forKey: "ideaflow_url") ?? ""
    }

    func saveIdeaFlowShortcut(_ shortcut: KeyboardShortcut?) {
        ideaFlowShortcut = shortcut
        if let shortcut = shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "ideaflow_shortcut")
        } else {
            UserDefaults.standard.removeObject(forKey: "ideaflow_shortcut")
        }
    }

    func saveIdeaFlowURL(_ url: String) {
        ideaFlowURL = url
        UserDefaults.standard.set(url, forKey: "ideaflow_url")
    }

    private func loadLaunchMode() {
        if let modeString = UserDefaults.standard.string(forKey: "launch_mode"),
           let mode = MicrophoneMode(rawValue: modeString) {
            launchMode = mode
        } else {
            launchMode = .sleep // Default to Sleep
        }
    }

    func saveLaunchMode(_ mode: MicrophoneMode) {
        launchMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "launch_mode")
    }

    /// Force end of current utterance immediately
    func forceEndUtterance() {
        logger.info("Force end utterance requested (connected=\(self.isConnected ? "true" : "false"))")
        
        // 1. Check for commands and immediately type whatever is currently in the buffer if it's not empty
        if !currentTranscript.isEmpty {
            // Construct a temporary turn to process commands from the current buffer
            let tempTurn = TranscriptTurn(
                transcript: currentTranscript,
                words: currentWords,
                endOfTurn: true,
                isFormatted: false,
                turnOrder: -1,
                utterance: currentTranscript
            )
            
            // Process commands from the buffer
            if activeBehavior != .dictation {
                processVoiceCommands(tempTurn)
            }

            // Only type if we haven't just executed a command that halts processing (like 'microphone off')
            // or if the utterance didn't have a command.
            // preprocessDictation also helps strip the command phrases from the text.
            let processed = preprocessDictation(currentTranscript)
            
            if !processed.isEmpty {
                logDebug("Force pushing buffer: \"\(processed.prefix(20))...\"")
                typeText(processed, appendSpace: true)
                if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    didTypeDictationThisUtterance = true
                }
            }
            
            currentTranscript = ""
            currentWords = []
        }

        // 2. Reset state locally so we are ready for the next turn
        let wasPending = forceEndPending
        forceEndPending = true
        forceEndRequestedAt = Date()
        
        if !wasPending {
            assemblyAIService?.forceEndUtterance()
            appleSpeechService?.forceEndUtterance()
        }
        
        // 3. Clear state after a short delay to ensure no double-typing from the server response
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resetUtteranceState()
        }
    }

    func saveToIdeaFlow() {
        // Find the latest non-command history entry
        guard let latestNote = dictationHistory.first(where: { !$0.hasPrefix("[Command]") }) else {
            logDebug("Idea Flow: No dictation found to save")
            return
        }
        
        logDebug("Idea Flow: Saving note \"\(latestNote.prefix(20))...\"")
        
        // 1. Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestNote, forType: .string)
        
        // 2. Open URL or execute shortcut
        if let urlString = ideaFlowURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else if let shortcut = ideaFlowShortcut {
            executeKeyboardShortcut(shortcut)
        } else {
            // Fallback: search for IdeaFlow app
            let apps = NSWorkspace.shared.runningApplications
            if let ideaFlow = apps.first(where: { $0.localizedName?.contains("IdeaFlow") == true }) {
                ideaFlow.activate()
                // Wait briefly for app to focus then paste
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command]))
                }
            } else {
                logDebug("Idea Flow: App not found and no URL/Shortcut configured")
            }
        }
    }
}
