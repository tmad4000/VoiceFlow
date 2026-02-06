import SwiftUI

struct PTTPreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var pulse = false
    @AppStorage("ptt_popup_minimized") private var isMinimized = false

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

    private var indicatorColor: Color {
        appState.isPTTProcessing ? Color.orange : Color.green
    }

    private var levelScale: CGFloat {
        let amplified = min(1.0, Double(appState.audioLevel) * 5.0)
        return 0.5 + CGFloat(amplified) * 0.7
    }

    var body: some View {
        Group {
            if isMinimized {
                minimizedView
            } else {
                expandedView
            }
        }
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
    }

    // MARK: - Minimized View (tiny indicator)
    private var minimizedView: some View {
        HStack(spacing: 4) {
            // Pulsing dot with audio level
            ZStack {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(levelScale)
                    .animation(.easeInOut(duration: 0.08), value: levelScale)
            }

            // Expand button
            Button(action: { isMinimized = false }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 2)
    }

    // MARK: - Expanded View (compact - just dot + text)
    private var expandedView: some View {
        HStack(alignment: .top, spacing: 8) {
            // Simple pulsing dot
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .scaleEffect(levelScale)
                .animation(.easeInOut(duration: 0.08), value: levelScale)
                .padding(.top, 4)

            // Transcript text
            Text(previewText.isEmpty ? "Listening..." : previewText)
                .font(.system(size: 13))
                .foregroundColor(previewText.isEmpty ? .secondary : .primary)
                .lineSpacing(2)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Minimize button
            Button(action: { isMinimized = true }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 3)
        .frame(width: 240)
    }
}

// MARK: - Mini Waveform View
struct MiniWaveformView: View {
    let audioLevel: Float
    let color: Color

    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3)
                    .frame(height: barHeight(for: index))
                    .animation(.easeInOut(duration: 0.1), value: audioLevel)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base = CGFloat(audioLevel) * 3.0
        let variation = sin(Double(index) * 0.8 + Double(audioLevel) * 10) * 0.3 + 0.7
        let height = max(3, min(16, base * CGFloat(variation) * 16))
        return height
    }
}

#Preview {
    PTTPreviewView()
        .environmentObject(AppState())
}
