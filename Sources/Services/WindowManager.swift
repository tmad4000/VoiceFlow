import AppKit
import os.log

private let logger = Logger(subsystem: "com.voiceflow", category: "WindowManager")

enum FocusMatchType {
    case exact
    case prefix
    case contains
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
        "messages app": "messages"
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
        var lowerQuery = normalizeQuery(query)
        if let alias = focusAliases[lowerQuery] {
            lowerQuery = alias
        }
        guard !lowerQuery.isEmpty else {
            logger.warning("Focus requested with empty query")
            return .emptyQuery
        }
        
        // 1. Try exact match
        if let exactMatch = apps.first(where: { normalizeQuery($0.localizedName ?? "") == lowerQuery }) {
            exactMatch.activate()
            return .focused(appName: exactMatch.localizedName ?? query, matchType: .exact)
        }
        
        // 2. Try prefix match
        if let prefixMatch = apps.first(where: { normalizeQuery($0.localizedName ?? "").hasPrefix(lowerQuery) }) {
            prefixMatch.activate()
            return .focused(appName: prefixMatch.localizedName ?? query, matchType: .prefix)
        }
        
        // 3. Try contains match
        if let containsMatch = apps.first(where: { normalizeQuery($0.localizedName ?? "").contains(lowerQuery) }) {
            containsMatch.activate()
            return .focused(appName: containsMatch.localizedName ?? query, matchType: .contains)
        }
        
        logger.warning("No running app found matching: \(query)")
        return .notFound(query: query)
    }
}
