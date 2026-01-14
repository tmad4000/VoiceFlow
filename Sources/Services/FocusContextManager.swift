import Foundation
import AppKit

/// Manages focus-based context segmentation for AI formatting
/// Tracks which app is focused and segments transcript history accordingly
@MainActor
class FocusContextManager: ObservableObject {

    // MARK: - Types

    struct FocusSegment {
        let appName: String?
        let bundleId: String?
        let windowTitle: String?
        let startTime: Date
        var utterances: [String] = []

        var isTerminal: Bool {
            bundleId == "com.apple.Terminal" ||
            bundleId == "com.googlecode.iterm2" ||
            bundleId == "io.alacritty" ||
            bundleId == "com.github.wez.wezterm" ||
            appName?.lowercased().contains("terminal") == true ||
            appName?.lowercased().contains("gemini") == true
        }

        var isCodeEditor: Bool {
            bundleId == "com.microsoft.VSCode" ||
            bundleId == "com.sublimetext.4" ||
            bundleId == "com.jetbrains.intellij" ||
            bundleId?.contains("Xcode") == true ||
            appName?.lowercased().contains("code") == true
        }

        var isChat: Bool {
            bundleId == "com.tinyspeck.slackmacgap" ||
            bundleId == "com.apple.MobileSMS" ||
            bundleId == "us.zoom.xos" ||
            bundleId == "com.hnc.Discord" ||
            appName?.lowercased().contains("slack") == true ||
            appName?.lowercased().contains("messages") == true
        }

        var isBrowser: Bool {
            bundleId == "com.apple.Safari" ||
            bundleId == "com.google.Chrome" ||
            bundleId == "org.mozilla.firefox" ||
            bundleId == "com.microsoft.edgemac" ||
            bundleId == "com.brave.Browser" ||
            bundleId == "company.thebrowser.Browser" ||  // Arc
            appName?.lowercased().contains("safari") == true ||
            appName?.lowercased().contains("chrome") == true ||
            appName?.lowercased().contains("firefox") == true
        }

        /// Apps that need slower keystroke injection (web-based apps with complex input handling)
        var needsSlowTyping: Bool {
            isBrowser  // All browsers need slower typing for web apps like Google Docs
        }

        var appCategory: AppCategory {
            if isTerminal { return .terminal }
            if isCodeEditor { return .codeEditor }
            if isChat { return .chat }
            return .document
        }
    }

    enum AppCategory: String {
        case terminal = "terminal"
        case codeEditor = "code"
        case chat = "chat"
        case document = "document"

        var formattingStyle: String {
            switch self {
            case .terminal: return "lowercase, minimal punctuation, command-style"
            case .codeEditor: return "context-dependent case, minimal punctuation"
            case .chat: return "casual, optional periods, conversational"
            case .document: return "sentence case, full punctuation, formal"
            }
        }
    }

    // MARK: - Properties

    @Published private(set) var currentSegment: FocusSegment?
    @Published private(set) var segmentHistory: [FocusSegment] = []

    private var workspaceObserver: Any?

    // Keep last N utterances per segment for context
    private let maxUtterancesPerSegment = 10

    // MARK: - Initialization

    init() {
        setupFocusObserver()
        captureCurrentFocus()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Focus Tracking

    private func setupFocusObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAppActivation(notification)
            }
        }
    }

    private func captureCurrentFocus() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        startNewSegment(for: frontApp)
    }

    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        // Don't start new segment if it's the same app
        if app.bundleIdentifier == currentSegment?.bundleId {
            return
        }

        // Save current segment to history before starting new one
        if let current = currentSegment {
            segmentHistory.append(current)
            // Keep only last 5 segments
            if segmentHistory.count > 5 {
                segmentHistory.removeFirst()
            }
        }

        startNewSegment(for: app)
    }

    private func startNewSegment(for app: NSRunningApplication) {
        currentSegment = FocusSegment(
            appName: app.localizedName,
            bundleId: app.bundleIdentifier,
            windowTitle: nil, // Would need accessibility for window title
            startTime: Date()
        )

        NSLog("[FocusContext] New segment: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? ""))")
    }

    // MARK: - Utterance Tracking

    /// Add an utterance to the current segment
    func addUtterance(_ text: String) {
        guard !text.isEmpty else { return }

        currentSegment?.utterances.append(text)

        // Trim to max
        if let count = currentSegment?.utterances.count, count > maxUtterancesPerSegment {
            currentSegment?.utterances.removeFirst()
        }
    }

    // MARK: - Context for AI Formatter

    struct FormattingContext {
        let appName: String?
        let bundleId: String?
        let appCategory: AppCategory
        let formattingStyle: String
        let recentUtterances: [String]
        let previousEnding: String?
        let isNewSegment: Bool
        let segmentDurationSeconds: TimeInterval
    }

    /// Get the current context for AI formatting decisions
    func getFormattingContext() -> FormattingContext {
        guard let segment = currentSegment else {
            return FormattingContext(
                appName: nil,
                bundleId: nil,
                appCategory: .document,
                formattingStyle: AppCategory.document.formattingStyle,
                recentUtterances: [],
                previousEnding: nil,
                isNewSegment: true,
                segmentDurationSeconds: 0
            )
        }

        let previousEnding: String?
        if let lastUtterance = segment.utterances.last {
            previousEnding = String(lastUtterance.suffix(20))
        } else {
            previousEnding = nil
        }

        return FormattingContext(
            appName: segment.appName,
            bundleId: segment.bundleId,
            appCategory: segment.appCategory,
            formattingStyle: segment.appCategory.formattingStyle,
            recentUtterances: segment.utterances,
            previousEnding: previousEnding,
            isNewSegment: segment.utterances.isEmpty,
            segmentDurationSeconds: Date().timeIntervalSince(segment.startTime)
        )
    }

    /// Clear all segments (e.g., when turning off)
    func clearHistory() {
        segmentHistory.removeAll()
        currentSegment?.utterances.removeAll()
    }

    /// Check if current app needs slower keystroke injection
    /// Returns true for browsers (Google Docs, etc.) and other apps with complex input handling
    func currentAppNeedsSlowTyping() -> Bool {
        return currentSegment?.needsSlowTyping ?? false
    }

    /// Get recommended inter-character delay for current app
    /// Returns 0 for most apps, small delay for browsers/complex apps
    func getInterCharacterDelay() -> TimeInterval {
        if currentSegment?.needsSlowTyping == true {
            return 0.003  // 3ms delay between characters for browsers
        }
        return 0  // No delay for native apps
    }

    /// Check if current focused app is a terminal/CLI
    /// Used to apply longer Enter key delay for terminal UIs
    func isCurrentAppTerminal() -> Bool {
        return currentSegment?.isTerminal ?? false
    }
}
