import AppKit

/// Window container for the Notes panel
final class NotesPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        true  // Needs to be key for search/interaction
    }

    override var canBecomeMain: Bool {
        false  // Don't become main app window
    }

    /// Handle Escape key to close panel
    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
        // Notify AppState that panel was closed
        NotificationCenter.default.post(
            name: NSNotification.Name("NotesPanelDidClose"),
            object: nil
        )
    }
}
