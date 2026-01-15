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
    
    func instantTooltip(_ text: String) -> some View {
        modifier(InstantTooltipModifier(text: text))
    }
}

struct InstantTooltipModifier: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovering = hover
                }
            }
            .overlay(alignment: .bottom) { // Default below, or logic to flip?
                if isHovering {
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.9))
                        .cornerRadius(4)
                        .fixedSize()
                        .offset(y: 24) // Shift down
                        .zIndex(1000)
                        .allowsHitTesting(false)
                        .shadow(radius: 2)
                }
            }
    }
}
