import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(MicrophoneMode.allCases) { mode in
                    ModeButton(mode: mode, isSelected: appState.microphoneMode == mode) {
                        appState.setMode(mode)
                    }
                }
            }

            Divider()
                .frame(height: 20)

            TranscriptLineView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(PanelWindowConfigurator { window in
            appState.configurePanelWindow(window)
        })
        .frame(minWidth: 360)
    }
}

private struct TranscriptLineView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !appState.currentWords.isEmpty {
            TranscriptWordsText(words: appState.currentWords)
        } else {
            Text(placeholderText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window, !context.coordinator.didConfigure {
                context.coordinator.didConfigure = true
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window, !context.coordinator.didConfigure {
                context.coordinator.didConfigure = true
                configure(window)
            }
        }
    }

    class Coordinator {
        var didConfigure = false
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
