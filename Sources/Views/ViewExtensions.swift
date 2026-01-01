import SwiftUI
import AppKit

extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }

    /// Helper to show a pointing hand cursor on hover (macOS)
    func pointerCursor() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
