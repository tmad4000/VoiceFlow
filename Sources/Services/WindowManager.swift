import AppKit
import os.log

private let logger = Logger(subsystem: "com.voiceflow", category: "WindowManager")

enum FocusMatchType {
    case exact
    case prefix
    case contains
    case windowTitle  // Matched by window title (e.g., terminal window)
}

enum FocusResult {
    case focused(appName: String, matchType: FocusMatchType)
    case notFound(query: String)
    case emptyQuery
}

class WindowManager: ObservableObject {
    private var appHistory: [NSRunningApplication] = []
    private let maxHistory = 10

    private let focusAliases: [String: String] = [
        "imessage": "messages",
        "i message": "messages",
        "message": "messages",
        "messages app": "messages",
        "one password": "1password",
        "onepassword": "1password"
    ]
    
    init() {
        setupNotifications()
        // Initial state
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            addToHistory(frontApp)
        }
    }
    
    private func setupNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        // Don't track ourselves
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.addToHistory(app)
        }
    }
    
    private func addToHistory(_ app: NSRunningApplication) {
        // Remove if already in list to move to front
        appHistory.removeAll { $0.processIdentifier == app.processIdentifier }
        
        appHistory.insert(app, at: 0)
        
        if appHistory.count > maxHistory {
            appHistory.removeLast()
        }
        
        let historyNames = appHistory.compactMap { $0.localizedName }
        logger.debug("App history: \(historyNames.joined(separator: " -> "))")
    }
    
    func switchToRecent(index: Int) {
        // index 0 is current frontmost app (usually)
        // index 1 is previous
        // index 2 is one before that
        
        guard index < appHistory.count else {
            logger.warning("Requested index \(index) out of history range (\(self.appHistory.count))")
            return
        }
        
        let targetApp = appHistory[index]
        logger.info("Switching to recent app at index \(index): \(targetApp.localizedName ?? "unknown")")
        
        // Activate the target application
        targetApp.activate()
    }
    
    private func normalizeQuery(_ text: String) -> String {
        let lower = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = lower.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let collapsed = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func focusApp(named query: String) -> FocusResult {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var normalizedQuery = normalizeQuery(query)
        if let alias = focusAliases[normalizedQuery] {
            normalizedQuery = alias
        }
        guard !normalizedQuery.isEmpty else {
            logger.warning("Focus requested with empty query")
            return .emptyQuery
        }
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")

        struct NormalizedApp {
            let app: NSRunningApplication
            let normalizedName: String
            let compactName: String
        }

        let normalizedApps: [NormalizedApp] = apps.map { app in
            let normalizedName = normalizeQuery(app.localizedName ?? "")
            let compactName = normalizedName.replacingOccurrences(of: " ", with: "")
            return NormalizedApp(app: app, normalizedName: normalizedName, compactName: compactName)
        }
        
        // 1. Try exact match
        if let exactMatch = normalizedApps.first(where: { $0.normalizedName == normalizedQuery }) {
            exactMatch.app.activate()
            return .focused(appName: exactMatch.app.localizedName ?? query, matchType: .exact)
        }
        
        if !compactQuery.isEmpty, let exactCompactMatch = normalizedApps.first(where: { $0.compactName == compactQuery }) {
            exactCompactMatch.app.activate()
            return .focused(appName: exactCompactMatch.app.localizedName ?? query, matchType: .exact)
        }
        
        // 2. Try prefix match
        if let prefixMatch = normalizedApps.first(where: { $0.normalizedName.hasPrefix(normalizedQuery) }) {
            prefixMatch.app.activate()
            return .focused(appName: prefixMatch.app.localizedName ?? query, matchType: .prefix)
        }
        
        if !compactQuery.isEmpty, let prefixCompactMatch = normalizedApps.first(where: { $0.compactName.hasPrefix(compactQuery) }) {
            prefixCompactMatch.app.activate()
            return .focused(appName: prefixCompactMatch.app.localizedName ?? query, matchType: .prefix)
        }
        
        // 3. Try contains match
        if let containsMatch = normalizedApps.first(where: { $0.normalizedName.contains(normalizedQuery) }) {
            containsMatch.app.activate()
            return .focused(appName: containsMatch.app.localizedName ?? query, matchType: .contains)
        }
        
        if !compactQuery.isEmpty, let containsCompactMatch = normalizedApps.first(where: { $0.compactName.contains(compactQuery) }) {
            containsCompactMatch.app.activate()
            return .focused(appName: containsCompactMatch.app.localizedName ?? query, matchType: .contains)
        }

        // 4. Try matching window titles (especially useful for terminal windows)
        if let windowMatch = focusWindowByTitle(query: normalizedQuery, compactQuery: compactQuery, apps: apps) {
            return windowMatch
        }

        logger.warning("No running app found matching: \(query)")
        return .notFound(query: query)
    }

    /// Focus a window by its title (useful for terminal windows like "VoiceFlow")
    private func focusWindowByTitle(query: String, compactQuery: String, apps: [NSRunningApplication]) -> FocusResult? {
        // Apps that commonly have meaningful window titles we want to search
        let windowTitleApps = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "io.alacritty",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "com.microsoft.VSCode",
            "com.sublimetext.4"
        ]

        for app in apps {
            guard let bundleId = app.bundleIdentifier,
                  windowTitleApps.contains(bundleId) else { continue }

            // Get windows for this app using Accessibility API
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

            guard result == .success, let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

                guard titleResult == .success, let title = titleRef as? String else { continue }

                let normalizedTitle = normalizeQuery(title)
                let compactTitle = normalizedTitle.replacingOccurrences(of: " ", with: "")

                // Check if query matches window title
                let matches = normalizedTitle.contains(query) ||
                              (!compactQuery.isEmpty && compactTitle.contains(compactQuery))

                if matches {
                    // Raise this specific window and activate the app
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    app.activate()

                    logger.info("Focused window by title: \"\(title)\" in \(app.localizedName ?? "unknown")")
                    return .focused(appName: "\(app.localizedName ?? "App"): \(title)", matchType: .windowTitle)
                }
            }
        }

        return nil
    }
}
