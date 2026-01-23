import Foundation
import AppKit

/// CLI interface for VoiceFlow
/// Usage:
///   VoiceFlow config list              - List all settings
///   VoiceFlow config get <key>         - Get a specific setting
///   VoiceFlow config set <key> <value> - Set a setting
///   VoiceFlow mode <on|off|sleep>      - Set mode (sends to running app)
///   VoiceFlow status                   - Get status from running app
///   VoiceFlow help                     - Show help
enum VoiceFlowCLI {

    // MARK: - Bundle ID

    static let bundleIds = [
        "com.jacobcole.voiceflow.dev",
        "com.jacobcole.voiceflow"
    ]

    static var activeBundleId: String {
        Bundle.main.bundleIdentifier ?? bundleIds[0]
    }

    // MARK: - Settings Keys

    static let settingsKeys: [(key: String, description: String, type: String)] = [
        ("assemblyai_api_key", "AssemblyAI API key", "string"),
        ("deepgram_api_key", "Deepgram API key", "string"),
        ("dictation_provider", "Dictation provider (auto/online/deepgram/offline)", "string"),
        ("launch_mode", "Initial mode on launch (On/Off/Sleep)", "string"),
        ("utterance_mode", "Utterance detection mode (quick/balanced/patient/dictation/extra_long/custom)", "string"),
        ("live_dictation_enabled", "Enable live dictation mode", "bool"),
        ("command_delay_ms", "Delay before executing commands (ms)", "number"),
        ("sleep_timer_enabled", "Enable auto-sleep timer", "bool"),
        ("sleep_timer_minutes", "Minutes before auto-sleep", "number"),
        ("vocabulary_prompt", "Custom vocabulary terms (comma-separated)", "string"),
        ("auto_populate_vocabulary", "Auto-add command phrases to vocabulary", "bool"),
        ("custom_confidence_threshold", "Custom end-of-turn confidence (0.0-1.0)", "number"),
        ("custom_silence_threshold_ms", "Custom silence threshold (ms)", "number"),
        ("active_behavior", "Active mode behavior (mixed/dictation/command)", "string"),
        ("auto_submit_enabled", "Auto-press Enter after utterance + silence (vibe coding)", "bool"),
        ("auto_submit_delay_seconds", "Seconds of silence before auto-submit (default 2.0)", "number"),
    ]

    // MARK: - Distributed Notification Names

    static let setModeNotification = "com.jacobcole.voiceflow.setMode"
    static let getStatusNotification = "com.jacobcole.voiceflow.getStatus"
    static let statusResponseNotification = "com.jacobcole.voiceflow.statusResponse"
    static let forceSendNotification = "com.jacobcole.voiceflow.forceSend"
    static let restartNotification = "com.jacobcole.voiceflow.restart"
    static let setAutoSubmitNotification = "com.jacobcole.voiceflow.setAutoSubmit"

    // MARK: - Main Entry Point

    /// Returns true if CLI handled the command, false to continue launching GUI
    static func handleArguments() -> Bool {
        let args = CommandLine.arguments

        // If no arguments (just the binary name), launch GUI
        guard args.count > 1 else { return false }

        let command = args[1].lowercased()

        switch command {
        case "config":
            handleConfig(Array(args.dropFirst(2)))
            return true

        case "mode":
            handleMode(Array(args.dropFirst(2)))
            return true

        case "status":
            handleStatus()
            return true

        case "force-send", "send":
            handleForceSend()
            return true

        case "log":
            handleLog(Array(args.dropFirst(2)))
            return true

        case "history":
            handleHistory(Array(args.dropFirst(2)))
            return true

        case "restart":
            handleRestart()
            return true

        case "auto-submit":
            handleAutoSubmit(Array(args.dropFirst(2)))
            return true

        case "vocab", "vocabulary":
            handleVocabulary(Array(args.dropFirst(2)))
            return true

        case "shortcuts":
            handleShortcuts()
            return true

        case "help", "-h", "--help":
            printHelp()
            return true

        case "-v", "--version":
            printVersion()
            return true

        default:
            // Unknown command - might be a macOS launch argument, continue to GUI
            if command.hasPrefix("-") {
                return false
            }
            print("Unknown command: \(command)")
            print("Run 'VoiceFlow help' for usage information.")
            exit(1)
        }
    }

    // MARK: - Config Commands

    private static func handleConfig(_ args: [String]) {
        guard let subcommand = args.first?.lowercased() else {
            print("Usage: VoiceFlow config <list|get|set>")
            exit(1)
        }

        switch subcommand {
        case "list":
            configList()

        case "get":
            guard args.count > 1 else {
                print("Usage: VoiceFlow config get <key>")
                exit(1)
            }
            configGet(args[1])

        case "set":
            guard args.count > 2 else {
                print("Usage: VoiceFlow config set <key> <value>")
                exit(1)
            }
            configSet(args[1], value: args[2])

        default:
            print("Unknown config command: \(subcommand)")
            print("Usage: VoiceFlow config <list|get|set>")
            exit(1)
        }
    }

    private static func configList() {
        let defaults = UserDefaults.standard

        print("VoiceFlow Settings (\(activeBundleId)):\n")
        print(String(repeating: "-", count: 70))

        for setting in settingsKeys {
            let value = defaults.object(forKey: setting.key)
            let displayValue: String

            if let value = value {
                switch setting.type {
                case "bool":
                    displayValue = (value as? Bool == true) ? "true" : "false"
                case "number":
                    displayValue = "\(value)"
                default:
                    if let str = value as? String {
                        // Mask API keys
                        if setting.key.contains("api_key") && str.count > 8 {
                            displayValue = String(str.prefix(8)) + "..." + " (\(str.count) chars)"
                        } else {
                            displayValue = str
                        }
                    } else {
                        displayValue = "\(value)"
                    }
                }
            } else {
                displayValue = "(not set)"
            }

            print("\(setting.key)")
            print("  Value: \(displayValue)")
            print("  Type: \(setting.type) - \(setting.description)\n")
        }
    }

    private static func configGet(_ key: String) {
        let defaults = UserDefaults.standard

        if let value = defaults.object(forKey: key) {
            print("\(value)")
        } else {
            print("(not set)")
        }
    }

    private static func configSet(_ key: String, value: String) {
        let defaults = UserDefaults.standard

        // Find the setting type
        let settingInfo = settingsKeys.first { $0.key == key }

        switch settingInfo?.type {
        case "bool":
            let boolValue = ["true", "1", "yes", "on"].contains(value.lowercased())
            defaults.set(boolValue, forKey: key)
            print("Set \(key) = \(boolValue)")

        case "number":
            if let doubleValue = Double(value) {
                defaults.set(doubleValue, forKey: key)
                print("Set \(key) = \(doubleValue)")
            } else {
                print("Error: Invalid number value '\(value)'")
                exit(1)
            }

        default:
            defaults.set(value, forKey: key)
            print("Set \(key) = \(value)")
        }

        // Sync to disk
        defaults.synchronize()
    }

    // MARK: - Mode Command

    private static func handleMode(_ args: [String]) {
        guard let mode = args.first?.lowercased() else {
            print("Usage: VoiceFlow mode <on|off|sleep>")
            exit(1)
        }

        guard ["on", "off", "sleep"].contains(mode) else {
            print("Invalid mode: \(mode)")
            print("Valid modes: on, off, sleep")
            exit(1)
        }

        // Send notification to running app
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name(setModeNotification),
            object: nil,
            userInfo: ["mode": mode],
            deliverImmediately: true
        )

        print("Sent mode command: \(mode)")
        print("(If VoiceFlow is not running, this command has no effect)")
    }

    // MARK: - Status Command

    private static func handleStatus() {
        let center = DistributedNotificationCenter.default()
        var receivedResponse = false

        // Listen for response
        let observer = center.addObserver(
            forName: NSNotification.Name(statusResponseNotification),
            object: nil,
            queue: .main
        ) { notification in
            receivedResponse = true

            if let userInfo = notification.userInfo {
                print("DEBUG: Received userInfo keys: \(userInfo.keys)")
                print("VoiceFlow Status:")
                print(String(repeating: "-", count: 40))

                if let mode = userInfo["mode"] as? String {
                    print("Mode: \(mode)")
                }
                if let connected = userInfo["connected"] as? Bool {
                    print("Connected: \(connected)")
                }
                if let provider = userInfo["provider"] as? String {
                    print("Provider: \(provider)")
                }
                if let build = userInfo["build"] as? Int {
                    print("Build: \(build)")
                }
                if let newerBuild = userInfo["newerBuild"] as? Bool {
                    print("Newer build available: \(newerBuild ? "YES (Restart required)" : "no")")
                }
                if let isPanelMinimal = userInfo["isPanelMinimal"] as? Bool {
                    print("Panel mode: \(isPanelMinimal ? "minimal" : "full")")
                }
                if let isPanelVisible = userInfo["isPanelVisible"] as? Bool {
                    print("Panel visible: \(isPanelVisible)")
                }
                if let audioLevel = userInfo["audioLevel"] as? Double {
                    print("Audio Level: \(String(format: "%.4f", audioLevel))")
                }
                if let transcript = userInfo["transcript"] as? String, !transcript.isEmpty {
                    print("Current transcript: \(transcript)")
                }
            }

            CFRunLoopStop(CFRunLoopGetMain())
        }

        // Request status
        center.postNotificationName(
            NSNotification.Name(getStatusNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        // Wait for response with timeout
        let timeout = DispatchTime.now() + .seconds(2)
        DispatchQueue.main.asyncAfter(deadline: timeout) {
            if !receivedResponse {
                print("VoiceFlow is not running or not responding.")
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }

        CFRunLoopRun()
        center.removeObserver(observer)
    }

    // MARK: - Force Send Command

    private static func handleForceSend() {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name(forceSendNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        print("Sent force-send command")
        print("(Types partial text or resends last utterance if buffer empty)")
    }

    // MARK: - Restart Command

    private static func handleRestart() {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name(restartNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        print("Sent restart command")
        print("(VoiceFlow will restart and preserve current mode)")
    }

    // MARK: - Auto-Submit Command

    private static func handleAutoSubmit(_ args: [String]) {
        guard let arg = args.first?.lowercased() else {
            print("Usage: VoiceFlow auto-submit <on|off> [delay_seconds]")
            print("  on    - Enable auto-submit (press Enter after utterance + silence)")
            print("  off   - Disable auto-submit")
            print("  delay - Optional: seconds of silence before submit (default 2.0)")
            exit(1)
        }

        let enabled = arg == "on" || arg == "true" || arg == "1"
        let delay = args.dropFirst().first.flatMap { Double($0) } ?? 2.0

        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name(setAutoSubmitNotification),
            object: nil,
            userInfo: ["enabled": enabled, "delay": delay],
            deliverImmediately: true
        )

        print("Auto-submit: \(enabled ? "ON" : "OFF") (delay: \(delay)s)")
        print("(Sends Enter key after utterance completes + \(delay)s silence)")
    }

    // MARK: - Log Command

    private static func handleLog(_ args: [String]) {
        let logPath = NSHomeDirectory() + "/Library/Logs/VoiceFlow/voiceflow.log"
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: logPath) else {
            print("Log file not found at: \(logPath)")
            print("(VoiceFlow needs to run first to create the log)")
            exit(1)
        }

        let lines = args.first.flatMap { Int($0) } ?? 50

        if args.contains("-f") || args.contains("--follow") {
            // Follow mode - exec tail -f
            print("Following log file (Ctrl+C to stop)...")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            task.arguments = ["-f", "-n", String(lines), logPath]
            task.standardOutput = FileHandle.standardOutput
            task.standardError = FileHandle.standardError
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                print("Error running tail: \(error)")
            }
        } else {
            // Show last N lines
            do {
                let content = try String(contentsOfFile: logPath, encoding: .utf8)
                let allLines = content.components(separatedBy: "\n")
                let lastLines = allLines.suffix(lines)
                print(lastLines.joined(separator: "\n"))
            } catch {
                print("Error reading log: \(error)")
            }
        }
    }

    // MARK: - History Command

    private static func handleHistory(_ args: [String]) {
        let defaults = UserDefaults.standard
        let history = defaults.stringArray(forKey: "dictation_history") ?? []

        if history.isEmpty {
            print("No dictation history.")
            return
        }

        let count = args.first.flatMap { Int($0) } ?? 10
        let showAll = args.contains("--all") || args.contains("-a")
        let showCommands = args.contains("--commands") || args.contains("-c")

        var filteredHistory = history
        if !showCommands {
            filteredHistory = history.filter { !$0.hasPrefix("[Command]") }
        }

        let itemsToShow = showAll ? filteredHistory : Array(filteredHistory.prefix(count))

        print("Dictation History (\(itemsToShow.count) of \(filteredHistory.count) entries):")
        print(String(repeating: "-", count: 50))

        for (index, entry) in itemsToShow.enumerated() {
            let truncated = entry.count > 80 ? String(entry.prefix(77)) + "..." : entry
            print("\(index + 1). \(truncated)")
        }
    }

    // MARK: - Vocabulary Command

    private static func handleVocabulary(_ args: [String]) {
        guard let subcommand = args.first?.lowercased() else {
            print("Usage: VoiceFlow vocab <list|add|remove|enable|disable>")
            print("")
            print("Commands:")
            print("  list              - List all vocabulary entries")
            print("  add <spoken> <written> [category]  - Add a new entry")
            print("  remove <spoken>   - Remove an entry by spoken phrase")
            print("  enable <spoken>   - Enable an entry")
            print("  disable <spoken>  - Disable an entry")
            exit(1)
        }

        let defaults = UserDefaults.standard
        var entries = loadVocabularyEntries(from: defaults)

        switch subcommand {
        case "list":
            if entries.isEmpty {
                print("No custom vocabulary entries.")
                print("Add entries with: VoiceFlow vocab add <spoken> <written>")
            } else {
                print("Custom Vocabulary (\(entries.count) entries):")
                print(String(repeating: "-", count: 60))
                for entry in entries {
                    let status = entry.isEnabled ? "✓" : "○"
                    let category = entry.category.map { " [\($0)]" } ?? ""
                    print("\(status) \"\(entry.spokenPhrase)\" → \"\(entry.writtenForm)\"\(category)")
                }
            }

        case "add":
            guard args.count >= 3 else {
                print("Usage: VoiceFlow vocab add <spoken> <written> [category]")
                print("Example: VoiceFlow vocab add \"nuos\" \"Noos\" \"Projects\"")
                exit(1)
            }
            let spoken = args[1]
            let written = args[2]
            let category = args.count > 3 ? args[3] : nil

            // Check for duplicate
            if entries.contains(where: { $0.spokenPhrase.lowercased() == spoken.lowercased() }) {
                print("Entry for '\(spoken)' already exists. Remove it first to replace.")
                exit(1)
            }

            let newEntry = VocabEntry(
                id: UUID().uuidString,
                spokenPhrase: spoken,
                writtenForm: written,
                category: category,
                isEnabled: true
            )
            entries.append(newEntry)
            saveVocabularyEntries(entries, to: defaults)
            print("Added: \"\(spoken)\" → \"\(written)\"")
            notifyVocabularyChanged()

        case "remove", "delete":
            guard args.count >= 2 else {
                print("Usage: VoiceFlow vocab remove <spoken>")
                exit(1)
            }
            let spoken = args[1].lowercased()
            let originalCount = entries.count
            entries.removeAll { $0.spokenPhrase.lowercased() == spoken }
            if entries.count < originalCount {
                saveVocabularyEntries(entries, to: defaults)
                print("Removed entry for '\(args[1])'")
                notifyVocabularyChanged()
            } else {
                print("No entry found for '\(args[1])'")
                exit(1)
            }

        case "enable":
            guard args.count >= 2 else {
                print("Usage: VoiceFlow vocab enable <spoken>")
                exit(1)
            }
            let spoken = args[1].lowercased()
            if let index = entries.firstIndex(where: { $0.spokenPhrase.lowercased() == spoken }) {
                entries[index].isEnabled = true
                saveVocabularyEntries(entries, to: defaults)
                print("Enabled: '\(entries[index].spokenPhrase)'")
                notifyVocabularyChanged()
            } else {
                print("No entry found for '\(args[1])'")
                exit(1)
            }

        case "disable":
            guard args.count >= 2 else {
                print("Usage: VoiceFlow vocab disable <spoken>")
                exit(1)
            }
            let spoken = args[1].lowercased()
            if let index = entries.firstIndex(where: { $0.spokenPhrase.lowercased() == spoken }) {
                entries[index].isEnabled = false
                saveVocabularyEntries(entries, to: defaults)
                print("Disabled: '\(entries[index].spokenPhrase)'")
                notifyVocabularyChanged()
            } else {
                print("No entry found for '\(args[1])'")
                exit(1)
            }

        default:
            print("Unknown vocab command: \(subcommand)")
            print("Valid commands: list, add, remove, enable, disable")
            exit(1)
        }
    }

    // Simple struct for CLI vocabulary handling (matches AppState.VocabularyEntry)
    private struct VocabEntry: Codable {
        var id: String
        var spokenPhrase: String
        var writtenForm: String
        var category: String?
        var isEnabled: Bool
    }

    private static func loadVocabularyEntries(from defaults: UserDefaults) -> [VocabEntry] {
        guard let data = defaults.data(forKey: "custom_vocabulary"),
              let entries = try? JSONDecoder().decode([VocabEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func saveVocabularyEntries(_ entries: [VocabEntry], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: "custom_vocabulary")
            defaults.synchronize()
        }
    }

    private static func notifyVocabularyChanged() {
        // Notify running app to reload vocabulary
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("com.jacobcole.voiceflow.vocabularyChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        print("(Notified running app to reload vocabulary)")
    }

    // MARK: - Shortcuts Command

    private static func handleShortcuts() {
        let defaults = UserDefaults.standard

        print("VoiceFlow Keyboard Shortcuts:")
        print(String(repeating: "-", count: 50))

        // Mode shortcuts
        print("\nMode Shortcuts:")
        let modeOnKey = defaults.integer(forKey: "modeOnShortcut_keyCode")
        let modeOnMods = defaults.integer(forKey: "modeOnShortcut_modifiers")
        print("  On:     \(formatShortcut(keyCode: modeOnKey, modifiers: modeOnMods, defaultKey: "1", defaultMods: "⌃⌥⌘"))")

        let modeSleepKey = defaults.integer(forKey: "modeSleepShortcut_keyCode")
        let modeSleepMods = defaults.integer(forKey: "modeSleepShortcut_modifiers")
        print("  Sleep:  \(formatShortcut(keyCode: modeSleepKey, modifiers: modeSleepMods, defaultKey: "2", defaultMods: "⌃⌥⌘"))")

        let modeOffKey = defaults.integer(forKey: "modeOffShortcut_keyCode")
        let modeOffMods = defaults.integer(forKey: "modeOffShortcut_modifiers")
        print("  Off:    \(formatShortcut(keyCode: modeOffKey, modifiers: modeOffMods, defaultKey: "0", defaultMods: "⌃⌥⌘"))")

        // Toggle shortcut
        print("\nOther Shortcuts:")
        let toggleKey = defaults.integer(forKey: "modeToggleShortcut_keyCode")
        let toggleMods = defaults.integer(forKey: "modeToggleShortcut_modifiers")
        print("  Toggle On/Sleep:  \(formatShortcut(keyCode: toggleKey, modifiers: toggleMods, defaultKey: "F19", defaultMods: ""))")

        let pttKey = defaults.integer(forKey: "pttShortcut_keyCode")
        let pttMods = defaults.integer(forKey: "pttShortcut_modifiers")
        print("  Push-to-Talk:     \(formatShortcut(keyCode: pttKey, modifiers: pttMods, defaultKey: "Space", defaultMods: "⌃⌥"))")

        let cmdPanelKey = defaults.integer(forKey: "commandPanelShortcut_keyCode")
        let cmdPanelMods = defaults.integer(forKey: "commandPanelShortcut_modifiers")
        print("  Command Panel:    \(formatShortcut(keyCode: cmdPanelKey, modifiers: cmdPanelMods, defaultKey: "C", defaultMods: "⌃⌥"))")
    }

    private static func formatShortcut(keyCode: Int, modifiers: Int, defaultKey: String, defaultMods: String) -> String {
        // If not set (0), return default
        if keyCode == 0 && modifiers == 0 {
            return "\(defaultMods)\(defaultKey) (default)"
        }

        var result = ""

        // Decode modifiers (NSEvent.ModifierFlags raw values)
        if modifiers & (1 << 18) != 0 { result += "⌃" }  // control
        if modifiers & (1 << 19) != 0 { result += "⌥" }  // option
        if modifiers & (1 << 17) != 0 { result += "⇧" }  // shift
        if modifiers & (1 << 20) != 0 { result += "⌘" }  // command

        // Map common key codes to readable names
        let keyName: String
        switch keyCode {
        case 0: keyName = "A"
        case 1: keyName = "S"
        case 2: keyName = "D"
        case 3: keyName = "F"
        case 8: keyName = "C"
        case 18: keyName = "1"
        case 19: keyName = "2"
        case 20: keyName = "3"
        case 29: keyName = "0"
        case 49: keyName = "Space"
        case 53: keyName = "Esc"
        case 80: keyName = "F19"
        case 96: keyName = "F5"
        case 97: keyName = "F6"
        case 98: keyName = "F7"
        case 99: keyName = "F3"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 103: keyName = "F11"
        case 105: keyName = "F13"
        case 107: keyName = "F14"
        case 109: keyName = "F10"
        case 111: keyName = "F12"
        case 113: keyName = "F15"
        case 118: keyName = "F4"
        case 120: keyName = "F2"
        case 122: keyName = "F1"
        default: keyName = "key(\(keyCode))"
        }

        return result + keyName
    }

    // MARK: - Help

    private static func printHelp() {
        print("""
        VoiceFlow - Voice dictation and commands for macOS

        USAGE:
            VoiceFlow                           Launch the GUI application
            VoiceFlow config list               List all settings with values
            VoiceFlow config get <key>          Get a specific setting value
            VoiceFlow config set <key> <value>  Set a setting value
            VoiceFlow mode <on|off|sleep>       Set mode (controls running app)
            VoiceFlow status                    Get status from running app
            VoiceFlow force-send                Force send partial text or last utterance
            VoiceFlow log [N] [-f]              Show last N log lines (default 50), -f to follow
            VoiceFlow history [N] [-c] [-a]     Show dictation history (default 10), -c=commands, -a=all
            VoiceFlow vocab list                List custom vocabulary entries
            VoiceFlow vocab add <s> <w> [cat]   Add vocabulary: spoken → written [category]
            VoiceFlow vocab remove <spoken>     Remove a vocabulary entry
            VoiceFlow vocab enable/disable <s>  Toggle a vocabulary entry
            VoiceFlow restart                   Restart app (preserves current mode)
            VoiceFlow auto-submit <on|off> [s]  Toggle auto-Enter after utterance (vibe coding)
            VoiceFlow shortcuts                 Show all keyboard shortcuts
            VoiceFlow help                      Show this help message

        CONFIG KEYS:
        """)

        for setting in settingsKeys {
            print("    \(setting.key.padding(toLength: 30, withPad: " ", startingAt: 0)) \(setting.description)")
        }

        print("""

        EXAMPLES:
            VoiceFlow config set dictation_provider deepgram
            VoiceFlow config set live_dictation_enabled true
            VoiceFlow config get assemblyai_api_key
            VoiceFlow mode on
            VoiceFlow status
        """)
    }

    private static func printVersion() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        print("VoiceFlow \(version)")
    }
}
