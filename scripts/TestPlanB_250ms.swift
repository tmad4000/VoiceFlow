import Foundation
import CoreGraphics

func testPlanB_Short() {
    let kVK_Return: UInt16 = 36
    
    print("🚀 Script started. You have 3 seconds to focus Claude Code...")
    Thread.sleep(forTimeInterval: 3.0)
    
    let text = "ls"
    print("⌨️ Sending 'ls' via Unicode...")
    
    let source = CGEventSource(stateID: .hidSystemState)
    let utf16Units = Array(text.utf16)
    
    // 1. Send "ls"
    utf16Units.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: base)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: base)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    // 2. THE SHORT AIR GAP: Wait 250ms
    print("⏳ Waiting 250ms for Claude Code to render...")
    Thread.sleep(forTimeInterval: 0.25)
    
    // 3. Send physical RETURN key (VK 36)
    print("⏎ Sending physical Return key...")
    let retDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: true)
    let retUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Return, keyDown: false)
    
    var cr: UniChar = 0x0D
    retDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)
    retUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)
    
    retDown?.post(tap: .cghidEventTap)
    retUp?.post(tap: .cghidEventTap)
    
    print("✅ Done. Did Claude Code execute 'ls'?")
}

testPlanB_Short()
