import AppKit

final class FloatingPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        false  // Don't steal focus from user's text fields
    }

    override var canBecomeMain: Bool {
        false  // Utility panel, not main window
    }
}

final class FirstMouseContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
