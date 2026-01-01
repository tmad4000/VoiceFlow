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
    ]

    // MARK: - Distributed Notification Names

    static let setModeNotification = "com.jacobcole.voiceflow.setMode"
    static let getStatusNotification = "com.jacobcole.voiceflow.getStatus"
    static let statusResponseNotification = "com.jacobcole.voiceflow.statusResponse"

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
