import Foundation
import CoreGraphics

func sendCommand(_ text: String, source: CGEventSource?) {
    let kVK_Return: UInt16 = 36
    let utf16Units = Array(text.utf16)
    
    print("⌨️ Sending '\(text)'...")
    utf16Units.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: base)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: base)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    print("⏳ Wait 100ms...")
    Thread.sleep(forTimeInterval: 0.1)
    
    print("⏎ Return...")
    let retDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: true)
    let retUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: false)
    var cr: UniChar = 0x0D
    retDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)
    retUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)
    retDown?.post(tap: .cghidEventTap)
    retUp?.post(tap: .cghidEventTap)
}

func testChain() {
    print("🚀 Stress test starting. You have 3 seconds to focus Claude Code...")
    Thread.sleep(forTimeInterval: 3.0)
    
    let source = CGEventSource(stateID: .hidSystemState)
    
    sendCommand("pwd", source: source)
    Thread.sleep(forTimeInterval: 0.1)
    
    // Escaping quotes for the shell command inside the Swift string
    sendCommand("echo \"VoiceFlow Test\"", source: source)
    Thread.sleep(forTimeInterval: 0.1)
    
    sendCommand("ls -a", source: source)
    
    print("✅ Chain complete.")
}

testChain()
