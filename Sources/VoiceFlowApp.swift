import SwiftUI
import AppKit
import AVFoundation

@main
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
    var wakeMenuItem: NSMenuItem?
    var showHideMenuItem: NSMenuItem?
    var settingsWindow: NSWindow?
    private var panelWindow: FloatingPanelWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        print("[VoiceFlow] App launched")

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "VoiceFlow")
        }
        print("[VoiceFlow] Status bar item created")

        // Create menu
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "VoiceFlow", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        offMenuItem = NSMenuItem(title: "Off", action: #selector(setModeOff), keyEquivalent: "")
        offMenuItem?.target = self
        menu.addItem(offMenuItem!)

        onMenuItem = NSMenuItem(title: "On", action: #selector(setModeOn), keyEquivalent: "")
        onMenuItem?.target = self
        menu.addItem(onMenuItem!)

        wakeMenuItem = NSMenuItem(title: "Wake", action: #selector(setModeWake), keyEquivalent: "")
        wakeMenuItem?.target = self
        menu.addItem(wakeMenuItem!)

        menu.addItem(NSMenuItem.separator())

        showHideMenuItem = NSMenuItem(title: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "")
        showHideMenuItem?.target = self
        menu.addItem(showHideMenuItem!)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
    }

    func showPanelWindow() {
        setPanelVisible(true)
    }

    private func configurePanelWindow() {
        let panel = FloatingPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let hostingController = NSHostingController(
            rootView: FloatingPanelView()
                .environmentObject(appState)
        )
        panel.contentViewController = hostingController
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            panel.setContentSize(fittingSize)
        }

        panel.identifier = NSUserInterfaceItemIdentifier("voiceflow.panel")
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

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
        updateIcon("mic.slash.fill")
    }

    @objc func setModeOn() {
        print("[VoiceFlow] Setting mode: On")
        Task { @MainActor in
            appState.setMode(.on)
        }
        updateIcon("mic.fill")
    }

    @objc func setModeWake() {
        print("[VoiceFlow] Setting mode: Wake")
        Task { @MainActor in
            appState.setMode(.wake)
        }
        updateIcon("waveform")
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
        }
        
        print("[VoiceFlow] Showing settings window")
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateIcon(_ name: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceFlow")
    }

    func updateMenuCheckmarks() {
        Task { @MainActor in
            let mode = appState.microphoneMode
            offMenuItem?.state = mode == .off ? .on : .off
            onMenuItem?.state = mode == .on ? .on : .off
            wakeMenuItem?.state = mode == .wake ? .on : .off
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
