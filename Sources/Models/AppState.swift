import Foundation
import Combine
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import AVFoundation
import Speech
import ServiceManagement
import os.log
import NaturalLanguage

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
    case deepgram = "deepgram"

    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return "Auto (Default)"
        case .online: return "AssemblyAI (Online Primary)"
        case .deepgram: return "Deepgram (Online Secondary)"
        case .offline: return "Mac Speech (Offline)"
        }
    }
}

struct AppWarning: Identifiable {
    let id: String
    let message: String
    let severity: Severity
    let action: (() -> Void)?
    let actionLabel: String?
    
    init(id: String, message: String, severity: Severity, action: (() -> Void)? = nil, actionLabel: String? = nil) {
        self.id = id
        self.message = message
        self.severity = severity
        self.action = action
        self.actionLabel = actionLabel
    }
    
    enum Severity {
        case warning, error
    }
}

/// Main application state management
@MainActor
class AppState: ObservableObject {
    @Published var microphoneMode: MicrophoneMode = .off
    @Published var currentTranscript: String = ""
    @Published var recentTurns: [TranscriptTurn] = []
    @Published var isolatedSpeakerId: Int? = nil
    @Published var isConnected: Bool = false

    func toggleSpeakerIsolation(speakerId: Int) {
        if isolatedSpeakerId == speakerId {
            isolatedSpeakerId = nil // Unlock
        } else {
            isolatedSpeakerId = speakerId // Lock to new speaker
        }
    }
    @Published var errorMessage: String? {
        didSet {
            if errorMessage != nil && isDebugMode {
                showCompactError = true
                // Auto-hide after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.showCompactError = false
                }
            }
        }
    }
    @Published var apiKey: String = ""
    @Published var deepgramApiKey: String = ""
    @Published var voiceCommands: [VoiceCommand] = VoiceCommand.defaults
    @Published var isPanelVisible: Bool = true
    @Published var isPanelMinimal: Bool = false
    @Published var currentWords: [TranscriptWord] = []
    @Published var commandDelayMs: Double = 50
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
    @Published var lastKeywordName: String? = nil
    @Published var isKeywordFlashActive: Bool = false
    @Published var debugLog: [String] = []
    @Published var dictationHistory: [String] = []
    @Published var vocabularyPrompt: String = ""
    @Published var autoPopulateVocabulary: Bool = true  // Auto-add commands to vocabulary
    @Published var ideaFlowShortcut: KeyboardShortcut? = nil
    @Published var ideaFlowURL: String = ""
    @Published var isOffline: Bool = false
    @Published var connectionLatencyMs: Int? = nil
    @Published var isLatencyDegraded: Bool = false
    @Published var dictationProvider: DictationProvider = .auto
    @Published var sleepTimerEnabled: Bool = true
    @Published var sleepTimerMinutes: Double = 15
    @Published var autoOffEnabled: Bool = true
    @Published var autoOffMinutes: Double = 30
    @Published var launchMode: MicrophoneMode = .sleep
    @Published var launchAtLogin: Bool = false
    @Published var selectedInputDeviceId: String? = nil
    @Published var isNewerBuildAvailable: Bool = false
    @Published var settingsSearchText: String = ""
    
    private let launchTime = Date()
    private var buildCheckTimer: Timer?
    
    // Customizable Shortcuts
    @Published var pttShortcut: KeyboardShortcut = KeyboardShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])
    @Published var modeToggleShortcut: KeyboardShortcut = KeyboardShortcut(keyCode: UInt16(kVK_F19), modifiers: []) // Default F19 or similar?
    @Published var modeOnShortcut: KeyboardShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_1), modifiers: [.control, .option, .command])
    @Published var modeSleepShortcut: KeyboardShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_2), modifiers: [.control, .option, .command])
    @Published var modeOffShortcut: KeyboardShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_0), modifiers: [.control, .option, .command])
    
    #if DEBUG
    @Published var isDebugMode: Bool = true
    #else
    @Published var isDebugMode: Bool = false
    #endif
    @Published var showCompactError: Bool = false

    // AI Formatter
    @Published var aiFormatterEnabled: Bool = true
    @Published var anthropicApiKey: String = ""
    let focusContextManager = FocusContextManager()
    private(set) lazy var aiFormatterService: AIFormatterService = {
        AIFormatterService(focusContext: focusContextManager)
    }()

    /// Built-in system commands for reference in UI
    static let systemCommandList: [(phrase: String, description: String)] = [
        ("wake up", "Switch to On mode"),
        ("microphone on", "Switch to On mode"),
        ("flow on", "Switch to On mode"),
        ("speech on", "Switch to On mode"),
        ("go to sleep", "Switch to Sleep mode"),
        ("flow sleep", "Switch to Sleep mode"),
        ("speech off", "Switch to Sleep mode"),
        ("flow off", "Turn microphone completely Off"),
        ("microphone off", "Turn microphone completely Off"),
        ("stop dictation", "Turn microphone completely Off"),
        ("cancel that", "Undo last keyboard command"),
        ("no wait", "Undo last keyboard command"),
        ("submit dictation", "Force finalize and type current speech"),
        ("send dictation", "Force finalize and type current speech"),
        ("window recent", "Switch to previous application"),
        ("flip", "Switch to previous application (short alias)"),
        ("window recent 2", "Switch to 2nd most recent application"),
        ("window next", "Cycle to next window in same app (⌘`)"),
        ("window previous", "Cycle to previous window in same app (⌘⇧`)"),
        ("focus [app]", "Switch to a running application by name"),
        ("press [modifier] [key]", "Press a keyboard shortcut (e.g., \"press command x\")"),
        ("spell [text]", "Type characters one-by-one without spaces"),
        ("save to idea flow", "Copy last dictation and open Idea Flow")
    ]

    /// Special dictation keywords (not commands)
    static let specialKeywordList: [(phrase: String, description: String)] = [
        ("say [text]", "Speak literally; disables command parsing for this utterance"),
        ("new line", "Insert a line break"),
        ("newline", "Insert a line break"),
        ("space bar", "Insert a space"),
        ("spacebar", "Insert a space"),
        ("no caps", "Lowercase the next word"),
        ("letter [char]", "Type the next word as a single letter"),
        ("at sign [text]", "Insert @ and condense following words"),
        ("hashtag [text]", "Insert # and condense following words"),
        ("hash tag [text]", "Insert # and condense following words")
    ]

    var panelVisibilityHandler: ((Bool) -> Void)?

    /// Current issues that should be surfaced to the user
    var activeWarnings: [AppWarning] {
        var warnings: [AppWarning] = []

        // Connection/API errors - show prominently
        if let error = errorMessage {
            let isAuthError = error.lowercased().contains("unauthorized") || error.lowercased().contains("invalid")
            let message: String
            if isAuthError {
                // Determine which service is active to show specific API key name
                switch dictationProvider {
                case .deepgram:
                    message = "Invalid Deepgram API Key - check Settings"
                case .online, .auto:
                    message = "Invalid AssemblyAI API Key - check Settings"
                case .offline:
                    message = "API Error - check Settings"
                }
            } else {
                message = error
            }
            warnings.append(AppWarning(id: "connection_error", message: message, severity: .error))
        }

        // Key checks
        if apiKey.isEmpty && (dictationProvider == .auto || dictationProvider == .online) {
            warnings.append(AppWarning(id: "assembly_key", message: "AssemblyAI API Key missing", severity: .error))
        }
        if deepgramApiKey.isEmpty && dictgramIsRequired {
            warnings.append(AppWarning(id: "deepgram_key", message: "Deepgram API Key missing", severity: .error))
        }

        // Permission checks
        if !isAccessibilityGranted {
            warnings.append(AppWarning(id: "a11y", message: "Accessibility permission needed for typing", severity: .warning))
        }
        if !isMicrophoneGranted {
            warnings.append(AppWarning(id: "mic", message: "Microphone access needed", severity: .error))
        }
        if !isSpeechGranted && (dictationProvider == .offline || effectiveIsOffline) {
            warnings.append(AppWarning(id: "speech", message: "Speech recognition permission needed for Mac Speech", severity: .error))
        }

        // Offline detection + suggestions
        if isOffline && dictationProvider != .offline {
            if dictationProvider == .auto {
                warnings.append(AppWarning(id: "network_offline_auto", message: "Offline detected — using Mac Speech (Auto).", severity: .warning))
            } else {
                warnings.append(AppWarning(id: "network_offline", message: "Network offline — switch to Mac Speech (Offline) or set provider to Auto.", severity: .warning))
            }
        }

        if effectiveIsOffline, supportsOnDeviceSpeech == false {
            warnings.append(AppWarning(id: "offline_unsupported", message: "On-device speech not supported on this Mac — offline dictation may not work.", severity: .warning))
        }

        if isLatencyDegraded, let latency = connectionLatencyMs, !effectiveIsOffline {
            warnings.append(AppWarning(
                id: "latency_high",
                message: "High network latency (\(latency)ms)",
                severity: .warning,
                action: { [weak self] in
                    self?.saveDictationProvider(.offline)
                },
                actionLabel: "Switch to Offline"
            ))
        }

        return warnings
    }

    private var dictgramIsRequired: Bool {
        dictationProvider == .deepgram || (dictationProvider == .auto && isOffline && false) // Auto doesn't use Deepgram as fallback yet
    }

    private var supportsOnDeviceSpeech: Bool? {
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition
    }

    func pasteLastUtterance() {
        guard let last = dictationHistory.first(where: { !$0.hasPrefix("[Command]") }) else {
            logDebug("Paste: No last utterance found")
            return
        }
        logDebug("Pasting last utterance: \"\(last.prefix(20))...\"")
        typeText(last, appendSpace: true)
    }

    private var audioCaptureManager: AudioCaptureManager?
    private var assemblyAIService: AssemblyAIService?
    private var deepgramService: DeepgramService?
    private var appleSpeechService: AppleSpeechService?
    private var networkMonitor = NetworkMonitor()
    private var windowManager = WindowManager()
    private var cancellables = Set<AnyCancellable>()
    private var sleepTimer: Timer?
    private var autoOffTimer: Timer?
    private var lastExecutedEndWordIndexByCommand: [String: Int] = [:]
    private var currentUtteranceHadCommand = false
    private var currentUtteranceIsLiteral = false
    private var literalStartWordIndex: Int = 0  // Word index AFTER "say" keyword
    private var lastHaltingCommandEndIndex = -1
    private var wakeUpTime: Date?
    private let wakeUpGracePeriod: TimeInterval = 0.8  // Don't type for 0.8s after waking
    private let commandPrefixToken = "voiceflow"
    private var expectsFormattedTurns: Bool {
        // In live dictation mode (format_turns=false), we don't expect formatted turns
        return !liveDictationEnabled
    }
    private var pendingCommandExecutions = Set<PendingExecutionKey>()
    private var lastCommandExecutionTime: Date?
    private let cancelWindowSeconds: TimeInterval = 2
    private let undoShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])
    private let commandFlashDurationSeconds: TimeInterval = 2.0
    private let keywordFlashDurationSeconds: TimeInterval = 1.6
    private let keywordMaxGapSeconds: TimeInterval = 1.2
    private let typingFlushDelaySeconds: TimeInterval = 0.12
    private let latencyWarningThresholdMs = 1500
    private let latencyRecoveryThresholdMs = 900
    private var didTriggerSayKeyword = false
    private var turnHandledBySpecialCommand = false  // Set by spell, focus to prevent dictation
    private var typedFinalWordCount = 0
    private var didTypeDictationThisUtterance = false
    private var hasTypedInSession = false  // Tracks if we've typed anything since going On
    private var forceEndPending = false
    private var forceEndRequestedAt: Date?
    private let forceEndTimeoutSeconds: TimeInterval = 2.0
    private var lastTypedTurnOrder = -1
    private var suppressNextAutoCap = false
    private var lastKeyEventTime: Date?  // For consistent Return key timing across typeText calls

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
        case .online, .deepgram: return false
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
        loadLaunchAtLogin()
        loadInputDevice()
        loadShortcuts()
        loadDictationProvider()
        loadDictationHistory()
        loadVocabularyPrompt()
        loadIdeaFlowSettings()
        loadSleepTimerSettings()
        loadAutoOffSettings()
        loadAIFormatterSettings()
        checkAccessibilityPermission(silent: true)
        checkMicrophonePermission()
        checkSpeechPermission()
        
        startBuildCheckTimer()
        
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

    private var accessibilityPollTimer: Timer?
    private var accessibilityPollCount = 0

    func checkAccessibilityPermission(silent: Bool = true) {
        if silent {
            let trusted = AXIsProcessTrusted()
            isAccessibilityGranted = trusted
            logger.info("Accessibility permission (silent check): \(trusted ? "GRANTED" : "NOT GRANTED")")
        } else {
            // First check current status
            let alreadyTrusted = AXIsProcessTrusted()
            if alreadyTrusted {
                isAccessibilityGranted = true
                logger.info("Accessibility permission already granted")
                return
            }

            // TRIGGER THE SYSTEM PROMPT
            // This is critical for cases where the user removed the app from the list.
            // calling this with prompt: true forces macOS to re-evaluate or prompt.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            
            if trusted {
                 isAccessibilityGranted = true
                 return
            }

            // Open System Settings directly to Accessibility pane
            logger.info("Opening System Settings for Accessibility permission...")
            // Give the prompt a moment to appear before opening settings, 
            // but opening settings is usually helpful regardless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Start polling to detect when permission is granted
            startAccessibilityPolling()
        }
    }

    private func startAccessibilityPolling() {
        // Stop any existing timer
        accessibilityPollTimer?.invalidate()
        accessibilityPollCount = 0

        // Poll every 1 second for up to 60 seconds
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            self.accessibilityPollCount += 1
            let trusted = AXIsProcessTrusted()

            if trusted {
                // Permission granted! Update state and stop polling
                DispatchQueue.main.async {
                    self.isAccessibilityGranted = true
                    logger.info("Accessibility permission detected as granted!")
                    self.logDebug("Accessibility permission granted")
                }
                timer.invalidate()
                self.accessibilityPollTimer = nil
            } else if self.accessibilityPollCount >= 60 {
                // Timed out after 60 seconds - show helpful message
                timer.invalidate()
                self.accessibilityPollTimer = nil
                DispatchQueue.main.async {
                    self.showAccessibilityHelpAlert()
                }
            }
        }
    }

    func recheckAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        let wasGranted = isAccessibilityGranted
        isAccessibilityGranted = trusted

        if trusted && !wasGranted {
            logDebug("Accessibility permission now granted")
        }
    }

    private func showAccessibilityHelpAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = """
            VoiceFlow needs Accessibility permission to type text.

            1. Open System Settings > Privacy & Security > Accessibility
            2. Find and enable VoiceFlow (or VoiceFlow-Dev)
            3. If already enabled, try toggling it off and on

            If the permission doesn't take effect, you may need to restart the app.
            If the app is missing from the list or stuck, try 'Reset Permissions'.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Restart App")
        alert.addButton(withTitle: "Reset Permissions (Fix)")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open Settings again
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Resume polling
            startAccessibilityPolling()
        } else if response == .alertSecondButtonReturn {
            restartApp()
        } else if response == .alertThirdButtonReturn {
            resetAccessibilityPermissions()
        }
    }
    
    func resetAccessibilityPermissions() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        logDebug("Resetting accessibility permissions for \(bundleId)...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleId]
            try? process.run()
            process.waitUntilExit()
            
            Task { @MainActor in
                self.logDebug("Permissions reset. Restarting...")
                self.restartApp()
            }
        }
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

    /// Returns the path to the currently running executable
    var executablePath: String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "Unknown"
    }

    /// Returns true if running from a .build directory (i.e., via `swift run`)
    var isRunningFromSwiftRun: Bool {
        executablePath.contains(".build/")
    }

    /// Returns diagnostic info about the current process identity for debugging permissions
    var accessibilityDiagnostics: (execPath: String, bundleId: String?, isSwiftRun: Bool, suggestion: String) {
        let execPath = executablePath
        let bundleId = Bundle.main.bundleIdentifier
        let isSwiftRun = isRunningFromSwiftRun

        var suggestion: String
        if isSwiftRun && !isAccessibilityGranted {
            suggestion = """
                Running via 'swift run' uses a different binary than the .app bundle.
                Permissions granted to 'VoiceFlow-Dev' don't apply here.

                Options:
                1. Run the .app instead: open VoiceFlow-Dev.app
                2. Grant permission to Terminal (which runs swift)
                3. Reset & re-grant: tccutil reset Accessibility \(bundleId ?? "com.jacobcole.voiceflow")
                """
        } else if !isAccessibilityGranted {
            suggestion = """
                Permission not granted. Try:
                1. Click 'Request' to prompt the system
                2. Manually enable in System Settings > Privacy > Accessibility
                3. If already enabled, the app identity may have changed - reset with:
                   tccutil reset Accessibility \(bundleId ?? "com.jacobcole.voiceflow")
                """
        } else {
            suggestion = "Accessibility permission is working correctly."
        }

        return (execPath, bundleId, isSwiftRun, suggestion)
    }

    private static var logFileURL: URL? = {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("VoiceFlow")
        if let logsDir = logsDir {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            return logsDir.appendingPathComponent("voiceflow.log")
        }
        return nil
    }()

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

        // Write to log file
        Self.writeToLogFile(entry)
    }

    private static func writeToLogFile(_ entry: String) {
        guard let logFileURL = logFileURL else { return }
        let line = entry + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    static var logFilePath: String {
        logFileURL?.path ?? "~/Library/Logs/VoiceFlow/voiceflow.log"
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    /// The default Push-to-Talk shortcut description
    static let pttShortcutDescription = "⌃⌥Space (Control+Option+Space)"

    /// Checks if macOS Spotlight "Search Mac" shortcut (Opt+Cmd+Space) is enabled
    /// Note: No longer conflicts after changing PTT to Control+Option+Space
    static func isSpotlightSearchMacShortcutEnabled() -> Bool {
        // The Spotlight "Search Mac" shortcut is stored in com.apple.symbolichotkeys.plist
        // Key 65 is the "Search Mac" shortcut (different from key 64 which is "Show Spotlight")
        let prefsPath = NSHomeDirectory() + "/Library/Preferences/com.apple.symbolichotkeys.plist"

        guard let plist = NSDictionary(contentsOfFile: prefsPath),
              let hotkeys = plist["AppleSymbolicHotKeys"] as? [String: Any],
              let key65 = hotkeys["65"] as? [String: Any],
              let enabled = key65["enabled"] as? Bool else {
            // If we can't read the preference, assume it's enabled (default)
            return true
        }

        return enabled
    }

    /// Opens System Settings to the Keyboard Shortcuts pane
    func openKeyboardShortcutsSettings() {
        // macOS Ventura+ uses System Settings with this URL
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }

    func restartApp() {
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

    func setMode(_ mode: MicrophoneMode, caller: String = #function, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        NSLog("[VoiceFlow] setMode called: %@ from %@:%d (%@)", mode.rawValue, fileName, line, caller)
        NSLog("[VoiceFlow] Permissions - a11y: %d, mic: %d, speech: %d", isAccessibilityGranted, isMicrophoneGranted, isSpeechGranted)

        // Check and request permissions before enabling active modes
        if mode == .on || mode == .sleep {
            if !isAccessibilityGranted {
                NSLog("[VoiceFlow] Requesting accessibility permission...")
                checkAccessibilityPermission(silent: false)
            }
            if !isMicrophoneGranted {
                NSLog("[VoiceFlow] Requesting microphone permission...")
                requestMicrophonePermission()
            }
            if !isSpeechGranted {
                NSLog("[VoiceFlow] Requesting speech permission...")
                requestSpeechPermission()
            }
        }

        let previousMode = microphoneMode
        microphoneMode = mode
        logDebug("Mode changed: \(previousMode.rawValue) -> \(mode.rawValue)")
        NSLog("[VoiceFlow] Mode changed: %@ -> %@", previousMode.rawValue, mode.rawValue)

        if mode == .on {
            resetSleepTimer()
        } else {
            stopSleepTimer()
        }

        // Auto-off timer runs in both On and Sleep modes
        if mode == .off {
            stopAutoOffTimer()
        } else {
            resetAutoOffTimer()
        }

        // Clear UI state when waking up or switching active modes
        if previousMode == .sleep && mode == .on {
            currentTranscript = ""
            currentWords = []
            recentTurns = []
            isolatedSpeakerId = nil
            // Mark that we just woke up to prevent the "wake up" phrase from typing
            currentUtteranceHadCommand = true
            wakeUpTime = Date()  // Grace period to ignore residual wake word audio
        }

        if (previousMode == .off || previousMode == .sleep) && mode == .on {
            recentTurns = []
            isolatedSpeakerId = nil
        }
        
        if mode == .sleep {
            recentTurns = []
            isolatedSpeakerId = nil
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
        NSLog("[VoiceFlow] startListening called, transcribeMode: %d", transcribeMode)
        NSLog("[VoiceFlow] effectiveIsOffline: %d, dictationProvider: %@", effectiveIsOffline, dictationProvider.rawValue)
        logDebug("Starting services (transcribeMode: \(transcribeMode))")

        // Always need AudioCaptureManager
        audioCaptureManager = AudioCaptureManager(deviceID: selectedInputDeviceId)

        if effectiveIsOffline {
            NSLog("[VoiceFlow] -> Starting Apple Speech (offline)")
            startAppleSpeech(transcribeMode: transcribeMode)
        } else if dictationProvider == .deepgram {
            NSLog("[VoiceFlow] -> Starting Deepgram")
            startDeepgram(transcribeMode: transcribeMode)
        } else {
            NSLog("[VoiceFlow] -> Starting AssemblyAI")
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

        assemblyAIService?.$lastPingLatencyMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latency in
                self?.updateLatency(latency)
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

    private func startDeepgram(transcribeMode: Bool) {
        NSLog("[VoiceFlow] startDeepgram called, key length: %d", deepgramApiKey.count)
        guard !deepgramApiKey.isEmpty else {
            errorMessage = "Please set your Deepgram API key in Settings"
            logDebug("Error: Deepgram API key missing")
            NSLog("[VoiceFlow] Deepgram API key is EMPTY!")
            return
        }

        NSLog("[VoiceFlow] Deepgram API key present, starting connection...")
        errorMessage = nil
        forceEndPending = false
        forceEndRequestedAt = nil
        lastTypedTurnOrder = -1

        // Initialize service
        deepgramService = DeepgramService(apiKey: deepgramApiKey)

        // Configure utterance detection
        let utteranceConfig = UtteranceConfig(
            confidenceThreshold: effectiveConfidenceThreshold,
            silenceThresholdMs: effectiveSilenceThresholdMs,
            maxTurnSilenceMs: utteranceMode.maxTurnSilenceMs
        )
        deepgramService?.setUtteranceConfig(utteranceConfig)

        // Set up bindings
        deepgramService?.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
                self?.logDebug(connected ? "Connected to Deepgram" : "Disconnected from Deepgram")
            }
            .store(in: &cancellables)

        deepgramService?.$lastPingLatencyMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latency in
                self?.updateLatency(latency)
            }
            .store(in: &cancellables)

        deepgramService?.$latestTurn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turn in
                guard let turn else { return }
                self?.handleTurn(turn)
            }
            .store(in: &cancellables)

        deepgramService?.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error
                if let error = error {
                    self?.logDebug("Deepgram API Error: \(error)")
                }
            }
            .store(in: &cancellables)

        // Connect audio output to WebSocket
        audioCaptureManager?.onAudioData = { [weak self] data in
            self?.deepgramService?.sendAudio(data)
        }

        // Connect audio level for visualization
        audioCaptureManager?.onAudioLevel = { [weak self] level in
            self?.audioLevel = level
        }

        // Start services
        deepgramService?.setTranscribeMode(transcribeMode)
        deepgramService?.setFormatTurns(!liveDictationEnabled)
        deepgramService?.setVocabularyPrompt(effectiveVocabularyPrompt)
        deepgramService?.connect()
        audioCaptureManager?.startCapture()
    }

    private func startAppleSpeech(transcribeMode: Bool) {
        logDebug("Using Apple Speech Recognition (Offline Mode)")
        guard isSpeechGranted else {
            errorMessage = "Speech recognition permission needed for Mac Speech"
            logDebug("Error: Speech recognition permission missing")
            isConnected = false
            updateLatency(nil)
            return
        }
        errorMessage = nil
        forceEndPending = false
        forceEndRequestedAt = nil
        lastTypedTurnOrder = -1

        appleSpeechService = AppleSpeechService()
        
        // Configure utterance detection for Apple Speech (simulated via silence timer)
        let utteranceConfig = UtteranceConfig(
            confidenceThreshold: effectiveConfidenceThreshold,
            silenceThresholdMs: effectiveSilenceThresholdMs,
            maxTurnSilenceMs: utteranceMode.maxTurnSilenceMs
        )
        appleSpeechService?.setUtteranceConfig(utteranceConfig)
        
        appleSpeechService?.$latestTurn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turn in
                guard let turn else { return }
                self?.handleTurn(turn)
            }
            .store(in: &cancellables)

        appleSpeechService?.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
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
        updateLatency(nil)
    }

    private func stopListening() {
        logDebug("Stopping services")
        audioCaptureManager?.stopCapture()
        assemblyAIService?.disconnect()
        deepgramService?.disconnect()
        appleSpeechService?.disconnect()
        audioCaptureManager = nil
        assemblyAIService = nil
        deepgramService = nil
        appleSpeechService = nil
        cancellables.removeAll()
        isConnected = false
        audioLevel = 0.0
        updateLatency(nil)
    }

    private func handleTurn(_ turn: TranscriptTurn) {
        // Reset timers on any speech detection
        if microphoneMode == .on {
            resetSleepTimer()
        }
        // Reset auto-off timer on speech (runs in both On and Sleep modes)
        if microphoneMode != .off {
            resetAutoOffTimer()
        }
        
        // Calculate force end status early
        let isForceEndTurn = forceEndPending && turn.endOfTurn

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

        let initialMode = microphoneMode
        if initialMode == .sleep || (initialMode == .on && activeBehavior != .dictation) {
            processVoiceCommands(turn)
        }

        // In dictation mode, still check for "say" escape keyword (but skip other commands)
        if initialMode == .on && activeBehavior == .dictation && !currentUtteranceIsLiteral {
            detectSayPrefix(turn)
        }

        if microphoneMode == .on && activeBehavior != .command {
            if liveDictationEnabled {
                handleLiveDictationTurn(turn, isForceEnd: isForceEndTurn)
            } else {
                handleDictationTurn(turn, isForceEnd: isForceEndTurn)
            }
        }
        
        if microphoneMode == .off {
            // Do nothing
        }

        if turn.endOfTurn {
            // Only add the "final" version to history: formatted turn when expecting formatted, or any when not
            let shouldAddToHistory = !expectsFormattedTurns || turn.isFormatted || isForceEndTurn
            if shouldAddToHistory && !turn.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recentTurns.append(turn)
                if recentTurns.count > 10 {
                    recentTurns.removeFirst()
                }
            }

            if shouldAddToHistory {
                resetUtteranceState()
            }
            currentUtteranceIsLiteral = false
            didTriggerSayKeyword = false
            turnHandledBySpecialCommand = false
        }
    }

    private func filterWordsForIsolation(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard let isolatedId = isolatedSpeakerId else { return words }
        return words.filter { $0.speaker == isolatedId }
    }

    private func handleDictationTurn(_ turn: TranscriptTurn, isForceEnd: Bool) {
        logger.info("handleDictationTurn: isFormatted=\(turn.isFormatted), endOfTurn=\(turn.endOfTurn), transcript=\"\(turn.transcript.prefix(50))...\"")

        // Skip if spell/focus already handled this turn
        if turnHandledBySpecialCommand {
            logger.debug("Skipping dictation - turn handled by special command (spell/focus)")
            return
        }

        if forceEndPending, let requestedAt = forceEndRequestedAt,
           Date().timeIntervalSince(requestedAt) > forceEndTimeoutSeconds {
            forceEndPending = false
            forceEndRequestedAt = nil
        }
        
        // SPEAKER ISOLATION FILTER
        // If the entire turn has a speaker assigned and it doesn't match, drop the whole turn.
        if let isolatedId = isolatedSpeakerId, let turnSpeaker = turn.speaker, turnSpeaker != isolatedId {
            logger.debug("Skipping turn from Speaker \(turnSpeaker) (Isolated to S\(isolatedId))")
            return
        }
        
        // If the turn has mixed speakers, filter words
        var effectiveWords = turn.words
        if isolatedSpeakerId != nil {
            effectiveWords = filterWordsForIsolation(turn.words)
            if effectiveWords.isEmpty && !turn.words.isEmpty {
                 logger.debug("Skipping turn: all words filtered out by speaker isolation")
                 return
            }
        }

        let lastCommandEndIndex = currentUtteranceHadCommand ? (lastExecutedEndWordIndexByCommand.values.max() ?? -1) : -1

        // Skip typing during wake-up grace period, UNLESS we have a matched command to skip precisely
        if let wakeTime = wakeUpTime, Date().timeIntervalSince(wakeTime) < wakeUpGracePeriod {
            if lastCommandEndIndex < 0 {
                return
            }
        }

        let isLiteralTurn = currentUtteranceIsLiteral  // Use flag set by processVoiceCommands
        let rawTranscript: String
        
        // Re-assemble transcript if words were filtered
        if isolatedSpeakerId != nil && effectiveWords.count != turn.words.count {
             rawTranscript = assembleDisplayText(from: effectiveWords)
        } else {
             if isLiteralTurn, !turn.transcript.isEmpty {
                 rawTranscript = turn.transcript
             } else if let utterance = turn.utterance, utterance.count > turn.transcript.count {
                 rawTranscript = utterance
             } else if turn.transcript.isEmpty {
                 rawTranscript = turn.utterance ?? ""
             } else {
                 rawTranscript = turn.transcript
             }
        }

        var textToType = rawTranscript
        var wordsForKeywords: [TranscriptWord]? = effectiveWords.isEmpty ? nil : effectiveWords
        
        // If utterance had a command, we might have already flushed the prefix.
        if lastCommandEndIndex >= 0 && !isForceEnd {
            if lastHaltingCommandEndIndex == lastCommandEndIndex {
                return
            }
            // Use literalStartWordIndex if in literal mode (e.g., "speech on say press enter")
            let skipToIndex = isLiteralTurn && literalStartWordIndex > lastCommandEndIndex + 1
                ? literalStartWordIndex
                : lastCommandEndIndex + 1
            if skipToIndex < effectiveWords.count {
                let wordsAfter = effectiveWords[skipToIndex...]
                let filteredWords = wordsAfter.filter { word in
                    let stripped = word.text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                    return !stripped.isEmpty
                }
                textToType = assembleDisplayText(from: Array(filteredWords))
                wordsForKeywords = Array(filteredWords)
                NSLog("[VoiceFlow] handleDictationTurn: skipToIndex=%d, textToType='%@'", skipToIndex, textToType)
            } else {
                return
            }
        }
        
        let shouldType = turn.isFormatted || (!expectsFormattedTurns && turn.endOfTurn) || isForceEnd
        
        if textToType.isEmpty, isForceEnd {
            textToType = turn.utterance ?? assembleDisplayText(from: effectiveWords)
        }
        
        if let turnOrder = turn.turnOrder, turnOrder <= lastTypedTurnOrder {
            return
        }

        guard shouldType, !textToType.isEmpty else {
            return
        }

        var processedText = preprocessDictation(textToType, forceLiteral: isLiteralTurn, words: wordsForKeywords)

        // Apply AI formatting if enabled (quick local heuristics for now)
        if aiFormatterEnabled {
            let context = focusContextManager.getFormattingContext()
            processedText = aiFormatterService.quickFormat(processedText, context: context)
        }
        
        if suppressNextAutoCap {
            processedText = lowercasedFirstLetter(processedText)
            suppressNextAutoCap = false
        }

        let trimmedProcessed = processedText.trimmingCharacters(in: .whitespaces)
        guard !trimmedProcessed.isEmpty else {
            return
        }

        // Track utterance in focus context for future formatting decisions
        focusContextManager.addUtterance(trimmedProcessed)

        typeText(processedText, appendSpace: true)
        if !trimmedProcessed.isEmpty {
            didTypeDictationThisUtterance = true
            hasTypedInSession = true
        }
        
        if let turnOrder = turn.turnOrder {
            lastTypedTurnOrder = turnOrder
        }
        if isForceEnd {
            forceEndPending = false
            forceEndRequestedAt = nil
        }
    }

    private func applyKeywordReplacements(_ text: String, words: [TranscriptWord]?, isLiteral: Bool) -> (String, String?) {
        guard !isLiteral else { return (text, nil) }
        if let words, !words.isEmpty {
            return applyKeywordReplacementsFromWords(words)
        }

        var result = text
        var keyword: String? = nil
        
        // "no caps" directive (string fallback)
        if let regex = try? NSRegularExpression(pattern: "(?i)^\\s*no\\s*caps\\b[\\.,!?]?\\s*", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            if let match = regex.firstMatch(in: result, options: [], range: range) {
                keyword = keyword ?? "No caps"
                suppressNextAutoCap = true
                result = (result as NSString).substring(from: match.range.length)
                result = lowercasedFirstWord(result)
            }
        }
        
        // "letter" directive (string fallback)
        if let regex = try? NSRegularExpression(pattern: "(?i)^\\s*letter\\b[\\.,!?]?\\s*", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            if let match = regex.firstMatch(in: result, options: [], range: range) {
                keyword = keyword ?? "Letter"
                suppressNextAutoCap = true
                let remainder = (result as NSString).substring(from: match.range.length)
                let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                if let wordRange = trimmed.range(of: "\\S+", options: .regularExpression),
                   let firstChar = trimmed[wordRange].first {
                    let afterWord = trimmed[wordRange.upperBound...]
                    result = String(firstChar).lowercased() + String(afterWord)
                } else {
                    result = remainder
                }
            }
        }

        // Match "new line" or "newline" with optional trailing punctuation
        if let regex = try? NSRegularExpression(pattern: "(?i)\\bnew\\s*line\\b(?:[\\.,!?])?", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "New line"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
        }

        // Remove spaces that immediately precede a newline (e.g., "Hello new line" -> "Hello\n")
        if let regex = try? NSRegularExpression(pattern: "\\s+\\n", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
        }

        // Remove punctuation that immediately follows a newline command (e.g., "new line.")
        if let regex = try? NSRegularExpression(pattern: "\\n\\s*[\\.,!?]", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
        }

        // Replace "spacebar" / "space bar" with a space
        if let regex = try? NSRegularExpression(pattern: "(?i)\\bspace\\s*bar\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Spacebar"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
        }

        // "no space" / "nospace" - removes space between adjacent words
        // e.g., "idea no space flow" → "ideaflow"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\s+no\\s*space\\s+", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "No space"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // "at sign" -> "@"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\bat\\s*sign\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "At sign"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "@")
        }
        
        // "hashtag" / "hash tag" -> "#"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\bhash\\s*tag\\b|\\bhashtag\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Hashtag"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "#")
        }
        
        // Collapse immediate spaces after @ or #
        if let regex = try? NSRegularExpression(pattern: "([@#])\\s+([A-Za-z0-9]+)", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2")
        }

        // Parentheses: "open paren" / "close paren" / "left paren" / "right paren"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(open|left)\\s*paren(thesis)?\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Open paren"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "(")
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(close|right)\\s*paren(thesis)?\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Close paren"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: ")")
        }

        // Brackets: "open bracket" / "close bracket"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(open|left)\\s*bracket\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Open bracket"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[")
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(close|right)\\s*bracket\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Close bracket"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "]")
        }

        // Braces: "open brace" / "close brace"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(open|left)\\s*brace\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Open brace"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "{")
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(close|right)\\s*brace\\b", options: []) {
            if regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)) != nil {
                keyword = keyword ?? "Close brace"
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "}")
        }

        // Remove space before closing punctuation
        if let regex = try? NSRegularExpression(pattern: "\\s+([\\)\\]\\}])", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove space after opening punctuation
        if let regex = try? NSRegularExpression(pattern: "([\\(\\[\\{])\\s+", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        return (result, keyword)
    }

    private func timeScale(for word: TranscriptWord) -> Double {
        guard let start = word.startTime, let end = word.endTime else {
            return 1.0
        }
        let duration = end - start
        return duration > 10 ? 0.001 : 1.0
    }

    private func isKeywordGapAcceptable(previous: TranscriptWord, next: TranscriptWord) -> Bool {
        guard let previousEnd = previous.endTime, let nextStart = next.startTime else {
            return true
        }
        let previousScale = timeScale(for: previous)
        let nextScale = timeScale(for: next)
        let scaledGap = (nextStart * nextScale) - (previousEnd * previousScale)
        return max(0, scaledGap) <= keywordMaxGapSeconds
    }

    private func applyKeywordReplacementsFromWords(_ words: [TranscriptWord]) -> (String, String?) {
        var output = ""
        var keyword: String? = nil
        var lowercaseNext = false
        var letterNext = false
        let maxTagWords = 4

        func appendNewline() {
            while output.last == " " {
                output.removeLast()
            }
            if output.last != "\n" {
                output.append("\n")
            }
        }

        func appendSpace() {
            output.append(" ")
        }

        func appendToken(_ token: String) {
            let isPunctuationOnly = token.rangeOfCharacter(from: CharacterSet.alphanumerics) == nil
            if isPunctuationOnly {
                if output.last == " " {
                    output.removeLast()
                }
                output.append(token)
                return
            }
            if output.isEmpty || output.last == " " || output.last == "\n" {
                output.append(token)
            } else {
                output.append(" ")
                output.append(token)
            }
        }

        func isSkippablePunctuation(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count == 1 && ".,!?".contains(trimmed)
        }

        func appendProcessedToken(_ wordText: String) {
            let normalized = normalizeToken(wordText)

            if letterNext {
                if !normalized.isEmpty, let firstChar = normalized.first {
                    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suppressNextAutoCap = true
                    }
                    appendToken(String(firstChar))
                    letterNext = false
                } else {
                    appendToken(wordText)
                }
                return
            }

            if lowercaseNext {
                if !normalized.isEmpty {
                    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suppressNextAutoCap = true
                    }
                    appendToken(wordText.lowercased())
                    lowercaseNext = false
                } else {
                    appendToken(wordText)
                }
                return
            }

            appendToken(wordText)
        }

        func isTagStopToken(_ token: String, nextToken: String?) -> Bool {
            if token == "at", nextToken == "sign" { return true }
            if token == "hash", nextToken == "tag" { return true }
            if token == "hashtag" { return true }
            if token == "new", nextToken == "line" { return true }
            if token == "newline" { return true }
            if token == "spacebar" { return true }
            if token == "space", nextToken == "bar" { return true }

            let commandStarters: Set<String> = [
                "window", "focus", "press", "copy", "paste", "cut", "undo", "redo", "select",
                "save", "tab", "go", "scroll", "cancel", "stop", "microphone", "flow", "speech",
                "wake", "submit", "send"
            ]
            return commandStarters.contains(token)
        }

        func consumeTag(startIndex: Int, prefix: String, skipCount: Int) -> Int {
            var tagText = ""
            var trailing = ""
            var consumed = skipCount
            var i = startIndex + skipCount
            var wordsCollected = 0

            while i < words.count && wordsCollected < maxTagWords {
                let raw = words[i].text
                let token = normalizeToken(raw)
                let nextToken = (i + 1 < words.count) ? normalizeToken(words[i + 1].text) : nil

                if token.isEmpty {
                    if !tagText.isEmpty {
                        trailing = raw
                        consumed += 1
                    }
                    break
                }

                if isTagStopToken(token, nextToken: nextToken) {
                    break
                }

                tagText += token
                trailing = trailingPunctuation(from: raw)
                consumed += 1
                wordsCollected += 1
                i += 1
            }

            guard !tagText.isEmpty else { return 0 }
            appendToken(prefix + tagText)
            if !trailing.isEmpty {
                appendToken(trailing)
            }
            keyword = keyword ?? (prefix == "@" ? "At sign" : "Hashtag")
            return consumed
        }

        var index = 0
        while index < words.count {
            let word = words[index]
            let token = normalizeToken(word.text)

            if token == "no", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "caps" || nextToken == "cap" {
                    keyword = keyword ?? "No caps"
                    lowercaseNext = true
                    index += 2
                    continue
                }
            }

            if token == "letter" {
                keyword = keyword ?? "Letter"
                letterNext = true
                index += 1
                continue
            }

            if token == "at", index + 1 < words.count {
                let nextToken = normalizeToken(words[index + 1].text)
                if nextToken == "sign" {
                    let consumed = consumeTag(startIndex: index, prefix: "@", skipCount: 2)
                    if consumed > 0 {
                        index += consumed
                        continue
                    }
                    keyword = keyword ?? "At sign"
                    appendToken("@")
                    index += 2
                    continue
                }
            }

            if token == "hashtag" {
                let consumed = consumeTag(startIndex: index, prefix: "#", skipCount: 1)
                if consumed > 0 {
                    index += consumed
                    continue
                }
                keyword = keyword ?? "Hashtag"
                appendToken("#")
                index += 1
                continue
            }

            if token == "hash", index + 1 < words.count {
                let nextToken = normalizeToken(words[index + 1].text)
                if nextToken == "tag" {
                    let consumed = consumeTag(startIndex: index, prefix: "#", skipCount: 2)
                    if consumed > 0 {
                        index += consumed
                        continue
                    }
                    keyword = keyword ?? "Hashtag"
                    appendToken("#")
                    index += 2
                    continue
                }
            }

            if token == "newline" {
                keyword = keyword ?? "New line"
                appendNewline()
                index += 1
                continue
            }

            if token == "new", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "line" {
                    // Check if "new" and "line" are spoken together (acceptable gap)
                    if isKeywordGapAcceptable(previous: word, next: next) {
                        // Always treat "new line" as a newline command when spoken together
                        // Users can say "say new line" if they want the literal text
                        keyword = keyword ?? "New line"
                        appendNewline()
                        if index + 2 < words.count, isSkippablePunctuation(words[index + 2].text) {
                            index += 3
                        } else {
                            index += 2
                        }
                        continue
                    } else if let previousEnd = word.endTime, let nextStart = next.startTime {
                        let gap = nextStart - previousEnd
                        logDebug("Keyword \"new line\" skipped due to pause gap (\(String(format: "%.2f", gap))s)")
                    }
                }
            }

            if token == "spacebar" {
                keyword = keyword ?? "Spacebar"
                appendSpace()
                index += 1
                continue
            }

            if token == "space", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "bar", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Spacebar"
                    appendSpace()
                    index += 2
                    continue
                }
            }

            // "nospace" or "no space" - joins adjacent words without space
            // e.g., "idea no space flow" → "ideaflow"
            if token == "nospace" {
                keyword = keyword ?? "No space"
                // Remove trailing space from output so next word joins directly
                while output.last == " " {
                    output.removeLast()
                }
                index += 1
                continue
            }

            if token == "no", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "space", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "No space"
                    // Remove trailing space from output so next word joins directly
                    while output.last == " " {
                        output.removeLast()
                    }
                    index += 2
                    continue
                }
            }

            // Parentheses: "open paren" / "close paren"
            if (token == "open" || token == "left"), index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if (nextToken == "paren" || nextToken == "parenthesis"), isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Open paren"
                    appendToken("(")
                    index += 2
                    continue
                }
                if nextToken == "bracket", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Open bracket"
                    appendToken("[")
                    index += 2
                    continue
                }
                if nextToken == "brace", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Open brace"
                    appendToken("{")
                    index += 2
                    continue
                }
            }

            if (token == "close" || token == "right"), index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if (nextToken == "paren" || nextToken == "parenthesis"), isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Close paren"
                    appendToken(")")
                    index += 2
                    continue
                }
                if nextToken == "bracket", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Close bracket"
                    appendToken("]")
                    index += 2
                    continue
                }
                if nextToken == "brace", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Close brace"
                    appendToken("}")
                    index += 2
                    continue
                }
            }

            appendProcessedToken(word.text)
            index += 1
        }

        return (output, keyword)
    }

    private func preprocessDictation(_ text: String, forceLiteral: Bool = false, words: [TranscriptWord]? = nil) -> String {
        var processed = text
        
        // 1. Handle "say" prefix (escape mode)
        // Use regex to find "say" at the beginning, ignoring optional trailing punctuation and whitespace
        var isLiteral = forceLiteral
        let sayPattern = "^say[\\.,?!]?(\\s+|$)"
        if let regex = try? NSRegularExpression(pattern: sayPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: processed, options: [], range: NSRange(location: 0, length: processed.utf16.count)) {
            isLiteral = true
            // Remove the "say" prefix and the following whitespace/punctuation
            processed = (processed as NSString).substring(from: match.range.length)
            if !didTriggerSayKeyword {
                triggerKeywordFlash(name: "Say")
                didTriggerSayKeyword = true
            }
        } else if processed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "say" {
            isLiteral = true
            processed = ""
            if !didTriggerSayKeyword {
                triggerKeywordFlash(name: "Say")
                didTriggerSayKeyword = true
            }
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

        // 2. Handle inline text replacements (only if not literal)
        if !isLiteral {
            let (keywordProcessed, keyword) = applyKeywordReplacements(processed, words: words, isLiteral: isLiteral)
            processed = keywordProcessed
            if let keyword {
                triggerKeywordFlash(name: keyword)
            }

            // 3. Strip wake-up phrases that might leak through after mode switch
            let wakeUpPhrases = ["wake up", "microphone on", "flow on"]
            for phrase in wakeUpPhrases {
                if processed.lowercased().hasPrefix(phrase) {
                    processed = String(processed.dropFirst(phrase.count))
                    processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            // 4. Handle trailing mode-switch commands if they are at the very end
            // This allows "Hello world microphone off" to just type "Hello world"
            let trailingCommands = ["microphone off", "flow off", "stop dictation", "go to sleep", "flow sleep", "submit dictation", "send dictation"]
            for cmd in trailingCommands {
                if processed.lowercased().hasSuffix(cmd) {
                    processed = String(processed.prefix(processed.count - cmd.count))
                    processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            // Strip system command phrases that might leak through
            let systemCommandPhrases = [
                "window recent two", "window recent 2", "window recent", "flip",
                "window previous", "window next",
                "cancel that", "no wait",
                "submit dictation", "send dictation",
                "save to idea flow",
                "copy that", "paste that", "cut that", "undo that", "redo that",
                "select all", "save that",
                "tab back", "tab forward", "new tab", "close tab",
                "go back", "go forward", "page up", "page down",
                "scroll up", "scroll down", "press escape", "press enter"
            ]
            for phrase in systemCommandPhrases {
                if let regex = try? NSRegularExpression(pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: phrase))[.,!?]?\\b", options: []) {
                    let range = NSRange(processed.startIndex..<processed.endIndex, in: processed)
                    processed = regex.stringByReplacingMatches(in: processed, options: [], range: range, withTemplate: "")
                }
            }
            
            // 4. (REMOVED) Strip trailing punctuation
            // User requested to keep this for now to avoid unnecessary complexity.
        }

        // 5. Smart period removal - strip trailing period from fragments
        processed = smartPeriodRemoval(processed)

        return processed
    }

    /// Remove trailing periods from text that doesn't appear to be a complete sentence.
    /// Uses word count heuristic and NaturalLanguage framework for verb detection.
    private func smartPeriodRemoval(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Only process if ends with a period
        guard trimmed.hasSuffix(".") else { return text }

        // Don't strip if it ends with ellipsis
        if trimmed.hasSuffix("...") { return text }

        // Strip the period to analyze the content
        let withoutPeriod = String(trimmed.dropLast())
        let words = withoutPeriod.split(whereSeparator: \.isWhitespace)

        // Heuristic 1: Very short utterances (1-2 words) are likely fragments
        if words.count <= 2 {
            logDebug("Smart period: stripped (≤2 words)")
            return withoutPeriod
        }

        // Heuristic 2: Use NLTagger to check for verbs
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = withoutPeriod

        var hasVerb = false
        tagger.enumerateTags(in: withoutPeriod.startIndex..<withoutPeriod.endIndex,
                             unit: .word,
                             scheme: .lexicalClass) { tag, _ in
            if tag == .verb {
                hasVerb = true
                return false // Stop enumeration
            }
            return true // Continue
        }

        // If no verb detected, it's likely a fragment - strip the period
        if !hasVerb {
            logDebug("Smart period: stripped (no verb detected)")
            return withoutPeriod
        }

        // Keep the period - appears to be a complete sentence
        return text
    }



    private func handleLiveDictationTurn(_ turn: TranscriptTurn, isForceEnd: Bool) {
        // Skip if spell/focus already handled this turn
        if turnHandledBySpecialCommand {
            logger.debug("Skipping live dictation - turn handled by special command (spell/focus)")
            return
        }

        // SPEAKER ISOLATION FILTER
        // Filter the words in the turn to only include the isolated speaker
        var effectiveWords = turn.words
        if isolatedSpeakerId != nil {
            effectiveWords = filterWordsForIsolation(turn.words)
            if effectiveWords.isEmpty && !turn.words.isEmpty {
                 logger.debug("Skipping live dictation: all words filtered out by speaker isolation")
                 return
            }
        }
        
        // If utterance had a command, we only care about words AFTER the command
        let lastCommandEndIndex = lastExecutedEndWordIndexByCommand.values.max() ?? -1

        // Skip typing during wake-up grace period, UNLESS we have a matched command to skip precisely
        if let wakeTime = wakeUpTime, Date().timeIntervalSince(wakeTime) < wakeUpGracePeriod {
            if lastCommandEndIndex < 0 {
                return
            }
        }
        
        if lastCommandEndIndex >= 0 && lastHaltingCommandEndIndex == lastCommandEndIndex {
            return
        }
        var startIndex = max(typedFinalWordCount, lastCommandEndIndex + 1)
        let isLiteral = currentUtteranceIsLiteral  // Use the flag set by processVoiceCommands

        // If literal mode was triggered by "say" after wake commands (e.g., "speech on say press enter"),
        // skip all words up to and including "say"
        if isLiteral && literalStartWordIndex > startIndex {
            startIndex = literalStartWordIndex
            NSLog("[VoiceFlow] Live dictation: adjusted startIndex to %d (literalStartWordIndex)", startIndex)
        }

        // Helper to filter out punctuation-only words
        let filterPunctuation: (String) -> Bool = { word in
            !word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty
        }

        // No longer need stripLeadingSay since we adjust startIndex above
        let stripLeadingSay: ([String]) -> [String] = { words in
            return words  // Now handled by startIndex adjustment
        }

        // Helper to process inline replacements
        let processInlineReplacements: (String, [TranscriptWord]?, Bool) -> String = { text, words, isLiteral in
            let (keywordProcessed, keyword) = self.applyKeywordReplacements(text, words: words, isLiteral: isLiteral)
            var result = keywordProcessed
            if let keyword {
                self.triggerKeywordFlash(name: keyword)
            }
            // Strip system command phrases that might leak through - BUT NOT in literal mode!
            // In literal mode (after "say"), we want to type these phrases, not strip them
            if !isLiteral {
                let systemCommandPhrases = [
                    "window recent two", "window recent 2", "window recent", "flip",
                    "window previous", "window next",
                    "cancel that", "no wait",
                    "submit dictation", "send dictation",
                    "save to idea flow",
                    "copy that", "paste that", "cut that", "undo that", "redo that",
                    "select all", "save that",
                    "tab back", "tab forward", "new tab", "close tab",
                    "go back", "go forward", "page up", "page down",
                    "scroll up", "scroll down", "press escape", "press enter"
                ]
                for phrase in systemCommandPhrases {
                    if let regex = try? NSRegularExpression(pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: phrase))[.,!?]?\\b", options: []) {
                        let range = NSRange(result.startIndex..<result.endIndex, in: result)
                        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
                    }
                }
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        // If it's a formatted turn (Cloud model with formatting ON)
        if turn.isFormatted {
            let finalWords = effectiveWords.filter { $0.isFinal == true }.map { $0.text }
            guard finalWords.count > startIndex else { return }
            var newWords = finalWords[startIndex...].filter(filterPunctuation)
            newWords = stripLeadingSay(Array(newWords))
            guard !newWords.isEmpty else { return }
            
            let needsSpace = startIndex > 0 || hasTypedInSession
            let prefix = needsSpace ? " " : ""
            let rawText = prefix + newWords.joined(separator: " ")
            let finalWordObjects = effectiveWords.filter { $0.isFinal == true }
            let wordSlice = Array(finalWordObjects[startIndex...].filter { filterPunctuation($0.text) })
            var textToType = processInlineReplacements(rawText, wordSlice, isLiteral)
            if needsSpace, !textToType.isEmpty, textToType.first != "\n", textToType.first != " " {
                textToType = " " + textToType
            }
            logDebug("Live typing delta (formatted): \"\(textToType)\"")
            typeText(textToType, appendSpace: false)
            if !textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didTypeDictationThisUtterance = true
                hasTypedInSession = true
            }
            typedFinalWordCount = finalWords.count
            return
        }

        // If it's unformatted (Live Dictation mode)
        if turn.endOfTurn {
            let allWords = effectiveWords.map { $0.text }
            guard allWords.count > startIndex else {
                typedFinalWordCount = 0
                return
            }
            var newWords = allWords[startIndex...].filter(filterPunctuation)
            newWords = stripLeadingSay(Array(newWords))
            guard !newWords.isEmpty else {
                typedFinalWordCount = 0
                return
            }
            
            let needsSpace = startIndex > 0 || hasTypedInSession
            let prefix = needsSpace ? " " : ""
            let rawText = prefix + newWords.joined(separator: " ")
            let wordSlice = Array(effectiveWords[startIndex...].filter { filterPunctuation($0.text) })
            var textToType = processInlineReplacements(rawText, wordSlice, isLiteral)
            if needsSpace, !textToType.isEmpty, textToType.first != "\n", textToType.first != " " {
                textToType = " " + textToType
            }
            logDebug("Live typing delta (final): \"\(textToType)\"")
            typeText(textToType, appendSpace: false)
            if !textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didTypeDictationThisUtterance = true
                hasTypedInSession = true
            }
            typedFinalWordCount = 0 // Reset after final
        }
    }

    private struct PendingCommandMatch {
        let key: String
        let startWordIndex: Int
        let endWordIndex: Int
        let isPrefixed: Bool
        let isStable: Bool
        let requiresPause: Bool
        let haltsProcessing: Bool
        let turn: TranscriptTurn
        let action: () -> Void
    }

    private struct PendingExecutionKey: Hashable {
        let key: String
        let endWordIndex: Int
    }

    /// Detect "say" prefix for literal/escape mode (used in dictation mode where full command processing is skipped)
    private func detectSayPrefix(_ turn: TranscriptTurn) {
        let normalizedTokens = normalizedWordTokens(from: turn.words)
        let transcriptForPrefix = turn.transcript.isEmpty ? (turn.utterance ?? "") : turn.transcript
        // Check both transcript prefix AND first word token (transcript may not reflect words accurately)
        let hasSayPrefix = isSayPrefix(transcriptForPrefix)
            || normalizedTokens.first?.token == "say"

        if hasSayPrefix {
            currentUtteranceIsLiteral = true
            let firstWordIndex = normalizedTokens.first?.wordIndex ?? 0
            literalStartWordIndex = firstWordIndex + 1  // Start after the first word ("say")
            if !didTriggerSayKeyword {
                triggerKeywordFlash(name: "Say")
                didTriggerSayKeyword = true
            }
            NSLog("[VoiceFlow] detectSayPrefix: detected 'say' in dictation mode, entering literal mode")
        }
    }

    private func processVoiceCommands(_ turn: TranscriptTurn) {
        let normalizedTokens = normalizedWordTokens(from: turn.words)
        let transcriptForPrefix = turn.transcript.isEmpty ? (turn.utterance ?? "") : turn.transcript
        let hasSayPrefix = isSayPrefix(transcriptForPrefix)
            || (transcriptForPrefix.isEmpty && normalizedTokens.first?.token == "say")
        NSLog("[VoiceFlow] processVoiceCommands: transcript=\"%@\", hasSayPrefix=%d", String(transcriptForPrefix.prefix(60)), hasSayPrefix ? 1 : 0)

        if hasSayPrefix {
            currentUtteranceIsLiteral = true
            let firstWordIndex = normalizedTokens.first?.wordIndex ?? 0
            literalStartWordIndex = firstWordIndex + 1  // Start after the first word ("say")
            if !didTriggerSayKeyword {
                triggerKeywordFlash(name: "Say")
                didTriggerSayKeyword = true
            }
            logger.debug("Utterance starts with 'say', skipping command processing")
            return
        }
        if currentUtteranceIsLiteral {
            logger.debug("Utterance already in literal mode, skipping command processing")
            return
        }
        guard !normalizedTokens.isEmpty else { return }

        // Debug: log the tokens
        let tokenList = normalizedTokens.map { $0.token }.joined(separator: ", ")
        NSLog("[VoiceFlow] normalizedTokens: [%@]", tokenList)

        // Check if "say" appears at the start OR after wake/mode commands
        // This handles "speech on say press enter" → escape "press enter"
        let wakeCommands = Set(["speech", "wake", "flow", "microphone"])
        let modifiers = Set(["on", "up"])
        var sayIndex: Int? = nil

        for (index, token) in normalizedTokens.enumerated() {
            if token.token == "say" {
                // Check if everything before this is wake/mode command words
                let precedingTokens = normalizedTokens.prefix(index).map { $0.token }
                let allPrecedingAreWakeWords = precedingTokens.allSatisfy { wakeCommands.contains($0) || modifiers.contains($0) }
                NSLog("[VoiceFlow] Found 'say' at index %d, preceding=[%@], allWake=%d", index, precedingTokens.joined(separator: ", "), allPrecedingAreWakeWords ? 1 : 0)
                if allPrecedingAreWakeWords {
                    sayIndex = index
                    break
                }
            }
        }

        if let idx = sayIndex {
            // Found "say" after wake commands - we need to:
            // 1. Execute the wake commands that come BEFORE "say"
            // 2. Then enter literal mode for everything after
            NSLog("[VoiceFlow] sayIndex found at %d, will process wake commands first", idx)

            // Get only the tokens BEFORE "say" for wake command processing
            let preTokens = Array(normalizedTokens.prefix(idx))
            let preTokenStrings = preTokens.map { $0.token }

            // Match and execute wake commands from the pre-say tokens
            var wakeCommands: [(phrase: String, key: String, name: String, action: () -> Void)] = []
            if microphoneMode == .sleep {
                wakeCommands = [
                    (phrase: "wake up", key: "system.wake_up", name: "On", action: { [weak self] in self?.setMode(.on) }),
                    (phrase: "microphone on", key: "system.wake_up", name: "On", action: { [weak self] in self?.setMode(.on) }),
                    (phrase: "flow on", key: "system.wake_up", name: "On", action: { [weak self] in self?.setMode(.on) }),
                    (phrase: "speech on", key: "system.wake_up", name: "On", action: { [weak self] in self?.setMode(.on) })
                ]
            }

            for cmd in wakeCommands {
                let phraseTokens = tokenizePhrase(cmd.phrase)
                if let range = findMatches(phraseTokens: phraseTokens, in: preTokenStrings).first {
                    let endWordIndex = preTokens[range.upperBound - 1].wordIndex
                    let lastEndIndex = lastExecutedEndWordIndexByCommand[cmd.key] ?? -1
                    if endWordIndex > lastEndIndex {
                        let wordIndices = preTokens[range].map { $0.wordIndex }
                        if isStableMatch(words: turn.words, wordIndices: wordIndices) {
                            NSLog("[VoiceFlow] Executing pre-say wake command: %@", cmd.name)
                            lastExecutedEndWordIndexByCommand[cmd.key] = endWordIndex
                            currentUtteranceHadCommand = true
                            cmd.action()
                            triggerCommandFlash(name: cmd.name)
                        }
                    }
                }
            }

            // Now enter literal mode
            currentUtteranceIsLiteral = true
            // Set literalStartWordIndex to the word AFTER "say"
            let sayWordIndex = normalizedTokens[idx].wordIndex
            literalStartWordIndex = sayWordIndex + 1
            NSLog("[VoiceFlow] literalStartWordIndex set to %d (word after 'say' at wordIndex %d)", literalStartWordIndex, sayWordIndex)
            if !didTriggerSayKeyword {
                triggerKeywordFlash(name: "Say")
                didTriggerSayKeyword = true
            }
            NSLog("[VoiceFlow] sayIndex at %d, now in literal mode", idx)
            logger.debug("Found 'say' at index \(idx), skipping further command processing for literal text")
            return
        }

        // Voice Spelling Mode
        let lowerTranscript = turn.transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerTranscript.hasPrefix("spell ") {
            let textToSpell = String(turn.transcript.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if !textToSpell.isEmpty && turn.endOfTurn {
                let converted = convertSpokenToCharacters(textToSpell)
                logDebug("Voice Spelling: \"\(textToSpell)\" → \"\(converted)\"")
                typeText(converted, appendSpace: false)
                triggerCommandFlash(name: "Spell")
                turnHandledBySpecialCommand = true  // Prevent dictation from also typing
                return
            }
        }

        // Voice App Focusing
        if lowerTranscript.hasPrefix("focus ") {
            let appName = String(turn.transcript.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if !appName.isEmpty && turn.endOfTurn {
                logDebug("Focusing App: \"\(appName)\"")
                let result = windowManager.focusApp(named: appName)
                switch result {
                case .focused(let name, let matchType):
                    logDebug("Focus success (\(matchType)): \"\(name)\"")
                    triggerCommandFlash(name: "Focus: \(name)")
                case .notFound(let query):
                    logDebug("Focus failed: no running app matching \"\(query)\"")
                    triggerCommandFlash(name: "Focus: not found (\(query))")
                case .emptyQuery:
                    logDebug("Focus failed: empty query")
                    triggerCommandFlash(name: "Focus: empty query")
                }
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.focus"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true  // Prevent dictation from also typing
                return
            }
        }

        let tokenStrings = normalizedTokens.map { $0.token }

        var matches: [PendingCommandMatch] = []
        
        if microphoneMode == .on {
            matches.append(contentsOf: pressCommandMatches(from: normalizedTokens, turn: turn))
        }

        // System commands based on current mode
        var systemCommands: [(phrase: String, key: String, name: String, haltsProcessing: Bool, action: () -> Void)] = []
        
        if microphoneMode == .sleep {
            systemCommands.append(contentsOf: [
                (phrase: "wake up", key: "system.wake_up", name: "On", haltsProcessing: false, action: { [weak self] in self?.setMode(.on) } as () -> Void),
                (phrase: "microphone on", key: "system.wake_up", name: "On", haltsProcessing: false, action: { [weak self] in self?.setMode(.on) } as () -> Void),
                (phrase: "flow on", key: "system.wake_up", name: "On", haltsProcessing: false, action: { [weak self] in self?.setMode(.on) } as () -> Void),
                (phrase: "speech on", key: "system.wake_up", name: "On", haltsProcessing: false, action: { [weak self] in self?.setMode(.on) } as () -> Void),
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
                (phrase: "speech off", key: "system.go_to_sleep", name: "Sleep", haltsProcessing: true, action: { [weak self] in
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
                (phrase: "flip", key: "system.window_recent", name: "Flip", haltsProcessing: true, action: { [weak self] in self?.windowManager.switchToRecent(index: 1) } as () -> Void),
                (phrase: "window recent 2", key: "system.window_recent_2", name: "Previous Window 2", haltsProcessing: true, action: { [weak self] in self?.windowManager.switchToRecent(index: 2) } as () -> Void),
                (phrase: "window recent two", key: "system.window_recent_2", name: "Previous Window 2", haltsProcessing: true, action: { [weak self] in self?.windowManager.switchToRecent(index: 2) } as () -> Void),
                // Window cycling within same app (Cmd+` and Cmd+Shift+`)
                (phrase: "window next", key: "system.window_next", name: "Next Window", haltsProcessing: true, action: { [weak self] in
                    self?.executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command]))
                } as () -> Void),
                (phrase: "window previous", key: "system.window_previous", name: "Previous Window", haltsProcessing: true, action: { [weak self] in
                    self?.executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command, .shift]))
                } as () -> Void),
                (phrase: "save to idea flow", key: "system.save_ideaflow", name: "Idea Flow", haltsProcessing: true, action: { [weak self] in self?.saveToIdeaFlow() } as () -> Void),
                
                // Dictation Provider Switching
                (phrase: "use online model", key: "system.provider_online", name: "Online Model", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.online) } as () -> Void),
                (phrase: "use offline model", key: "system.provider_offline", name: "Offline Model", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.offline) } as () -> Void),
                (phrase: "use auto model", key: "system.provider_auto", name: "Auto Model", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.auto) } as () -> Void),
                (phrase: "use deepgram", key: "system.provider_deepgram", name: "Deepgram", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.deepgram) } as () -> Void),
                (phrase: "switch to deepgram", key: "system.provider_deepgram", name: "Deepgram", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.deepgram) } as () -> Void)
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
                    requiresPause: false,
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
                        requiresPause: command.requiresPause,
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
            // Exception: If command requiresPause and it's NOT the end of the turn, we MUST delay it
            // (even if commandDelayMs is 0, we'll use a default minimal delay if needed, 
            // but scheduleMatch handles the delay via commandDelayMs).
            
            let shouldDelayForPause = match.requiresPause && !match.turn.endOfTurn
            
            if (match.isPrefixed || match.haltsProcessing || (commandDelayMs <= 0 && !match.requiresPause) || hasFollowingCommand) && !shouldDelayForPause {
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
        currentWords = []
        currentTranscript = ""
        lastExecutedEndWordIndexByCommand.removeAll()
        currentUtteranceHadCommand = false
        currentUtteranceIsLiteral = false
        literalStartWordIndex = 0
        lastHaltingCommandEndIndex = -1
        didTriggerSayKeyword = false
        pendingCommandExecutions.removeAll()
        typedFinalWordCount = 0
        didTypeDictationThisUtterance = false
        forceEndPending = false
        forceEndRequestedAt = nil
        suppressNextAutoCap = false
    }

    private func isSayPrefix(_ text: String) -> Bool {
        let sayPattern = "^say[\\.,?!]?(\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: sayPattern, options: [.caseInsensitive]) else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil
    }

    private func executeMatch(_ match: PendingCommandMatch) {
        let didFlushText = preExecuteMatch(match)
        executeMatchAction(match, didFlushText: didFlushText)
    }

    private func preExecuteMatch(_ match: PendingCommandMatch) -> Bool {
        var didFlushText = false
        // 1. Pre-emptive Flush: Type any words BEFORE the command phrase
        if microphoneMode == .on && activeBehavior != .command {
            let lastConsumedIndex = lastExecutedEndWordIndexByCommand.values.max() ?? -1
            let startFlushIndex = max(0, lastConsumedIndex + 1)
            
            if startFlushIndex < match.startWordIndex {
                let range = startFlushIndex..<match.startWordIndex
                
                // Determine what has already been typed
                let untypedWords: [String]
                if liveDictationEnabled {
                    // In live mode, we track by count
                    // We only care about words that are AFTER typedFinalWordCount
                    let effectiveStart = max(startFlushIndex, typedFinalWordCount)
                    if effectiveStart < match.startWordIndex {
                        untypedWords = match.turn.words[effectiveStart..<match.startWordIndex].map { $0.text }
                        typedFinalWordCount = match.startWordIndex
                    } else {
                        untypedWords = []
                    }
                } else {
                    // In turn-based mode, we flush everything in the range
                    untypedWords = match.turn.words[range].map { $0.text }
                }
                
                if !untypedWords.isEmpty {
                    let textToFlush = untypedWords.joined(separator: " ")
                    logDebug("Pre-emptive flush: \"\(textToFlush)\"")
                    typeText(textToFlush, appendSpace: true)
                    if !textToFlush.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        didTypeDictationThisUtterance = true
                    }
                    didFlushText = true
                }
            }
        }

        // 2. Mark as consumed IMMEDIATELY to prevent dictation handler from typing the command phrase
        lastExecutedEndWordIndexByCommand[match.key] = match.endWordIndex
        currentUtteranceHadCommand = true
        if match.haltsProcessing {
            lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, match.endWordIndex)
        }

        // 3. Add to history immediately so user sees command was recognized
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
        return didFlushText
    }

    private func executeMatchAction(_ match: PendingCommandMatch, didFlushText: Bool) {
        let performAction = { [weak self] in
            guard let self = self else { return }
            self.logDebug("Executing action for command: \(match.key)")
            match.action()
            if match.key.hasPrefix("user.") {
                self.lastCommandExecutionTime = Date()
            }
        }
        if didFlushText && typingFlushDelaySeconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + typingFlushDelaySeconds) {
                performAction()
            }
        } else {
            performAction()
        }
    }

    private func scheduleMatch(_ match: PendingCommandMatch) {
        let pendingKey = PendingExecutionKey(key: match.key, endWordIndex: match.endWordIndex)
        guard !pendingCommandExecutions.contains(pendingKey) else { return }
        pendingCommandExecutions.insert(pendingKey)

        // Mark as consumed IMMEDIATELY before the delay so it doesn't get typed as dictation
        let didFlushText = preExecuteMatch(match)

        let delaySeconds = commandDelayMs / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self = self else { return }
            self.pendingCommandExecutions.remove(pendingKey)

            // We don't need to check lastExecutedEndWordIndexByCommand here because preExecuteMatch 
            // already updated it, and processVoiceCommands checked it before scheduling.
            self.executeMatchAction(match, didFlushText: didFlushText)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + commandFlashDurationSeconds) { [weak self] in
            self?.isCommandFlashActive = false
        }
    }

    private func triggerKeywordFlash(name: String) {
        lastKeywordName = name
        isKeywordFlashActive = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + keywordFlashDurationSeconds) { [weak self] in
            self?.isKeywordFlashActive = false
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

    private func lowercasedFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    private func lowercasedFirstWord(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "\\S+", options: .regularExpression) else {
            return text
        }
        let prefix = trimmed[..<range.lowerBound]
        let word = trimmed[range]
        let suffix = trimmed[range.upperBound...]
        return String(prefix) + word.lowercased() + String(suffix)
    }

    private func trailingPunctuation(from text: String) -> String {
        guard let lastAlphaIndex = text.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
            return text
        }
        let trailing = text[text.index(after: lastAlphaIndex)...]
        return String(trailing)
    }

    private func modifierForToken(_ token: String) -> KeyboardModifiers? {
        switch token {
        case "command", "cmd":
            return .command
        case "control", "ctrl":
            return .control
        case "option", "alt":
            return .option
        case "shift":
            return .shift
        default:
            return nil
        }
    }

    private func keyCodeForToken(_ token: String, nextToken: String?) -> (keyCode: UInt16, consumedTokens: Int)? {
        switch token {
        case "escape", "esc":
            return (UInt16(kVK_Escape), 1)
        case "enter", "return":
            return (UInt16(kVK_Return), 1)
        case "tab":
            return (UInt16(kVK_Tab), 1)
        case "space":
            if nextToken == "bar" {
                return (UInt16(kVK_Space), 2)
            }
            return (UInt16(kVK_Space), 1)
        case "spacebar":
            return (UInt16(kVK_Space), 1)
        case "delete", "backspace":
            return (UInt16(kVK_Delete), 1)
        case "forward", "del":
            if nextToken == "delete" {
                return (UInt16(kVK_ForwardDelete), 2)
            }
        case "page":
            if nextToken == "up" {
                return (UInt16(kVK_PageUp), 2)
            } else if nextToken == "down" {
                return (UInt16(kVK_PageDown), 2)
            }
        case "left":
            if nextToken == "arrow" {
                return (UInt16(kVK_LeftArrow), 2)
            }
        case "right":
            if nextToken == "arrow" {
                return (UInt16(kVK_RightArrow), 2)
            }
        case "up":
            if nextToken == "arrow" {
                return (UInt16(kVK_UpArrow), 2)
            }
        case "down":
            if nextToken == "arrow" {
                return (UInt16(kVK_DownArrow), 2)
            }
        case "home":
            return (UInt16(kVK_Home), 1)
        case "end":
            return (UInt16(kVK_End), 1)
        case "backtick", "grave", "tilde":
            return (UInt16(kVK_ANSI_Grave), 1)
        case "back":
            if nextToken == "tick" {
                return (UInt16(kVK_ANSI_Grave), 2)  // "back tick" → `
            }
        default:
            break
        }

        if token.count == 1, let scalar = token.unicodeScalars.first {
            if CharacterSet.letters.contains(scalar) {
                let upper = String(token).uppercased()
                switch upper {
                case "A": return (UInt16(kVK_ANSI_A), 1)
                case "B": return (UInt16(kVK_ANSI_B), 1)
                case "C": return (UInt16(kVK_ANSI_C), 1)
                case "D": return (UInt16(kVK_ANSI_D), 1)
                case "E": return (UInt16(kVK_ANSI_E), 1)
                case "F": return (UInt16(kVK_ANSI_F), 1)
                case "G": return (UInt16(kVK_ANSI_G), 1)
                case "H": return (UInt16(kVK_ANSI_H), 1)
                case "I": return (UInt16(kVK_ANSI_I), 1)
                case "J": return (UInt16(kVK_ANSI_J), 1)
                case "K": return (UInt16(kVK_ANSI_K), 1)
                case "L": return (UInt16(kVK_ANSI_L), 1)
                case "M": return (UInt16(kVK_ANSI_M), 1)
                case "N": return (UInt16(kVK_ANSI_N), 1)
                case "O": return (UInt16(kVK_ANSI_O), 1)
                case "P": return (UInt16(kVK_ANSI_P), 1)
                case "Q": return (UInt16(kVK_ANSI_Q), 1)
                case "R": return (UInt16(kVK_ANSI_R), 1)
                case "S": return (UInt16(kVK_ANSI_S), 1)
                case "T": return (UInt16(kVK_ANSI_T), 1)
                case "U": return (UInt16(kVK_ANSI_U), 1)
                case "V": return (UInt16(kVK_ANSI_V), 1)
                case "W": return (UInt16(kVK_ANSI_W), 1)
                case "X": return (UInt16(kVK_ANSI_X), 1)
                case "Y": return (UInt16(kVK_ANSI_Y), 1)
                case "Z": return (UInt16(kVK_ANSI_Z), 1)
                default: break
                }
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                switch token {
                case "0": return (UInt16(kVK_ANSI_0), 1)
                case "1": return (UInt16(kVK_ANSI_1), 1)
                case "2": return (UInt16(kVK_ANSI_2), 1)
                case "3": return (UInt16(kVK_ANSI_3), 1)
                case "4": return (UInt16(kVK_ANSI_4), 1)
                case "5": return (UInt16(kVK_ANSI_5), 1)
                case "6": return (UInt16(kVK_ANSI_6), 1)
                case "7": return (UInt16(kVK_ANSI_7), 1)
                case "8": return (UInt16(kVK_ANSI_8), 1)
                case "9": return (UInt16(kVK_ANSI_9), 1)
                default: break
                }
            }
        }
        return nil
    }

    private func shortcutDisplayName(_ shortcut: KeyboardShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.command) { parts.append("Command") }
        if shortcut.modifiers.contains(.control) { parts.append("Control") }
        if shortcut.modifiers.contains(.option) { parts.append("Option") }
        if shortcut.modifiers.contains(.shift) { parts.append("Shift") }
        let keyName = KeyboardShortcut.keyCodeToString(shortcut.keyCode)
        parts.append(keyName)
        return parts.joined(separator: "+")
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

    private func pressCommandMatches(from normalizedTokens: [NormalizedToken], turn: TranscriptTurn) -> [PendingCommandMatch] {
        guard !normalizedTokens.isEmpty else { return [] }
        var matches: [PendingCommandMatch] = []
        var index = 0
        while index < normalizedTokens.count {
            let token = normalizedTokens[index].token
            guard token == "press" else {
                index += 1
                continue
            }

            var modifiers: KeyboardModifiers = []
            var cursor = index + 1
            while cursor < normalizedTokens.count {
                let candidate = normalizedTokens[cursor].token
                if let modifier = modifierForToken(candidate) {
                    modifiers.insert(modifier)
                    cursor += 1
                    continue
                }
                break
            }

            guard cursor < normalizedTokens.count else {
                index += 1
                continue
            }

            let keyToken = normalizedTokens[cursor].token
            let nextToken = (cursor + 1 < normalizedTokens.count) ? normalizedTokens[cursor + 1].token : nil
            guard let keyInfo = keyCodeForToken(keyToken, nextToken: nextToken) else {
                index += 1
                continue
            }

            if modifiers.isEmpty && (keyToken == "escape" || keyToken == "esc" || keyToken == "enter" || keyToken == "return") {
                index += 1
                continue
            }

            let endTokenIndex = cursor + keyInfo.consumedTokens - 1
            guard normalizedTokens.indices.contains(endTokenIndex) else {
                index += 1
                continue
            }

            let startWordIndex = normalizedTokens[index].wordIndex
            let endWordIndex = normalizedTokens[endTokenIndex].wordIndex
            let isPrefixed = index > 0 && normalizedTokens[index - 1].token == commandPrefixToken
            let wordIndices = normalizedTokens[index...endTokenIndex].map { $0.wordIndex }
            let isStable = isPrefixed || isStableMatch(words: turn.words, wordIndices: wordIndices)
            let shortcut = KeyboardShortcut(keyCode: keyInfo.keyCode, modifiers: modifiers)
            let label = "Press \(shortcutDisplayName(shortcut))"

            matches.append(PendingCommandMatch(
                key: "system.press",
                startWordIndex: startWordIndex,
                endWordIndex: endWordIndex,
                isPrefixed: isPrefixed,
                isStable: isStable,
                requiresPause: false,
                haltsProcessing: false,
                turn: turn,
                action: { [weak self] in
                    self?.executeKeyboardShortcut(shortcut)
                    self?.triggerCommandFlash(name: label)
                }
            ))

            index = endTokenIndex + 1
        }

        return matches
    }

    // MARK: - Spell Command Character Conversion

    /// Maps spoken words to their character equivalents for the spell command
    private static let spokenCharacterMap: [String: String] = [
        // Single digit numbers
        "zero": "0", "oh": "0",
        "one": "1",
        "two": "2", "to": "2", "too": "2",
        "three": "3",
        "four": "4", "for": "4",
        "five": "5",
        "six": "6",
        "seven": "7",
        "eight": "8",
        "nine": "9",

        // Compound numbers (for speech recognition that says "thirty nine" instead of "three nine")
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19",
        "twenty": "20", "twenty one": "21", "twenty two": "22", "twenty three": "23",
        "twenty four": "24", "twenty five": "25", "twenty six": "26", "twenty seven": "27",
        "twenty eight": "28", "twenty nine": "29",
        "thirty": "30", "thirty one": "31", "thirty two": "32", "thirty three": "33",
        "thirty four": "34", "thirty five": "35", "thirty six": "36", "thirty seven": "37",
        "thirty eight": "38", "thirty nine": "39",
        "forty": "40", "forty one": "41", "forty two": "42", "forty three": "43",
        "forty four": "44", "forty five": "45", "forty six": "46", "forty seven": "47",
        "forty eight": "48", "forty nine": "49",
        "fifty": "50", "fifty one": "51", "fifty two": "52", "fifty three": "53",
        "fifty four": "54", "fifty five": "55", "fifty six": "56", "fifty seven": "57",
        "fifty eight": "58", "fifty nine": "59",
        "sixty": "60", "sixty one": "61", "sixty two": "62", "sixty three": "63",
        "sixty four": "64", "sixty five": "65", "sixty six": "66", "sixty seven": "67",
        "sixty eight": "68", "sixty nine": "69",
        "seventy": "70", "seventy one": "71", "seventy two": "72", "seventy three": "73",
        "seventy four": "74", "seventy five": "75", "seventy six": "76", "seventy seven": "77",
        "seventy eight": "78", "seventy nine": "79",
        "eighty": "80", "eighty one": "81", "eighty two": "82", "eighty three": "83",
        "eighty four": "84", "eighty five": "85", "eighty six": "86", "eighty seven": "87",
        "eighty eight": "88", "eighty nine": "89",
        "ninety": "90", "ninety one": "91", "ninety two": "92", "ninety three": "93",
        "ninety four": "94", "ninety five": "95", "ninety six": "96", "ninety seven": "97",
        "ninety eight": "98", "ninety nine": "99",
        "hundred": "",  // Skip - "eight hundred thirty nine" → "8" + "" + "39" = "839"
        "thousand": "",  // Skip multiplier words

        // Common symbols
        "at": "@", "at sign": "@",
        "hash": "#", "hashtag": "#", "pound": "#", "number sign": "#",
        "dollar": "$", "dollar sign": "$",
        "percent": "%", "percent sign": "%",
        "ampersand": "&", "and sign": "&",
        "asterisk": "*", "star": "*",
        "plus": "+", "plus sign": "+",
        "equals": "=", "equal": "=", "equal sign": "=",
        "dash": "-", "hyphen": "-", "minus": "-",
        "underscore": "_",
        "period": ".", "dot": ".", "full stop": ".",
        "comma": ",",
        "slash": "/", "forward slash": "/",
        "backslash": "\\", "back slash": "\\",
        "colon": ":",
        "semicolon": ";", "semi colon": ";",
        "question": "?", "question mark": "?",
        "exclamation": "!", "exclamation point": "!", "exclamation mark": "!",
        "open paren": "(", "left paren": "(", "open parenthesis": "(",
        "close paren": ")", "right paren": ")", "close parenthesis": ")",
        "open bracket": "[", "left bracket": "[",
        "close bracket": "]", "right bracket": "]",
        "open brace": "{", "left brace": "{",
        "close brace": "}", "right brace": "}",
        "quote": "\"", "double quote": "\"",
        "single quote": "'", "apostrophe": "'",
        "backtick": "`", "back tick": "`",
        "tilde": "~",
        "caret": "^",
        "pipe": "|", "vertical bar": "|",
        "less than": "<", "left angle": "<",
        "greater than": ">", "right angle": ">",

        // Space
        "space": " "
    ]

    /// Converts spoken text to characters (for spell command)
    /// "eight three nine" → "839", "capital a b c" → "Abc"
    private func convertSpokenToCharacters(_ text: String) -> String {
        let words = text.lowercased().split(separator: " ").map(String.init)
        var result = ""
        var i = 0

        while i < words.count {
            let word = words[i]

            // Check for "capital" modifier
            if word == "capital" || word == "uppercase" || word == "cap" {
                if i + 1 < words.count {
                    let nextWord = words[i + 1]
                    if nextWord.count == 1 {
                        result += nextWord.uppercased()
                        i += 2
                        continue
                    } else if let mapped = Self.spokenCharacterMap[nextWord], mapped.count == 1 {
                        result += mapped.uppercased()
                        i += 2
                        continue
                    }
                }
            }

            // Check for two-word phrases first (e.g., "at sign", "open paren")
            if i + 1 < words.count {
                let twoWords = "\(word) \(words[i + 1])"
                if let mapped = Self.spokenCharacterMap[twoWords] {
                    result += mapped
                    i += 2
                    continue
                }
            }

            // Check single word mapping
            if let mapped = Self.spokenCharacterMap[word] {
                result += mapped
            } else if word.count == 1 {
                // Single letter - use as-is
                result += word
            } else {
                // Unknown word - pass through as-is (collapsed)
                result += word
            }

            i += 1
        }

        return result
    }

    private func typeText(_ text: String, appendSpace: Bool) {
        // Check accessibility first
        guard AXIsProcessTrusted() else {
            let msg = "Cannot type - Accessibility permission NOT granted"
            logger.error("\(msg)")
            logDebug("Error: \(msg)")
            return
        }

        // Log which app will receive the keystrokes (helps debug when text goes wrong place)
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appName = frontApp.localizedName ?? "Unknown"
            let bundleId = frontApp.bundleIdentifier ?? "?"
            logDebug("Target app: \(appName) (\(bundleId))")
        } else {
            logDebug("Target app: Unknown (no frontmost app)")
        }

        // Don't append space after newlines - it looks wrong
        let shouldAppendSpace = appendSpace && !text.hasSuffix("\n")
        let output = shouldAppendSpace ? text + " " : text
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

        // Get inter-character delay for current app (browsers like Google Docs need slower typing)
        let interCharDelay = focusContextManager.getInterCharacterDelay()
        if interCharDelay > 0 {
            logDebug("Using \(Int(interCharDelay * 1000))ms inter-character delay for browser app")
        }

        let minDelayBeforeReturn: TimeInterval = 0.02  // 20ms minimum delay before Return key

        for char in output {
            if char == "\n" {
                // Ensure sufficient delay before Return key, even across typeText calls
                // This fixes inconsistent newline submission at end of utterances
                if let lastTime = lastKeyEventTime {
                    let elapsed = Date().timeIntervalSince(lastTime)
                    let neededDelay = max(0, minDelayBeforeReturn - elapsed)
                    if neededDelay > 0 {
                        Thread.sleep(forTimeInterval: neededDelay)
                    }
                } else if eventsPosted > 0 {
                    // Fallback: delay within same call
                    Thread.sleep(forTimeInterval: minDelayBeforeReturn)
                }

                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
                lastKeyEventTime = Date()
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
                lastKeyEventTime = Date()
                eventsPosted += 1

                // Apply inter-character delay for apps that need slower typing (Google Docs, etc.)
                if interCharDelay > 0 {
                    Thread.sleep(forTimeInterval: interCharDelay)
                }
            }
        }
        logger.debug("Successfully posted \(eventsPosted) character events")
    }

    private func executeKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        // Log which app will receive the shortcut
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appName = frontApp.localizedName ?? "Unknown"
            logDebug("Shortcut target: \(appName)")
        }

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
        apiKey = UserDefaults.standard.string(forKey: "assemblyai_api_key") ?? "73686868686868686868686868686868" // Default placeholder or real key if provided
        deepgramApiKey = UserDefaults.standard.string(forKey: "deepgram_api_key") ?? "9988458f12e98ddd52fc20a9ed5eb089b22ca29e"
    }

    func saveAPIKey(_ key: String) {
        let previous = apiKey
        apiKey = key
        UserDefaults.standard.set(key, forKey: "assemblyai_api_key")
        
        if previous != key && microphoneMode != .off && (dictationProvider == .online || dictationProvider == .auto) {
            logDebug("API Key changed: Restarting services")
            restartServicesIfActive()
        }
    }

    func saveDeepgramApiKey(_ key: String) {
        let previous = deepgramApiKey
        deepgramApiKey = key
        UserDefaults.standard.set(key, forKey: "deepgram_api_key")
        
        if previous != key && microphoneMode != .off && dictationProvider == .deepgram {
            logDebug("Deepgram API Key changed: Restarting services")
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

    private func updateLatency(_ latencyMs: Int?) {
        connectionLatencyMs = latencyMs
        guard let latencyMs else {
            if isLatencyDegraded {
                logDebug("Latency cleared")
            }
            isLatencyDegraded = false
            return
        }

        if !isLatencyDegraded && latencyMs >= latencyWarningThresholdMs {
            isLatencyDegraded = true
            logDebug("High latency detected: \(latencyMs)ms")
        } else if isLatencyDegraded && latencyMs <= latencyRecoveryThresholdMs {
            isLatencyDegraded = false
            logDebug("Latency recovered: \(latencyMs)ms")
        }
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
        sleepTimerEnabled = UserDefaults.standard.object(forKey: "sleep_timer_enabled") as? Bool ?? true
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

    // MARK: - Auto-Off Timer Settings

    private func loadAutoOffSettings() {
        autoOffEnabled = UserDefaults.standard.object(forKey: "auto_off_enabled") as? Bool ?? true
        let storedMinutes = UserDefaults.standard.double(forKey: "auto_off_minutes")
        if storedMinutes > 0 {
            autoOffMinutes = storedMinutes
        }
    }

    func saveAutoOffEnabled(_ value: Bool) {
        autoOffEnabled = value
        UserDefaults.standard.set(value, forKey: "auto_off_enabled")
        if value {
            resetAutoOffTimer()
        } else {
            stopAutoOffTimer()
        }
    }

    func saveAutoOffMinutes(_ value: Double) {
        autoOffMinutes = value
        UserDefaults.standard.set(value, forKey: "auto_off_minutes")
        if autoOffEnabled {
            resetAutoOffTimer()
        }
    }

    private func resetAutoOffTimer() {
        stopAutoOffTimer()
        // Auto-off runs when mic is On or Sleep (not Off)
        guard autoOffEnabled && microphoneMode != .off else { return }

        let seconds = autoOffMinutes * 60
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleAutoOffTimeout()
            }
        }
    }

    private func stopAutoOffTimer() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
    }

    private func handleAutoOffTimeout() {
        guard microphoneMode != .off else { return }
        logDebug("Auto-off timeout: Turning microphone completely Off after \(Int(autoOffMinutes)) minutes")
        setMode(.off)
    }

    // MARK: - AI Formatter Settings

    private func loadAIFormatterSettings() {
        aiFormatterEnabled = UserDefaults.standard.bool(forKey: "ai_formatter_enabled")
        anthropicApiKey = UserDefaults.standard.string(forKey: "anthropic_api_key") ?? ""

        // Sync to service
        aiFormatterService.config.enabled = aiFormatterEnabled
        aiFormatterService.config.apiKey = anthropicApiKey
    }

    func saveAIFormatterEnabled(_ value: Bool) {
        aiFormatterEnabled = value
        UserDefaults.standard.set(value, forKey: "ai_formatter_enabled")
        aiFormatterService.config.enabled = value
        logDebug("AI Formatter \(value ? "enabled" : "disabled")")
    }

    func saveAnthropicApiKey(_ value: String) {
        anthropicApiKey = value
        UserDefaults.standard.set(value, forKey: "anthropic_api_key")
        aiFormatterService.config.apiKey = value
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

            // Special dictation keywords
            let keywordPhrases = Self.specialKeywordList.map { $0.phrase }
            terms.append(contentsOf: keywordPhrases)

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
        if let modeString = UserDefaults.standard.string(forKey: "launch_mode") {
            // Case-insensitive matching
            let normalized = modeString.lowercased()
            switch normalized {
            case "on": launchMode = .on
            case "off": launchMode = .off
            case "sleep": launchMode = .sleep
            default: launchMode = .sleep
            }
        } else {
            launchMode = .sleep // Default to Sleep
        }
    }

    func saveLaunchMode(_ mode: MicrophoneMode) {
        launchMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "launch_mode")
    }

    private func loadLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            // Check if we have explicitly set a preference before
            let hasSetPreference = UserDefaults.standard.bool(forKey: "launch_at_login_preference_set")
            
            if !hasSetPreference {
                // Default to OFF for now as requested
                launchAtLogin = false
                UserDefaults.standard.set(true, forKey: "launch_at_login_preference_set")
            } else {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    func saveLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        UserDefaults.standard.set(true, forKey: "launch_at_login_preference_set")
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    logDebug("Registered for launch at login")
                } else {
                    try SMAppService.mainApp.unregister()
                    logDebug("Unregistered from launch at login")
                }
            } catch {
                logDebug("Failed to update launch at login: \(error.localizedDescription)")
                // Revert the state if registration failed
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private func loadInputDevice() {
        selectedInputDeviceId = UserDefaults.standard.string(forKey: "selected_input_device_id")
    }

    func saveInputDevice(_ deviceId: String?) {
        selectedInputDeviceId = deviceId
        if let deviceId = deviceId {
            UserDefaults.standard.set(deviceId, forKey: "selected_input_device_id")
        } else {
            UserDefaults.standard.removeObject(forKey: "selected_input_device_id")
        }
        
        // Restart services if active to pick up the new device
        if microphoneMode != .off {
            logDebug("Input device changed: Restarting services")
            restartServicesIfActive()
        }
    }

    private func loadShortcuts() {
        if let data = UserDefaults.standard.data(forKey: "shortcut_ptt"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            pttShortcut = shortcut
        }
        if let data = UserDefaults.standard.data(forKey: "shortcut_mode_toggle"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            modeToggleShortcut = shortcut
        }
        if let data = UserDefaults.standard.data(forKey: "shortcut_mode_on"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            modeOnShortcut = shortcut
        }
        if let data = UserDefaults.standard.data(forKey: "shortcut_mode_sleep"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            modeSleepShortcut = shortcut
        }
        if let data = UserDefaults.standard.data(forKey: "shortcut_mode_off"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            modeOffShortcut = shortcut
        }
    }

    func savePTTShortcut(_ shortcut: KeyboardShortcut) {
        pttShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "shortcut_ptt")
        }
    }

    func saveModeToggleShortcut(_ shortcut: KeyboardShortcut) {
        modeToggleShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "shortcut_mode_toggle")
        }
    }

    func saveModeOnShortcut(_ shortcut: KeyboardShortcut) {
        modeOnShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "shortcut_mode_on")
        }
    }

    func saveModeSleepShortcut(_ shortcut: KeyboardShortcut) {
        modeSleepShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "shortcut_mode_sleep")
        }
    }

    func saveModeOffShortcut(_ shortcut: KeyboardShortcut) {
        modeOffShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "shortcut_mode_off")
        }
    }

    private func flushDictationBuffer(isForceEnd: Bool) {
        guard !currentTranscript.isEmpty, microphoneMode == .on else { return }
        // Construct a temporary turn to process commands from the current buffer
        let tempTurn = TranscriptTurn(
            transcript: currentTranscript,
            words: currentWords,
            endOfTurn: true,
            isFormatted: true, // Mark as formatted so it definitely types
            turnOrder: (lastTypedTurnOrder + 1),
            utterance: currentTranscript
        )
        
        logger.info("Force pushing buffer: \"\(self.currentTranscript)\"")
        handleDictationTurn(tempTurn, isForceEnd: isForceEnd)
        
        currentTranscript = ""
        currentWords = []
    }

    /// Force end of current utterance immediately
    func forceEndUtterance(contactServices: Bool = false) {
        logger.info("Force end utterance requested (connected=\(self.isConnected ? "true" : "false"), contactServices=\(contactServices))")
        
        // 1. Type whatever is currently in the buffer if it's not empty
        flushDictationBuffer(isForceEnd: true)

        if contactServices {
            // 2. Set pending flag so we can ignore any late responses for this turn from the server
            forceEndPending = true
            forceEndRequestedAt = Date()
            
            // 3. Request services to end current utterance
            assemblyAIService?.forceEndUtterance()
            appleSpeechService?.forceEndUtterance()
            
            // 4. Note: resetUtteranceState() will be called when we receive the end-of-turn
            // or when the forceEndPending timeout hits in handleDictationTurn.
            // We DON'T call it here immediately because that clears the command history
            // that handleDictationTurn might need to filter out already-executed commands.
        } else {
            forceEndPending = false
            forceEndRequestedAt = nil
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
    
    private func startBuildCheckTimer() {
        // Check every 5 seconds (for dev/local)
        buildCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForNewerBuild()
            }
        }
    }

    private func checkForNewerBuild() {
        guard let executableURL = Bundle.main.executableURL else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: executableURL.path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                // If file is newer than launch time + small buffer
                if modificationDate > launchTime.addingTimeInterval(5) {
                    if !isNewerBuildAvailable {
                        isNewerBuildAvailable = true
                        logDebug("Newer build detected! (File: \(modificationDate), Launch: \(launchTime))")
                    }
                }
            }
        } catch {
            // Ignore errors
        }
    }
}
