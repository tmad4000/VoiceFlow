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
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                ModeSelectionView()

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
                        .help("Force send current dictation")
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
            .padding(.top, 4)
            .padding(.bottom, 8)

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
    }

    private var onModePill: some View {
        let isSelected = appState.microphoneMode == .on
        return HStack(spacing: 0) {
            ModeButton(mode: .on, isSelected: isSelected, compact: true) {
                appState.setMode(.on)
            }
            
            if isSelected {
                Divider()
                    .frame(height: 12)
                    .background(Color.green.opacity(0.3))
                
                Menu {
                    ForEach(ActiveBehavior.allCases) { behavior in
                        Button {
                            appState.saveActiveBehavior(behavior)
                        } label: {
                            HStack {
                                Text(behavior.rawValue)
                                Spacer()
                                Image(systemName: behavior.icon)
                                if appState.activeBehavior == behavior {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Color.green.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
            }
        }
        .background(isSelected ? Color.green.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
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
