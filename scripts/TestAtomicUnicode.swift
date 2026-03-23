import Foundation
import CoreGraphics

func testAtomicUnicode() {
    print("🚀 Script started. You have 3 seconds to focus your target terminal...")
    Thread.sleep(forTimeInterval: 3.0)
    
    // Using Swift escape sequence for Carriage Return (0x0D)
    let text = "ls\u{0D}" 
    print("⌨️ Attempting to send 'ls' + <CR> as an atomic Unicode event...")
    
    let source = CGEventSource(stateID: .hidSystemState)
    let utf16Units = Array(text.utf16)
    
    utf16Units.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        
        // Use Virtual Key 0
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            print("❌ Failed to create CGEvent")
            return
        }
        
        keyDown.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: base)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: base)
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
    
    print("✅ Event posted. Check your terminal.")
}

testAtomicUnicode()
