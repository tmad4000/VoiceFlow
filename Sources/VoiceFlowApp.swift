import SwiftUI
import AppKit
import AVFoundation
import Combine

/// Main entry point - handles CLI or launches GUI
@main
enum VoiceFlowMain {
    static func main() {
        // Check if we should handle CLI commands
        if VoiceFlowCLI.handleArguments() {
            // CLI handled the command, exit without launching GUI
            return
        }

        // No CLI command, launch GUI normally
        VoiceFlowApp.main()
    }
}

struct VoiceFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            HiddenWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var appState: AppState = AppState() // Instantiated here
    var offMenuItem: NSMenuItem?
    var onMenuItem: NSMenuItem?
    var sleepMenuItem: NSMenuItem?
    var showHideMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var panelWindow: FloatingPanelWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pttMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSLog("[VoiceFlow] App launched - applicationDidFinishLaunching called")

        // Create status bar item
        NSLog("[VoiceFlow] Creating status bar item...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSLog("[VoiceFlow] statusItem created: \(statusItem != nil), button: \(statusItem?.button != nil)")

        if let button = statusItem?.button {
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceFlow") {
                button.image = image
                NSLog("[VoiceFlow] Set SF Symbol image on button")
            } else {
                button.title = "🎤"
                NSLog("[VoiceFlow] SF Symbol failed, set emoji title")
            }
        } else {
            NSLog("[VoiceFlow] ERROR: statusItem.button is nil!")
        }
        NSLog("[VoiceFlow] Status bar setup complete")

        // Subscribe to mode changes to update icon
        appState.$microphoneMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.updateIcon(mode.icon)
            }
            .store(in: &cancellables)

        // Create menu
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "VoiceFlow", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        offMenuItem = NSMenuItem(title: "Off", action: #selector(setModeOff), keyEquivalent: "0")
        offMenuItem?.keyEquivalentModifierMask = [.control, .option, .command]
        offMenuItem?.target = self
        menu.addItem(offMenuItem!)

        onMenuItem = NSMenuItem(title: "On", action: #selector(setModeOn), keyEquivalent: "1")
        onMenuItem?.keyEquivalentModifierMask = [.control, .option, .command]
        onMenuItem?.target = self
        menu.addItem(onMenuItem!)

        sleepMenuItem = NSMenuItem(title: "Sleep", action: #selector(setModeSleep), keyEquivalent: "2")
        sleepMenuItem?.keyEquivalentModifierMask = [.control, .option, .command]
        sleepMenuItem?.target = self
        menu.addItem(sleepMenuItem!)

        menu.addItem(NSMenuItem.separator())

        showHideMenuItem = NSMenuItem(title: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "")
        showHideMenuItem?.target = self
        menu.addItem(showHideMenuItem!)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        // Hidden shortcut for pasting last utterance (Ctrl+Cmd+V)
        let pasteItem = NSMenuItem(title: "Paste Last Utterance", action: #selector(pasteLastUtterance), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.control, .command]
        pasteItem.target = self
        pasteItem.isHidden = true // Hide from menu but keep shortcut active
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Request microphone permission on launch
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("[VoiceFlow] Microphone permission: \(granted ? "granted" : "denied")")
        }

        configurePanelWindow()
        appState.panelVisibilityHandler = { [weak self] visible in
            self?.setPanelVisible(visible)
        }

        // Show the panel window after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.setPanelVisible(self.appState.isPanelVisible)
        }

        // Listen for notifications from panel
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: Notification.Name("openSettings"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: Notification.Name("openHistory"),
            object: nil
        )

        // Listen for CLI commands via distributed notifications
        setupCLINotifications()

        setupPTT()
    }

    private func setupCLINotifications() {
        let center = DistributedNotificationCenter.default()

        // Handle mode changes from CLI
        center.addObserver(
            forName: NSNotification.Name(VoiceFlowCLI.setModeNotification),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let modeString = notification.userInfo?["mode"] as? String else { return }

            Task { @MainActor in
                switch modeString.lowercased() {
                case "on":
                    self.appState.setMode(.on)
                    self.appState.logDebug("CLI: Mode set to On")
                case "off":
                    self.appState.setMode(.off)
                    self.appState.logDebug("CLI: Mode set to Off")
                case "sleep":
                    self.appState.setMode(.sleep)
                    self.appState.logDebug("CLI: Mode set to Sleep")
                default:
                    break
                }
            }
        }

        // Handle status requests from CLI
        center.addObserver(
            forName: NSNotification.Name(VoiceFlowCLI.getStatusNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                let userInfo: [String: Any] = [
                    "mode": self.appState.microphoneMode.rawValue,
                    "connected": self.appState.isConnected,
                    "provider": self.appState.dictationProvider.rawValue,
                    "transcript": self.appState.currentTranscript
                ]

                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name(VoiceFlowCLI.statusResponseNotification),
                    object: nil,
                    userInfo: userInfo,
                    deliverImmediately: true
                )
            }
        }
    }

    func showPanelWindow() {
        setPanelVisible(true)
    }

    private func configurePanelWindow() {
        let panel = FloatingPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let hostingController = NSHostingController(
            rootView: FloatingPanelView()
                .environmentObject(appState)
        )
        
        let containerView = FirstMouseContainerView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
        
        panel.contentView = containerView
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            panel.setContentSize(fittingSize)
        }

        panel.identifier = NSUserInterfaceItemIdentifier("voiceflow.panel")
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        
        // Set size constraints
        panel.minSize = NSSize(width: 360, height: 140)
        panel.maxSize = NSSize(width: 520, height: 800)

        panelWindow = panel
    }

    private func setPanelVisible(_ visible: Bool) {
        guard let panelWindow else { return }
        appState.isPanelVisible = visible
        showHideMenuItem?.title = visible ? "Hide Panel" : "Show Panel"

        if visible {
            positionPanelWindow(panelWindow)
            panelWindow.makeKeyAndOrderFront(nil)
        } else {
            panelWindow.orderOut(nil)
        }
    }

    private func positionPanelWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let panelWidth = window.frame.width
        let x = (screen.frame.width - panelWidth) / 2 + screen.frame.origin.x
        let y = screen.frame.maxY - 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc func togglePanel() {
        setPanelVisible(!appState.isPanelVisible)
    }

    @objc func setModeOff() {
        print("[VoiceFlow] Setting mode: Off")
        Task { @MainActor in
            appState.setMode(.off)
        }
    }

    @objc func setModeOn() {
        print("[VoiceFlow] Setting mode: On")
        Task { @MainActor in
            appState.setMode(.on)
        }
    }

    @objc func setModeSleep() {
        print("[VoiceFlow] Setting mode: Sleep")
        Task { @MainActor in
            appState.setMode(.sleep)
        }
    }

    @objc func openSettings() {
        print("[VoiceFlow] openSettings called")
        if settingsWindow == nil {
            print("[VoiceFlow] Creating settings window")
            let settingsView = SettingsView()
                .environmentObject(appState)
            let hostingController = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "VoiceFlow Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 500, height: 400))
            window.center()
            window.isReleasedWhenClosed = false
            
            settingsWindow = window
        } else {
            settingsWindow?.center()
        }
        
        print("[VoiceFlow] Showing settings window")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.level = .normal // Reset level in case it was changed
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func pasteLastUtterance() {
        Task { @MainActor in
            appState.pasteLastUtterance()
        }
    }

    func updateIcon(_ name: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceFlow")
    }

    func updateMenuCheckmarks() {
        Task { @MainActor in
            let mode = appState.microphoneMode
            offMenuItem?.state = mode == .off ? .on : .off
            onMenuItem?.state = mode == .on ? .on : .off
            sleepMenuItem?.state = mode == .sleep ? .on : .off
        }
    }

    private func setupPTT() {
        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self else { return }

            // PTT Shortcut: Option+Cmd+Space (Hold)
            // Note: This conflicts with Spotlight "Search Mac" shortcut - user should disable it in System Settings
            let pttModifiers: NSEvent.ModifierFlags = [.option, .command]
            let currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if currentModifiers == pttModifiers && event.keyCode == 49 { // Space bar
                Task { @MainActor in
                    if event.type == .keyDown {
                        if self.appState.microphoneMode != .on {
                            self.appState.setMode(.on)
                            self.appState.logDebug("PTT: ON")
                        }
                    } else if event.type == .keyUp {
                        if self.appState.microphoneMode == .on {
                            // Delay slightly to ensure last words are caught
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                Task { @MainActor in
                                    // Only switch back if we are still in ON mode (user hasn't clicked something else)
                                    if self.appState.microphoneMode == .on {
                                        self.appState.setMode(.sleep)
                                        self.appState.logDebug("PTT: SLEEP")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuCheckmarks()
    }
}
