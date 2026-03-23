import SwiftUI

struct MenuShortcutRow: View {
    let title: String
    let shortcut: String?
    let voiceCommand: String?
    var minWidth: CGFloat = 140

    var body: some View {
        if shortcut == nil && voiceCommand == nil {
            Text(title)
        } else {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                    if let voiceCommand {
                        Text(voiceCommand)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }
            }
            .frame(minWidth: minWidth)
        }
    }
}
