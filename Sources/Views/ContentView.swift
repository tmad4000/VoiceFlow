import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.effectiveIsOffline {
                HStack {
                    Image(systemName: appState.isOffline ? "wifi.slash" : "internaldrive")
                    Text(appState.isOffline ? "Offline: Using Mac Speech Recognition" : "Offline Mode: Using Mac Speech Recognition")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.8))
                .foregroundColor(.white)
            }

            // Header with mode controls
            ModeControlBar()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Main transcript area
            TranscriptView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar
            StatusBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct ModeControlBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text("VoiceFlow")
                .font(.headline)
                .foregroundColor(.secondary)

            Spacer()

            // Mode toggle buttons
            ForEach(MicrophoneMode.allCases) { mode in
                ModeButton(mode: mode, isSelected: appState.microphoneMode == mode) {
                    appState.setMode(mode)
                }
            }
        }
    }
}

struct ModeButton: View {
    @EnvironmentObject var appState: AppState
    let mode: MicrophoneMode
    let isSelected: Bool
    var compact: Bool = false
    var plain: Bool = false
    let action: () -> Void

    var backgroundColor: Color {
        guard isSelected && !plain else { return Color.clear }
        switch mode {
        case .off: return Color.gray.opacity(0.3)
        case .on: return Color.green.opacity(0.3)
        case .sleep: return Color.orange.opacity(0.3)
        }
    }

    var iconColor: Color {
        switch mode {
        case .off: return isSelected ? .gray : .secondary
        case .on: return isSelected ? .green : .secondary
        case .sleep: return isSelected ? .orange : .secondary
        }
    }

    var labelText: String {
        return mode.rawValue
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: compact ? 10 : 13, weight: .semibold))
                
                Text(labelText)
                    .font(.system(size: compact ? 10 : 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if mode == .on {
                    Image(systemName: appState.activeBehavior.icon)
                        .font(.system(size: compact ? 8 : 11, weight: .bold))
                        .foregroundColor(iconColor.opacity(isSelected ? 0.8 : 0.4))
                }
            }
            .foregroundColor(iconColor)
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .background(backgroundColor)
            .cornerRadius(compact ? 6 : 8)
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 6 : 8)
                    .stroke(isSelected && !plain ? iconColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: compact ? 6 : 8))
        }
        .buttonStyle(.plain)
        .help(mode.description)
    }
}

struct TranscriptView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if appState.currentTranscript.isEmpty {
                    PlaceholderView()
                } else {
                    Text(appState.currentTranscript)
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }
}

struct PlaceholderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: appState.microphoneMode.icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text(placeholderText)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var placeholderText: String {
        switch appState.microphoneMode {
        case .off:
            return "Microphone is off\nClick \"On\" to start dictating or \"Sleep\" for voice commands"
        case .on:
            if appState.apiKey.isEmpty {
                return "Please add your AssemblyAI API key in Settings (⌘,)"
            }
            return appState.isConnected
                ? "Listening... Start speaking"
                : "Connecting to AssemblyAI..."
        case .sleep:
            if appState.apiKey.isEmpty {
                return "Please add your AssemblyAI API key in Settings (⌘,)"
            }
            return appState.isConnected
                ? "Listening for 'Wake up'...\nSay \"microphone on\" to start dictating"
                : "Connecting to AssemblyAI..."
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Error message
            if let error = appState.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    var statusColor: Color {
        if appState.effectiveIsOffline && appState.microphoneMode != .off {
            return .orange
        }
        switch appState.microphoneMode {
        case .off: return .gray
        case .on, .sleep: return appState.isConnected ? .green : .orange
        }
    }

    var statusText: String {
        if appState.effectiveIsOffline && appState.microphoneMode != .off {
            return "Offline (Mac Speech)"
        }
        switch appState.microphoneMode {
        case .off: return "Microphone off"
        case .on: return appState.isConnected ? "Transcribing" : "Connecting..."
        case .sleep: return appState.isConnected ? "Listening for 'Wake up'" : "Connecting..."
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
