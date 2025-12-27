import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingHideToast = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with mode buttons, volume indicator, and close button
            HStack(spacing: 8) {
                // Dev indicator - shows when not running from release bundle
                if Bundle.main.bundleIdentifier?.contains("release") != true {
                    Text("DEV")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                ForEach(MicrophoneMode.allCases) { mode in
                    ModeButton(mode: mode, isSelected: appState.microphoneMode == mode) {
                        appState.setMode(mode)
                        updateMenuBarIcon(for: mode)
                    }
                }

                Spacer()

                // Mic volume indicator
                if appState.microphoneMode != .off {
                    MicLevelIndicator(level: appState.audioLevel)

                    // Force end utterance button - appears when connected
                    if appState.isConnected {
                        Button(action: { appState.forceEndUtterance() }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Send now (force end utterance)")
                    }
                }

                // Close/hide button
                Button(action: hidePanel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide panel (access from menu bar)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 10)

            // Transcript area - scrollable with max height
            ScrollView {
                TranscriptContentView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: 170)
        }
        .frame(minWidth: 360, maxWidth: 520)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Bundle.main.bundleIdentifier?.contains("release") == true ? Color.clear : Color.orange.opacity(0.5),
                    lineWidth: 2
                )
        )
        .overlay(PanelWindowConfigurator { window in
            appState.configurePanelWindow(window)
        })
        .overlay(alignment: .bottom) {
            if showingHideToast {
                ToastView(message: "Panel hidden. Click menu bar icon to show.")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func updateMenuBarIcon(for mode: MicrophoneMode) {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            let iconName: String
            switch mode {
            case .off: iconName = "mic.slash.fill"
            case .on: iconName = "mic.fill"
            case .wake: iconName = "waveform"
            }
            appDelegate.updateIcon(iconName)
        }
    }

    private func hidePanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showingHideToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let window = NSApp.windows.first(where: { $0.level == .floating }) {
                window.orderOut(nil)
            }
            // Notify AppDelegate
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.isPanelVisible = false
                appDelegate.showHideMenuItem?.title = "Show Panel"
            }
        }
    }
}

private struct MicLevelIndicator: View {
    let level: Float  // 0.0 to 1.0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: CGFloat(4 + index * 2))
            }
        }
        .frame(height: 14)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / 5.0
        if level >= threshold {
            if index >= 4 {
                return .red
            } else if index >= 3 {
                return .orange
            } else {
                return .green
            }
        } else {
            return .gray.opacity(0.3)
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
            .padding(.bottom, 8)
    }
}

private struct TranscriptContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if shouldShowWordHighlights {
            TranscriptWordsText(words: appState.currentWords)
        } else if !appState.currentTranscript.isEmpty {
            Text(appState.currentTranscript)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundColor(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(placeholderText)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
                .lineSpacing(3)
        }
    }

    private var shouldShowWordHighlights: Bool {
        appState.currentWords.contains { $0.isFinal == false }
    }

    private var placeholderText: String {
        switch appState.microphoneMode {
        case .off:
            return "Microphone off"
        case .on:
            return appState.isConnected ? "Listening…" : "Connecting…"
        case .wake:
            return appState.isConnected ? "Listening for commands…" : "Connecting…"
        }
    }
}

private struct TranscriptWordsText: View {
    let words: [TranscriptWord]

    var body: some View {
        textView
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var textView: Text {
        words.enumerated().reduce(Text("")) { partial, element in
            let word = element.element
            let prefix = element.offset == 0 ? "" : " "
            let segment = Text(prefix + word.text)
                .foregroundColor(word.isFinal == false ? .secondary : .primary)
                .italic(word.isFinal == false)
            return partial + segment
        }
    }
}

struct PanelWindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
    }
}

/// NSView that doesn't intercept mouse events
private class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Pass all clicks through
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#Preview {
    FloatingPanelView()
        .environmentObject(AppState())
}
