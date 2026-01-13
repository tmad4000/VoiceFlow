import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings_selected_tab") private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            VoiceCommandsSettingsView()
                .tabItem {
                    Label("Commands", systemImage: "command")
                }
                .tag(1)

            DictationHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(2)

            DebugConsoleView()
                .tabItem {
                    Label("Debug", systemImage: "terminal")
                }
                .tag(3)
        }
        .frame(width: 480, height: 580)
        .onReceive(NotificationCenter.default.publisher(for: .openHistory)) { _ in
            selectedTab = 2
        }
    }
}

// MARK: - Reusable Components

private let globalShortcutHelpItems: [(keys: String, description: String)] = [
    ("⌃⌥Space", "Push-to-Talk (Hold)"),
    ("⌃⌘V", "Paste last utterance"),
    ("⌃⌥⌘1", "Mode: ON"),
    ("⌃⌥⌘2", "Mode: SLEEP"),
    ("⌃⌥⌘0", "Mode: OFF"),
    ("⌘,", "Open Settings")
]

struct SettingRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                content
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let formatAsInt: Bool

    init(_ title: String, subtitle: String? = nil, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, unit: String = "", formatAsInt: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.formatAsInt = formatAsInt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(formatAsInt ? "\(Int(value))\(unit)" : String(format: "%.2f\(unit)", value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(minWidth: 50, alignment: .trailing)
            }
            Slider(value: $value, in: range, step: step)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.top, 8)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var deepgramApiKeyInput: String = ""
    @State private var anthropicApiKeyInput: String = ""
    @State private var showAdvancedUtterance = false
    @State private var showDebugInfo = false

    // API Key test states
    @State private var assemblyTestStatus: TestStatus = .idle
    @State private var deepgramTestStatus: TestStatus = .idle
    @State private var anthropicTestStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, success, failed(String)

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .testing: return .orange
            case .success: return .green
            case .failed: return .red
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // AssemblyAI API Key Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AssemblyAI API Key")
                            .font(.system(size: 13, weight: .semibold))

                        SecureField("Enter your API key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { apiKeyInput = appState.apiKey }

                        HStack {
                            Button("Save") {
                                appState.saveAPIKey(apiKeyInput)
                            }
                            .disabled(apiKeyInput.isEmpty)

                            Button("Test") {
                                testAssemblyAIKey()
                            }
                            .disabled(apiKeyInput.isEmpty)

                            testStatusView(assemblyTestStatus)

                            Spacer()

                            Link("Get API Key", destination: URL(string: "https://www.assemblyai.com/app/account")!)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(4)
                }

                // Deepgram API Key Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Deepgram API Key")
                            .font(.system(size: 13, weight: .semibold))

                        SecureField("Enter your API key", text: $deepgramApiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { deepgramApiKeyInput = appState.deepgramApiKey }

                        HStack {
                            Button("Save") {
                                appState.saveDeepgramApiKey(deepgramApiKeyInput)
                            }
                            .disabled(deepgramApiKeyInput.isEmpty)

                            Button("Test") {
                                testDeepgramKey()
                            }
                            .disabled(deepgramApiKeyInput.isEmpty)

                            testStatusView(deepgramTestStatus)

                            Spacer()

                            Link("Get API Key", destination: URL(string: "https://console.deepgram.com/signup")!)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(4)
                }

                // AI Formatter Section (Experimental)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("AI Formatter")
                                .font(.system(size: 13, weight: .semibold))
                            Text("(Experimental)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }

                        Toggle("Enable context-aware formatting", isOn: Binding(
                            get: { appState.aiFormatterEnabled },
                            set: { appState.saveAIFormatterEnabled($0) }
                        ))
                        .font(.system(size: 12))

                        if appState.aiFormatterEnabled {
                            Text("Uses focus context to improve capitalization. Capitalizes after sentences and at the start of new app focus sessions.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            // Warning if no API key
                            if appState.anthropicApiKey.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("No API key set - using local heuristics only (basic capitalization)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                }
                                .padding(8)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(6)
                            }

                            Divider()

                            HStack {
                                Text("Anthropic API Key")
                                    .font(.system(size: 12, weight: .medium))
                                if !appState.anthropicApiKey.isEmpty {
                                    Text("(saved)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                }
                            }

                            SecureField("Enter your Anthropic API key", text: $anthropicApiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onAppear { anthropicApiKeyInput = appState.anthropicApiKey }

                            HStack {
                                Button("Save") {
                                    appState.saveAnthropicApiKey(anthropicApiKeyInput)
                                }
                                .disabled(anthropicApiKeyInput.isEmpty)
                                .font(.system(size: 11))

                                Button("Test") {
                                    testAnthropicKey()
                                }
                                .disabled(anthropicApiKeyInput.isEmpty)
                                .font(.system(size: 11))

                                testStatusView(anthropicTestStatus)

                                if !appState.anthropicApiKey.isEmpty {
                                    Button("Clear") {
                                        appState.saveAnthropicApiKey("")
                                        anthropicApiKeyInput = ""
                                    }
                                    .foregroundColor(.red)
                                    .font(.system(size: 11))
                                }

                                Spacer()

                                Link("Get API Key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                    .padding(4)
                }

                // Permissions Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VoiceFlow"

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Permissions")
                                .font(.system(size: 13, weight: .semibold))
                            Text("(look for \"\(appName)\" in System Settings)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        // Swift run warning banner
                        if appState.isRunningFromSwiftRun && !appState.isAccessibilityGranted {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Running via 'swift run'")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text("Permissions granted to VoiceFlow-Dev.app don't apply to the swift run binary. Either run the .app or grant permissions to Terminal.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Button("Run .app Instead") {
                                        // Try to find and launch the app bundle
                                        let possiblePaths = [
                                            "./VoiceFlow-Dev.app",
                                            "~/Applications/VoiceFlow-Dev.app",
                                            "/Applications/VoiceFlow-Dev.app"
                                        ]
                                        for path in possiblePaths {
                                            let expandedPath = NSString(string: path).expandingTildeInPath
                                            if FileManager.default.fileExists(atPath: expandedPath) {
                                                NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
                                                NSApp.terminate(nil)
                                                return
                                            }
                                        }
                                    }
                                    .font(.system(size: 11))

                                    Button("Copy tccutil Command") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("tccutil reset Accessibility com.jacobcole.voiceflow && open ./VoiceFlow-Dev.app", forType: .string)
                                    }
                                    .font(.system(size: 11))
                                }
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }

                        PermissionRow(
                            name: "Microphone",
                            isGranted: appState.isMicrophoneGranted,
                            onRequest: { appState.requestMicrophonePermission() },
                            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        )

                        PermissionRow(
                            name: "Accessibility (Typing)",
                            isGranted: appState.isAccessibilityGranted,
                            onRequest: { appState.checkAccessibilityPermission(silent: false) },
                            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )

                        PermissionRow(
                            name: "Speech Recognition",
                            isGranted: appState.isSpeechGranted,
                            onRequest: { appState.requestSpeechPermission() },
                            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                        )
                        
                        Divider()
                        
                        HStack {
                            Button("Refresh") {
                                appState.checkMicrophonePermission()
                                appState.checkSpeechPermission()
                                appState.recheckAccessibilityPermission()
                            }
                            .pointerCursor()

                            Spacer()

                            Button("Reset All") {
                                resetAllPermissions()
                            }
                            .foregroundColor(.red)
                            .pointerCursor()
                            .help("Revokes all permissions for this app. Requires restart.")

                            CopyCommandButton()
                            .pointerCursor()

                            Button("Restart App") {
                                appState.restartApp()
                            }
                            .pointerCursor()
                            .help("Restart VoiceFlow to pick up permission changes")
                        }
                        .font(.system(size: 11))
                    }
                    .padding(4)
                }

                // Push-to-Talk Shortcut Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Shortcuts")
                            .font(.system(size: 13, weight: .semibold))

                        ShortcutRecorder(
                            shortcut: $appState.pttShortcut,
                            label: "Push-to-Talk",
                            onChange: { appState.savePTTShortcut($0) }
                        )
                        
                        Text("Hold to talk.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)
                        
                        Divider()
                        
                        ShortcutRecorder(
                            shortcut: $appState.modeOnShortcut,
                            label: "Switch to ON",
                            onChange: { appState.saveModeOnShortcut($0) }
                        )
                        
                        ShortcutRecorder(
                            shortcut: $appState.modeSleepShortcut,
                            label: "Switch to SLEEP",
                            onChange: { appState.saveModeSleepShortcut($0) }
                        )
                        
                        ShortcutRecorder(
                            shortcut: $appState.modeOffShortcut,
                            label: "Switch to OFF",
                            onChange: { appState.saveModeOffShortcut($0) }
                        )
                    }
                    .padding(4)
                }

                // Startup Settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Startup")
                            .font(.system(size: 13, weight: .semibold))

                        HStack {
                            Text("Initial Mode")
                                .font(.system(size: 13))
                            Spacer()
                            Picker("", selection: launchModeBinding) {
                                ForEach(MicrophoneMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        
                        Text("The mode VoiceFlow will enter when first launched.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("Launch at Login", isOn: launchAtLoginBinding)
                            .font(.system(size: 13))

                        Text("Automatically start VoiceFlow when you log in.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Auto-Sleep", isOn: sleepTimerEnabledBinding)
                                .font(.system(size: 13))

                            Text("Automatically switch from On to Sleep mode after inactivity.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            if appState.sleepTimerEnabled {
                                SliderRow(
                                    "Inactivity Timeout",
                                    subtitle: "Minutes of silence before sleeping.",
                                    value: sleepTimerMinutesBinding,
                                    range: 1...60,
                                    step: 1,
                                    unit: " min"
                                )
                                .padding(.leading, 16)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Auto-Off", isOn: autoOffEnabledBinding)
                                .font(.system(size: 13))

                            Text("Turn microphone completely Off after extended inactivity (even in Sleep mode). Saves battery and reduces background processing.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            if appState.autoOffEnabled {
                                SliderRow(
                                    "Off Timeout",
                                    subtitle: "Minutes before turning Off.",
                                    value: autoOffMinutesBinding,
                                    range: 5...120,
                                    step: 5,
                                    unit: " min"
                                )
                                .padding(.leading, 16)
                            }
                        }
                    }
                    .padding(4)
                }

                // Dictation Settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dictation")
                            .font(.system(size: 13, weight: .semibold))

                        HStack {
                            Text("Provider")
                                .font(.system(size: 13))
                            Spacer()
                            Picker("", selection: dictationProviderBinding) {
                                ForEach(DictationProvider.allCases) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .frame(width: 180)
                        }

                        Text("Choose between cloud-based (AssemblyAI, Deepgram) or local Mac speech recognition.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Divider()

                        HStack {
                            Text("Microphone")
                                .font(.system(size: 13))
                            Spacer()
                            InputDevicePicker(selectedDeviceID: $appState.selectedInputDeviceId) {
                                // On change, save (the binding updates the state, but we need to persist)
                                appState.saveInputDevice($0)
                            }
                            .frame(width: 180)
                        }
                        
                        Text("Select which microphone to use for dictation.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("Live Dictation", isOn: liveDictationBinding)
                            .font(.system(size: 13))

                        Text("Type words as they become final (lower latency, but disables punctuation).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Divider()

                        SliderRow(
                            "Command Delay",
                            subtitle: "Delay before triggering non-prefixed commands.",
                            value: commandDelayBinding,
                            range: 0...500,
                            step: 50,
                            unit: " ms"
                        )
                    }
                    .padding(4)
                }

                // Vocabulary Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vocabulary")
                            .font(.system(size: 13, weight: .semibold))

                        TextField("Custom words or phrases...", text: vocabularyPromptBinding)
                            .textFieldStyle(.roundedBorder)

                        Text("Comma-separated words or phrases to improve recognition of technical terms, names, or jargon (Online mode only).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                }

                // Idea Flow Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Idea Flow Integration")
                            .font(.system(size: 13, weight: .semibold))

                        TextField("Optional URL (e.g., ideaflow://)", text: ideaFlowURLBinding)
                            .textFieldStyle(.roundedBorder)

                        Text("Configure how to trigger Idea Flow when saying \"save to idea flow\".")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                }

                // Utterance Detection
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Utterance Detection")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(action: { appState.forceEndUtterance() }) {
                                Text("Force End")
                                    .font(.system(size: 11))
                            }
                            .disabled(!appState.isConnected)
                            .help("Force end current utterance (or say \"send that\" / \"done\")")
                        }

                        Text("How long to wait before finalizing speech.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        // Mode picker as menu (cleaner for multiple options)
                        HStack {
                            Text("Mode")
                                .font(.system(size: 13))
                            Spacer()
                            Picker("", selection: utteranceModeBinding) {
                                ForEach(UtteranceMode.allCases, id: \.self) { mode in
                                    Text(modeLabel(mode)).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }

                        // Current mode description + reset button
                        HStack(spacing: 8) {
                            Image(systemName: modeIcon)
                                .foregroundColor(.secondary)
                            Text(appState.utteranceMode.description)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            if appState.utteranceMode != .balanced {
                                Button("Reset") {
                                    appState.saveUtteranceMode(.balanced)
                                }
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            }
                        }

                        // Advanced toggle button
                        Button(action: { withAnimation { showAdvancedUtterance.toggle() } }) {
                            HStack {
                                Image(systemName: showAdvancedUtterance ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text("Advanced")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showAdvancedUtterance {
                            VStack(alignment: .leading, spacing: 16) {
                                SliderRow(
                                    "Confidence",
                                    subtitle: "Higher = waits longer for certainty",
                                    value: confidenceThresholdBinding,
                                    range: 0.3...0.99,
                                    step: 0.01,
                                    formatAsInt: false
                                )

                                SliderRow(
                                    "Silence",
                                    subtitle: "Minimum pause (ms) after confident end",
                                    value: silenceThresholdBinding,
                                    range: 50...3000,
                                    step: 25,
                                    unit: " ms"
                                )
                            }
                            .padding(.leading, 16)
                            .padding(.top, 4)
                        }
                    }
                    .padding(4)
                }

                // Debug Section
                Button(action: { withAnimation { showDebugInfo.toggle() } }) {
                    HStack {
                        Image(systemName: showDebugInfo ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("Debug Info")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showDebugInfo {
                    let diagnostics = appState.accessibilityDiagnostics

                    VStack(alignment: .leading, spacing: 8) {
                        // Warning banner if running from swift run without permission
                        if diagnostics.isSwiftRun && !appState.isAccessibilityGranted {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Running via 'swift run' - permissions may not apply")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(6)
                        }

                        // Status
                        Group {
                            Text("Mic: \(appState.microphoneAuthStatusDescription)")
                            Text("Accessibility: \(appState.accessibilityStatusDescription)")
                            Text("isMicGranted: \(appState.isMicrophoneGranted ? "true" : "false")")
                            Text("isA11yGranted: \(appState.isAccessibilityGranted ? "true" : "false")")
                        }

                        Divider()

                        // Process identity info
                        Group {
                            HStack(alignment: .top) {
                                Text("Executable:")
                                    .foregroundColor(.secondary)
                                Text(diagnostics.execPath)
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Text("Bundle ID:")
                                    .foregroundColor(.secondary)
                                Text(diagnostics.bundleId ?? "nil")
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Text("swift run:")
                                    .foregroundColor(.secondary)
                                Text(diagnostics.isSwiftRun ? "Yes" : "No")
                                    .foregroundColor(diagnostics.isSwiftRun ? .orange : .green)
                            }
                        }

                        // Suggestion box
                        if !appState.isAccessibilityGranted {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Suggestion:")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(diagnostics.suggestion)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                        }

                        Divider()

                        HStack(spacing: 8) {
                            Button("Refresh") {
                                appState.checkMicrophonePermission()
                                appState.recheckAccessibilityPermission()
                            }
                            .font(.system(size: 11))

                            Button("Reset Accessibility") {
                                resetAccessibilityPermission()
                            }
                            .font(.system(size: 11))
                            .help("Runs: tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "")")

                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .font(.system(size: 11))

                            Button("Copy Reset Cmd") {
                                let cmd = "tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "com.jacobcole.voiceflow")"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.leading, 16)
                }

                // About
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VoiceFlow"
                        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
                        Text("\(bundleName) v\(bundleVersion)")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    
                    Text("Installed at: \(Bundle.main.bundlePath)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            NSApp.terminate(nil)
                        } label: {
                            Label("Quit VoiceFlow", systemImage: "power")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
    }

    private var modeIcon: String {
        switch appState.utteranceMode {
        case .quick: return "hare"
        case .balanced: return "scale.3d"
        case .patient: return "tortoise"
        case .dictation: return "doc.text"
        case .extraLong: return "hourglass"
        case .custom: return "slider.horizontal.3"
        }
    }

    private func modeLabel(_ mode: UtteranceMode) -> String {
        let isSelected = appState.utteranceMode == mode
        let checkmark = isSelected ? " ✓" : ""
        
        switch mode {
        case .quick: return "Quick (100ms)\(checkmark)"
        case .balanced: return "Balanced (160ms)\(checkmark)"
        case .patient: return "Patient (400ms)\(checkmark)"
        case .dictation: return "Dictation (560ms)\(checkmark)"
        case .extraLong: return "Extra Long (2000ms)\(checkmark)"
        case .custom: return "Custom\(checkmark)"
        }
    }

    // MARK: - Bindings

    private var launchModeBinding: Binding<MicrophoneMode> {
        Binding(
            get: { appState.launchMode },
            set: { appState.saveLaunchMode($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.launchAtLogin },
            set: { appState.saveLaunchAtLogin($0) }
        )
    }

    private var sleepTimerEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.sleepTimerEnabled },
            set: { appState.saveSleepTimerEnabled($0) }
        )
    }

    private var sleepTimerMinutesBinding: Binding<Double> {
        Binding(
            get: { appState.sleepTimerMinutes },
            set: { appState.saveSleepTimerMinutes($0) }
        )
    }

    private var autoOffEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.autoOffEnabled },
            set: { appState.saveAutoOffEnabled($0) }
        )
    }

    private var autoOffMinutesBinding: Binding<Double> {
        Binding(
            get: { appState.autoOffMinutes },
            set: { appState.saveAutoOffMinutes($0) }
        )
    }

    private var dictationProviderBinding: Binding<DictationProvider> {
        Binding(
            get: { appState.dictationProvider },
            set: { appState.saveDictationProvider($0) }
        )
    }

    private var commandDelayBinding: Binding<Double> {
        Binding(
            get: { appState.commandDelayMs },
            set: { appState.saveCommandDelay($0) }
        )
    }

    private var liveDictationBinding: Binding<Bool> {
        Binding(
            get: { appState.liveDictationEnabled },
            set: { appState.saveLiveDictationEnabled($0) }
        )
    }

    private var vocabularyPromptBinding: Binding<String> {
        Binding(
            get: { appState.vocabularyPrompt },
            set: { appState.saveVocabularyPrompt($0) }
        )
    }

    private var ideaFlowURLBinding: Binding<String> {
        Binding(
            get: { appState.ideaFlowURL },
            set: { appState.saveIdeaFlowURL($0) }
        )
    }

    private var utteranceModeBinding: Binding<UtteranceMode> {
        Binding(
            get: { appState.utteranceMode },
            set: { appState.saveUtteranceMode($0) }
        )
    }

    private var confidenceThresholdBinding: Binding<Double> {
        Binding(
            get: { appState.customConfidenceThreshold },
            set: { appState.saveCustomConfidenceThreshold($0) }
        )
    }

    private var silenceThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(appState.customSilenceThresholdMs) },
            set: { appState.saveCustomSilenceThreshold(Int($0)) }
        )
    }

    private func resetAllPermissions() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleId]
        try? process.run()
        process.waitUntilExit()
        
        // Refresh status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appState.checkMicrophonePermission()
            appState.checkSpeechPermission()
            appState.recheckAccessibilityPermission()
        }
    }

    private func resetAccessibilityPermission() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleId]
        try? process.run()
        process.waitUntilExit()

        // Refresh status after reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appState.recheckAccessibilityPermission()
        }
    }

    // MARK: - API Key Test Helpers

    @ViewBuilder
    private func testStatusView(_ status: TestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
        case .failed(let message):
            HStack(spacing: 2) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 12))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    private func testAssemblyAIKey() {
        assemblyTestStatus = .testing
        Task {
            do {
                let url = URL(string: "https://api.assemblyai.com/v2/transcript")!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(apiKeyInput, forHTTPHeaderField: "Authorization")

                let (_, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse

                await MainActor.run {
                    if httpResponse?.statusCode == 401 {
                        assemblyTestStatus = .failed("Invalid key")
                    } else if httpResponse?.statusCode == 200 || httpResponse?.statusCode == 400 {
                        // 400 means key is valid but request is malformed (expected)
                        assemblyTestStatus = .success
                    } else {
                        assemblyTestStatus = .failed("Error \(httpResponse?.statusCode ?? 0)")
                    }
                }
            } catch {
                await MainActor.run {
                    assemblyTestStatus = .failed("Network error")
                }
            }
        }
    }

    private func testDeepgramKey() {
        deepgramTestStatus = .testing
        Task {
            do {
                let url = URL(string: "https://api.deepgram.com/v1/projects")!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("Token \(deepgramApiKeyInput)", forHTTPHeaderField: "Authorization")

                let (_, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse

                await MainActor.run {
                    if httpResponse?.statusCode == 401 || httpResponse?.statusCode == 403 {
                        deepgramTestStatus = .failed("Invalid key")
                    } else if httpResponse?.statusCode == 200 {
                        deepgramTestStatus = .success
                    } else {
                        deepgramTestStatus = .failed("Error \(httpResponse?.statusCode ?? 0)")
                    }
                }
            } catch {
                await MainActor.run {
                    deepgramTestStatus = .failed("Network error")
                }
            }
        }
    }

    private func testAnthropicKey() {
        anthropicTestStatus = .testing
        Task {
            do {
                let url = URL(string: "https://api.anthropic.com/v1/messages")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anthropicApiKeyInput, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                // Minimal request body
                let body: [String: Any] = [
                    "model": "claude-3-5-haiku-20241022",
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "hi"]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse

                await MainActor.run {
                    if httpResponse?.statusCode == 401 {
                        anthropicTestStatus = .failed("Invalid key")
                    } else if httpResponse?.statusCode == 200 {
                        anthropicTestStatus = .success
                    } else {
                        anthropicTestStatus = .failed("Error \(httpResponse?.statusCode ?? 0)")
                    }
                }
            } catch {
                await MainActor.run {
                    anthropicTestStatus = .failed("Network error")
                }
            }
        }
    }
}

struct CopyCommandButton: View {
    @State private var showingPopover = false
    @State private var copied = false

    private var command: String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.jacobcole.voiceflow"
        return "tccutil reset All \(bundleId)"
    }

    var body: some View {
        Button(action: {
            showingPopover = true
        }) {
            Image(systemName: "terminal")
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reset Permissions")
                    .font(.system(size: 13, weight: .semibold))

                Text("If permissions aren't working correctly, you can reset them by running this command in Terminal:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(6)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                        .textSelection(.enabled)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundColor(copied ? .green : .primary)
                    }
                    .buttonStyle(.plain)
                }

                Text("After running, restart the app and re-grant permissions in System Settings.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    if copied {
                        Text("Copied!")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                    }
                    Button("Done") {
                        showingPopover = false
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

struct ShortcutHelpRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack {
            Text(description)
                .font(.system(size: 12))
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let name: String
    let isGranted: Bool
    let onRequest: () -> Void
    let settingsURL: String

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isGranted ? .green : .orange)
                .font(.system(size: 14))

            Text(name)
                .font(.system(size: 13))
                .foregroundColor(isGranted ? .primary : .orange)

            Spacer()

            if !isGranted {
                Button("Request") { onRequest() }
                    .font(.system(size: 11))
                Button("Settings") {
                    NSWorkspace.shared.open(URL(string: settingsURL)!)
                }
                .font(.system(size: 11))
            } else {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Voice Commands Settings

struct VoiceCommandsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedCommand: VoiceCommand?
    @State private var showingAddSheet = false
    @State private var searchText = ""
    @State private var showingShortcuts = false
    @State private var sectionFilter: CommandSectionFilter = .all

    enum CommandSectionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case system = "System"
        case keywords = "Keywords"
        case user = "Yours"

        var id: String { rawValue }
    }

    var filteredSystemCommands: [(phrase: String, description: String)] {
        if searchText.isEmpty {
            return AppState.systemCommandList
        }
        return AppState.systemCommandList.filter {
            $0.phrase.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredUserCommands: [VoiceCommand] {
        if searchText.isEmpty {
            return appState.voiceCommands
        }
        return appState.voiceCommands.filter {
            $0.phrase.localizedCaseInsensitiveContains(searchText) ||
            ($0.replacementText ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredSpecialKeywords: [(phrase: String, description: String)] {
        if searchText.isEmpty {
            return AppState.specialKeywordList
        }
        return AppState.specialKeywordList.filter {
            $0.phrase.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search
            HStack {
                Text("Voice Commands")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 100)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .help("Add new voice command")

                Button(action: {
                    appState.voiceCommands = VoiceCommand.defaults
                    appState.saveVoiceCommands()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset to default commands")

                Button(action: { showingShortcuts = true }) {
                    Image(systemName: "keyboard")
                }
                .help("View global shortcuts")
                .popover(isPresented: $showingShortcuts) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Global Shortcuts")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(globalShortcutHelpItems, id: \.keys) { item in
                            ShortcutHelpRow(keys: item.keys, description: item.description)
                        }
                        Divider()
                        Button("Open General Settings") {
                            NotificationCenter.default.post(name: .openSettings, object: nil)
                            showingShortcuts = false
                        }
                        .font(.system(size: 11))
                    }
                    .padding(12)
                    .frame(width: 300)
                }
            }
            .padding()

            Divider()

            HStack {
                Text("Sections")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker("", selection: $sectionFilter) {
                    ForEach(CommandSectionFilter.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Command list
            List {
                // System Commands at top (pinned)
                if sectionFilter == .all || sectionFilter == .system {
                    Section(header: HStack {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("System Commands")
                    }) {
                        ForEach(filteredSystemCommands, id: \.phrase) { command in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\"\(command.phrase)\"")
                                        .font(.system(size: 13, weight: .medium))
                                    Text(command.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("Built-in")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundColor(.orange)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Special Keywords
                if sectionFilter == .all || sectionFilter == .keywords {
                    Section(header: Text("Special Keywords")) {
                        ForEach(filteredSpecialKeywords, id: \.phrase) { keyword in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\"\(keyword.phrase)\"")
                                        .font(.system(size: 13, weight: .medium))
                                    Text(keyword.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("Keyword")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundColor(.blue)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // User Commands
                if sectionFilter == .all || sectionFilter == .user {
                    Section(header: Text("Your Commands")) {
                        ForEach(filteredUserCommands) { command in
                            VoiceCommandRow(command: command)
                                .tag(command)
                        }
                        .onDelete(perform: deleteCommands)
                    }
                }
            }
            .listStyle(.inset)

            // Footer info
            VStack(alignment: .leading, spacing: 8) {
                Text("Say a phrase in On mode to trigger a shortcut.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("See **General** tab for global keyboard shortcuts")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddCommandSheet { newCommand in
                appState.voiceCommands.append(newCommand)
                appState.saveVoiceCommands()
            }
        }
    }

    func deleteCommands(at offsets: IndexSet) {
        // Map filtered indices back to original indices
        let commandsToDelete = offsets.map { filteredUserCommands[$0] }
        for command in commandsToDelete {
            if let index = appState.voiceCommands.firstIndex(where: { $0.id == command.id }) {
                appState.voiceCommands.remove(at: index)
            }
        }
        appState.saveVoiceCommands()
    }
}

struct VoiceCommandRow: View {
    let command: VoiceCommand

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(command.phrase)\"")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 6) {
                    Text(command.replacementText ?? command.shortcut?.description ?? "")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if command.requiresPause {
                        Text("• Requires Pause")
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }
            }

            Spacer()

            if !command.isEnabled {
                Text("Disabled")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddCommandSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var phrase: String = ""
    @State private var replacementText: String = ""
    @State private var selectedKey: String = "A"
    @State private var useCommand = false
    @State private var useShift = false
    @State private var useOption = false
    @State private var useControl = false
    @State private var requiresPause = false
    @State private var type: CommandType = .shortcut

    enum CommandType: String, CaseIterable {
        case shortcut = "Shortcut"
        case snippet = "Snippet"
    }

    let onSave: (VoiceCommand) -> Void

    let availableKeys = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
                         "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
                         "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                         "Tab", "Return", "Space", "Escape", "Delete",
                         "Left", "Right", "Up", "Down", "PageUp", "PageDown"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Voice Command")
                .font(.headline)

            Picker("Type", selection: $type) {
                ForEach(CommandType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Form {
                TextField("Phrase", text: $phrase)
                    .textFieldStyle(.roundedBorder)

                if type == .snippet {
                    TextField("Replacement Text", text: $replacementText)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Key", selection: $selectedKey) {
                        ForEach(availableKeys, id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }

                    HStack {
                        Toggle("⌘", isOn: $useCommand)
                        Toggle("⇧", isOn: $useShift)
                        Toggle("⌥", isOn: $useOption)
                        Toggle("⌃", isOn: $useControl)
                    }
                }

                Toggle("Requires Pause", isOn: $requiresPause)
                    .font(.system(size: 13))
                Text("Only trigger if there is a pause before or after. Recommended for common words to avoid accidental triggers.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Add") {
                    let command = createCommand()
                    onSave(command)
                    dismiss()
                }
                .disabled(phrase.isEmpty || (type == .snippet && replacementText.isEmpty))
            }
        }
        .padding()
        .frame(width: 300)
    }

    func createCommand() -> VoiceCommand {
        if type == .snippet {
            return VoiceCommand(phrase: phrase, shortcut: nil, replacementText: replacementText, requiresPause: requiresPause)
        } else {
            var modifiers = KeyboardModifiers()
            if useCommand { modifiers.insert(.command) }
            if useShift { modifiers.insert(.shift) }
            if useOption { modifiers.insert(.option) }
            if useControl { modifiers.insert(.control) }
            let shortcut = KeyboardShortcut(keyCode: keyCodeForString(selectedKey), modifiers: modifiers)
            return VoiceCommand(phrase: phrase, shortcut: shortcut, replacementText: nil, requiresPause: requiresPause)
        }
    }

    func keyCodeForString(_ key: String) -> UInt16 {
        switch key {
        case "A": return 0x00
        case "B": return 0x0B
        case "C": return 0x08
        case "D": return 0x02
        case "E": return 0x0E
        case "F": return 0x03
        case "G": return 0x05
        case "H": return 0x04
        case "I": return 0x22
        case "J": return 0x26
        case "K": return 0x28
        case "L": return 0x25
        case "M": return 0x2E
        case "N": return 0x2D
        case "O": return 0x1F
        case "P": return 0x23
        case "Q": return 0x0C
        case "R": return 0x0F
        case "S": return 0x01
        case "T": return 0x11
        case "U": return 0x20
        case "V": return 0x09
        case "W": return 0x0D
        case "X": return 0x07
        case "Y": return 0x10
        case "Z": return 0x06
        case "0": return 0x1D
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        case "Tab": return 0x30
        case "Return": return 0x24
        case "Space": return 0x31
        case "Escape": return 0x35
        case "Delete": return 0x33
        case "Left": return 0x7B
        case "Right": return 0x7C
        case "Up": return 0x7E
        case "Down": return 0x7D
        case "PageUp": return 0x74
        case "PageDown": return 0x79
        default: return 0x00
        }
    }
}

// MARK: - Dictation History

struct DictationHistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = Set<Int>()
    @State private var lastSelectedIndex: Int?
    @State private var shouldAutoScroll = true
    @State private var lastScrollTime = Date()
    @State private var searchText = ""
    @State private var currentMatchIndex = 0
    @State private var scrollProxy: ScrollViewProxy?

    // Reversed history (oldest first, newest at bottom - like a chat)
    var reversedHistory: [String] {
        Array(appState.dictationHistory.reversed())
    }

    // Indices of entries matching search
    var matchingIndices: [Int] {
        guard !searchText.isEmpty else { return [] }
        return reversedHistory.enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(searchText) }
            .map { $0.offset }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Dictation History")
                    .font(.system(size: 13, weight: .semibold))

                if !selection.isEmpty {
                    Text("(\(selection.count) selected)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Scroll to bottom button
                Button {
                    shouldAutoScroll = true
                    if let proxy = scrollProxy, let lastIndex = reversedHistory.indices.last {
                        withAnimation { proxy.scrollTo(lastIndex, anchor: .bottom) }
                    }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Scroll to bottom")
                .opacity(shouldAutoScroll ? 0.3 : 1.0)

                if !selection.isEmpty {
                    Button("Copy Selected") {
                        let selectedText = reversedHistory.enumerated()
                            .filter { selection.contains($0.offset) }
                            .map { $0.element }
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selectedText, forType: .string)
                    }
                    .font(.system(size: 11))
                }

                Button("Clear History") {
                    appState.dictationHistory.removeAll()
                    appState.saveDictationHistory()
                    selection.removeAll()
                    searchText = ""
                }
                .font(.system(size: 11))
            }
            .padding()

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))

                TextField("Search history...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: searchText) { _, _ in
                        currentMatchIndex = 0
                        jumpToCurrentMatch()
                    }

                if !searchText.isEmpty {
                    // Match counter and navigation
                    if !matchingIndices.isEmpty {
                        Text("\(currentMatchIndex + 1)/\(matchingIndices.count)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 40)

                        Button {
                            if currentMatchIndex > 0 {
                                currentMatchIndex -= 1
                                jumpToCurrentMatch()
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentMatchIndex == 0)

                        Button {
                            if currentMatchIndex < matchingIndices.count - 1 {
                                currentMatchIndex += 1
                                jumpToCurrentMatch()
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentMatchIndex >= matchingIndices.count - 1)
                    } else {
                        Text("No matches")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))

            Divider()

            if appState.dictationHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No dictation history yet.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(reversedHistory.enumerated()), id: \.offset) { index, entry in
                                let isMatch = matchingIndices.contains(index)
                                let isCurrentMatch = !matchingIndices.isEmpty &&
                                    currentMatchIndex < matchingIndices.count &&
                                    matchingIndices[currentMatchIndex] == index

                                VStack(alignment: .leading, spacing: 0) {
                                    // Show divider every 10 entries for visual grouping
                                    if index > 0 && index % 10 == 0 {
                                        Divider()
                                            .padding(.vertical, 8)
                                    }

                                    HStack(alignment: .top) {
                                        // Highlight matching text
                                        if isMatch && !searchText.isEmpty {
                                            highlightedText(entry, highlight: searchText)
                                                .font(.system(size: 12))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        } else {
                                            Text(entry)
                                                .font(.system(size: 12))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }

                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(entry, forType: .string)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Copy to clipboard")
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(
                                        isCurrentMatch ? Color.yellow.opacity(0.3) :
                                        (selection.contains(index) ? Color.accentColor.opacity(0.2) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        let modifiers = NSEvent.modifierFlags
                                        if modifiers.contains(.shift), let last = lastSelectedIndex {
                                            let start = min(last, index)
                                            let end = max(last, index)
                                            if !modifiers.contains(.command) {
                                                selection.removeAll()
                                            }
                                            for i in start...end {
                                                selection.insert(i)
                                            }
                                        } else if modifiers.contains(.command) {
                                            if selection.contains(index) {
                                                selection.remove(index)
                                            } else {
                                                selection.insert(index)
                                            }
                                            lastSelectedIndex = index
                                        } else {
                                            selection = [index]
                                            lastSelectedIndex = index
                                        }
                                    }
                                }
                                .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        scrollProxy = proxy
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: appState.dictationHistory.count) { _, _ in
                        if shouldAutoScroll && searchText.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToBottom(proxy: proxy)
                            }
                        }
                    }
                    .simultaneousGesture(
                        DragGesture().onChanged { _ in
                            // User is scrolling manually, disable auto-scroll temporarily
                            shouldAutoScroll = false
                            lastScrollTime = Date()
                        }
                    )
                }

                // Footer hint
                Text("Click to select • Cmd+click for multiple • Shift+click for range • Drag to select text")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastIndex = reversedHistory.indices.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastIndex, anchor: .bottom)
            }
        }
    }

    private func jumpToCurrentMatch() {
        guard !matchingIndices.isEmpty,
              currentMatchIndex < matchingIndices.count,
              let proxy = scrollProxy else { return }

        let targetIndex = matchingIndices[currentMatchIndex]
        shouldAutoScroll = false
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(targetIndex, anchor: .center)
        }
    }

    private func highlightedText(_ text: String, highlight: String) -> some View {
        guard !highlight.isEmpty else { return Text(text).eraseToAnyView() }

        var attributedString = AttributedString(text)
        var searchStart = attributedString.startIndex

        while let range = attributedString[searchStart...].range(of: highlight, options: .caseInsensitive) {
            attributedString[range].backgroundColor = .yellow
            attributedString[range].foregroundColor = .black
            searchStart = range.upperBound
        }

        return Text(attributedString).eraseToAnyView()
    }
}

// MARK: - Debug Console

struct DebugConsoleView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug Log")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") {
                    appState.clearDebugLog()
                }
                .font(.system(size: 11))
            }
            .padding()

            Divider()

            if appState.debugLog.isEmpty {
                VStack {
                    Spacer()
                    Text("No log entries yet.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(appState.debugLog, id: \.self) { entry in
                                Text(entry)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(colorForLog(entry))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                                    .textSelection(.enabled)
                                Divider()
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func colorForLog(_ entry: String) -> Color {
        let lower = entry.lowercased()
        if lower.contains("error") || lower.contains("failed") {
            return .red
        }
        if lower.contains("warning") {
            return .orange
        }
        return .primary
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

struct InputDevicePicker: View {
    @Binding var selectedDeviceID: String?
    var onChange: (String?) -> Void
    
    @State private var devices: [AVCaptureDevice] = []
    
    var body: some View {
        Picker("", selection: Binding(
            get: { selectedDeviceID ?? "default" },
            set: { newValue in
                if newValue == "default" {
                    selectedDeviceID = nil
                    onChange(nil)
                } else {
                    selectedDeviceID = newValue
                    onChange(newValue)
                }
            }
        )) {
            Text("System Default").tag("default")
            Divider()
            ForEach(devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(device.uniqueID)
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

struct ShortcutRecorder: View {
    @Binding var shortcut: KeyboardShortcut
    let label: String
    var onChange: ((KeyboardShortcut) -> Void)?
    @State private var isRecording = false
    @State private var monitor: Any?
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                Text(isRecording ? "Type shortcut..." : shortcut.description)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.1))
                    .foregroundColor(isRecording ? .white : .primary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
    }
    
    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore just modifier keys
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 54 || event.keyCode == 55 || event.keyCode == 56 || event.keyCode == 57 ||
               event.keyCode == 58 || event.keyCode == 59 || event.keyCode == 60 || event.keyCode == 61 ||
               event.keyCode == 62 || event.keyCode == 63 {
                return event
            }
            
            // Map modifiers
            var modifiers: KeyboardModifiers = []
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            
            let newShortcut = KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers)
            shortcut = newShortcut
            onChange?(newShortcut)
            
            stopRecording()
            return nil // Consume event
        }
    }
    
    private func stopRecording() {
        isRecording = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

