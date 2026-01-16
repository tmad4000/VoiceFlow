import SwiftUI
import AppKit
import AVFoundation

struct FloatingPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingHideToast = false
    @State private var autoScrollEnabled = true

    var body: some View {
        Group {
            if appState.isPanelMinimal {
                minimalPanel
            } else {
                fullPanel
            }
        }
    }

    private var minimalPanel: some View {
        HStack(spacing: 6) {
            // Compact mode buttons
            CompactModeButtons()

            // Audio pulse indicator when active
            if appState.microphoneMode != .off {
                AudioPulseIndicator(level: appState.audioLevel, mode: appState.microphoneMode)
            }

            // PTT processing indicator (waiting for finalized text)
            if appState.isPTTProcessing {
                PTTProcessingWaveView()
                    .instantTooltip("Processing speech...")
            }

            if appState.isNewerBuildAvailable {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                    .instantTooltip("New build available - Click to Restart")
                    .onTapGesture {
                        appState.restartApp()
                    }
            }

            // Expand button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.isPanelMinimal = false
                }
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .instantTooltip("Expand panel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: appState.isCommandFlashActive ? 2 : 0)
                        .animation(.easeInOut(duration: 0.2), value: appState.isCommandFlashActive)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Small padding at edges to allow window resize handles
        .padding(3)
    }

    private var fullPanel: some View {
        VStack(spacing: 0) {
            // Header with mode buttons, volume indicator, and close button
            HStack(spacing: 14) {
                // ... DEV indicator ...
                if Bundle.main.bundleIdentifier?.contains("release") != true {
                    Text("DEV")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .fixedSize()  // Prevent text from wrapping when window is narrow
                }

                if appState.isNewerBuildAvailable {
                    Button(action: { appState.restartApp() }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .instantTooltip("New build available - Click to Restart")
                }

                // MODE CONTROL - Icon Only
                UnifiedModeButton()
                    .fixedSize()

                Spacer()

                // VOLUME METER - Large & Dramatic
                if appState.microphoneMode != .off {
                    Menu {
                        InputDeviceMenuItems()
                    } label: {
                        MicLevelIndicator(level: appState.audioLevel)
                            .frame(width: 100, height: 12)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .instantTooltip("Click to change microphone")

                    // Force end button
                    if appState.isConnected {
                        Button(action: { appState.forceEndUtterance() }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .instantTooltip("Force send current dictation")
                    }

                    // PTT processing indicator
                    if appState.isPTTProcessing {
                        PTTProcessingWaveView()
                            .instantTooltip("Processing speech...")
                    }
                }

                // Utility buttons
                HStack(spacing: 10) {
                    Button(action: { appState.toggleCommandPanel() }) {
                        Image(systemName: "terminal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(appState.isCommandPanelVisible ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .instantTooltip("Claude Code")

                    Button(action: openHistory) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .instantTooltip("Open history")

                    Button(action: openSettings) {
                        Image(systemName: "gear")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .instantTooltip("Open settings")

                    // More options menu
                    Menu {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appState.isPanelMinimal = true
                            }
                        }) {
                            Label("Minimize Panel", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        Button(action: hidePanel) {
                            Label("Hide Panel", systemImage: "minus")
                        }
                        Button(action: { appState.restartApp() }) {
                            Label("Restart App", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive, action: quitApp) {
                            Label("Quit VoiceFlow", systemImage: "power")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointerCursor()
                    .instantTooltip("More options")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.1))

            // Warning Banners - limited to 2 max to prevent layout issues
            if !appState.activeWarnings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(appState.activeWarnings.prefix(2)) { warning in
                        WarningBanner(warning: warning) {
                            appState.dismissWarning(id: warning.id)
                        }
                    }
                    // Show overflow indicator if more than 2 warnings
                    if appState.activeWarnings.count > 2 {
                        HStack {
                            Text("+\(appState.activeWarnings.count - 2) more")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Dismiss all") {
                                for warning in appState.activeWarnings {
                                    appState.dismissWarning(id: warning.id)
                                }
                            }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.1))
                    }
                }
                .frame(maxHeight: 120) // Cap warning section height
            }

            Divider()
                .padding(.horizontal, 10)

            // Transcript area - scrollable with flexible height
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        TranscriptContentView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .textSelection(.enabled)
                            .contentShape(Rectangle())

                        // Invisible anchor for scrolling
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .coordinateSpace(name: "scroll")
                    .frame(minHeight: 100, maxHeight: .infinity)
                    // Detect user scroll interaction - disable auto-scroll when user drags
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { _ in
                                // User is actively scrolling - disable auto-scroll
                                if autoScrollEnabled {
                                    autoScrollEnabled = false
                                }
                            }
                    )
                    .onChange(of: appState.recentTurns.count) { _ in
                        if autoScrollEnabled {
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: appState.currentTranscript) { _ in
                        if autoScrollEnabled {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    
                    if !autoScrollEnabled {
                        Button(action: {
                            autoScrollEnabled = true
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)
                                .background(Circle().fill(Color.white).shadow(radius: 2))
                        }
                        .padding(16)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !appState.recentTurns.isEmpty || !appState.currentTranscript.isEmpty {
                    Button(action: {
                        // Combine all turns plus current transcript
                        var allText = appState.recentTurns.map { $0.transcript }.joined(separator: " ")
                        if !appState.currentTranscript.isEmpty {
                            if !allText.isEmpty { allText += " " }
                            allText += appState.currentTranscript
                        }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(allText, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .help("Copy all visible text to clipboard")
                }
            }
        }
        .frame(minWidth: 280, maxWidth: 1000, minHeight: 100, maxHeight: 800)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: appState.isCommandFlashActive ? 3 : 0)
                        .animation(.easeInOut(duration: 0.2), value: appState.isCommandFlashActive)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Small padding at edges to allow window resize handles to be accessible
        .padding(3)
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if appState.isCommandFlashActive, let commandName = appState.lastCommandName {
                    Text("Command: \(commandName)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.8))
                        .clipShape(Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if appState.isKeywordFlashActive, let keywordName = appState.lastKeywordName {
                    Text("Keyword: \(keywordName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.75))
                        .clipShape(Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Extended command mode indicator
                if appState.isExtendedCommandMode {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("Long Command Mode...")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.85))
                    .clipShape(Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Audio recording indicator
                if appState.isRecordingAudio {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 8, height: 8)
                                    .scaleEffect(1.5)
                                    .opacity(0.5)
                            )
                        Text("Recording Audio...")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
        }
        .overlay(alignment: .bottom) {
            if showingHideToast {
                ToastView(message: "Panel hidden. Click menu bar icon to show.")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Error Popup Overlay (Compact)
            if appState.showCompactError, let error = appState.errorMessage {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Reconnect button for connection errors
                    Button(action: {
                        appState.showCompactError = false
                        appState.reconnect()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    // Dismiss button
                    Button(action: {
                        appState.showCompactError = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.85))
                .cornerRadius(6)
                .padding(.bottom, 50) // Above status/toast
                .transition(.scale.combined(with: .opacity))
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

private struct InputDeviceMenu: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [AVCaptureDevice] = []
    
    var body: some View {
        Menu {
            Text("Select Input Device")
                .font(.caption)
            Divider()
            
            Button {
                appState.saveInputDevice(nil)
            } label: {
                if appState.selectedInputDeviceId == nil {
                    Label("System Default", systemImage: "checkmark")
                } else {
                    Text("System Default")
                }
            }
            
            ForEach(devices, id: \.uniqueID) { device in
                Button {
                    appState.saveInputDevice(device.uniqueID)
                } label: {
                    if appState.selectedInputDeviceId == device.uniqueID {
                        Label(device.localizedName, systemImage: "checkmark")
                    } else {
                        Text(device.localizedName)
                    }
                }
            }
            
            Divider()
            Button("Audio Settings...") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
            }
        } label: {
            EmptyView()
        }
        .menuStyle(.borderlessButton)
        .onAppear {
            refreshDevices()
        }
    }
    
    private func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        self.devices = discoverySession.devices
    }
}


struct WarningBanner: View {
    let warning: AppWarning
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(warning.severity == .error ? .red : .orange)
                .font(.system(size: 12))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(warning.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionLabel = warning.actionLabel {
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.top, 2)
                }
            }

            Spacer()

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(warning.severity == .error ? Color.red.opacity(0.1) : Color.orange.opacity(0.1))
        .contentShape(Rectangle())
        .onTapGesture {
            if let action = warning.action {
                action()
            } else {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
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
            // Unified mode button with dropdown
            UnifiedModeButton()

            // Speaker isolation indicator (when active)
            if let speakerId = appState.isolatedSpeakerId {
                SpeakerFilterPill(speakerId: speakerId)
            }
        }
        .fixedSize()
    }
}

/// Unified mode button: click toggles, dropdown for full options
private struct UnifiedModeButton: View {
    @EnvironmentObject var appState: AppState

    private var mode: MicrophoneMode { appState.microphoneMode }

    private var modeColor: Color {
        switch mode {
        case .off: return .gray
        case .on: return .green
        case .sleep: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main clickable area - toggles mode
            Button(action: toggleMode) {
                HStack(spacing: 4) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 10, weight: .semibold))

                    // Show behavior icon when On
                    if mode == .on {
                        Image(systemName: appState.activeBehavior.icon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(modeColor.opacity(0.7))
                    }
                }
                .foregroundColor(modeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(modeColor.opacity(0.15))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .instantTooltip(toggleHelpText)

            // Dropdown menu
            Menu {
                // ... menu items ...
                Section("Mode") {
                    ForEach(MicrophoneMode.allCases) { m in
                        Button {
                            appState.setMode(m)
                        } label: {
                            Label {
                                HStack {
                                    Text(m.rawValue)
                                    Spacer()
                                    Text(m.voiceCommandHint)
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            } icon: {
                                Image(systemName: m.icon)
                            }
                        }
                        .disabled(m == mode)
                    }
                }

                // Behavior section (only relevant when On or will be On)
                Section("Dictation Behavior") {
                    ForEach(ActiveBehavior.allCases) { behavior in
                        Button {
                            appState.saveActiveBehavior(behavior)
                        } label: {
                            if behavior == appState.activeBehavior {
                                Label(behavior.rawValue, systemImage: "checkmark")
                            } else {
                                Label(behavior.rawValue, systemImage: behavior.icon)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundColor(modeColor.opacity(0.6))
                    .frame(width: 14, height: 24)
                    .background(modeColor.opacity(0.1))
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .pointerCursor()
            .fixedSize()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(modeColor.opacity(0.3), lineWidth: 1)
        )
    }

    /// Toggle behavior: Sleep↔On, Off→On
    private func toggleMode() {
        switch mode {
        case .off:
            appState.setMode(.on)
        case .on:
            appState.setMode(.sleep)
        case .sleep:
            appState.setMode(.on)
        }
    }

    private var toggleHelpText: String {
        switch mode {
        case .off: return "Click to turn On"
        case .on: return "Click to Sleep"
        case .sleep: return "Click to turn On"
        }
    }
}

/// Shows when speaker isolation is active
private struct SpeakerFilterPill: View {
    @EnvironmentObject var appState: AppState
    let speakerId: Int

    var body: some View {
        Button {
            appState.toggleSpeakerIsolation(speakerId: speakerId)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 9))
                Text("S\(speakerId) only")
                    .font(.system(size: 9, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Click to listen to all speakers")
    }
}

private struct MicLevelIndicator: View {
    let level: Float  // 0.0 to 1.0

    var body: some View {
        ZStack(alignment: .leading) {
            // Background track
            Capsule()
                .fill(Color.white.opacity(0.1))
                .frame(height: 6)
            
            // Level bar with glow
            Capsule()
                .fill(LinearGradient(
                    gradient: Gradient(colors: [.green, .yellow, .red]),
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: max(4, CGFloat(level) * 120), height: 6)
                .shadow(color: levelColor.opacity(level > 0.05 ? 0.6 : 0), radius: 4)
        }
    }

    private var levelColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}

private struct InputDeviceMenuItems: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [AVCaptureDevice] = []
    
    var body: some View {
        Group {
            Text("Select Microphone")
                .font(.caption)
            Divider()
            
            Button {
                appState.saveInputDevice(nil)
            } label: {
                if appState.selectedInputDeviceId == nil {
                    Label("System Default", systemImage: "checkmark")
                } else {
                    Text("System Default")
                }
            }
            
            ForEach(devices, id: \.uniqueID) { device in
                Button {
                    appState.saveInputDevice(device.uniqueID)
                } label: {
                    if appState.selectedInputDeviceId == device.uniqueID {
                        Label(device.localizedName, systemImage: "checkmark")
                    } else {
                        Text(device.localizedName)
                    }
                }
            }
            
            Divider()
            Button("Audio Settings...") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
            }
        }
        .onAppear {
            refreshDevices()
        }
    }
    
    private func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        self.devices = discoverySession.devices
    }
}


// Compact mode buttons for minimal panel
private struct CompactModeButtons: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach([MicrophoneMode.off, .sleep, .on], id: \.self) { mode in
                Button(action: { appState.setMode(mode) }) {
                    Circle()
                        .fill(colorFor(mode).opacity(appState.microphoneMode == mode ? 1.0 : 0.3))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(colorFor(mode), lineWidth: appState.microphoneMode == mode ? 0 : 1)
                                .opacity(0.5)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(mode.rawValue.capitalized)
            }
        }
    }

    private func colorFor(_ mode: MicrophoneMode) -> Color {
        switch mode {
        case .off: return .gray
        case .sleep: return .orange
        case .on: return .green
        }
    }
}

// Audio pulse indicator that pulses based on audio level
private struct AudioPulseIndicator: View {
    let level: Float
    let mode: MicrophoneMode

    // Amplify level for better visibility (input is typically 0-0.3)
    private var amplifiedLevel: Float {
        min(1.0, level * 5.0)
    }

    var body: some View {
        ZStack {
            // Outer glow when speaking
            Circle()
                .fill(pulseColor.opacity(0.3))
                .frame(width: 14, height: 14)
                .scaleEffect(1.0 + CGFloat(amplifiedLevel) * 0.5)
                .opacity(Double(amplifiedLevel))

            // Inner solid circle
            Circle()
                .fill(pulseColor)
                .frame(width: 8, height: 8)
        }
        .animation(.easeInOut(duration: 0.08), value: amplifiedLevel)
    }

    private var pulseColor: Color {
        switch mode {
        case .on: return amplifiedLevel > 0.5 ? .orange : .green
        case .sleep: return .orange
        case .off: return .gray
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
        VStack(alignment: .leading, spacing: 4) { // Reduced spacing from 10 to 4
            if appState.recentTurns.isEmpty && appState.currentWords.isEmpty && appState.currentTranscript.isEmpty {
                Text(placeholderText)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
            } else {
                // Show history turns
                ForEach(Array(appState.recentTurns.enumerated()), id: \.offset) { index, turn in
                    let showSpeaker = shouldShowSpeaker(for: turn, index: index)
                    TranscriptTurnView(turn: turn, showSpeaker: showSpeaker, isHistory: true)
                }
                
                // Show active turn
                if !appState.currentWords.isEmpty {
                    let activeTurn = TranscriptTurn(
                        transcript: appState.currentTranscript,
                        words: appState.currentWords,
                        endOfTurn: false,
                        isFormatted: false,
                        speaker: appState.currentWords.first?.speaker
                    )
                    let showSpeaker = shouldShowSpeaker(for: activeTurn, index: appState.recentTurns.count)
                    TranscriptTurnView(turn: activeTurn, showSpeaker: showSpeaker, isHistory: false)
                } else if !appState.currentTranscript.isEmpty {
                    // Fallback for simple transcript without words
                    Text(appState.currentTranscript)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundColor(.primary.opacity(0.6)) // Active is gray
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            // Add a bit of selectable "breathing room" at the bottom
            // This makes it much easier to click and drag from below the last line.
            Text("\n ")
                .font(.system(size: 12))
                .opacity(0.01)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shouldShowSpeaker(for turn: TranscriptTurn, index: Int) -> Bool {
        // Check if multiple speakers exist across all visible turns
        let allSpeakers = appState.recentTurns.compactMap { $0.speaker } + (appState.currentWords.compactMap { $0.speaker })
        let uniqueSpeakers = Set(allSpeakers)
        guard uniqueSpeakers.count > 1 else { return false }
        
        // If first turn, always show speaker if we have multiple total
        if index == 0 { return turn.speaker != nil }
        
        // Show if speaker changed from previous turn
        let previousSpeaker = appState.recentTurns[index - 1].speaker
        return turn.speaker != previousSpeaker && turn.speaker != nil
    }

    private var placeholderText: String {
        switch appState.microphoneMode {
        case .off:
            return "Microphone off"
        case .on:
            if appState.effectiveIsOffline {
                return appState.isConnected ? "Listening (Mac Speech)…" : "Starting Mac Speech…"
            }
            return appState.isConnected ? "Listening…" : "Connecting…"
        case .sleep:
            if appState.effectiveIsOffline {
                return appState.isConnected ? "Listening for 'Speech on' (Mac Speech)…" : "Starting Mac Speech…"
            }
            return appState.isConnected ? "Listening for 'Speech on'…" : "Connecting…"
        }
    }
}

private struct TranscriptTurnView: View {
    @EnvironmentObject var appState: AppState
    let turn: TranscriptTurn
    let showSpeaker: Bool
    let isHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showSpeaker, let speaker = turn.speaker {
                HStack(spacing: 4) {
                    Button(action: {
                        appState.toggleSpeakerIsolation(speakerId: speaker)
                    }) {
                        HStack(spacing: 2) {
                            Text("S\(speaker)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                            
                            if let isolated = appState.isolatedSpeakerId {
                                Image(systemName: isolated == speaker ? "lock.fill" : "speaker.slash.fill")
                                    .font(.system(size: 8))
                            } else {
                                Image(systemName: "lock.open")
                                    .font(.system(size: 8))
                                    .opacity(0.5)
                            }
                        }
                        .foregroundColor(speakerColor(for: speaker))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(speakerBgColor(for: speaker))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help(helpText(for: speaker))
                }
                .padding(.top, 4) // Add extra space when speaker changes
            }
            
            TranscriptWordsText(words: turn.words, isHistory: isHistory)
                .opacity(isIgnored ? 0.3 : 1.0)
                .saturation(isIgnored ? 0.0 : 1.0)
        }
    }
    
    private var isIgnored: Bool {
        guard let isolated = appState.isolatedSpeakerId, let speaker = turn.speaker else { return false }
        return isolated != speaker
    }
    
    private func speakerColor(for speaker: Int) -> Color {
        if let isolated = appState.isolatedSpeakerId {
            return isolated == speaker ? .green : .secondary
        }
        return .accentColor
    }
    
    private func speakerBgColor(for speaker: Int) -> Color {
        if let isolated = appState.isolatedSpeakerId {
            return isolated == speaker ? .green.opacity(0.15) : .gray.opacity(0.1)
        }
        return .accentColor.opacity(0.1)
    }
    
    private func helpText(for speaker: Int) -> String {
        if let isolated = appState.isolatedSpeakerId {
            return isolated == speaker ? "Click to unlock (listen to all)" : "Click to switch lock to S\(speaker)"
        }
        return "Click to only listen to S\(speaker)"
    }
}

private struct TranscriptWordsText: View {
    let words: [TranscriptWord]
    let isHistory: Bool

    var body: some View {
        textView
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var textView: Text {
        var result = Text("")
        
        for (index, word) in words.enumerated() {
            let needsSpace = index > 0
            let prefix = needsSpace ? " " : ""
            
            // COLOR SWAP LOGIC:
            // Finalized (History) = Primary (Black/White)
            // Active (Not History) = Secondary (Gray)
            let baseColor: Color = isHistory ? .primary : .secondary
            
            result = result + Text(prefix + word.text)
                .foregroundColor(word.isFinal == false ? .secondary.opacity(0.5) : baseColor)
                .italic(word.isFinal == false)
        }
        return result
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

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - PTT Processing Indicator

/// Animated waveform indicator shown when waiting for finalized text after PTT release
struct PTTProcessingWaveView: View {
    @State private var animate = false
    let barCount = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.orange)
                    .frame(width: 3, height: animate ? 12 : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.1),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

#Preview {
    FloatingPanelView()
        .environmentObject(AppState())
}
