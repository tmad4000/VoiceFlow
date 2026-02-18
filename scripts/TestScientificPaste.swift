import Foundation
import Cocoa
import CoreGraphics

func testScientificPaste(inclusionDelay: TimeInterval) {
    let pb = NSPasteboard.general
    let kVK_V: UInt16 = 9
    let kVK_Return: UInt16 = 36
    
    print("🚀 Scientific Paste Test (\(Int(inclusionDelay * 1000))ms delay)")
    let oldClipboard = pb.string(forType: .string) ?? ""
    
    print("⏳ 3s to focus...")
    Thread.sleep(forTimeInterval: 3.0)
    
    pb.clearContents()
    pb.setString("echo 'Stable Paste Success'", forType: .string)
    
    let source = CGEventSource(stateID: .hidSystemState)
    
    // 1. Send Cmd+V
    print("⌨️ Pasting...")
    let vDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: true)
    let vUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_V, keyDown: false)
    vDown?.flags = .maskCommand
    vUp?.flags = .maskCommand
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)
    
    // 2. Wait for terminal to handle the paste event
    Thread.sleep(forTimeInterval: inclusionDelay)
    
    // 3. Restore Clipboard
    print("📋 Restoring clipboard...")
    pb.clearContents()
    pb.setString(oldClipboard, forType: .string)
    
    // 4. THE AIR GAP: Wait 100ms more for TUI to settle after restore
    print("⏳ Settling...")
    Thread.sleep(forTimeInterval: 0.1)
    
    // 5. Send Return
    print("⏎ Submitting...")
    let retDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: true)
    let retUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: false)
    retDown?.flags = [] 
    retUp?.flags = []
    retDown?.post(tap: .cghidEventTap)
    retUp?.post(tap: .cghidEventTap)
    
    print("✅ Done.")
}

testScientificPaste(inclusionDelay: 0.1) // 100ms inhale
