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
    private var pttActivatedOnMode: Bool = false  // Track if On mode was activated via PTT

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

        setupGlobalShortcuts()
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
                    "audioLevel": Double(self.appState.audioLevel),
                    "mode": self.appState.microphoneMode.rawValue,
                    "connected": self.appState.isConnected,
                    "provider": self.appState.dictationProvider.rawValue,
                    "transcript": self.appState.currentTranscript,
                    "newerBuild": self.appState.isNewerBuildAvailable
                ]
                
                self.appState.logDebug("CLI Status Check: Level=\(self.appState.audioLevel)")

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
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
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
        panel.level = .floating // Changed from statusBar to play nice with non-activating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        
        // Set size constraints
        panel.minSize = NSSize(width: 280, height: 100)
        panel.maxSize = NSSize(width: 1000, height: 800)

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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 500, height: 600))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self // Set delegate to detect close
            
            settingsWindow = window
        } else {
            settingsWindow?.center()
        }
        
        print("[VoiceFlow] Showing settings window")
        NSApp.setActivationPolicy(.regular) // Show in Dock and show menu bar
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.setupMainMenu()
            NSApp.activate(ignoringOtherApps: true)
            self.settingsWindow?.level = .normal // Reset level in case it was changed
            self.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu(title: "App")
        appMenu.submenu?.addItem(withTitle: "About VoiceFlow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.submenu?.addItem(NSMenuItem.separator())
        appMenu.submenu?.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.submenu?.addItem(NSMenuItem.separator())
        appMenu.submenu?.addItem(withTitle: "Quit VoiceFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenu)
        
        // Edit Menu (Required for Search Bar to work with Cmd+V etc)
        let editMenu = NSMenuItem()
        editMenu.submenu = NSMenu(title: "Edit")
        editMenu.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editMenu)
        
        // Help Menu
        let helpMenu = NSMenuItem()
        helpMenu.submenu = NSMenu(title: "Help")
        let searchItem = NSMenuItem(title: "Search Settings", action: #selector(focusSearch), keyEquivalent: "f")
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        helpMenu.submenu?.addItem(searchItem)
        mainMenu.addItem(helpMenu)
        
        NSApp.mainMenu = mainMenu
    }

    @objc func focusSearch() {
        appState.settingsSearchText = ""
        // This is a bit of a hack to focus the search bar, 
        // usually we'd use a focused binding or @FocusState, 
        // but for now setting the text empty and opening the window is a good start.
        openSettings()
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

    private func setupGlobalShortcuts() {
        // Remove existing monitor if any (though we only call this once usually)
        if let monitor = pttMonitor {
            NSEvent.removeMonitor(monitor)
        }

        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return }

            let currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = UInt16(event.keyCode)
            
            // DEBUG LOGGING
            if self.appState.isDebugMode {
                // Log non-standard keys or modifiers for debugging
                if keyCode > 64 || event.type == .flagsChanged {
                    Task { @MainActor in
                        self.appState.logDebug("Key Event: Code=\(keyCode), Type=\(event.type == .keyDown ? "Down" : (event.type == .keyUp ? "Up" : "Flag"))")
                    }
                }
            }
            
            // Helper to check precise match (for toggles/commands)
            func matches(_ shortcut: KeyboardShortcut) -> Bool {
                let requiredFlags = self.mapModifiers(shortcut.modifiers)
                return currentModifiers == requiredFlags && keyCode == shortcut.keyCode
            }

            // PTT Logic (Special handling for Hold)
            if keyCode == self.appState.pttShortcut.keyCode {
                let shortcut = self.appState.pttShortcut
                let requiredFlags = self.mapModifiers(shortcut.modifiers)
                
                var isPTTPressed = false
                let isModifierKey = (54...63).contains(keyCode)
                
                if isModifierKey {
                    // For modifier PTT (e.g. Ctrl), check if the specific flag is present
                    // Note: If shortcut is just "Ctrl", requiredFlags is [.control].
                    // If user presses "Ctrl+Opt", flags are [.control, .option]. 
                    // Strict equality (current == required) fails if other keys held.
                    // For PTT, strict is safer to avoid accidental triggers, but lenient is often expected.
                    // Let's use strict equality for PTT to avoid conflicts.
                    isPTTPressed = (event.type == .flagsChanged) && (currentModifiers == requiredFlags)
                } else {
                    // Standard key: Must be KeyDown and modifiers match
                    isPTTPressed = (event.type == .keyDown) && (currentModifiers == requiredFlags)
                }
                
                // Determine Release
                var isPTTReleased = false
                if isModifierKey {
                    // Released if flagsChanged AND flags NO LONGER match required
                    // (Usually flags are empty or missing the bit)
                    isPTTReleased = (event.type == .flagsChanged) && (currentModifiers != requiredFlags)
                } else {
                    isPTTReleased = (event.type == .keyUp)
                    // Note: We don't check modifiers on KeyUp because users might release modifiers before key
                }

                Task { @MainActor in
                    if isPTTPressed {
                        if self.appState.microphoneMode != .on {
                            self.appState.setMode(.on)
                            self.pttActivatedOnMode = true  // Mark that PTT activated On mode
                            self.appState.logDebug("PTT: ON")
                        }
                    } else if isPTTReleased {
                        // Only trigger sleep if PTT was actually used to enter On mode
                        if self.appState.microphoneMode == .on && self.pttActivatedOnMode {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                Task { @MainActor in
                                    if self.appState.microphoneMode == .on && self.pttActivatedOnMode {
                                        self.appState.setMode(.sleep)
                                        self.pttActivatedOnMode = false  // Reset flag
                                        self.appState.logDebug("PTT: SLEEP")
                                    }
                                }
                            }
                        }
                    }
                }
                // Don't return here, allow other checks? No, PTT consumes the logic for this key.
                // But wait, if PTT is same as Toggle? Conflict. PTT wins.
            }
            
            // Mode Switching (Trigger on KeyDown or relevant FlagsChanged)
            let isModifierKey = (54...63).contains(keyCode)
            let isDown = event.type == .keyDown || (event.type == .flagsChanged && currentModifiers.contains(self.mapModifiers(KeyboardModifiers(rawValue: 1 << 0)).union(self.mapModifiers(KeyboardModifiers(rawValue: 1 << 1))).union(self.mapModifiers(KeyboardModifiers(rawValue: 1 << 2))).union(self.mapModifiers(KeyboardModifiers(rawValue: 1 << 3)))))
            
            // Re-evaluating isDown for modifiers is hard without knowing which bit changed.
            // But matches() already checks if the flags match the requirement.
            // If matches() is true AND it's a keyDown -> Always a press.
            // If matches() is true AND it's a flagsChanged -> It's a press (since flags now match).
            
            if event.type == .keyDown || event.type == .flagsChanged {
                if matches(self.appState.modeToggleShortcut) {
                    Task { @MainActor in
                        self.appState.logDebug("Shortcut: modeToggle triggered")
                        if self.appState.microphoneMode == .on {
                            self.appState.setMode(.sleep)
                        } else {
                            self.appState.setMode(.on)
                        }
                    }
                } else if matches(self.appState.modeOnShortcut) {
                    Task { @MainActor in
                        self.appState.logDebug("Shortcut: modeOn triggered")
                        self.appState.setMode(.on)
                    }
                } else if matches(self.appState.modeSleepShortcut) {
                    Task { @MainActor in
                        self.appState.logDebug("Shortcut: modeSleep triggered")
                        self.appState.setMode(.sleep)
                    }
                } else if matches(self.appState.modeOffShortcut) {
                    Task { @MainActor in
                        self.appState.logDebug("Shortcut: modeOff triggered")
                        self.appState.setMode(.off)
                    }
                }
            }
        }
    }
    
    nonisolated private func mapModifiers(_ modifiers: KeyboardModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

extension AppDelegate: NSMenuDelegate, NSWindowDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuCheckmarks()
    }
    
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
