import AppKit

final class FloatingPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        false  // Don't steal focus from user's text fields
    }

    override var canBecomeMain: Bool {
        false  // Utility panel, not main window
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var newFrame = frameRect
        
        // If height changes, anchor to the top edge (maxY)
        // This prevents the window from growing upwards and pushing the header off-screen
        if frameRect.height != self.frame.height {
            let currentTop = self.frame.maxY
            newFrame.origin.y = currentTop - frameRect.height
        }
        
        super.setFrame(newFrame, display: flag)
    }
}

final class FirstMouseContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
