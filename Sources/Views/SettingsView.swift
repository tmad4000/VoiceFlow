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
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKeyInput: String = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AssemblyAI API Key")
                        .font(.headline)

                    SecureField("Enter your API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onAppear {
                            apiKeyInput = appState.apiKey
                        }

                    HStack {
                        Button("Save") {
                            appState.saveAPIKey(apiKeyInput)
                        }
                        .disabled(apiKeyInput.isEmpty)

                        Spacer()

                        Link("Get API Key",
                             destination: URL(string: "https://www.assemblyai.com/app/account")!)
                            .font(.caption)
                    }

                    Text("Your API key is stored locally in UserDefaults.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility Permissions")
                        .font(.headline)

                    Text("VoiceFlow needs Accessibility permissions to type text and execute keyboard shortcuts in other applications.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Open System Preferences") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About VoiceFlow")
                        .font(.headline)

                    Text("A speech recognition app designed for users with RSI. Uses AssemblyAI for real-time transcription.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Version 1.0.0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

struct VoiceCommandsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedCommand: VoiceCommand?
    @State private var showingAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Voice Commands")
                    .font(.headline)

                Spacer()

                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .help("Add new voice command")
            }
            .padding()

            Divider()

            // Command list
            List(selection: $selectedCommand) {
                ForEach(appState.voiceCommands) { command in
                    VoiceCommandRow(command: command)
                        .tag(command)
                }
                .onDelete(perform: deleteCommands)
            }
            .listStyle(.inset)

            // Footer info
            VStack(alignment: .leading, spacing: 4) {
                Text("Say a phrase in Wake mode to trigger the keyboard shortcut.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Built-in commands: \"microphone on\", \"microphone off\", \"start dictation\", \"stop dictation\"")
                    .font(.caption)
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

                Text(command.shortcut.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !command.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddCommandSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var phrase: String = ""
    @State private var selectedKey: String = "A"
    @State private var useCommand = false
    @State private var useShift = false
    @State private var useOption = false
    @State private var useControl = false

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

            Form {
                TextField("Phrase", text: $phrase)
                    .textFieldStyle(.roundedBorder)

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
                .disabled(phrase.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    func createCommand() -> VoiceCommand {
        var modifiers = KeyboardModifiers()
        if useCommand { modifiers.insert(.command) }
        if useShift { modifiers.insert(.shift) }
        if useOption { modifiers.insert(.option) }
        if useControl { modifiers.insert(.control) }

        let keyCode = keyCodeForString(selectedKey)
        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)

        return VoiceCommand(phrase: phrase, shortcut: shortcut)
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

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
