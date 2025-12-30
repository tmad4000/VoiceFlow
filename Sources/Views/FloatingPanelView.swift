import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingHideToast = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with mode buttons, volume indicator, and close button
            HStack(spacing: 8) {
                // ... DEV indicator ...
                if Bundle.main.bundleIdentifier?.contains("release") != true {
                    Text("DEV")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                ModeSelectionView()

                Spacer()

                // Mic volume indicator
                if appState.microphoneMode != .off {
                    MicLevelIndicator(level: appState.audioLevel)
                        .padding(.trailing, 4)

                    // Force end utterance button - appears when connected
                    if appState.isConnected {
                        Button(action: { appState.forceEndUtterance() }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Force send current dictation")
                    }
                }

                // History button
                Button(action: openHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open dictation history")

                // Settings button
                Button(action: openSettings) {
                    Image(systemName: "gear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open settings")
                
                // Close menu button
                Menu {
                    Button(action: hidePanel) {
                        Label("Hide Panel", systemImage: "minus")
                    }
                    Button(role: .destructive, action: quitApp) {
                        Label("Quit VoiceFlow", systemImage: "power")
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help("Hide or Quit")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.05))

            // Warning Banners
            VStack(spacing: 0) {
                ForEach(appState.activeWarnings) { warning in
                    WarningBanner(warning: warning)
                }
            }

            Divider()
                .padding(.horizontal, 10)

            // Transcript area - scrollable with flexible height
            ScrollView {
                TranscriptContentView()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(minHeight: 100, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if !appState.currentTranscript.isEmpty {
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(appState.currentTranscript, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .help("Copy transcript to clipboard")
                }
            }
        }
        .frame(minWidth: 360, maxWidth: 520, minHeight: 140, maxHeight: 800)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: appState.isCommandFlashActive ? 3 : 0)
                        .animation(.easeInOut(duration: 0.2), value: appState.isCommandFlashActive)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) {
            if appState.isCommandFlashActive, let commandName = appState.lastCommandName {
                Text("Command: \(commandName)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showingHideToast {
                ToastView(message: "Panel hidden. Click menu bar icon to show.")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func hidePanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showingHideToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            appState.hidePanelWindow()
        }
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    private func openHistory() {
        NotificationCenter.default.post(name: .openHistory, object: nil)
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }
}

struct WarningBanner: View {
    let warning: AppWarning
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: warning.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(warning.severity == .error ? .red : .orange)
                .font(.system(size: 12))
            
            Text(warning.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(warning.severity == .error ? Color.red.opacity(0.1) : Color.orange.opacity(0.1))
        .onTapGesture {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openHistory = Notification.Name("openHistory")
}

private struct ModeSelectionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MicrophoneMode.allCases) { mode in
                if mode == .on {
                    onModePill
                } else {
                    ModeButton(mode: mode, isSelected: appState.microphoneMode == mode, compact: true) {
                        appState.setMode(mode)
                    }
                }
            }
        }
        .fixedSize()
    }

    private var onModePill: some View {
        let isSelected = appState.microphoneMode == .on
        let color = isSelected ? Color.green : Color.secondary

        return HStack(spacing: 0) {
            ModeButton(mode: .on, isSelected: isSelected, compact: true, plain: true) {
                appState.setMode(.on)
            }
            .padding(.trailing, -4) // Pull arrow closer

            onModeMenu(color: color, isSelected: isSelected)
        }
        .fixedSize() // Ensure pill doesn't expand
        .background(isSelected ? Color.green.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func onModeMenu(color: Color, isSelected: Bool) -> some View {
        Menu {
            ForEach(ActiveBehavior.allCases) { behavior in
                Button {
                    appState.saveActiveBehavior(behavior)
                } label: {
                    Label(behavior.rawValue, systemImage: behavior.icon)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .semibold))
                .foregroundColor(color.opacity(isSelected ? 0.6 : 0.4))
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct MicLevelIndicator: View {
    let level: Float  // 0.0 to 1.0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background bar
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 3, height: 16)
            
            // Level overlay
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(width: 3, height: max(2, CGFloat(level) * 16))
        }
    }

    private var barColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .orange }
        return .green
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
        case .sleep:
            return appState.isConnected ? "Listening for 'Wake up'…" : "Connecting…"
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
