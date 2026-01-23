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

/// Claude model options for command panel
enum ClaudeModel: String, CaseIterable, Codable, Identifiable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Opus (Smartest)"
        case .sonnet: return "Sonnet (Balanced)"
        case .haiku: return "Haiku (Fastest)"
        }
    }

    var shortName: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        }
    }

    var cliFlag: String? {
        switch self {
        case .opus: return "opus"
        case .sonnet: return nil  // Default, no flag needed
        case .haiku: return "haiku"
        }
    }
}

struct AppWarning: Identifiable {
    let id: String
    let message: String
    let severity: Severity
    let action: (() -> Void)?
    let actionLabel: String?
    let details: String?  // Full error details for expandable view

    init(id: String, message: String, severity: Severity, action: (() -> Void)? = nil, actionLabel: String? = nil, details: String? = nil) {
        self.id = id
        self.message = message
        self.severity = severity
        self.action = action
        self.actionLabel = actionLabel
        self.details = details
    }

    enum Severity {
        case warning, error
    }
}

/// A custom vocabulary entry that maps a spoken phrase to a written form
struct VocabularyEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var spokenPhrase: String      // What the user says (e.g., "jacob cole")
    var writtenForm: String       // What gets typed (e.g., "Jacob Cole")
    var category: String?         // Optional category for organization
    var isEnabled: Bool           // Whether this entry is active

    init(id: UUID = UUID(), spokenPhrase: String, writtenForm: String, category: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.spokenPhrase = spokenPhrase
        self.writtenForm = writtenForm
        self.category = category
        self.isEnabled = isEnabled
    }
}

/// Main application state management
@MainActor
class AppState: ObservableObject {
    @Published var microphoneMode: MicrophoneMode = .off
    @Published var currentTranscript: String = ""
    @Published var recentTurns: [TranscriptTurn] = []

    /// Preserved transcript from Sleep mode - allows force send to type text that was transcribed while in Sleep mode
    private var lastSleepModeTranscript: String = ""
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
    @Published var customVocabulary: [VocabularyEntry] = []
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
    @Published var systemThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
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
    @Published var commandPanelShortcut: KeyboardShortcut = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.control, .option])  // Ctrl+Opt+C

    #if DEBUG
    @Published var isDebugMode: Bool = true
    #else
    @Published var isDebugMode: Bool = false
    #endif
    @Published var showCompactError: Bool = false
    @Published var dismissedWarningIds: Set<String> = []  // Temporarily dismissed warnings

    // AI Formatter
    @Published var aiFormatterEnabled: Bool = true
    @Published var anthropicApiKey: String = ""

    // MARK: - Command Panel (Claude Code Integration)
    @Published var isCommandPanelVisible: Bool = false
    @Published var isNotesPanelVisible: Bool = false
    @Published var isTranscriptsPanelVisible: Bool = false
    @Published var isTicketsPanelVisible: Bool = false
    @Published var isVocabularyPanelVisible: Bool = false
    @Published var commandMessages: [CommandMessage] = []
    @Published var commandInput: String = ""
    @Published var commandMessageQueue: [String] = []
    @Published var isClaudeProcessing: Bool = false
    @Published var isClaudeConnected: Bool = false
    @Published var commandWorkingDirectory: String = "~/code/ai-os-apple-data/workspace"
    @Published var commandError: String?
    @Published var inlineCommandResponse: CommandMessage?
    @Published var showInlineResponse: Bool = false
    @Published var claudeModel: ClaudeModel = .sonnet
    @Published var claudeDebugLog: [String] = []
    @Published var showClaudeDebugPanel: Bool = false
    @Published var commandPanelFontSize: Double = 14.0  // Default font size for command panel text

    // Session management
    @Published var claudeSessions: [ClaudeSession] = []
    @Published var currentSessionId: String?

    // Extended command capture mode ("long command")
    @Published var isExtendedCommandMode: Bool = false
    private var extendedCommandBuffer: String = ""
    private var extendedCommandPauseTimer: Timer?
    private let extendedCommandPauseThreshold: TimeInterval = 10.0  // 10 seconds of silence

    // Audio recording mode ("voiceflow start recording")
    @Published var isRecordingAudio: Bool = false
    private var recordingAudioBuffer: [Data] = []
    private var recordingStartTime: Date?
    private let recordingsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceFlow/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Note-taking modes
    @Published var isCapturingNote: Bool = false           // Single utterance note
    @Published var isCapturingLongNote: Bool = false       // Timeout-based long note
    @Published var isContinuousNote: Bool = false          // Start/stop continuous note
    private var noteBuffer: String = ""
    private var notePauseTimer: Timer?
    private let notePauseThreshold: TimeInterval = 10.0    // 10 seconds for long note
    private let notesDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceFlow/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Transcribing mode ("voiceflow start transcribing")
    @Published var isTranscribing: Bool = false
    private var transcriptBuffer: String = ""
    private let transcriptsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceFlow/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var claudeCodeService: ClaudeCodeService?

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
        ("save to idea flow", "Copy last dictation and open Idea Flow"),
        ("command open", "Open the Claude Code command panel"),
        ("command close", "Close the Claude Code command panel"),
        ("command [text]", "Execute command immediately via Claude Code"),
        ("long command [text]", "Start extended voice command (10s pause or 'stop command' to finish)"),
        ("stop command", "End extended voice command capture"),
        ("stop listening", "End extended voice command capture (alternate)"),
        ("are you listening", "Confirm VoiceFlow is active with audio/visual feedback"),
        ("are you there", "Confirm VoiceFlow is active (alternate)"),
        ("voiceflow start recording", "Start recording audio to a WAV file"),
        ("voiceflow stop recording", "Stop recording and save audio file"),
        ("take a note [text]", "Capture a single utterance as a note"),
        ("voiceflow make a note [text]", "Capture a single utterance as a note"),
        ("voiceflow make a long note", "Start extended note (10s pause to finish)"),
        ("voiceflow start making a note", "Start continuous note-taking"),
        ("voiceflow stop making a note", "Stop continuous note-taking and save"),
        ("voiceflow start transcribing", "Start continuous transcription"),
        ("voiceflow stop transcribing", "Stop transcription and save"),
        ("voiceflow open notes", "Open Notes folder in Finder"),
        ("voiceflow open notes panel", "Open the Notes panel"),
        ("voiceflow open transcripts panel", "Open the Transcripts panel"),
        ("voiceflow vocabulary", "Open the Custom Vocabulary panel"),
        ("voiceflow open vocabulary", "Open the Custom Vocabulary panel"),
        ("voiceflow open recordings", "Open Recordings folder in Finder"),
        ("voiceflow open transcripts", "Open Transcripts folder in Finder"),
        ("voiceflow send", "Retype/paste the last utterance")
    ]

    /// Special dictation keywords (not commands)
    static let specialKeywordList: [(phrase: String, description: String)] = [
        ("say [text]", "Speak literally; disables command parsing for this utterance"),
        ("new line", "Insert a line break (buffered in terminals until utterance ends)"),
        ("newline", "Insert a line break (buffered in terminals until utterance ends)"),
        ("press enter", "Send Enter key immediately (for explicit terminal submission)"),
        ("press return", "Send Enter key immediately (for explicit terminal submission)"),
        ("submit", "Flush buffered newlines and send Enter (for terminals)"),
        ("send", "Flush buffered newlines and send Enter (for terminals)"),
        ("space bar", "Insert a space"),
        ("spacebar", "Insert a space"),
        ("no space", "Join adjacent words without space (e.g., 'idea no space flow' → 'ideaflow')"),
        ("nospace", "Join adjacent words without space"),
        ("no caps", "Lowercase the next word"),
        ("letter [char]", "Type the next word as a single letter"),
        ("at sign [text]", "Insert @ and condense following words"),
        ("hashtag [text]", "Insert # and condense following words"),
        ("hash tag [text]", "Insert # and condense following words"),
        ("open paren", "Insert ("),
        ("close paren", "Insert )"),
        ("open bracket", "Insert ["),
        ("close bracket", "Insert ]"),
        ("open brace", "Insert {"),
        ("close brace", "Insert }"),
        ("backspace", "Delete previous character"),
        ("backspace N", "Delete N characters (e.g., \"backspace 3\", \"backspace five\")")
    ]

    var panelVisibilityHandler: ((Bool) -> Void)?

    /// Current issues that should be surfaced to the user
    var activeWarnings: [AppWarning] {
        var warnings: [AppWarning] = []

        // Connection/API errors - show the actual error, not assumptions
        if let error = errorMessage {
            // Add service context but show actual error
            let serviceName: String
            switch dictationProvider {
            case .deepgram: serviceName = "Deepgram"
            case .online, .auto: serviceName = "AssemblyAI"
            case .offline: serviceName = "Speech"
            }
            // Show actual error with service prefix for context
            let message = "[\(serviceName)] \(error)"
            warnings.append(AppWarning(id: "connection_error", message: message, severity: .error, details: error))
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

        if let message = vocabularyBiasUnsupportedMessage {
            warnings.append(AppWarning(
                id: "vocab_bias_unsupported",
                message: message,
                severity: .warning,
                actionLabel: "Open Settings"
            ))
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

        // System thermal state warning - CPU under heavy load affects dictation quality
        if systemThermalState == .serious {
            warnings.append(AppWarning(
                id: "thermal_serious",
                message: "System under load — dictation may be degraded",
                severity: .warning
            ))
        } else if systemThermalState == .critical {
            warnings.append(AppWarning(
                id: "thermal_critical",
                message: "System overheating — dictation quality affected",
                severity: .error
            ))
        }

        // Filter out temporarily dismissed warnings
        return warnings.filter { !dismissedWarningIds.contains($0.id) }
    }

    /// Temporarily dismiss a warning (will reappear on next session or if condition changes)
    func dismissWarning(id: String) {
        dismissedWarningIds.insert(id)
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
    private var autoSubmitTimer: Timer?
    @Published var autoSubmitEnabled: Bool = false  // Auto-press Enter after utterance + silence
    @Published var autoSubmitDelaySeconds: Double = 3.0  // Seconds of silence before auto-submit
    @Published var trailingNewlineSendsEnter: Bool = true  // "newline" at end of utterance sends Enter key
    private var lastExecutedEndWordIndexByCommand: [String: Int] = [:]
    private var currentUtteranceHadCommand = false
    private var currentUtteranceIsLiteral = false
    private var pendingLiteralMode = false  // Persists "say" literal mode across turn boundaries
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
    private let autoSwitchOfflineThresholdMs = 500  // Auto-switch to offline if latency exceeds this
    @Published var autoSwitchToOfflineOnHighLatency = false  // Toggle for auto-switch feature
    private var didAutoSwitchToOffline = false  // Track if we auto-switched this session
    private var didTriggerSayKeyword = false
    private var turnHandledBySpecialCommand = false  // Set by spell, focus to prevent dictation
    private var typedFinalWordCount = 0
    private var didTypeDictationThisUtterance = false
    private var hasTypedInSession = false  // Tracks if we've typed anything since going On
    @Published var isPTTProcessing = false  // When true, waiting for finalized text before sleep
    private var pttSleepTimeoutTask: Task<Void, Never>?  // Fallback timeout for PTT sleep
    @Published var isPTMMuted = false  // Push-to-mute: temporarily mute when key held in On mode
    var lastPTTKeyDownTime: Date?  // For double-tap detection

    // PTT timestamp tracking - filters words to only include those within PTT time window
    private var streamStartTime: Date?  // When audio stream started (for calculating stream-relative times)
    private var pttPressStreamTime: Double?  // Stream-relative timestamp when PTT was pressed
    private var pttReleaseStreamTime: Double?  // Stream-relative timestamp when PTT was released
    private var isPTTActive = false  // True while PTT key is held down
    private var forceEndPending = false
    private var forceEndRequestedAt: Date?
    private let forceEndTimeoutSeconds: TimeInterval = 2.0
    private var lastTypedTurnOrder = -1
    private var suppressNextAutoCap = false
    private var lastKeyEventTime: Date?  // For consistent Return key timing across typeText calls
    private var bufferedTerminalNewlines: Int = 0  // Newlines to send after utterance ends (terminal mode)

    // Cross-utterance keyword state: tracks partial keywords that span utterance boundaries
    // e.g., "new" at end of one utterance + "line" at start of next = "new line"
    private var pendingCrossUtteranceKeyword: String? = nil
    private var pendingCrossUtteranceTime: Date? = nil
    private let crossUtteranceKeywordWindowSeconds: TimeInterval = 2.0  // Max time to wait for continuation

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
        loadCustomVocabulary()
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
        loadCommandPanelSettings()
        loadAutoSwitchOfflineSettings()
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

        // Monitor thermal state for system performance warnings
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let newState = ProcessInfo.processInfo.thermalState
                self.systemThermalState = newState
                if newState == .serious || newState == .critical {
                    NSLog("[VoiceFlow] ⚠️ Thermal state changed to \(newState == .critical ? "CRITICAL" : "SERIOUS") - dictation quality may be affected")
                }
            }
            .store(in: &cancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.logDebug("System sleep detected")
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.logDebug("System wake detected - reconnecting speech services")
                if self.microphoneMode != .off {
                    self.reconnect()
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
        // Save current mode to restore after restart
        UserDefaults.standard.set(microphoneMode.rawValue, forKey: "resume_mode")
        UserDefaults.standard.synchronize()

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

    /// Reconnect to speech recognition service (useful after network errors)
    func reconnect() {
        errorMessage = nil
        restartServicesIfActive()
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
            lastSleepModeTranscript = ""  // Clear preserved Sleep transcript when waking
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
                guard let self = self else { return }
                let wasConnected = self.isConnected
                self.isConnected = connected
                self.logDebug(connected ? "Connected to AssemblyAI" : "Disconnected from AssemblyAI")

                // DIAGNOSTIC: Track reconnect cycles (investigating clunk sounds during quiet periods)
                if !wasConnected && connected {
                    NSLog("[VoiceFlow] 🔄 RECONNECT CYCLE: AssemblyAI reconnected (mode=\(self.microphoneMode.rawValue))")
                }
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
            guard let self = self, !self.isPTMMuted else { return }  // PTM: skip audio when muted
            self.assemblyAIService?.sendAudio(data)
            self.bufferAudioForRecording(data)
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

        // Record stream start time for PTT timestamp tracking
        streamStartTime = Date()
        resetPTTTimestamps()
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
            guard let self = self, !self.isPTMMuted else { return }  // PTM: skip audio when muted
            self.deepgramService?.sendAudio(data)
            self.bufferAudioForRecording(data)
        }

        // Connect audio level for visualization
        audioCaptureManager?.onAudioLevel = { [weak self] level in
            self?.audioLevel = level
        }

        // Start services
        deepgramService?.setTranscribeMode(transcribeMode)
        deepgramService?.setFormatTurns(!liveDictationEnabled)
        deepgramService?.setVocabularyTerms(effectiveVocabularyTerms)
        deepgramService?.connect()
        audioCaptureManager?.startCapture()

        // Record stream start time for PTT timestamp tracking
        streamStartTime = Date()
        resetPTTTimestamps()
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
            guard let self = self, !self.isPTMMuted else { return }  // PTM: skip audio when muted
            self.appleSpeechService?.sendAudio(data)
            self.bufferAudioForRecording(data)
        }

        // Connect audio level for visualization
        audioCaptureManager?.onAudioLevel = { [weak self] level in
            self?.audioLevel = level
        }
        
        appleSpeechService?.setTranscribeMode(transcribeMode)
        appleSpeechService?.startRecognition(addsPunctuation: !liveDictationEnabled)
        audioCaptureManager?.startCapture()
        updateLatency(nil)

        // Record stream start time for PTT timestamp tracking
        streamStartTime = Date()
        resetPTTTimestamps()
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
        // Cancel auto-submit timer when new speech arrives
        cancelAutoSubmitTimer()

        // Calculate force end status early
        let isForceEndTurn = forceEndPending && turn.endOfTurn

        // Apply PTT timestamp filter to exclude words outside the PTT time window
        let filteredWords = filterWordsForPTT(turn.words)

        let fallbackTranscript = turn.transcript.isEmpty ? (turn.utterance ?? "") : turn.transcript
        if !filteredWords.isEmpty {
            currentWords = filteredWords
            if !fallbackTranscript.isEmpty {
                // Rebuild transcript from filtered words if we removed any
                if filteredWords.count != turn.words.count {
                    currentTranscript = assembleDisplayText(from: filteredWords)
                } else {
                    currentTranscript = fallbackTranscript
                }
            } else {
                currentTranscript = assembleDisplayText(from: filteredWords)
            }
        } else if !fallbackTranscript.isEmpty && turn.words.isEmpty {
            // Only use fallback if original turn had no words (not filtered out)
            currentWords = []
            currentTranscript = fallbackTranscript
        } else if filteredWords.isEmpty && !turn.words.isEmpty {
            // All words were filtered out by PTT - ignore this turn's content
            // but still process for timing/state updates
            currentWords = []
            currentTranscript = ""
        }

        let initialMode = microphoneMode
        if initialMode == .sleep || (initialMode == .on && activeBehavior != .dictation) {
            processVoiceCommands(turn)
        }

        // In dictation mode, still check for "say" escape keyword and note-taking commands
        if initialMode == .on && activeBehavior == .dictation && !currentUtteranceIsLiteral {
            detectSayPrefix(turn)
            detectNoteTakingCommands(turn)
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

            // Capture this before reset clears it
            let shouldAutoSubmit = autoSubmitEnabled && microphoneMode == .on && didTypeDictationThisUtterance

            if shouldAddToHistory {
                // Preserve transcript in Sleep mode so force send can use it
                if microphoneMode == .sleep && !currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastSleepModeTranscript = currentTranscript
                }
                // Flush any buffered terminal newlines before resetting state
                // This ensures newlines are sent after the full utterance is typed
                flushBufferedTerminalNewlines()
                resetUtteranceState()
            }
            currentUtteranceIsLiteral = false
            didTriggerSayKeyword = false
            turnHandledBySpecialCommand = false

            // Auto-submit: start timer after utterance ends (for vibe coding mode)
            if shouldAutoSubmit {
                startAutoSubmitTimer()
            }

            // Handle pending PTT sleep - switch to sleep after finalized text is received
            if isPTTProcessing {
                logDebug("PTT: Received finalized text, switching to sleep")
                isPTTProcessing = false
                pttSleepTimeoutTask?.cancel()
                pttSleepTimeoutTask = nil
                setMode(.sleep)
            }
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

        // Capture for note-taking/transcription modes
        if isCapturingNote {
            captureNoteUtterance(trimmedProcessed)
        } else if isCapturingLongNote {
            appendToLongNote(trimmedProcessed)
        } else if isContinuousNote {
            appendToContinuousNote(trimmedProcessed)
        }
        if isTranscribing {
            appendToTranscript(trimmedProcessed)
        }

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

        func consumeLeadingBackspace(_ input: String) -> (remaining: String, count: Int)? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTokens = trimmed.split(whereSeparator: \.isWhitespace)
            guard !rawTokens.isEmpty else { return nil }
            let firstToken = normalizeToken(String(rawTokens[0]))
            var consumed = 0
            if firstToken == "backspace" {
                consumed = 1
            } else if firstToken == "back", rawTokens.count > 1, normalizeToken(String(rawTokens[1])) == "space" {
                consumed = 2
            } else {
                return nil
            }
            var count = 1
            if rawTokens.count > consumed {
                let numberToken = normalizeToken(String(rawTokens[consumed]))
                if let num = parseNumberWord(numberToken) {
                    count = num
                    consumed += 1
                }
            }
            let remainder = rawTokens.dropFirst(consumed).joined(separator: " ")
            return (remainder, count)
        }
        
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

        if let consumed = consumeLeadingBackspace(result) {
            keyword = keyword ?? (consumed.count == 1 ? "Backspace" : "Backspace \(consumed.count)")
            sendBackspaceKeypresses(consumed.count)
            result = consumed.remaining
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
        var suppressNextSpace = false  // For "no space" command
        let maxTagWords = 4
        var consumedFirstWordForCrossUtterance = false

        // === CROSS-UTTERANCE KEYWORD HANDLING ===
        // Check if we have a pending "new" from the previous utterance and current starts with "line"
        if let pending = pendingCrossUtteranceKeyword,
           let pendingTime = pendingCrossUtteranceTime,
           Date().timeIntervalSince(pendingTime) < crossUtteranceKeywordWindowSeconds,
           !words.isEmpty {
            let firstToken = normalizeToken(words[0].text)
            if pending == "new" && firstToken == "line" {
                logDebug("Cross-utterance 'new line' detected! Previous utterance ended with 'new', this one starts with 'line'")
                // Buffer newline for terminals, otherwise prepend to output
                if focusContextManager.isCurrentAppTerminal() {
                    bufferedTerminalNewlines += 1
                    logDebug("Buffering cross-utterance newline for terminal")
                } else {
                    output = "\n"
                }
                keyword = "New line"
                consumedFirstWordForCrossUtterance = true
                triggerKeywordFlash(name: "New line")
            } else {
                // The pending keyword wasn't completed, output it
                logDebug("Cross-utterance keyword '\(pending)' not continued (got '\(firstToken)'), outputting it")
                output = pending + " "
            }
            pendingCrossUtteranceKeyword = nil
            pendingCrossUtteranceTime = nil
        } else if pendingCrossUtteranceKeyword != nil {
            // Pending keyword timed out
            logDebug("Cross-utterance keyword timed out")
            if let pending = pendingCrossUtteranceKeyword {
                output = pending + " "
            }
            pendingCrossUtteranceKeyword = nil
            pendingCrossUtteranceTime = nil
        }

        func appendNewline(isTrailing: Bool = false) {
            while output.last == " " {
                output.removeLast()
            }
            // In terminal mode OR when trailing newline sends Enter is enabled,
            // buffer the newline to send at end of utterance as an Enter key press
            // This ensures Enter is sent AFTER all text is typed
            if focusContextManager.isCurrentAppTerminal() || (isTrailing && trailingNewlineSendsEnter) {
                bufferedTerminalNewlines += 1
                logDebug("Buffering newline (terminal=\(focusContextManager.isCurrentAppTerminal()), trailing=\(isTrailing), total buffered: \(bufferedTerminalNewlines))")
            } else if output.last != "\n" {
                output.append("\n")
            }
        }

        func appendSpace() {
            output.append(" ")
        }

        func appendToken(_ token: String, joinDirectly: Bool = false) {
            let isPunctuationOnly = token.rangeOfCharacter(from: CharacterSet.alphanumerics) == nil
            if isPunctuationOnly {
                if output.last == " " {
                    output.removeLast()
                }
                output.append(token)
                return
            }
            if output.isEmpty || output.last == " " || output.last == "\n" || joinDirectly {
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
            let shouldJoin = suppressNextSpace
            suppressNextSpace = false  // Reset after use

            if letterNext {
                if !normalized.isEmpty, let firstChar = normalized.first {
                    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suppressNextAutoCap = true
                    }
                    appendToken(String(firstChar), joinDirectly: shouldJoin)
                    letterNext = false
                } else {
                    appendToken(wordText, joinDirectly: shouldJoin)
                }
                return
            }

            if lowercaseNext {
                if !normalized.isEmpty {
                    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suppressNextAutoCap = true
                    }
                    appendToken(wordText.lowercased(), joinDirectly: shouldJoin)
                    lowercaseNext = false
                } else {
                    appendToken(wordText, joinDirectly: shouldJoin)
                }
                return
            }

            appendToken(wordText, joinDirectly: shouldJoin)
        }

        let sayStartIndex = consumedFirstWordForCrossUtterance ? 1 : 0
        if words.indices.contains(sayStartIndex),
           normalizeToken(words[sayStartIndex].text) == "say" {
            keyword = keyword ?? "Say"
            var index = sayStartIndex + 1
            while index < words.count {
                appendToken(words[index].text)
                index += 1
            }
            return (output, keyword)
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
                "submit", "send"
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

        // Skip first word if it was consumed by cross-utterance keyword handling
        var index = consumedFirstWordForCrossUtterance ? 1 : 0
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
                // Check if trailing: at end OR followed only by punctuation at end
                let isTrailing = index == words.count - 1 ||
                    (index + 1 < words.count && isSkippablePunctuation(words[index + 1].text) && index + 1 == words.count - 1)
                NSLog("[VoiceFlow] ⏎ Newline keyword detected: token='newline', wordIndex=%d, totalWords=%d, isEndOfUtterance=%@",
                      index, words.count, isTrailing ? "YES" : "no")
                triggerKeywordFlash(name: "New line")
                appendNewline(isTrailing: isTrailing)
                // Skip trailing punctuation if present
                if index + 1 < words.count && isSkippablePunctuation(words[index + 1].text) {
                    index += 2
                } else {
                    index += 1
                }
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
                        // Check if this is trailing - "new line" at end, or followed only by punctuation
                        let isTrailing = index + 1 >= words.count - 1 ||
                            (index + 2 < words.count && isSkippablePunctuation(words[index + 2].text) && index + 2 == words.count - 1)
                        NSLog("[VoiceFlow] ⏎ Newline keyword detected: token='new line', wordIndex=%d, totalWords=%d, isEndOfUtterance=%@",
                              index, words.count, isTrailing ? "YES" : "no")
                        logDebug("Keyword \"new line\" detected at word index \(index), appending newline")
                        triggerKeywordFlash(name: "New line")
                        appendNewline(isTrailing: isTrailing)
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
                suppressNextSpace = true  // Next word will join directly
                index += 1
                continue
            }

            if token == "no", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "space", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "No space"
                    suppressNextSpace = true  // Next word will join directly
                    index += 2
                    continue
                }
            }

            // "backspace" or "backspace N" - delete previous character(s) from output
            if token == "backspace" {
                var count = 1
                var wordsConsumed = 1

                // Check if next word is a number (e.g., "backspace 3" or "backspace three")
                if index + 1 < words.count {
                    let nextWord = words[index + 1]
                    let nextToken = normalizeToken(nextWord.text)
                    if let num = parseNumberWord(nextToken), isKeywordGapAcceptable(previous: word, next: nextWord) {
                        count = num
                        wordsConsumed = 2
                    }
                }

                keyword = keyword ?? (count == 1 ? "Backspace" : "Backspace \(count)")
                let toRemove = min(count, output.count)
                if toRemove > 0 {
                    output.removeLast(toRemove)
                }
                let remaining = count - toRemove
                if remaining > 0 {
                    sendBackspaceKeypresses(remaining)
                }
                triggerKeywordFlash(name: count == 1 ? "Backspace" : "⌫\(count)")
                index += wordsConsumed
                continue
            }

            // "back space" or "back space N" - two word variant
            if token == "back", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "space", isKeywordGapAcceptable(previous: word, next: next) {
                    var count = 1
                    var wordsConsumed = 2

                    // Check if word after "back space" is a number
                    if index + 2 < words.count {
                        let numWord = words[index + 2]
                        let numToken = normalizeToken(numWord.text)
                        if let num = parseNumberWord(numToken), isKeywordGapAcceptable(previous: next, next: numWord) {
                            count = num
                            wordsConsumed = 3
                        }
                    }

                    keyword = keyword ?? (count == 1 ? "Backspace" : "Backspace \(count)")
                    let toRemove = min(count, output.count)
                    if toRemove > 0 {
                        output.removeLast(toRemove)
                    }
                    let remaining = count - toRemove
                    if remaining > 0 {
                        sendBackspaceKeypresses(remaining)
                    }
                    triggerKeywordFlash(name: count == 1 ? "Backspace" : "⌫\(count)")
                    index += wordsConsumed
                    continue
                }
            }

            // "press enter" / "press return" - sends Enter key (useful for submitting in terminals)
            if token == "press", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if (nextToken == "enter" || nextToken == "return"), isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Press enter"
                    NSLog("[VoiceFlow] ⏎ Press enter keyword detected at word index %d", index)
                    triggerKeywordFlash(name: "Press enter")
                    // "press enter/return" always sends Enter key (acts as trailing)
                    appendNewline(isTrailing: true)
                    // Skip trailing punctuation if present
                    if index + 2 < words.count && isSkippablePunctuation(words[index + 2].text) {
                        index += 3
                    } else {
                        index += 2
                    }
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

            // === SPOKEN PUNCTUATION KEYWORDS ===
            // These allow users to insert punctuation by saying the punctuation name

            // Period / dot / full stop
            if token == "period" || token == "dot" {
                keyword = keyword ?? "Period"
                appendToken(".")
                index += 1
                continue
            }
            if token == "full", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "stop", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Full stop"
                    appendToken(".")
                    index += 2
                    continue
                }
            }

            // Comma
            if token == "comma" {
                keyword = keyword ?? "Comma"
                appendToken(",")
                index += 1
                continue
            }

            // Colon
            if token == "colon" {
                keyword = keyword ?? "Colon"
                appendToken(":")
                index += 1
                continue
            }

            // Semicolon / semi colon
            if token == "semicolon" {
                keyword = keyword ?? "Semicolon"
                appendToken(";")
                index += 1
                continue
            }
            if token == "semi", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "colon", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Semicolon"
                    appendToken(";")
                    index += 2
                    continue
                }
            }

            // Question mark
            if token == "question", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "mark", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Question mark"
                    appendToken("?")
                    index += 2
                    continue
                }
            }

            // Exclamation point / exclamation mark
            if token == "exclamation", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if (nextToken == "point" || nextToken == "mark"), isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Exclamation point"
                    appendToken("!")
                    index += 2
                    continue
                }
            }

            // Dash / hyphen
            if token == "dash" || token == "hyphen" {
                keyword = keyword ?? "Dash"
                appendToken("-")
                index += 1
                continue
            }

            // Quote / double quote
            if token == "quote" {
                keyword = keyword ?? "Quote"
                appendToken("\"")
                index += 1
                continue
            }
            if token == "double", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "quote", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Double quote"
                    appendToken("\"")
                    index += 2
                    continue
                }
            }

            // Single quote / apostrophe
            if token == "apostrophe" {
                keyword = keyword ?? "Apostrophe"
                appendToken("'")
                index += 1
                continue
            }
            if token == "single", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "quote", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Single quote"
                    appendToken("'")
                    index += 2
                    continue
                }
            }

            // Ellipsis
            if token == "ellipsis" {
                keyword = keyword ?? "Ellipsis"
                appendToken("...")
                index += 1
                continue
            }

            // Underscore
            if token == "underscore" {
                keyword = keyword ?? "Underscore"
                appendToken("_")
                index += 1
                continue
            }

            // Asterisk / star
            if token == "asterisk" || token == "star" {
                keyword = keyword ?? "Asterisk"
                appendToken("*")
                index += 1
                continue
            }

            // Ampersand
            if token == "ampersand" {
                keyword = keyword ?? "Ampersand"
                appendToken("&")
                index += 1
                continue
            }

            // Percent / percent sign
            if token == "percent" {
                keyword = keyword ?? "Percent"
                appendToken("%")
                index += 1
                continue
            }

            // Dollar / dollar sign
            if token == "dollar" {
                keyword = keyword ?? "Dollar"
                appendToken("$")
                index += 1
                continue
            }

            // Slash / forward slash
            if token == "slash" {
                keyword = keyword ?? "Slash"
                appendToken("/")
                index += 1
                continue
            }
            if token == "forward", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "slash", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Forward slash"
                    appendToken("/")
                    index += 2
                    continue
                }
            }

            // Backslash / back slash
            if token == "backslash" {
                keyword = keyword ?? "Backslash"
                appendToken("\\")
                index += 1
                continue
            }
            if token == "back", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "slash", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Backslash"
                    appendToken("\\")
                    index += 2
                    continue
                }
            }

            // Pipe / vertical bar
            if token == "pipe" {
                keyword = keyword ?? "Pipe"
                appendToken("|")
                index += 1
                continue
            }

            // Tilde
            if token == "tilde" {
                keyword = keyword ?? "Tilde"
                appendToken("~")
                index += 1
                continue
            }

            // Caret
            if token == "caret" {
                keyword = keyword ?? "Caret"
                appendToken("^")
                index += 1
                continue
            }

            // Backtick / back tick
            if token == "backtick" {
                keyword = keyword ?? "Backtick"
                appendToken("`")
                index += 1
                continue
            }
            if token == "back", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "tick", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Backtick"
                    appendToken("`")
                    index += 2
                    continue
                }
            }

            // Plus / plus sign
            if token == "plus" {
                keyword = keyword ?? "Plus"
                appendToken("+")
                index += 1
                continue
            }

            // Equals / equal sign
            if token == "equals" || token == "equal" {
                keyword = keyword ?? "Equals"
                appendToken("=")
                index += 1
                continue
            }

            // Less than / left angle
            if token == "less", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "than", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Less than"
                    appendToken("<")
                    index += 2
                    continue
                }
            }

            // Greater than / right angle
            if token == "greater", index + 1 < words.count {
                let next = words[index + 1]
                let nextToken = normalizeToken(next.text)
                if nextToken == "than", isKeywordGapAcceptable(previous: word, next: next) {
                    keyword = keyword ?? "Greater than"
                    appendToken(">")
                    index += 2
                    continue
                }
            }

            appendProcessedToken(word.text)
            index += 1
        }

        // === CROSS-UTTERANCE PENDING DETECTION ===
        // Check if output ends with "new" (without "line" following) - set as pending for next utterance
        // This handles the case where "new line" is split across utterance boundaries
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputWords = trimmedOutput.lowercased().split(separator: " ")
        if let lastWord = outputWords.last, lastWord == "new" {
            // Check if this "new" is isolated at the end (not part of "new line" which was already processed)
            // We should only set pending if:
            // 1. The output ends with "new"
            // 2. There's no "line" after it (which there shouldn't be if we're here)
            logDebug("Utterance ends with 'new' - saving as pending for potential cross-utterance 'new line'")
            pendingCrossUtteranceKeyword = "new"
            pendingCrossUtteranceTime = Date()
            // Remove "new" from output - we'll output it later if needed
            if let range = output.range(of: "new", options: [.backwards, .caseInsensitive]) {
                // Only remove if it's at the end (possibly with trailing space)
                let afterNew = output[range.upperBound...]
                if afterNew.trimmingCharacters(in: .whitespaces).isEmpty {
                    output = String(output[..<range.lowerBound])
                    logDebug("Removed trailing 'new' from output, will be handled in next utterance")
                }
            }
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

        // 1c. Apply custom vocabulary substitutions (only if not literal)
        if !isLiteral {
            processed = applyVocabularySubstitutions(processed)
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
                "cancel that",
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

        let startsWithNoSpaceCommand: ([String]) -> Bool = { [self] words in
            guard !isLiteral, let first = words.first else { return false }
            let firstToken = self.normalizeToken(first)
            if firstToken == "nospace" {
                return true
            }
            if firstToken == "no", words.count > 1 {
                return self.normalizeToken(words[1]) == "space"
            }
            return false
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
                    "cancel that",
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
                result = self.applyVocabularySubstitutions(result)
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

            let suppressLeadingSpace = startsWithNoSpaceCommand(newWords)
            let needsSpace = (startIndex > 0 || hasTypedInSession) && !suppressLeadingSpace
            let prefix = needsSpace ? " " : ""
            let rawText = prefix + newWords.joined(separator: " ")
            let finalWordObjects = effectiveWords.filter { $0.isFinal == true }
            let wordSlice = Array(finalWordObjects[startIndex...].filter { filterPunctuation($0.text) })
            var textToType = processInlineReplacements(rawText, wordSlice, isLiteral)
            if needsSpace, !textToType.isEmpty, textToType.first != "\n", textToType.first != " " {
                textToType = " " + textToType
            }
            // Simpler approach: detect trailing newline CHARACTER and convert to buffered Enter
            if trailingNewlineSendsEnter && textToType.hasSuffix("\n") {
                textToType = String(textToType.dropLast())
                bufferedTerminalNewlines += 1
                NSLog("[VoiceFlow] ⏎ Trailing newline char detected in output, buffering Enter")
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

            let suppressLeadingSpace = startsWithNoSpaceCommand(newWords)
            let needsSpace = (startIndex > 0 || hasTypedInSession) && !suppressLeadingSpace
            let prefix = needsSpace ? " " : ""
            let rawText = prefix + newWords.joined(separator: " ")
            let wordSlice = Array(effectiveWords[startIndex...].filter { filterPunctuation($0.text) })
            var textToType = processInlineReplacements(rawText, wordSlice, isLiteral)
            if needsSpace, !textToType.isEmpty, textToType.first != "\n", textToType.first != " " {
                textToType = " " + textToType
            }
            // Simpler approach: detect trailing newline CHARACTER and convert to buffered Enter
            if trailingNewlineSendsEnter && textToType.hasSuffix("\n") {
                textToType = String(textToType.dropLast())
                bufferedTerminalNewlines += 1
                NSLog("[VoiceFlow] ⏎ Trailing newline char detected in output, buffering Enter")
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
        let skipStabilityCheck: Bool  // For commands like "submit" that should execute even if words aren't final
        let turn: TranscriptTurn
        let action: () -> Void
    }

    private struct PendingExecutionKey: Hashable {
        let key: String
        let endWordIndex: Int
    }

    /// Detect "say" prefix for literal/escape mode (used in dictation mode where full command processing is skipped)
    private func detectSayPrefix(_ turn: TranscriptTurn) {
        // Check if previous turn ended with "say" alone - restore literal mode
        if pendingLiteralMode {
            currentUtteranceIsLiteral = true
            pendingLiteralMode = false
            literalStartWordIndex = 0  // Start from beginning since "say" was in previous turn
            NSLog("[VoiceFlow] detectSayPrefix: restored literal mode from pending (cross-turn 'say')")
        }

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

            // If turn ends with just "say" (no content after), set pending for next turn
            let wordsAfterSay = normalizedTokens.dropFirst()
            if turn.endOfTurn && wordsAfterSay.isEmpty {
                pendingLiteralMode = true
                NSLog("[VoiceFlow] detectSayPrefix: 'say' alone at end of turn, setting pendingLiteralMode")
            }
        }
    }

    /// Detect note-taking commands even during dictation mode
    private func detectNoteTakingCommands(_ turn: TranscriptTurn) {
        let lowerTranscript = (turn.transcript.isEmpty ? (turn.utterance ?? "") : turn.transcript).lowercased()

        // "take a note" / "voiceflow make a note" - capture this utterance as note
        if lowerTranscript.hasPrefix("take a note") || lowerTranscript.hasPrefix("voiceflow make a note") || lowerTranscript.hasPrefix("voice flow make a note") {
            if turn.endOfTurn {
                // Extract the note content (everything after the command)
                var noteContent = lowerTranscript
                if noteContent.hasPrefix("take a note") {
                    noteContent = String(noteContent.dropFirst("take a note".count))
                } else if noteContent.hasPrefix("voiceflow make a note") {
                    noteContent = String(noteContent.dropFirst("voiceflow make a note".count))
                } else if noteContent.hasPrefix("voice flow make a note") {
                    noteContent = String(noteContent.dropFirst("voice flow make a note".count))
                }
                noteContent = noteContent.trimmingCharacters(in: .whitespaces)

                if !noteContent.isEmpty {
                    // Save the note content directly
                    saveNote(noteContent)
                    triggerCommandFlash(name: "Note Saved")
                } else {
                    // No content after command - start capture mode for next utterance
                    startCapturingNote()
                }

                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'take a note' detected, content='%@'", noteContent)
            }
            return
        }

        // "voiceflow make a long note" - capture until 10s pause
        if lowerTranscript.hasPrefix("voiceflow make a long note") || lowerTranscript.hasPrefix("voice flow make a long note") {
            if turn.endOfTurn {
                startCapturingLongNote()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_long_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow make a long note' detected")
            }
            return
        }

        // "voiceflow start making a note" - continuous note until stop
        if lowerTranscript.hasPrefix("voiceflow start making a note") || lowerTranscript.hasPrefix("voice flow start making a note") {
            if turn.endOfTurn {
                startContinuousNote()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_continuous_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow start making a note' detected")
            }
            return
        }

        // "voiceflow stop making a note" / "stop making a note"
        if lowerTranscript.hasPrefix("voiceflow stop making a note") || lowerTranscript.hasPrefix("voice flow stop making a note") || lowerTranscript.hasPrefix("stop making a note") {
            if turn.endOfTurn {
                stopContinuousNote()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_continuous_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow stop making a note' detected")
            }
            return
        }

        // "voiceflow start transcribing" - continuous transcription until stop
        if lowerTranscript.hasPrefix("voiceflow start transcribing") || lowerTranscript.hasPrefix("voice flow start transcribing") {
            if turn.endOfTurn {
                startTranscribing()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_transcribing"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow start transcribing' detected")
            }
            return
        }

        // "voiceflow stop transcribing" / "stop transcribing"
        if lowerTranscript.hasPrefix("voiceflow stop transcribing") || lowerTranscript.hasPrefix("voice flow stop transcribing") || lowerTranscript.hasPrefix("stop transcribing") {
            if turn.endOfTurn {
                stopTranscribing()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_transcribing"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow stop transcribing' detected")
            }
            return
        }

        // "voiceflow open notes panel" - open the notes panel (check BEFORE open notes folder)
        if lowerTranscript.hasPrefix("voiceflow open notes panel") || lowerTranscript.hasPrefix("voice flow open notes panel") {
            if turn.endOfTurn {
                openNotesPanel()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_notes_panel"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow open notes panel' detected")
            }
            return
        }

        // "voiceflow open notes" / "voice flow open note(s)" - open notes folder in Finder
        if lowerTranscript.hasPrefix("voiceflow open note") || lowerTranscript.hasPrefix("voice flow open note") || lowerTranscript.hasPrefix("open note") {
            if turn.endOfTurn {
                openNotesFolder()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_notes"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow open notes' detected")
            }
            return
        }

        // "voiceflow open recordings" / "voice flow open recording(s)" - open recordings folder
        if lowerTranscript.hasPrefix("voiceflow open recording") || lowerTranscript.hasPrefix("voice flow open recording") || lowerTranscript.hasPrefix("open recording") {
            if turn.endOfTurn {
                openRecordingsFolder()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_recordings"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow open recordings' detected")
            }
            return
        }

        // "voiceflow open transcripts panel" - open the transcripts panel (check BEFORE open transcripts folder)
        if lowerTranscript.hasPrefix("voiceflow open transcripts panel") || lowerTranscript.hasPrefix("voice flow open transcripts panel") {
            if turn.endOfTurn {
                openTranscriptsPanel()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_transcripts_panel"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow open transcripts panel' detected")
            }
            return
        }

        // "voiceflow open transcripts" - open transcripts folder
        if lowerTranscript.hasPrefix("voiceflow open transcript") || lowerTranscript.hasPrefix("voice flow open transcript") || lowerTranscript.hasPrefix("open transcript") {
            if turn.endOfTurn {
                openTranscriptsFolder()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_transcripts"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow open transcripts' detected")
            }
            return
        }

        // "voiceflow vocabulary" / "voiceflow open vocabulary" - open the custom vocabulary panel
        if lowerTranscript.hasPrefix("voiceflow vocabulary") || lowerTranscript.hasPrefix("voice flow vocabulary") ||
           lowerTranscript.hasPrefix("voiceflow open vocabulary") || lowerTranscript.hasPrefix("voice flow open vocabulary") {
            if turn.endOfTurn {
                openVocabularyPanel()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_vocabulary"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow vocabulary' detected")
            }
            return
        }

        // "voiceflow send" - retype/paste the last utterance
        if lowerTranscript.hasPrefix("voiceflow send") || lowerTranscript.hasPrefix("voice flow send") {
            if turn.endOfTurn {
                pasteLastUtterance()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_send"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                NSLog("[VoiceFlow] detectNoteTakingCommands: 'voiceflow send' detected")
            }
            return
        }
    }

    private func processVoiceCommands(_ turn: TranscriptTurn) {
        // Check if previous turn ended with "say" alone - restore literal mode
        if pendingLiteralMode {
            currentUtteranceIsLiteral = true
            pendingLiteralMode = false
            literalStartWordIndex = 0  // Start from beginning since "say" was in previous turn
            NSLog("[VoiceFlow] processVoiceCommands: restored literal mode from pending (cross-turn 'say')")
        }

        let normalizedTokens = normalizedWordTokens(from: turn.words)
        let transcriptForPrefix = turn.transcript.isEmpty ? (turn.utterance ?? "") : turn.transcript
        // Check both transcript AND first token (transcript may not match words accurately)
        let hasSayPrefix = isSayPrefix(transcriptForPrefix)
            || normalizedTokens.first?.token == "say"
        NSLog("[VoiceFlow] processVoiceCommands: transcript=\"%@\", hasSayPrefix=%d, endOfTurn=%d", String(transcriptForPrefix.prefix(60)), hasSayPrefix ? 1 : 0, turn.endOfTurn ? 1 : 0)

        if hasSayPrefix {
            currentUtteranceIsLiteral = true
            let firstWordIndex = normalizedTokens.first?.wordIndex ?? 0
            literalStartWordIndex = firstWordIndex + 1  // Start after the first word ("say")
            if !didTriggerSayKeyword {
                triggerKeywordFlash(name: "Say")
                didTriggerSayKeyword = true
            }
            logger.debug("Utterance starts with 'say', skipping command processing")

            // If turn ends with just "say" (no content after), set pending for next turn
            let wordsAfterSay = normalizedTokens.dropFirst()
            if turn.endOfTurn && wordsAfterSay.isEmpty {
                pendingLiteralMode = true
                NSLog("[VoiceFlow] processVoiceCommands: 'say' alone at end of turn, setting pendingLiteralMode")
            }
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
        let wakeCommands = Set(["speech", "flow", "microphone"])
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

        // Terminal Window Focusing - "terminal [name]" focuses a terminal window by title
        // This is a shorthand for focusing specific terminal windows (e.g., "terminal voice flow" → VoiceFlow)
        if lowerTranscript.hasPrefix("terminal ") {
            let windowName = String(turn.transcript.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            if !windowName.isEmpty && turn.endOfTurn {
                logDebug("Focusing Terminal Window: \"\(windowName)\"")
                let result = windowManager.focusTerminalWindow(named: windowName)
                switch result {
                case .focused(let name, _):
                    logDebug("Terminal focus success: \"\(name)\"")
                    triggerCommandFlash(name: name)
                case .notFound(let query):
                    logDebug("Terminal focus failed: no window matching \"\(query)\"")
                    triggerCommandFlash(name: "Terminal: not found")
                case .emptyQuery:
                    logDebug("Terminal focus failed: empty query")
                }
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.terminal"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // Extended Command Mode handling - when active, buffer text and check for stop keywords
        if isExtendedCommandMode {
            // Check for stop keywords
            if lowerTranscript.contains("stop command") || lowerTranscript.contains("stop listening") {
                // Extract text before stop keyword and send
                let stopIndex = lowerTranscript.range(of: "stop command") ?? lowerTranscript.range(of: "stop listening")
                if let idx = stopIndex {
                    let textBeforeStop = String(turn.transcript[..<idx.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !textBeforeStop.isEmpty {
                        extendedCommandBuffer += (extendedCommandBuffer.isEmpty ? "" : " ") + textBeforeStop
                    }
                }
                finishExtendedCommand()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.extended_command"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }

            // Buffer the text
            if !turn.transcript.isEmpty {
                extendedCommandBuffer += (extendedCommandBuffer.isEmpty ? "" : " ") + turn.transcript
                resetExtendedCommandTimer()
            }

            // Mark turn as handled to prevent dictation
            turnHandledBySpecialCommand = true
            return
        }

        // Extended Command Mode - "long command [initial text]" starts extended capture
        if lowerTranscript.hasPrefix("long command") {
            // Extract initial text after "long command"
            let initialText = String(turn.transcript.dropFirst(12)).trimmingCharacters(in: .whitespaces)

            if turn.endOfTurn {
                // Start extended command mode
                startExtendedCommand(initialText: initialText)
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.extended_command"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // VoiceFlow Recording Commands - "voiceflow start/stop recording"
        if lowerTranscript.hasPrefix("voiceflow start recording") || lowerTranscript.hasPrefix("voice flow start recording") {
            if turn.endOfTurn {
                startAudioRecording()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_recording"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        if lowerTranscript.hasPrefix("voiceflow stop recording") || lowerTranscript.hasPrefix("voice flow stop recording") {
            if turn.endOfTurn {
                stopAudioRecording()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_recording"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // VoiceFlow Note-Taking Commands
        // "take a note" / "voiceflow make a note" - capture this utterance as note
        if lowerTranscript.hasPrefix("take a note") || lowerTranscript.hasPrefix("voiceflow make a note") || lowerTranscript.hasPrefix("voice flow make a note") {
            if turn.endOfTurn {
                // Extract note content (everything after the command)
                var noteContent = lowerTranscript
                if noteContent.hasPrefix("take a note") {
                    noteContent = String(noteContent.dropFirst("take a note".count))
                } else if noteContent.hasPrefix("voiceflow make a note") {
                    noteContent = String(noteContent.dropFirst("voiceflow make a note".count))
                } else if noteContent.hasPrefix("voice flow make a note") {
                    noteContent = String(noteContent.dropFirst("voice flow make a note".count))
                }
                noteContent = noteContent.trimmingCharacters(in: .whitespaces)

                if !noteContent.isEmpty {
                    // Save the note content directly
                    saveNote(noteContent)
                    triggerCommandFlash(name: "Note Saved")
                } else {
                    // No content after command - start capture mode for next utterance
                    startCapturingNote()
                }

                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // "voiceflow make a long note" - capture until 10s pause
        if lowerTranscript.hasPrefix("voiceflow make a long note") || lowerTranscript.hasPrefix("voice flow make a long note") {
            if turn.endOfTurn {
                startCapturingLongNote()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_long_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // "voiceflow start making a note" - continuous note until stop
        if lowerTranscript.hasPrefix("voiceflow start making a note") || lowerTranscript.hasPrefix("voice flow start making a note") {
            if turn.endOfTurn {
                startContinuousNote()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_continuous_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // "voiceflow stop making a note" / "stop making a note"
        if lowerTranscript.hasPrefix("voiceflow stop making a note") || lowerTranscript.hasPrefix("voice flow stop making a note") || lowerTranscript.hasPrefix("stop making a note") {
            if turn.endOfTurn {
                stopContinuousNote()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_continuous_note"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // VoiceFlow Transcribing Commands
        if lowerTranscript.hasPrefix("voiceflow start transcribing") || lowerTranscript.hasPrefix("voice flow start transcribing") {
            if turn.endOfTurn {
                startTranscribing()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_transcribing"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        if lowerTranscript.hasPrefix("voiceflow stop transcribing") || lowerTranscript.hasPrefix("voice flow stop transcribing") || lowerTranscript.hasPrefix("stop transcribing") {
            if turn.endOfTurn {
                stopTranscribing()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_transcribing"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // VoiceFlow Open Folder Commands
        if lowerTranscript.hasPrefix("voiceflow open note") || lowerTranscript.hasPrefix("voice flow open note") || lowerTranscript.hasPrefix("open note") {
            if turn.endOfTurn {
                openNotesFolder()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_notes"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        if lowerTranscript.hasPrefix("voiceflow open recording") || lowerTranscript.hasPrefix("voice flow open recording") || lowerTranscript.hasPrefix("open recording") {
            if turn.endOfTurn {
                openRecordingsFolder()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_recordings"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        if lowerTranscript.hasPrefix("voiceflow open transcript") || lowerTranscript.hasPrefix("voice flow open transcript") || lowerTranscript.hasPrefix("open transcript") {
            if turn.endOfTurn {
                openTranscriptsFolder()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_open_transcripts"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        if lowerTranscript.hasPrefix("voiceflow send") || lowerTranscript.hasPrefix("voice flow send") {
            if turn.endOfTurn {
                pasteLastUtterance()
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.voiceflow_send"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        // Claude Code Command Mode - "command [text]" sends to Claude Code
        NSLog("[VoiceFlow] 🔍 Checking command prefix: transcript=\"%@\", hasPrefix=%@, isLiteral=%@", String(lowerTranscript.prefix(40)), lowerTranscript.hasPrefix("command ") ? "true" : "false", currentUtteranceIsLiteral ? "true" : "false")
        if lowerTranscript.hasPrefix("command ") {
            let commandText = String(turn.transcript.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            if turn.endOfTurn {
                // Check for "command open" or "command close"
                let commandLower = commandText.lowercased()
                if commandLower == "open" || commandLower.isEmpty {
                    logDebug("Opening command panel")
                    if isCommandPanelVisible {
                        // Panel already open - just focus the input
                        NotificationCenter.default.post(name: NSNotification.Name("CommandPanelShouldFocusInput"), object: nil)
                    } else {
                        openCommandPanel()
                    }
                    triggerCommandFlash(name: "Command Open")
                } else if commandLower == "close" {
                    logDebug("Closing command panel")
                    closeCommandPanel()
                    triggerCommandFlash(name: "Command Close")
                } else if commandLower.hasPrefix("make an issue for voiceflow") ||
                          commandLower.hasPrefix("create an issue for voiceflow") ||
                          commandLower.hasPrefix("make issue for voiceflow") ||
                          commandLower.hasPrefix("create issue for voiceflow") ||
                          commandLower.hasPrefix("new issue for voiceflow") {
                    // Special handler: Create beads issue for VoiceFlow project
                    let patterns = [
                        "make an issue for voiceflow",
                        "create an issue for voiceflow",
                        "make issue for voiceflow",
                        "create issue for voiceflow",
                        "new issue for voiceflow"
                    ]
                    var issueDescription = commandLower
                    for pattern in patterns {
                        if commandLower.hasPrefix(pattern) {
                            issueDescription = String(commandText.dropFirst(pattern.count)).trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                    if issueDescription.isEmpty {
                        issueDescription = "New issue from voice command"
                    }
                    logDebug("Creating VoiceFlow issue: \"\(issueDescription)\"")
                    createBeadsIssue(title: issueDescription, projectPath: "~/code/VoiceFlow")
                    triggerCommandFlash(name: "VoiceFlow Issue")
                } else if commandLower == "format" || commandLower == "format that" ||
                          commandLower == "improve" || commandLower == "improve that" ||
                          commandLower == "improve this" || commandLower == "format this" {
                    // AI text improvement - copies selected text, improves, and pastes back
                    logDebug("Improving selected text via command prefix")
                    improveSelectedText()
                } else {
                    // Execute inline command
                    logDebug("Executing command: \"\(commandText)\"")
                    executeInlineCommand(commandText)
                    triggerCommandFlash(name: "Command")
                }
                if !turn.words.isEmpty {
                    let endIndex = max(0, turn.words.count - 1)
                    lastExecutedEndWordIndexByCommand["system.command"] = endIndex
                    currentUtteranceHadCommand = true
                    lastHaltingCommandEndIndex = max(lastHaltingCommandEndIndex, endIndex)
                }
                turnHandledBySpecialCommand = true
                return
            }
        }

        let tokenStrings = normalizedTokens.map { $0.token }
        let wakeCommandPhrases = ["wake up", "microphone on", "flow on", "speech on"]
        let hasWakeCommandPrefix = wakeCommandPhrases.contains { phrase in
            let phraseTokens = tokenizePhrase(phrase)
            guard tokenStrings.count >= phraseTokens.count else { return false }
            return Array(tokenStrings.prefix(phraseTokens.count)) == phraseTokens
        }

        var matches: [PendingCommandMatch] = []

        let allowPressCommandsInSleep = microphoneMode == .sleep && hasWakeCommandPrefix
        if microphoneMode == .on || allowPressCommandsInSleep {
            // Log tokens for press command debugging (VoiceFlow-3o0)
            if tokenStrings.contains("press") {
                NSLog("[VoiceFlow] 🔍 Pre-pressCommandMatches: detected 'press' in tokens [%@]", tokenStrings.joined(separator: ", "))
            }
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
                // Status check
                (phrase: "are you listening", key: "system.status_check", name: "Status", haltsProcessing: true, action: { [weak self] in self?.confirmListening() } as () -> Void),
                (phrase: "are you there", key: "system.status_check", name: "Status", haltsProcessing: true, action: { [weak self] in self?.confirmListening() } as () -> Void),
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
                (phrase: "submit dictation", key: "system.force_end_utterance", name: "Submit", haltsProcessing: false, action: { [weak self] in self?.forceEndUtterance(contactServices: true) } as () -> Void),
                (phrase: "send dictation", key: "system.force_end_utterance", name: "Send", haltsProcessing: false, action: { [weak self] in self?.forceEndUtterance(contactServices: true) } as () -> Void),
                (phrase: "submit", key: "system.force_end_utterance", name: "Submit", haltsProcessing: false, action: { [weak self] in self?.forceEndUtterance(contactServices: true) } as () -> Void),
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

                // VoiceFlow Issue Creation - sends to Claude Code to create beads issue
                (phrase: "voiceflow issue", key: "system.voiceflow_issue", name: "VF Issue", haltsProcessing: true, action: { [weak self] in self?.createVoiceFlowIssue() } as () -> Void),
                (phrase: "voice flow issue", key: "system.voiceflow_issue", name: "VF Issue", haltsProcessing: true, action: { [weak self] in self?.createVoiceFlowIssue() } as () -> Void),
                (phrase: "make an issue for voiceflow", key: "system.voiceflow_issue", name: "VF Issue", haltsProcessing: true, action: { [weak self] in self?.createVoiceFlowIssue() } as () -> Void),
                (phrase: "make an issue for voice flow", key: "system.voiceflow_issue", name: "VF Issue", haltsProcessing: true, action: { [weak self] in self?.createVoiceFlowIssue() } as () -> Void),
                (phrase: "create voiceflow issue", key: "system.voiceflow_issue", name: "VF Issue", haltsProcessing: true, action: { [weak self] in self?.createVoiceFlowIssue() } as () -> Void),

                // Dictation Provider Switching
                (phrase: "use online model", key: "system.provider_online", name: "Online Model", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.online) } as () -> Void),
                (phrase: "use offline model", key: "system.provider_offline", name: "Offline Model", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.offline) } as () -> Void),
                (phrase: "use auto model", key: "system.provider_auto", name: "Auto Model", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.auto) } as () -> Void),
                (phrase: "use deepgram", key: "system.provider_deepgram", name: "Deepgram", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.deepgram) } as () -> Void),
                (phrase: "switch to deepgram", key: "system.provider_deepgram", name: "Deepgram", haltsProcessing: true, action: { [weak self] in self?.saveDictationProvider(.deepgram) } as () -> Void),

                // AI Text Improvement - improves selected text (requires pause to avoid false positives)
                (phrase: "improve that", key: "system.improve_text", name: "Improve", haltsProcessing: true, action: { [weak self] in self?.improveSelectedText() } as () -> Void),
                (phrase: "improve this", key: "system.improve_text", name: "Improve", haltsProcessing: true, action: { [weak self] in self?.improveSelectedText() } as () -> Void),
                (phrase: "format that", key: "system.improve_text", name: "Improve", haltsProcessing: true, action: { [weak self] in self?.improveSelectedText() } as () -> Void),
                (phrase: "format this", key: "system.improve_text", name: "Improve", haltsProcessing: true, action: { [weak self] in self?.improveSelectedText() } as () -> Void)
            ])
        }

        // Mode-changing commands that must appear at START of utterance only (prevents "oddly enough, speech off" from triggering)
        let modeCommandKeys: Set<String> = ["system.wake_up", "system.go_to_sleep", "system.microphone_off"]

        // Commands that require a pause (endOfTurn) to avoid false positives in natural speech
        // e.g., "improve that" or "format that" could be said naturally without intending a command
        let pauseRequiredKeys: Set<String> = ["system.improve_text"]

        for systemCommand in systemCommands {
            let phraseTokens = tokenizePhrase(systemCommand.phrase)
            for range in findMatches(phraseTokens: phraseTokens, in: tokenStrings) {
                let startTokenIndex = range.lowerBound
                let endTokenIndex = range.upperBound - 1
                let startWordIndex = normalizedTokens[startTokenIndex].wordIndex
                let endWordIndex = normalizedTokens[endTokenIndex].wordIndex

                let isPrefixed = startTokenIndex > 0 && normalizedTokens[startTokenIndex - 1].token == commandPrefixToken

                // FIX VoiceFlow-7n8p: Mode commands must be at START of utterance (word index 0)
                // This prevents natural speech like "Oddly enough, speech off." from triggering mode changes
                // BUT allow if explicitly prefixed with "command" (e.g., "command speech off")
                if modeCommandKeys.contains(systemCommand.key) && startWordIndex != 0 && !isPrefixed {
                    NSLog("[VoiceFlow] 🚫 Ignoring mode command '%@' at word index %d (must be at start, or use 'command' prefix)", systemCommand.phrase, startWordIndex)
                    continue
                }
                let wordIndices = normalizedTokens[range].map { $0.wordIndex }
                let isStable = isPrefixed || isStableMatch(words: turn.words, wordIndices: wordIndices)
                // Submit/send commands should execute even if words aren't final
                let skipStability = systemCommand.key == "system.force_end_utterance"
                // Some commands require a pause to avoid false positives
                let needsPause = pauseRequiredKeys.contains(systemCommand.key)
                matches.append(PendingCommandMatch(
                    key: systemCommand.key,
                    startWordIndex: startWordIndex,
                    endWordIndex: endWordIndex,
                    isPrefixed: isPrefixed,
                    isStable: isStable,
                    requiresPause: needsPause,
                    haltsProcessing: systemCommand.haltsProcessing,
                    skipStabilityCheck: skipStability,
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
                        skipStabilityCheck: false,
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
            guard match.isStable || match.skipStabilityCheck else { continue }
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
        // Note: We intentionally DON'T reset these flags here because they persist across utterances:
        // - pendingCrossUtteranceKeyword: for cross-utterance keyword detection (e.g., "new" + "line")
        // - pendingLiteralMode: for cross-turn "say" escape (e.g., "say" + [pause] + "newline")
    }

    private func isSayPrefix(_ text: String) -> Bool {
        let sayPattern = "^say[\\.,?!]?(\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: sayPattern, options: [.caseInsensitive]) else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil
        NSLog("[VoiceFlow] 🔍 isSayPrefix: text=\"%@\", result=%@", String(trimmed.prefix(40)), result ? "true" : "false")
        return result
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

    func triggerCommandFlash(name: String) {
        lastCommandName = name
        isCommandFlashActive = true

        // Log command to debug history
        logDebug("⚡ Command: \(name)")

        // Reset flash after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + commandFlashDurationSeconds) { [weak self] in
            self?.isCommandFlashActive = false
        }
    }

    private func triggerKeywordFlash(name: String) {
        lastKeywordName = name
        isKeywordFlashActive = true

        // Log keyword to debug history
        logDebug("🎯 Keyword: \(name)")

        DispatchQueue.main.asyncAfter(deadline: .now() + keywordFlashDurationSeconds) { [weak self] in
            self?.isKeywordFlashActive = false
        }
    }

    /// Provides audio/visual confirmation that VoiceFlow is listening
    func confirmListening() {
        // Play system sound for audio feedback
        NSLog("[VoiceFlow] 🔔 BEEP: confirmListening() - user asked 'are you listening'")
        NSSound.beep()

        // Show visual flash with current mode status
        let statusText: String
        switch microphoneMode {
        case .on:
            statusText = "Listening ✓"
        case .sleep:
            statusText = "Sleep Mode"
        case .off:
            statusText = "Mic Off"
        }
        triggerCommandFlash(name: statusText)
    }

    // MARK: - Extended Command Mode ("long command")

    /// Start extended command capture mode
    private func startExtendedCommand(initialText: String) {
        logDebug("Starting extended command mode with initial: \"\(initialText)\"")
        isExtendedCommandMode = true
        extendedCommandBuffer = initialText
        triggerCommandFlash(name: "Long Command...")

        // Start the pause timer
        resetExtendedCommandTimer()
    }

    /// Reset the extended command pause timer (called when speech is received)
    private func resetExtendedCommandTimer() {
        extendedCommandPauseTimer?.invalidate()
        extendedCommandPauseTimer = Timer.scheduledTimer(
            withTimeInterval: extendedCommandPauseThreshold,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishExtendedCommand()
            }
        }
    }

    /// Finish extended command mode and send buffered text to Claude
    private func finishExtendedCommand() {
        extendedCommandPauseTimer?.invalidate()
        extendedCommandPauseTimer = nil

        let commandText = extendedCommandBuffer.trimmingCharacters(in: .whitespaces)
        logDebug("Finishing extended command: \"\(commandText)\"")

        isExtendedCommandMode = false
        extendedCommandBuffer = ""

        if !commandText.isEmpty {
            executeInlineCommand(commandText)
            triggerCommandFlash(name: "Long Command ✓")
        } else {
            triggerCommandFlash(name: "Long Command (empty)")
        }
    }

    /// Cancel extended command mode without sending
    func cancelExtendedCommand() {
        guard isExtendedCommandMode else { return }

        logDebug("Cancelling extended command mode")
        extendedCommandPauseTimer?.invalidate()
        extendedCommandPauseTimer = nil
        isExtendedCommandMode = false
        extendedCommandBuffer = ""
        triggerCommandFlash(name: "Command Cancelled")
    }

    // MARK: - Audio Recording ("voiceflow start/stop recording")

    /// Start recording audio to a file
    func startAudioRecording() {
        guard !isRecordingAudio else {
            logDebug("Already recording audio")
            return
        }

        logDebug("Starting audio recording")
        recordingAudioBuffer.removeAll()
        recordingStartTime = Date()
        isRecordingAudio = true
        triggerCommandFlash(name: "Recording...")

        // Play a sound to indicate recording started
        NSLog("[VoiceFlow] 🔔 BEEP: startAudioRecording() - voice command 'voiceflow start recording'")
        NSSound.beep()
    }

    /// Stop recording and save the audio file
    func stopAudioRecording() {
        guard isRecordingAudio else {
            logDebug("Not currently recording audio")
            return
        }

        logDebug("Stopping audio recording")
        isRecordingAudio = false

        guard !recordingAudioBuffer.isEmpty else {
            logDebug("No audio data captured")
            triggerCommandFlash(name: "Recording Empty")
            recordingStartTime = nil
            return
        }

        // Combine all audio data
        var combinedData = Data()
        for chunk in recordingAudioBuffer {
            combinedData.append(chunk)
        }
        recordingAudioBuffer.removeAll()

        // Create filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "recording_\(formatter.string(from: recordingStartTime ?? Date())).wav"
        let fileURL = recordingsDirectory.appendingPathComponent(filename)

        // Create WAV file with header
        // Format: 16-bit PCM mono at 16kHz (same as AudioCaptureManager)
        let wavData = createWAVFile(from: combinedData, sampleRate: 16000, channels: 1, bitsPerSample: 16)

        do {
            try wavData.write(to: fileURL)
            let durationSec = Double(combinedData.count) / (16000.0 * 2.0)  // 16kHz * 2 bytes per sample
            logDebug("Saved recording: \(filename) (\(String(format: "%.1f", durationSec))s)")
            triggerCommandFlash(name: "Recording Saved")

            // Play a sound to indicate recording saved
            NSLog("[VoiceFlow] 🔔 BEEP: stopAudioRecording() - recording saved to \(filename)")
            NSSound.beep()
        } catch {
            logDebug("Failed to save recording: \(error)")
            triggerCommandFlash(name: "Save Failed")
        }

        recordingStartTime = nil
    }

    /// Create a WAV file with proper header from raw PCM data
    private func createWAVFile(from pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var wavData = Data()

        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize  // 44 bytes header - 8 for RIFF header itself + data

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // Subchunk1Size (16 for PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // AudioFormat (1 = PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
    }

    /// Buffer audio data for recording (called from onAudioData callbacks)
    func bufferAudioForRecording(_ data: Data) {
        guard isRecordingAudio else { return }
        recordingAudioBuffer.append(data)
    }

    // MARK: - Note Taking ("take a note", "voiceflow make a note")

    /// Start capturing next utterance as a note (single utterance mode)
    func startCapturingNote() {
        logDebug("Starting note capture (single utterance)")
        isCapturingNote = true
        noteBuffer = ""
        triggerCommandFlash(name: "Note...")
        NSLog("[VoiceFlow] 🔔 BEEP: startCapturingNote() - 'take a note' command")
        NSSound.beep()
    }

    /// Called when a complete utterance is received while in note capture mode
    func captureNoteUtterance(_ text: String) {
        guard isCapturingNote else { return }

        isCapturingNote = false
        saveNote(text)
    }

    /// Start capturing a long note (timeout-based, 10s pause to finish)
    func startCapturingLongNote() {
        logDebug("Starting long note capture (10s timeout)")
        isCapturingLongNote = true
        noteBuffer = ""
        triggerCommandFlash(name: "Long Note...")
        NSLog("[VoiceFlow] 🔔 BEEP: startCapturingLongNote() - 'voiceflow make a long note' command")
        NSSound.beep()
        resetNotePauseTimer()
    }

    /// Add text to long note buffer and reset timer
    func appendToLongNote(_ text: String) {
        guard isCapturingLongNote else { return }

        if !noteBuffer.isEmpty {
            noteBuffer += " "
        }
        noteBuffer += text
        resetNotePauseTimer()
    }

    /// Reset the pause timer for long note
    private func resetNotePauseTimer() {
        notePauseTimer?.invalidate()
        notePauseTimer = Timer.scheduledTimer(withTimeInterval: notePauseThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finishLongNote()
            }
        }
    }

    /// Finish and save the long note
    private func finishLongNote() {
        guard isCapturingLongNote else { return }

        notePauseTimer?.invalidate()
        notePauseTimer = nil
        isCapturingLongNote = false

        if noteBuffer.isEmpty {
            triggerCommandFlash(name: "Note Empty")
        } else {
            saveNote(noteBuffer)
        }
        noteBuffer = ""
    }

    /// Start continuous note mode (until "stop making a note")
    func startContinuousNote() {
        logDebug("Starting continuous note")
        isContinuousNote = true
        noteBuffer = ""
        triggerCommandFlash(name: "Note On...")
        NSLog("[VoiceFlow] 🔔 BEEP: startContinuousNote() - 'voiceflow start making a note' command")
        NSSound.beep()
    }

    /// Add text to continuous note buffer
    func appendToContinuousNote(_ text: String) {
        guard isContinuousNote else { return }

        if !noteBuffer.isEmpty {
            noteBuffer += " "
        }
        noteBuffer += text
    }

    /// Stop continuous note and save
    func stopContinuousNote() {
        guard isContinuousNote else {
            logDebug("Not in continuous note mode")
            return
        }

        logDebug("Stopping continuous note")
        isContinuousNote = false

        if noteBuffer.isEmpty {
            triggerCommandFlash(name: "Note Empty")
        } else {
            saveNote(noteBuffer)
        }
        noteBuffer = ""
    }

    /// Save note to file
    private func saveNote(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "note_\(formatter.string(from: Date())).txt"
        let fileURL = notesDirectory.appendingPathComponent(filename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            logDebug("Saved note: \(filename)")
            triggerCommandFlash(name: "Note Saved")
        } catch {
            logDebug("Failed to save note: \(error)")
            triggerCommandFlash(name: "Note Failed")
        }
    }

    // MARK: - Transcribing ("voiceflow start/stop transcribing")

    /// Start transcribing mode - saves all speech to transcript file
    func startTranscribing() {
        logDebug("Starting transcription")
        isTranscribing = true
        transcriptBuffer = ""
        triggerCommandFlash(name: "Transcribing...")
        NSLog("[VoiceFlow] 🔔 BEEP: startTranscribing() - 'voiceflow start transcribing' command")
        NSSound.beep()
    }

    /// Add text to transcript buffer
    func appendToTranscript(_ text: String) {
        guard isTranscribing else { return }

        if !transcriptBuffer.isEmpty {
            transcriptBuffer += "\n"
        }
        transcriptBuffer += text
    }

    /// Stop transcribing and save
    func stopTranscribing() {
        guard isTranscribing else {
            logDebug("Not transcribing")
            return
        }

        logDebug("Stopping transcription")
        isTranscribing = false

        if transcriptBuffer.isEmpty {
            triggerCommandFlash(name: "Transcript Empty")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "transcript_\(formatter.string(from: Date())).txt"
            let fileURL = transcriptsDirectory.appendingPathComponent(filename)

            do {
                try transcriptBuffer.write(to: fileURL, atomically: true, encoding: .utf8)
                logDebug("Saved transcript: \(filename)")
                triggerCommandFlash(name: "Transcript Saved")
                NSLog("[VoiceFlow] 🔔 BEEP: stopTranscribing() - transcript saved to \(filename)")
                NSSound.beep()
            } catch {
                logDebug("Failed to save transcript: \(error)")
                triggerCommandFlash(name: "Save Failed")
            }
        }
        transcriptBuffer = ""
    }

    // MARK: - Folder Opening Commands

    /// Open the notes folder in Finder
    func openNotesFolder() {
        NSWorkspace.shared.open(notesDirectory)
        triggerCommandFlash(name: "Opening Notes")
    }

    /// Open the Notes panel
    func openNotesPanel() {
        // Post notification to VoiceFlowApp to show the panel
        NotificationCenter.default.post(
            name: NSNotification.Name("VoiceFlowShowNotesPanel"),
            object: nil
        )
        triggerCommandFlash(name: "Notes Panel")
    }

    /// Open the Transcripts panel
    func openTranscriptsPanel() {
        // Post notification to VoiceFlowApp to show the panel
        NotificationCenter.default.post(
            name: NSNotification.Name("VoiceFlowShowTranscriptsPanel"),
            object: nil
        )
        triggerCommandFlash(name: "Transcripts Panel")
    }

    /// Open the Tickets panel
    func openTicketsPanel() {
        // Post notification to VoiceFlowApp to show the panel
        NotificationCenter.default.post(
            name: NSNotification.Name("VoiceFlowShowTicketsPanel"),
            object: nil
        )
        triggerCommandFlash(name: "Tickets Panel")
    }

    /// Open the Vocabulary panel
    func openVocabularyPanel() {
        // Post notification to VoiceFlowApp to show the panel
        NotificationCenter.default.post(
            name: NSNotification.Name("VoiceFlowShowVocabularyPanel"),
            object: nil
        )
        triggerCommandFlash(name: "Vocabulary")
    }

    /// Open the recordings folder in Finder
    func openRecordingsFolder() {
        let recordingsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/VoiceFlow/Recordings")
        // Create if doesn't exist
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDir)
        triggerCommandFlash(name: "Opening Recordings")
    }

    /// Open the transcripts folder in Finder
    func openTranscriptsFolder() {
        NSWorkspace.shared.open(transcriptsDirectory)
        triggerCommandFlash(name: "Opening Transcripts")
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

    /// Parse a number word or digit string to an integer (1-99), or nil if not a number
    private func parseNumberWord(_ text: String) -> Int? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Try parsing as digit first
        if let num = Int(normalized), num >= 1 && num <= 99 {
            return num
        }

        // Word to number mapping
        let wordNumbers: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
            "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
            "seventy": 70, "eighty": 80, "ninety": 90
        ]

        return wordNumbers[normalized]
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

            // Diagnostic logging for cmd+k bug (VoiceFlow-3o0)
            let tokenSequence = normalizedTokens[index...min(cursor, normalizedTokens.count - 1)].map { $0.token }.joined(separator: " ")
            NSLog("[VoiceFlow] 🔍 pressCommandMatches: parsing tokens [%@], keyToken='%@', modifiers=%@", tokenSequence, keyToken, String(describing: modifiers))

            guard let keyInfo = keyCodeForToken(keyToken, nextToken: nextToken) else {
                NSLog("[VoiceFlow] 🔍 pressCommandMatches: keyToken '%@' not recognized by keyCodeForToken", keyToken)
                index += 1
                continue
            }

            NSLog("[VoiceFlow] 🔍 pressCommandMatches: keyCodeForToken returned keyCode=%d (0x%02X) for '%@'", keyInfo.keyCode, keyInfo.keyCode, keyToken)

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
            NSLog("[VoiceFlow] 🔍 pressCommandMatches: creating match for '%@' with keyCode=%d (0x%02X), isStable=%@", label, shortcut.keyCode, shortcut.keyCode, isStable ? "true" : "false")

            matches.append(PendingCommandMatch(
                key: "system.press",
                startWordIndex: startWordIndex,
                endWordIndex: endWordIndex,
                isPrefixed: isPrefixed,
                isStable: isStable,
                requiresPause: false,
                haltsProcessing: false,
                skipStabilityCheck: false,
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
        // DIAGNOSTIC: Log if typing during Sleep/Off mode (shouldn't happen - investigating clunk sounds)
        if microphoneMode != .on {
            NSLog("[VoiceFlow] ⚠️ DIAGNOSTIC: typeText called during \(microphoneMode.rawValue) mode! text=\"\(text.prefix(50))...\"")
        }

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
            let isActive = frontApp.isActive
            logDebug("Target app: \(appName) (\(bundleId)) active=\(isActive)")
        } else {
            logDebug("Target app: Unknown (no frontmost app)")
        }

        // Check if we can get focused element info (for debugging clunk sounds)
        if let systemWide = AXUIElementCreateSystemWide() as AXUIElement? {
            var focusedElement: AnyObject?
            let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
            if result == .success, let element = focusedElement {
                var roleValue: AnyObject?
                AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &roleValue)
                let role = roleValue as? String ?? "unknown"
                logDebug("Focused element role: \(role)")
            } else {
                logDebug("Focused element: none (may cause clunk)")
            }
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

        // Terminal UIs (Claude Code, Gemini CLI) need longer delay before Enter for reliable submission
        // Regular apps work fine with shorter delay
        let isTerminal = focusContextManager.isCurrentAppTerminal()
        let minDelayBeforeReturn: TimeInterval = isTerminal ? 0.05 : 0.02  // 50ms for terminals (using AppleScript), 20ms otherwise

        for char in output {
            if char == "\n" {
                // Diagnostic logging for newline debugging (VoiceFlow-qs3)
                let beforeNewline = Date()
                var actualDelay: TimeInterval = 0

                // Ensure sufficient delay before Return key, even across typeText calls
                // This fixes inconsistent newline submission at end of utterances
                // Terminal UIs (like Claude Code) need time to process the keypress as "submit"
                if let lastTime = lastKeyEventTime {
                    let elapsed = beforeNewline.timeIntervalSince(lastTime)
                    let neededDelay = max(0, minDelayBeforeReturn - elapsed)
                    if neededDelay > 0 {
                        Thread.sleep(forTimeInterval: neededDelay)
                        actualDelay = neededDelay
                    }
                    NSLog("[VoiceFlow] ⏎ Return key: elapsed=%.0fms, needed=%.0fms, actual_delay=%.0fms (isTerminal=%@)",
                          elapsed * 1000, minDelayBeforeReturn * 1000, actualDelay * 1000, isTerminal ? "true" : "false")
                } else {
                    // Always delay before Enter, even if this is the first/only keypress
                    // This ensures terminal UIs have time to be ready for the submission
                    Thread.sleep(forTimeInterval: minDelayBeforeReturn)
                    actualDelay = minDelayBeforeReturn
                    NSLog("[VoiceFlow] ⏎ Return key: FIRST_KEYPRESS, forced_delay=%.0fms (isTerminal=%@)",
                          actualDelay * 1000, isTerminal ? "true" : "false")
                }

                logDebug("Sending Return key for newline (isTerminal=\(isTerminal), delay=\(Int(actualDelay * 1000))ms)")

                // For terminals (especially ink/React apps like Claude Code), we need to ensure
                // the Return key sends \r (carriage return), not \n (line feed).
                // Ink's useInput hook checks key.return which expects \r for submit.
                // If \n is received, it's treated as regular input (just a newline character).
                if isTerminal {
                    // Send Return key with explicit \r character and clear modifier flags
                    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
                    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)

                    // Explicitly set the character to \r (carriage return) for terminal apps
                    var cr: UniChar = 0x0D  // \r = carriage return
                    keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)
                    keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)

                    // Clear any modifier flags to avoid Shift+Enter being interpreted as newline
                    keyDown?.flags = []
                    keyUp?.flags = []

                    keyDown?.post(tap: .cghidEventTap)
                    keyUp?.post(tap: .cghidEventTap)
                } else {
                    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
                    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
                    keyDown?.post(tap: .cghidEventTap)
                    keyUp?.post(tap: .cghidEventTap)
                }
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

    /// Send Return key via AppleScript (System Events)
    /// This uses a different mechanism than CGEvent and may be more reliable for some apps
    /// The delay parameter adds a pause INSIDE AppleScript before keystroke - this is more
    /// reliable than Thread.sleep because it happens in the same event context as the keystroke
    private func sendReturnViaAppleScript(delaySeconds: Double = 0) {
        let script: String
        if delaySeconds > 0 {
            script = """
            tell application "System Events"
                delay \(delaySeconds)
                keystroke return
            end tell
            """
            NSLog("[VoiceFlow] ⏎ AppleScript: delay %.0fms then return", delaySeconds * 1000)
        } else {
            script = """
            tell application "System Events"
                keystroke return
            end tell
            """
        }
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                logDebug("AppleScript error: \(error)")
            }
        }
    }

    /// Flush any buffered terminal newlines (called at end of utterance)
    /// This sends the Return key presses that were deferred during live typing in terminal mode
    private func flushBufferedTerminalNewlines() {
        guard bufferedTerminalNewlines > 0 else { return }

        logDebug("Flushing \(bufferedTerminalNewlines) buffered terminal newline(s)")

        let isTerminal = focusContextManager.isCurrentAppTerminal()

        // For terminals: use AppleScript with built-in delay (more atomic/reliable than Thread.sleep)
        // For non-terminals: CGEvent with no delay (faster)
        let appleScriptDelay: Double = 0.15  // 150ms delay inside AppleScript

        for i in 0..<bufferedTerminalNewlines {
            if isTerminal {
                // AppleScript handles its own timing internally - more reliable than Thread.sleep
                sendReturnViaAppleScript(delaySeconds: i == 0 ? appleScriptDelay : 0.05)
            } else {
                let source = CGEventSource(stateID: .hidSystemState)
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
            lastKeyEventTime = Date()
        }

        bufferedTerminalNewlines = 0
    }

    /// Send a single Enter key press (for explicit "press enter" / "submit" command)
    private func sendEnterKey() {
        logDebug("Sending explicit Enter key")
        let isTerminal = focusContextManager.isCurrentAppTerminal()
        if isTerminal {
            sendReturnViaAppleScript()
        } else {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Return), keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        lastKeyEventTime = Date()
    }

    private func sendBackspaceKeypresses(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            usleep(10000)
        }
        lastKeyEventTime = Date()
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
        NSLog("[VoiceFlow] executeKeyboardShortcut: keyCode=%d (0x%02X), flags=%llu", shortcut.keyCode, shortcut.keyCode, flags.rawValue)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)

        keyDown?.flags = flags
        keyUp?.flags = flags

        // Post keyDown, wait briefly, then keyUp (more realistic timing)
        keyDown?.post(tap: .cghidEventTap)
        usleep(10000)  // 10ms delay between keyDown and keyUp
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

    // MARK: - Custom Vocabulary

    private func loadCustomVocabulary() {
        if let data = UserDefaults.standard.data(forKey: "custom_vocabulary"),
           let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
            customVocabulary = entries
        }
    }

    /// Reload vocabulary from UserDefaults (called when CLI modifies vocabulary)
    func reloadVocabulary() {
        loadCustomVocabulary()
        loadVocabularyPrompt()
        // Reconnect to apply new vocabulary to AssemblyAI
        if microphoneMode != .off && !effectiveIsOffline {
            reconnect()
        }
    }

    func saveCustomVocabulary() {
        if let data = try? JSONEncoder().encode(customVocabulary) {
            UserDefaults.standard.set(data, forKey: "custom_vocabulary")
        }
    }

    func addVocabularyEntry(_ entry: VocabularyEntry) {
        customVocabulary.append(entry)
        saveCustomVocabulary()
    }

    func updateVocabularyEntry(_ entry: VocabularyEntry) {
        if let index = customVocabulary.firstIndex(where: { $0.id == entry.id }) {
            customVocabulary[index] = entry
            saveCustomVocabulary()
        }
    }

    func deleteVocabularyEntry(_ entry: VocabularyEntry) {
        customVocabulary.removeAll { $0.id == entry.id }
        saveCustomVocabulary()
    }

    /// Build a lookup dictionary from custom vocabulary for fast matching
    func vocabularyLookup() -> [String: String] {
        var lookup: [String: String] = [:]
        for entry in customVocabulary where entry.isEnabled {
            // Store with lowercased key for case-insensitive matching
            lookup[entry.spokenPhrase.lowercased()] = entry.writtenForm
        }
        return lookup
    }

    /// Apply custom vocabulary substitutions to text
    /// Replaces spoken phrases with their written forms (case-insensitive)
    private func applyVocabularySubstitutions(_ text: String) -> String {
        guard !customVocabulary.isEmpty else { return text }

        var result = text

        // Sort entries by spoken phrase length (longest first) to handle overlapping phrases
        let sortedEntries = customVocabulary
            .filter { $0.isEnabled }
            .sorted { $0.spokenPhrase.count > $1.spokenPhrase.count }

        for entry in sortedEntries {
            let lowerResult = result.lowercased()
            let spokenLower = entry.spokenPhrase.lowercased()
            let containsSpoken = lowerResult.contains(spokenLower)

            // Use word boundary matching to avoid partial word replacements
            // The pattern matches the spoken phrase with optional surrounding punctuation
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: entry.spokenPhrase))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                let matches = regex.matches(in: result, options: [], range: range)

                if matches.isEmpty {
                    if isDebugMode && containsSpoken {
                        logDebug("Vocabulary: '\(entry.spokenPhrase)' seen but no word-boundary match in \"\(result.prefix(120))\"")
                    }
                    continue
                }

                // Replace from end to start to preserve indices
                for match in matches.reversed() {
                    if let matchRange = Range(match.range, in: result) {
                        let originalText = String(result[matchRange])
                        // Preserve the original case pattern for simple cases
                        let replacement = preserveCase(original: originalText, replacement: entry.writtenForm)
                        result.replaceSubrange(matchRange, with: replacement)
                        logDebug("Vocabulary: '\(originalText)' → '\(replacement)'")
                    }
                }
            }
        }

        return result
    }

    /// Attempt to preserve case pattern from original text in replacement
    private func preserveCase(original: String, replacement: String) -> String {
        // If original is all uppercase, make replacement all uppercase
        if original == original.uppercased() && original != original.lowercased() {
            return replacement.uppercased()
        }
        // If original is all lowercase, keep replacement as-is (it has the desired form)
        if original == original.lowercased() {
            return replacement
        }
        // If original is capitalized (first letter upper, rest lower), capitalize replacement
        if original.first?.isUppercase == true &&
           String(original.dropFirst()) == String(original.dropFirst()).lowercased() {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        // Otherwise, use the replacement as defined
        return replacement
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

        // Auto-switch to offline if enabled and latency exceeds threshold
        if autoSwitchToOfflineOnHighLatency && !didAutoSwitchToOffline && latencyMs >= autoSwitchOfflineThresholdMs {
            // Only switch if we're currently using an online provider
            if dictationProvider != .offline && !effectiveIsOffline {
                didAutoSwitchToOffline = true
                logDebug("Auto-switching to offline due to high latency: \(latencyMs)ms")
                NSLog("[VoiceFlow] Auto-switching to offline speech (latency: %dms > %dms threshold)", latencyMs, autoSwitchOfflineThresholdMs)

                // Switch to offline provider
                let wasOn = microphoneMode == .on
                if wasOn {
                    stopListening()
                }
                // Temporarily switch to offline
                let previousProvider = dictationProvider
                dictationProvider = .offline
                if wasOn {
                    startListening(transcribeMode: true)
                }

                // Flash notification
                triggerCommandFlash(name: "Slow network → Offline")

                // Restore original provider after some time (30 seconds) if latency improves
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
                    if self.didAutoSwitchToOffline {
                        self.didAutoSwitchToOffline = false
                        // Check if latency has improved
                        if let currentLatency = self.connectionLatencyMs, currentLatency < self.autoSwitchOfflineThresholdMs {
                            self.logDebug("Latency recovered, switching back to \(previousProvider.rawValue)")
                            let wasOn = self.microphoneMode == .on
                            if wasOn { self.stopListening() }
                            self.dictationProvider = previousProvider
                            if wasOn { self.startListening(transcribeMode: true) }
                            self.triggerCommandFlash(name: "Online restored")
                        }
                    }
                }
            }
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

    // MARK: - Auto-Submit Timer (Vibe Coding Mode)

    private func startAutoSubmitTimer() {
        cancelAutoSubmitTimer()
        logDebug("Auto-submit: Starting \(autoSubmitDelaySeconds)s timer")
        autoSubmitTimer = Timer.scheduledTimer(withTimeInterval: autoSubmitDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleAutoSubmitTimeout()
            }
        }
    }

    private func cancelAutoSubmitTimer() {
        if autoSubmitTimer != nil {
            logDebug("Auto-submit: Timer cancelled")
        }
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
    }

    private func handleAutoSubmitTimeout() {
        guard autoSubmitEnabled && microphoneMode == .on else {
            logDebug("Auto-submit: Skipped (mode=\(microphoneMode.rawValue), enabled=\(autoSubmitEnabled))")
            return
        }
        logDebug("Auto-submit: Pressing Enter after silence")
        typeText("\n", appendSpace: false)
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

    // MARK: - Command Panel Settings

    private func loadCommandPanelSettings() {
        let storedSize = UserDefaults.standard.double(forKey: "command_panel_font_size")
        commandPanelFontSize = storedSize > 0 ? storedSize : 14.0  // Default to 14 if not set
        // Load session history
        loadSessions()
    }

    func saveCommandPanelFontSize(_ value: Double) {
        commandPanelFontSize = value
        UserDefaults.standard.set(value, forKey: "command_panel_font_size")
    }

    // MARK: - Auto-Switch Offline Settings

    private func loadAutoSwitchOfflineSettings() {
        autoSwitchToOfflineOnHighLatency = UserDefaults.standard.bool(forKey: "auto_switch_offline_high_latency")
    }

    func saveAutoSwitchOfflineSetting(_ enabled: Bool) {
        autoSwitchToOfflineOnHighLatency = enabled
        UserDefaults.standard.set(enabled, forKey: "auto_switch_offline_high_latency")
        logDebug("Auto-switch to offline on high latency: \(enabled)")
    }

    private func loadDictationHistory() {
        if let history = UserDefaults.standard.stringArray(forKey: "dictation_history") {
            dictationHistory = history
        }
    }

    func saveDictationHistory() {
        UserDefaults.standard.set(dictationHistory, forKey: "dictation_history")
    }

    /// Clear dictation history
    func clearDictationHistory() {
        dictationHistory.removeAll()
        saveDictationHistory()
    }

    /// Retype/paste text (public interface for panels)
    func retypeText(_ text: String) {
        typeText(text, appendSpace: false)
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
    private var effectiveVocabularyTerms: [String] {
        var terms: [String] = []

        // Add user-specified vocabulary (split by comma or newline)
        if !vocabularyPrompt.isEmpty {
            let userTerms = vocabularyPrompt
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            terms.append(contentsOf: userTerms)
        }

        // Add custom vocabulary entries (both spoken and written forms for better recognition)
        for entry in customVocabulary where entry.isEnabled {
            terms.append(entry.spokenPhrase)
            // Also add written form if different (helps AssemblyAI recognize both)
            if entry.writtenForm.lowercased() != entry.spokenPhrase.lowercased() {
                terms.append(entry.writtenForm)
            }
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
        return Array(Set(terms)).prefix(100).map { $0 }
    }

    /// Generates the effective vocabulary prompt combining user prompt + command phrases
    var effectiveVocabularyPrompt: String {
        let terms = effectiveVocabularyTerms
        guard !terms.isEmpty else { return "" }
        // Format as JSON array for keyterms_prompt
        if let jsonData = try? JSONSerialization.data(withJSONObject: terms),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return ""
    }

    var hasUserVocabularyBiasTerms: Bool {
        let hasPrompt = !vocabularyPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCustom = customVocabulary.contains { $0.isEnabled }
        return hasPrompt || hasCustom
    }

    var supportsVocabularyBiasForCurrentProvider: Bool {
        if effectiveIsOffline || dictationProvider == .offline {
            return false
        }
        if dictationProvider == .deepgram {
            return true
        }
        return true
    }

    var vocabularyBiasSupportedProvidersLabel: String {
        "AssemblyAI (Auto/Online) and Deepgram (Nova-2 keywords)"
    }

    var vocabularyBiasUnsupportedMessage: String? {
        guard hasUserVocabularyBiasTerms else { return nil }
        if effectiveIsOffline || dictationProvider == .offline {
            if dictationProvider == .auto {
                return "Vocabulary bias terms are ignored while offline (Auto uses Mac Speech)."
            }
            return "Vocabulary bias terms aren't supported in Mac Speech (Offline)."
        }
        return nil
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
        // Check for resume_mode first (set during restart to preserve state)
        if let resumeMode = UserDefaults.standard.string(forKey: "resume_mode") {
            // Clear it immediately so it's only used once
            UserDefaults.standard.removeObject(forKey: "resume_mode")
            UserDefaults.standard.synchronize()

            let normalized = resumeMode.lowercased()
            switch normalized {
            case "on": launchMode = .on
            case "off": launchMode = .off
            case "sleep": launchMode = .sleep
            default: break // Fall through to normal launch_mode
            }
            logDebug("Resuming from restart with mode: \(launchMode.rawValue)")
            return
        }

        // Normal launch - use configured launch_mode
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

    /// Request graceful transition to sleep mode - waits for finalized text before switching
    /// Called when PTT is released so we don't cut off mid-word
    func requestGracefulSleep() {
        guard microphoneMode == .on else { return }

        logDebug("PTT: Requesting graceful sleep, waiting for finalized text")
        isPTTProcessing = true

        // Tell the speech service to finalize current utterance
        assemblyAIService?.forceEndUtterance()
        appleSpeechService?.forceEndUtterance()

        // Set a timeout - if we don't get a final turn within 2 seconds, force sleep
        pttSleepTimeoutTask?.cancel()
        pttSleepTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
            if self.isPTTProcessing {
                self.logDebug("PTT: Timeout waiting for finalized text, forcing sleep")
                self.isPTTProcessing = false
                self.setMode(.sleep)
            }
        }
    }

    /// Cancel pending PTT sleep (e.g., if PTT is pressed again)
    func cancelPendingPTTSleep() {
        if isPTTProcessing {
            logDebug("PTT: Cancelling pending sleep")
            isPTTProcessing = false
            pttSleepTimeoutTask?.cancel()
            pttSleepTimeoutTask = nil
        }
    }

    /// Called when PTT key is pressed - records the stream-relative timestamp
    func recordPTTPress() {
        isPTTActive = true
        if let startTime = streamStartTime {
            pttPressStreamTime = Date().timeIntervalSince(startTime)
            pttReleaseStreamTime = nil  // Clear release time from previous PTT
            logDebug("PTT: Press recorded at stream time \(String(format: "%.2f", pttPressStreamTime!))s")
        } else {
            logDebug("PTT: Press recorded (no stream start time yet)")
            pttPressStreamTime = nil
        }
    }

    /// Called when PTT key is released - records the stream-relative timestamp
    func recordPTTRelease() {
        isPTTActive = false
        if let startTime = streamStartTime {
            pttReleaseStreamTime = Date().timeIntervalSince(startTime)
            logDebug("PTT: Release recorded at stream time \(String(format: "%.2f", pttReleaseStreamTime!))s")
        } else {
            logDebug("PTT: Release recorded (no stream start time)")
        }
    }

    /// Filter words to exclude pre-press background speech
    /// Only filters out words that started before PTT was pressed
    /// Does NOT filter by release time - the graceful sleep mechanism handles capturing all speech
    private func filterWordsForPTT(_ words: [TranscriptWord]) -> [TranscriptWord] {
        // Only filter if PTT was pressed and we have a press timestamp
        guard let pressTime = pttPressStreamTime else {
            return words
        }

        // Don't filter while PTT is actively held - only filter completed PTT sessions
        // This prevents filtering interim words while user is still speaking
        guard !isPTTActive else {
            return words
        }

        var excludedCount = 0
        let filtered = words.filter { word in
            // If word has no timing info, include it (can't filter)
            guard let wordStart = word.startTime else { return true }

            // Filter out words that started before PTT was pressed
            // This excludes background speech detected before user pressed the key
            if wordStart < pressTime {
                excludedCount += 1
                return false
            }

            return true
        }

        if excludedCount > 0 {
            logDebug("PTT filter: Excluded \(excludedCount) pre-press words (press time: \(String(format: "%.2f", pressTime))s)")
        }

        return filtered
    }

    /// Reset PTT timestamps (called when stream restarts or mode changes)
    private func resetPTTTimestamps() {
        pttPressStreamTime = nil
        pttReleaseStreamTime = nil
        isPTTActive = false
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

    func shortcut(for mode: MicrophoneMode) -> KeyboardShortcut {
        switch mode {
        case .off: return modeOffShortcut
        case .sleep: return modeSleepShortcut
        case .on: return modeOnShortcut
        }
    }

    func shortcutString(for mode: MicrophoneMode) -> String? {
        shortcutString(for: shortcut(for: mode))
    }

    func shortcutString(for shortcut: KeyboardShortcut) -> String? {
        shortcut.isEmpty ? nil : shortcut.description
    }

    func shortcutString(for shortcut: KeyboardShortcut?) -> String? {
        guard let shortcut else { return nil }
        return shortcutString(for: shortcut)
    }

    private func flushDictationBuffer(isForceEnd: Bool) {
        logDebug("flushDictationBuffer called: transcript=\"\(currentTranscript.prefix(50))\", mode=\(microphoneMode.rawValue), isForceEnd=\(isForceEnd)")

        // If buffer is empty but force end requested, try to use preserved Sleep mode transcript or last utterance
        if currentTranscript.isEmpty {
            if isForceEnd {
                // First, try to use the preserved Sleep mode transcript
                if !lastSleepModeTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logDebug("flushDictationBuffer: buffer empty, using preserved Sleep mode transcript: \"\(lastSleepModeTranscript.prefix(50))\"")
                    typeText(lastSleepModeTranscript, appendSpace: true)
                    lastSleepModeTranscript = ""
                    return
                }

                // Find the most complete utterance - history may have partials
                // Look through recent non-command entries and find the longest one
                // that's part of the same "utterance group" (similar prefix)
                let recentUtterances = dictationHistory.prefix(20).filter { !$0.hasPrefix("[Command]") }

                if let firstUtterance = recentUtterances.first {
                    // Find the longest version among similar entries
                    var longestUtterance = firstUtterance
                    for utterance in recentUtterances.dropFirst() {
                        // Stop if we hit something that's clearly a different utterance
                        // (doesn't share a common prefix with our candidate)
                        let shorter = min(utterance.count, longestUtterance.count)
                        let commonPrefix = String(utterance.prefix(shorter / 2))
                        if !longestUtterance.hasPrefix(commonPrefix) && !utterance.hasPrefix(commonPrefix) {
                            break
                        }
                        // Use the longer one if they seem related
                        if utterance.count > longestUtterance.count && longestUtterance.hasPrefix(String(utterance.prefix(longestUtterance.count))) {
                            longestUtterance = utterance
                        } else if longestUtterance.hasPrefix(String(utterance.prefix(utterance.count / 2))) && utterance.count > longestUtterance.count {
                            longestUtterance = utterance
                        }
                    }
                    logDebug("flushDictationBuffer: buffer empty, resending utterance: \"\(longestUtterance.prefix(50))\" (found longest among \(recentUtterances.count) recent)")
                    typeText(longestUtterance, appendSpace: true)
                    return
                }
            }
            logDebug("flushDictationBuffer: skipped - transcript is empty and no last utterance")
            return
        }
        // Force send works in any mode when explicitly requested
        guard microphoneMode == .on || isForceEnd else {
            logDebug("flushDictationBuffer: skipped - mode is \(microphoneMode.rawValue), not on")
            return
        }
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

    // MARK: - Improve Selected Text

    /// Improve selected text using AI - copies, improves, and pastes back
    /// Triggered by "improve that" voice command
    func improveSelectedText() {
        logDebug("Improve: Starting text improvement")
        triggerCommandFlash(name: "Improving...")

        // 1. Copy selected text (Cmd+C)
        executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command]))

        // 2. Wait for clipboard to update, then read and improve
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            // Read from clipboard
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.logDebug("Improve: No text selected or clipboard empty")
                self.triggerCommandFlash(name: "No Selection")
                return
            }

            self.logDebug("Improve: Got text \"\(text.prefix(30))...\"")

            // 3. Call AI to improve
            Task { @MainActor in
                let improved = await self.aiFormatterService.improve(text)

                if improved == text {
                    self.logDebug("Improve: No changes made")
                    self.triggerCommandFlash(name: "No Changes")
                    return
                }

                self.logDebug("Improve: Text improved, pasting")

                // 4. Write improved text to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(improved, forType: .string)

                // 5. Paste (Cmd+V)
                self.executeKeyboardShortcut(KeyboardShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command]))

                self.triggerCommandFlash(name: "Improved")
            }
        }
    }

    /// Create a VoiceFlow issue from recent dictation using beads
    func createVoiceFlowIssue() {
        // Find the latest non-command dictation to use as issue context
        let latestDictation = dictationHistory.first(where: { !$0.hasPrefix("[Command]") })

        logDebug("VoiceFlow Issue: Creating issue from dictation")

        // Use latest dictation as title, or generic title
        let title: String
        if let dictation = latestDictation, !dictation.isEmpty {
            // Truncate to reasonable length for title
            title = String(dictation.prefix(100))
        } else {
            title = "New issue from voice command"
        }

        // Create issue directly (faster, more reliable than via Claude)
        createBeadsIssue(title: title, projectPath: "~/code/VoiceFlow")
        triggerCommandFlash(name: "VoiceFlow Issue")
    }

    // MARK: - Command Panel (Claude Code)

    /// Open the command panel and start Claude Code service
    func openCommandPanel() {
        guard !isCommandPanelVisible else { return }
        isCommandPanelVisible = true

        // Start Claude Code service if needed
        if claudeCodeService == nil {
            claudeCodeService = ClaudeCodeService(
                workingDirectory: commandWorkingDirectory,
                model: claudeModel.cliFlag
            )
            // Restore last session ID for context continuity
            if let savedSessionId = UserDefaults.standard.string(forKey: "claude_session_id") {
                claudeCodeService?.sessionId = savedSessionId
                NSLog("[VoiceFlow] Restored session ID: \(savedSessionId)")
            }
            setupClaudeCodeEventHandler()
        }
        claudeCodeService?.start()

        // Post notification for AppDelegate to show window
        NotificationCenter.default.post(
            name: NSNotification.Name("CommandPanelShouldOpen"),
            object: nil
        )
    }

    /// Close the command panel
    func closeCommandPanel() {
        guard isCommandPanelVisible else { return }
        isCommandPanelVisible = false
        claudeCodeService?.stop()

        // Post notification for AppDelegate to hide window
        NotificationCenter.default.post(
            name: NSNotification.Name("CommandPanelShouldClose"),
            object: nil
        )
    }

    /// Toggle the command panel
    func toggleCommandPanel() {
        if isCommandPanelVisible {
            closeCommandPanel()
        } else {
            openCommandPanel()
        }
    }

    // MARK: - Session Management

    /// Start a new Claude session
    func startNewClaudeSession() {
        // Save current session before starting new one
        saveCurrentSession()

        // Clear for new session
        claudeCodeService?.clearSession()
        currentSessionId = nil
        commandMessages = []
        NSLog("[VoiceFlow] New Claude session started")
    }

    /// Switch to a different session
    func switchToSession(_ session: ClaudeSession) {
        // Save current session first
        saveCurrentSession()

        // Load the selected session
        currentSessionId = session.id
        claudeCodeService?.sessionId = session.id
        commandMessages = session.chatHistory

        // Update last used time
        if let index = claudeSessions.firstIndex(where: { $0.id == session.id }) {
            claudeSessions[index].lastUsedAt = Date()
            saveSessions()
        }

        NSLog("[VoiceFlow] Switched to session: \(session.name)")
    }

    /// Save the current session state
    func saveCurrentSession() {
        guard let sessionId = currentSessionId ?? claudeCodeService?.sessionId,
              !commandMessages.isEmpty else { return }

        if let index = claudeSessions.firstIndex(where: { $0.id == sessionId }) {
            // Update existing session
            claudeSessions[index].chatHistory = commandMessages
            claudeSessions[index].lastUsedAt = Date()
        } else {
            // Create new session entry
            let firstUserMessage = commandMessages.first(where: { $0.role == .user })?.content ?? "New conversation"
            var newSession = ClaudeSession.create(id: sessionId, firstMessage: firstUserMessage)
            newSession.chatHistory = commandMessages
            claudeSessions.insert(newSession, at: 0)  // Most recent first
        }

        currentSessionId = sessionId
        saveSessions()
    }

    /// Save sessions to UserDefaults
    private func saveSessions() {
        if let data = try? JSONEncoder().encode(claudeSessions) {
            UserDefaults.standard.set(data, forKey: "claude_sessions")
        }
    }

    /// Load sessions from UserDefaults
    func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: "claude_sessions"),
           let sessions = try? JSONDecoder().decode([ClaudeSession].self, from: data) {
            claudeSessions = sessions
            NSLog("[VoiceFlow] Loaded \(sessions.count) sessions")
        }

        // Also restore current session ID
        if let savedId = UserDefaults.standard.string(forKey: "claude_session_id") {
            currentSessionId = savedId
            // Load chat history for current session
            if let session = claudeSessions.first(where: { $0.id == savedId }) {
                commandMessages = session.chatHistory
            }
        }
    }

    /// Get the current session (if any)
    var currentSession: ClaudeSession? {
        guard let id = currentSessionId else { return nil }
        return claudeSessions.first(where: { $0.id == id })
    }

    /// Create a beads issue in a specific project directory
    /// - Parameters:
    ///   - title: The issue title/description
    ///   - projectPath: Path to the project (e.g., "~/code/VoiceFlow")
    ///   - type: Issue type (default: "task")
    ///   - priority: Priority 0-4 (default: 2)
    func createBeadsIssue(title: String, projectPath: String, type: String = "task", priority: Int = 2) {
        let expandedPath = (projectPath as NSString).expandingTildeInPath

        // Build the bd create command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bd")
        process.arguments = ["create", "--title=\(title)", "--type=\(type)", "--priority=\(priority)"]
        process.currentDirectoryURL = URL(fileURLWithPath: expandedPath)

        // Inherit environment for PATH
        var env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()
        let additionalPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.local/bin"
        ]
        if let existingPath = env["PATH"] {
            env["PATH"] = additionalPaths.joined(separator: ":") + ":" + existingPath
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                NSLog("[VoiceFlow] Beads issue created: %@", stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                // Add to command messages for visibility
                let successMsg = "✅ Created issue: \(title)\n\(stdout)"
                DispatchQueue.main.async { [weak self] in
                    self?.commandMessages.append(CommandMessage(role: .assistant, content: successMsg, isComplete: true))
                }
            } else {
                NSLog("[VoiceFlow] Beads error: %@", stderr)
                DispatchQueue.main.async { [weak self] in
                    self?.commandError = "Failed to create issue: \(stderr)"
                }
            }
        } catch {
            NSLog("[VoiceFlow] Failed to run bd: %@", error.localizedDescription)
            DispatchQueue.main.async { [weak self] in
                self?.commandError = "Failed to run bd: \(error.localizedDescription)"
            }
        }
    }

    /// Execute an inline command (no panel needed for simple commands)
    func executeInlineCommand(_ text: String) {
        // Queue message if already processing
        if isClaudeProcessing {
            commandMessageQueue.append(text)
            NSLog("[ClaudeCode] Queued message (queue size: \(commandMessageQueue.count))")
            return
        }

        sendCommandMessage(text)
    }

    /// Internal: Actually send a command message (not queued)
    private func sendCommandMessage(_ text: String) {
        // Clear any previous error when sending new message
        commandError = nil

        // Ensure service is running
        if claudeCodeService == nil {
            claudeCodeService = ClaudeCodeService(
                workingDirectory: commandWorkingDirectory,
                model: claudeModel.cliFlag
            )
            // Restore last session ID for context continuity
            if let savedSessionId = UserDefaults.standard.string(forKey: "claude_session_id") {
                claudeCodeService?.sessionId = savedSessionId
                NSLog("[VoiceFlow] Restored session ID: \(savedSessionId)")
            }
            setupClaudeCodeEventHandler()
        }

        // Add user message to history
        commandMessages.append(CommandMessage.user(text))

        // Create placeholder for response
        let assistantMessage = CommandMessage.assistant()
        commandMessages.append(assistantMessage)
        inlineCommandResponse = assistantMessage
        showInlineResponse = true

        // Send to Claude (uses --resume for context continuity)
        claudeCodeService?.send(text)
    }

    /// Process next message in queue if any
    private func processCommandQueue() {
        guard !commandMessageQueue.isEmpty else { return }
        let nextMessage = commandMessageQueue.removeFirst()
        NSLog("[ClaudeCode] Processing queued message (remaining: \(commandMessageQueue.count))")
        sendCommandMessage(nextMessage)
    }

    private func setupClaudeCodeEventHandler() {
        claudeCodeService?.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleClaudeEvent(event)
            }
        }
        claudeCodeService?.onDebugLog = { [weak self] logEntry in
            Task { @MainActor [weak self] in
                self?.claudeDebugLog.append(logEntry)
                // Keep only last 200 entries
                if self?.claudeDebugLog.count ?? 0 > 200 {
                    self?.claudeDebugLog.removeFirst()
                }
            }
        }
    }

    // DIAGNOSTIC VoiceFlow-ab1z: Track event handling for CPU spin debugging
    private var claudeEventCount: Int = 0
    private var lastClaudeEventTime: Date?

    private func handleClaudeEvent(_ event: ClaudeCodeService.ClaudeEvent) {
        // DIAGNOSTIC: Track event frequency (investigating CPU spin VoiceFlow-ab1z)
        claudeEventCount += 1
        let now = Date()
        if let lastTime = lastClaudeEventTime {
            let interval = now.timeIntervalSince(lastTime)
            // Log if events are coming extremely fast (potential spin indicator)
            if interval < 0.001 {
                NSLog("[VoiceFlow] ⚠️ RAPID EVENTS: %d events, interval %.4fs - potential spin!", claudeEventCount, interval)
            }
        }
        lastClaudeEventTime = now

        switch event {
        case .connected:
            NSLog("[VoiceFlow] 🔌 Claude connected")
            isClaudeConnected = true
            commandError = nil

        case .disconnected(let error):
            NSLog("[VoiceFlow] 🔌 Claude disconnected (error: \(error?.localizedDescription ?? "none"))")
            isClaudeConnected = false
            if let error = error {
                commandError = error.localizedDescription
            }

        case .textChunk(let text):
            // Append to the last assistant message
            if let lastIndex = commandMessages.lastIndex(where: { $0.role == .assistant }) {
                commandMessages[lastIndex].content += text
                // Also update inline response if showing
                if showInlineResponse {
                    inlineCommandResponse?.content += text
                }
            }

        case .textComplete(let text):
            NSLog("[VoiceFlow] ✅ textComplete: %d chars", text.count)
            // Set the complete text on the last assistant message
            if let lastIndex = commandMessages.lastIndex(where: { $0.role == .assistant }) {
                commandMessages[lastIndex].content = text
                commandMessages[lastIndex].isStreaming = false
                commandMessages[lastIndex].isComplete = true
            }

        case .toolUseStart(_, let name, let input):
            NSLog("[VoiceFlow] 🔧 Tool start: \(name)")
            // Add tool use to the last assistant message
            if let lastIndex = commandMessages.lastIndex(where: { $0.role == .assistant }) {
                let toolUse = CommandToolUse(toolName: name, input: input)
                commandMessages[lastIndex].toolUses.append(toolUse)
            }

        case .toolUseEnd(_, let output):
            NSLog("[VoiceFlow] 🔧 Tool end")
            // Update tool use with output
            if let lastIndex = commandMessages.lastIndex(where: { $0.role == .assistant }) {
                if var lastToolUse = commandMessages[lastIndex].toolUses.last {
                    lastToolUse.output = output
                    lastToolUse.endTime = Date()
                    let toolIndex = commandMessages[lastIndex].toolUses.count - 1
                    commandMessages[lastIndex].toolUses[toolIndex] = lastToolUse
                }
            }

        case .messageComplete:
            NSLog("[VoiceFlow] ✅ messageComplete - setting isClaudeProcessing=false")
            isClaudeProcessing = false
            // Mark the last assistant message as complete
            if let lastIndex = commandMessages.lastIndex(where: { $0.role == .assistant }) {
                commandMessages[lastIndex].isStreaming = false
                commandMessages[lastIndex].isComplete = true
            }
            // Process any queued messages
            NSLog("[VoiceFlow] ✅ Calling processCommandQueue...")
            processCommandQueue()
            NSLog("[VoiceFlow] ✅ processCommandQueue returned")

        case .sessionId(let sessionId):
            // Update current session and persist
            currentSessionId = sessionId
            UserDefaults.standard.set(sessionId, forKey: "claude_session_id")
            // Save session with chat history
            saveCurrentSession()
            NSLog("[VoiceFlow] Session ID saved: \(sessionId)")

        case .error(let errorMsg):
            NSLog("[VoiceFlow] ❌ Claude error: \(errorMsg)")
            commandError = errorMsg
            isClaudeProcessing = false
            // Process any queued messages even after error
            processCommandQueue()
        }
        NSLog("[VoiceFlow] 📊 Event handled (count: \(claudeEventCount))")
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
