import AppKit

final class PTTPreviewWindow: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
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
