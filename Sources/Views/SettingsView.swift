import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            VoiceCommandsSettingsView()
                .tabItem {
                    Label("Commands", systemImage: "command")
                }

            DebugConsoleView()
                .tabItem {
                    Label("Debug", systemImage: "terminal")
                }
        }
        .frame(width: 480, height: 580)
    }
}

// MARK: - Reusable Components

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
    @State private var showAdvancedUtterance = false
    @State private var showDebugInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // API Key Section
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

                            Spacer()

                            Link("Get API Key", destination: URL(string: "https://www.assemblyai.com/app/account")!)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(4)
                }

                // permissions section ...
                
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
                    }
                    .padding(4)
                }

                // Dictation Settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dictation")
                            .font(.system(size: 13, weight: .semibold))

                        Toggle("Live Dictation", isOn: liveDictationBinding)
                            .font(.system(size: 13))

                        Text("Type words as they become final (faster, but no punctuation).")
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mic: \(appState.microphoneAuthStatusDescription)")
                        Text("Accessibility: \(appState.accessibilityStatusDescription)")
                        Text("isMicGranted: \(appState.isMicrophoneGranted ? "true" : "false")")
                        Text("isA11yGranted: \(appState.isAccessibilityGranted ? "true" : "false")")

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
                        }
                        .padding(.top, 4)

                        Text("Reset command: tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Voice Commands")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .help("Add new voice command")
            }
            .padding()

            Divider()

            // Command list
            List {
                Section(header: Text("User Commands")) {
                    ForEach(appState.voiceCommands) { command in
                        VoiceCommandRow(command: command)
                            .tag(command)
                    }
                    .onDelete(perform: deleteCommands)
                }

                Section(header: Text("System Commands")) {
                    ForEach(AppState.systemCommandList, id: \.phrase) { command in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\"\(command.phrase)\"")
                                    .font(.system(size: 13, weight: .medium))
                                Text(command.description)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("System")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset)

            // Footer info
            VStack(alignment: .leading, spacing: 4) {
                Text("Say a phrase in On mode to trigger a shortcut.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
        appState.voiceCommands.remove(atOffsets: offsets)
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

                Text(command.replacementText ?? command.shortcut?.description ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
            return VoiceCommand(phrase: phrase, shortcut: nil, replacementText: replacementText)
        } else {
            var modifiers = KeyboardModifiers()
            if useCommand { modifiers.insert(.command) }
            if useShift { modifiers.insert(.shift) }
            if useOption { modifiers.insert(.option) }
            if useControl { modifiers.insert(.control) }

            let keyCode = keyCodeForString(selectedKey)
            let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)

            return VoiceCommand(phrase: phrase, shortcut: shortcut, replacementText: nil)
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
                                    .foregroundColor(.primary)
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
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
