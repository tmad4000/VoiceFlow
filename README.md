# VoiceFlow
A native macOS speech recognition app designed for users with Repetitive Strain Injury (RSI). Uses AssemblyAI for real-time transcription with minimal keyboard usage.
## Features
- **Real-time Speech-to-Text**: Dictate text directly into any application
- **Live Dictation (Optional)**: Type words as they become final for lower latency
- **Three Microphone Modes**:
- **Off**: Microphone completely disabled
- **On**: Active transcription mode - speak and text appears
- **Wake**: Listen for voice commands only
- **Voice Commands**: Map spoken phrases to keyboard shortcuts (e.g., "tab back" → Ctrl+Shift+Tab)
- **RSI-Friendly**: Designed to minimize keyboard and mouse usage
## Requirements
- macOS 14.0 (Sonoma) or later
- AssemblyAI API key ([Get one here](https://www.assemblyai.com/app/account))
- Microphone access
- Accessibility permissions (for typing into other apps)
## Installation
### Build from Source
```bash
cd VoiceFlow
swift build
swift run
```
### Or open in Xcode
```bash
open Package.swift
```
Then build and run (⌘R).
## Setup
- Launch VoiceFlow
- Open Settings (⌘,)
- Enter your AssemblyAI API key
- Grant Accessibility permissions when prompted
## Usage
### Microphone Modes
- **Off**: Click when you don't want the app listening at all
- **On**: Click to start dictating. Speech will be typed into the currently focused app
- **Wake**: Click to listen for voice commands only. Say "microphone on" to start dictating
### Voice Commands
In Wake mode, you can use voice commands to control your computer:
- "microphone on" / "start dictation" - Switch to On mode
- "microphone off" / "stop dictation" - Switch to Off mode.
- "tab back" - Ctrl+Shift+Tab
- "tab forward" - Ctrl+Tab
- "new tab" - ⌘T
- "close tab" - ⌘W
- "undo that" / "redo that" - ⌘Z / ⌘⇧Z
- "copy that" / "paste that" / "cut that" - Standard clipboard shortcuts
- "save that" / "find that" - ⌘S / ⌘F
- "cancel that" / "no wait" - Best-effort undo of last command
- And more...
Add custom voice commands in Settings → Commands.
## Architecture
- **AssemblyAI Streaming API**: WebSocket connection for real-time transcription
- **AVFoundation**: Audio capture at 16kHz mono PCM
- **CGEvent**: Keyboard simulation for typing and shortcuts
- **SwiftUI**: Native macOS interface
## Privacy
- Audio is streamed to AssemblyAI for processing
- API key stored locally in UserDefaults
- No data stored on disk except settings
## License
MIT
