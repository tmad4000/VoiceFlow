import SwiftUI

@main
struct VoiceFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.microphoneMode.icon)
                .foregroundStyle(menuBarIconColor)
        }

        Window("VoiceFlow", id: "panel") {
            FloatingPanelView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var menuBarIconColor: Color {
        switch appState.microphoneMode {
        case .off: return .secondary
        case .on: return .green
        case .wake: return .orange
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Request microphone permission on launch
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("Microphone permission denied")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

import AVFoundation
