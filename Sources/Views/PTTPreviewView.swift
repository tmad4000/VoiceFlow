import SwiftUI

struct PTTPreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var pulse = false

    private var previewText: String {
        let live = appState.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let buffered = appState.pttBufferedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if buffered.isEmpty { return live }
        if live.isEmpty { return buffered }
        if buffered.hasSuffix(live) { return buffered }
        return buffered + " " + live
    }

    private var footerText: String {
        if appState.isPTTProcessing {
            return "Finalizing..."
        }
        return appState.isPTTSticky ? "Press PTT again to send" : "Release to finish"
    }

    private var titleText: String {
        appState.isPTTSticky ? "Dictation (Sticky)" : "Dictation"
    }

    private var indicatorColor: Color {
        appState.isPTTProcessing ? Color.orange : Color.green
    }

    private var levelScale: CGFloat {
        let amplified = min(1.0, Double(appState.audioLevel) * 5.0)
        return 0.5 + CGFloat(amplified) * 0.7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(indicatorColor.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Circle()
                        .stroke(indicatorColor.opacity(0.4), lineWidth: 2)
                        .scaleEffect(pulse ? 1.7 : 0.9)
                        .opacity(pulse ? 0.0 : 1.0)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 8, height: 8)
                        .scaleEffect(levelScale)
                        .animation(.easeInOut(duration: 0.08), value: levelScale)
                }

                Text(titleText)
                    .font(.headline)
                    .foregroundColor(.secondary)

                if appState.isPTTProcessing {
                    PTTProcessingWaveView()
                }

                Spacer()

                if appState.isPTTSticky {
                    Text("Sticky")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                }
            }

            ScrollView(showsIndicators: false) {
                Text(previewText.isEmpty ? "Listening..." : previewText)
                    .font(.system(size: 15))
                    .foregroundColor(previewText.isEmpty ? .secondary : .primary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            Divider().opacity(0.2)

            Text(footerText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 8)
        .frame(minWidth: 600, maxWidth: 760, alignment: .leading)
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
    }
}

#Preview {
    PTTPreviewView()
        .environmentObject(AppState())
}
