# VoiceFlow iOS Keyboard

This folder contains an iOS host app and a custom keyboard extension that supports live speech-to-text.

## Getting Started

1. Generate the Xcode project:
   ```bash
   cd iOSKeyboard
   xcodegen
   ```
2. Open the project:
   ```bash
   open VoiceFlowKeyboard.xcodeproj
   ```
3. Select the `VoiceFlowKeyboardHost` scheme and run on an iOS device.
4. Enable the keyboard:
   - Settings → General → Keyboard → Keyboards → Add New Keyboard…
   - Select “VoiceFlow Keyboard”
   - Tap “VoiceFlow Keyboard” and enable **Full Access**
5. Open any app, switch to VoiceFlow Keyboard, and tap **mic** to start dictating.

## Notes
- The keyboard uses Apple Speech recognition and requires microphone + speech permissions.
- Live partial results are inserted into the active text field as you speak.
- Full Access is required to use the microphone inside the keyboard extension.
