import AppKit
import os.log

private let logger = Logger(subsystem: "com.voiceflow", category: "WindowManager")

class WindowManager: ObservableObject {
    private var appHistory: [NSRunningApplication] = []
    private let maxHistory = 10
    
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
    
    func focusApp(named query: String) {
        let apps = NSWorkspace.shared.runningApplications
        let lowerQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        
        // 1. Try exact match
        if let exactMatch = apps.first(where: { $0.localizedName?.lowercased() == lowerQuery }) {
            exactMatch.activate()
            return
        }
        
        // 2. Try prefix match
        if let prefixMatch = apps.first(where: { $0.localizedName?.lowercased().hasPrefix(lowerQuery) == true }) {
            prefixMatch.activate()
            return
        }
        
        // 3. Try contains match
        if let containsMatch = apps.first(where: { $0.localizedName?.lowercased().contains(lowerQuery) == true }) {
            containsMatch.activate()
            return
        }
        
        logger.warning("No running app found matching: \(query)")
    }
}
