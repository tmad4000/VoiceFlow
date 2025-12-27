# VoiceFlow App Architecture Plan

## Overview

VoiceFlow is a native macOS speech recognition app designed for users with RSI (Repetitive Strain Injury). It uses AssemblyAI's real-time streaming API for transcription and supports voice-activated keyboard shortcuts.

**Key Design Goals:**
- Minimal keyboard/mouse usage
- Fast command detection for voice shortcuts
- Always-visible floating panel
- RSI-friendly alternative to Aqua Voice / Whisper Flow

## App Structure

VoiceFlow will be a **menu bar app** with a **floating panel** and **separate settings window**.

### Components

1. **Menu Bar Icon**
   - Always visible in menu bar
   - Color-coded status indicator (gray=off, green=on, orange=wake)
   - Dropdown menu:
     - Mode toggles: Off / On / Wake
     - "Show Panel" / "Hide Panel"
     - "Settings..." (opens settings window)
     - Separator
     - "Quit VoiceFlow"

2. **Floating Panel** (always on top)
   - Horizontal strip (~320x50px)
   - Layout: `[Off][On][Wake] | Transcript text scrolling...`
   - Mode buttons on left, live transcript on right
   - Rounded corners, subtle shadow, semi-transparent background
   - Draggable by background, remembers position
   - Window level: `.floating` (stays above other windows)
   - No Dock icon, no Cmd-Tab (accessory app)

3. **Settings Window** (separate, standard window)
   - Opens as regular window when needed
   - API key configuration
   - Voice commands list/editor
   - Opens via menu bar "Settings..." or ⌘,

### App Lifecycle

- **Launch**: App starts as menu bar accessory (no Dock icon)
- **Panel**: Floating panel shown by default, can hide via menu
- **Quit methods**:
  - Menu bar dropdown → "Quit VoiceFlow"
  - Voice command: "quit voice flow" (when in Wake mode)
  - ⌘Q when Settings window is focused

## Files to Modify

### `Sources/VoiceFlowApp.swift`
- Change to `MenuBarExtra` scene instead of `WindowGroup`
- Set activation policy to `.accessory`
- Add floating panel as separate `Window` scene

### `Sources/Views/FloatingPanelView.swift` (new)
- Compact UI with mode buttons + transcript
- Minimal chrome, draggable

### `Sources/Views/MenuBarView.swift` (new)
- Menu bar dropdown content

### `Sources/Views/ContentView.swift`
- Refactor to `FloatingPanelView` (compact)
- Keep `SettingsView` as separate window

### `Sources/Models/AppState.swift`
- Add `isPanelVisible` state
- Add "quit voiceflow" voice command

## Key Implementation Details

```swift
// VoiceFlowApp.swift structure
@main
struct VoiceFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar with dropdown
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.microphoneMode.icon)
        }

        // Floating panel (always on top)
        Window("VoiceFlow", id: "panel") {
            FloatingPanelView()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// AppDelegate - set as accessory app
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No Dock icon
        // Configure floating panel window level after launch
    }
}
```

---

## Transcript Handling Strategy

### AssemblyAI Message Types

AssemblyAI's streaming API sends two types of transcript data:

| Message Type | Description | Latency | Content |
|--------------|-------------|---------|---------|
| **Partial** | Real-time updates as words are recognized | ~100-200ms | Raw text, no punctuation, may change |
| **Turn** | Finalized transcript for completed utterance | ~300-500ms | Formatted with punctuation, immutable |

**Example timeline for user saying "Hello world":**
```
t=0.1s  Partial: "hel"
t=0.2s  Partial: "hello"
t=0.3s  Partial: "hello wor"
t=0.4s  Partial: "hello world"
t=0.6s  Turn: "Hello world."  ← finalized with punctuation
```

### V1 Processing Strategy

**Two-tier processing for V1:**

| Tier | Trigger | Action | Mode |
|------|---------|--------|------|
| **Command Detection** | Every partial | Check for voice commands, execute immediately | Wake mode |
| **Text Pasting** | Turn only | Paste finalized text to active app | On mode |
| **Panel Display** | Every partial | Show real-time text (visual feedback) | Both modes |

**Rationale:**
- Commands need maximum speed → process partials
- Text pasting needs accuracy → wait for finalized Turn
- Panel always shows real-time feedback

---

## User Stories: Detailed Flow Analysis

### Story 1: Single Command - "tab back" in Wake mode

**User intent:** Switch to previous browser tab

**Timeline:**
```
t=0.0s  User starts speaking: "tab back"
t=0.1s  Partial: "tab"           → No match (looking for "tab back")
t=0.2s  Partial: "tab ba"        → No match
t=0.3s  Partial: "tab back"      → MATCH! Execute Ctrl+Shift+Tab
t=0.4s  Partial: "tab back"      → Already executed, skip
t=0.5s  Partial: "tab back"      → Already executed, skip
t=0.7s  Turn: "Tab back."        → Reset executed commands set
```

**Expected behavior:** Command executes exactly once at t=0.3s

**Implementation requirement:**
- Track `executedCommandsThisUtterance: Set<String>`
- Add command phrase to set when executed
- Clear set on Turn event

---

### Story 2: Command Design - Explicit Phrases (RESOLVED)

**Design decision:** Commands use explicit, unambiguous phrases like "copy that" instead of single words like "copy".

**Benefits:**
- "copy that" won't appear naturally in dictation
- No false positives from words like "photocopy" or "escape artist"
- Consistent pattern users can learn
- Simple substring matching is now safe

**Command execution modes:**

1. **With pause (default):** Say command, pause ~500ms, then it executes
   - "copy that" [pause] → executes Cmd+C

2. **With prefix (instant):** Say "voiceflow" + command, executes immediately
   - "voiceflow copy that" → executes Cmd+C instantly

This prevents accidental triggers if you say a command phrase in normal speech - you'd keep talking and no pause would occur.

**Default command phrases:**
- "copy that" → Cmd+C
- "paste that" → Cmd+V
- "undo that" → Cmd+Z
- "redo that" → Cmd+Shift+Z
- "cut that" → Cmd+X
- "select all" → Cmd+A
- "save that" → Cmd+S
- "find that" → Cmd+F
- "tab back" → Ctrl+Shift+Tab
- "tab forward" → Ctrl+Tab
- "new tab" → Cmd+T
- "close tab" → Cmd+W
- "go back" → Cmd+←
- "go forward" → Cmd+→
- "scroll up" → ↑
- "scroll down" → ↓
- "page up" → Page Up
- "page down" → Page Down
- "escape" → Esc
- "enter" → Return

**System commands (always instant, no pause needed):**
- "microphone on" / "start dictation" → Switch to On mode
- "microphone off" / "stop dictation" → Switch to Off mode
- "quit voiceflow" → Quit app

**Implementation notes:**
- Track time since last partial to detect pauses
- Check for "voiceflow" prefix → execute immediately
- Otherwise, wait for pause before executing
- Configurable pause duration (default 500ms)

---

### Story 3: Multiple Commands in One Utterance - "undo that redo that"

**User intent:** Undo, then redo (two separate actions)

**Timeline:**
```
t=0.1s  Partial: "undo that"          → MATCH! Execute Cmd+Z
t=0.2s  Partial: "undo that redo"     → "undo that" already executed, skip
t=0.3s  Partial: "undo that redo that" → "undo that" skip, "redo that" MATCH! Execute Cmd+Shift+Z
t=0.4s  Partial: "undo that redo that" → Both already executed, skip
t=0.6s  Turn: "Undo that. Redo that." → Reset executed set
```

**Expected behavior:** Both commands execute exactly once, in order

**Implementation requirement:**
- Check ALL registered commands against each partial
- Track each command separately in the executed set

---

### Story 4: Mode Switch - "microphone on" in Wake mode

**User intent:** Switch from Wake mode to On mode (start dictating)

**Timeline:**
```
t=0.0s  Mode: Wake
t=0.1s  Partial: "microphone"    → No match
t=0.2s  Partial: "microphone on" → MATCH! Set mode to On
t=0.2s  Mode: On (immediate)
t=0.3s  Partial: "microphone on" → Mode is On, command detection skipped
t=0.5s  Turn: "Microphone on."   → Mode is On, text NOT pasted (it's a command)
```

**Expected behavior:** Mode switches once, no text pasted

**Edge case consideration:** Should "microphone on" be pasted as text? No - it's a system command.

**Implementation requirement:**
- System commands (mode switches) should never paste their text
- Track that this utterance was a command, skip pasting on Turn

---

### Story 5: Normal Dictation - "hello world" in On mode

**User intent:** Type "Hello world." into active application

**Timeline:**
```
t=0.0s  Mode: On
t=0.1s  Partial: "hel"           → Display in panel (gray/italic)
t=0.2s  Partial: "hello"         → Display in panel (updating)
t=0.3s  Partial: "hello wor"     → Display in panel
t=0.4s  Partial: "hello world"   → Display in panel
t=0.6s  Turn: "Hello world."     → PASTE to active app
```

**Expected behavior:**
- Panel shows real-time updates
- Text "Hello world." pasted once at finalization
- Proper punctuation and capitalization from Turn

---

### Story 6: Long Sentence Dictation

**User intent:** Dictate a full sentence

**Timeline:**
```
t=0.1s  Partial: "I need to"
t=0.2s  Partial: "I need to send"
t=0.3s  Partial: "I need to send an email"
t=0.4s  Partial: "I need to send an email to John"
t=0.5s  Partial: "I need to send an email to John about"
t=0.6s  Partial: "I need to send an email to John about the meeting"
t=0.8s  Turn: "I need to send an email to John about the meeting."
```

**Panel display:** Shows updating text in real-time
**Paste:** Only the final Turn with punctuation

---

### Story 7: Sequential Commands with Pauses

**User intent:** Execute "copy", pause, then "paste"

**Timeline:**
```
--- First utterance ---
t=0.1s  Partial: "copy"          → MATCH! Execute Cmd+C
t=0.3s  Turn: "Copy."            → Reset executed set

--- Pause (user doing something) ---

--- Second utterance ---
t=2.0s  Partial: "paste"         → MATCH! Execute Cmd+V
t=2.2s  Turn: "Paste."           → Reset executed set
```

**Expected behavior:** Each command executes once, Turn events provide natural boundaries

---

### Story 8: Command in On Mode (should be ignored)

**User intent:** Dictate the words "I need to copy this"

**Timeline:**
```
t=0.0s  Mode: On
t=0.1s  Partial: "I need"        → Display
t=0.2s  Partial: "I need to"     → Display
t=0.3s  Partial: "I need to copy"    → Display (NOT a command - we're in On mode)
t=0.4s  Partial: "I need to copy this" → Display
t=0.6s  Turn: "I need to copy this."  → PASTE full text
```

**Expected behavior:** No command executed, full text pasted

**Implementation requirement:** Command detection ONLY in Wake mode

---

### Story 9: Rapid Command Correction

**User intent:** Says "undo" but meant "redo", quickly corrects

**Timeline:**
```
t=0.1s  Partial: "und"           → No match
t=0.2s  Partial: "undo"          → MATCH! Execute Cmd+Z
t=0.3s  Partial: "undo no wait redo"  → "undo" already done, "redo" MATCH! Execute
```

**Problem:** User didn't want undo, but it executed before they could correct

**Possible solutions (future consideration):**
- Add brief delay before executing? (hurts responsiveness)
- "Cancel" voice command to undo last action?
- This might just be accepted behavior for voice control

---

## Known Issues & Edge Cases

### Issue 1: Command Multi-Fire (SOLVED in design)

**Problem:** Partials repeat full text, causing same command to match multiple times
**Solution:** Track executed commands per utterance, reset on Turn

### Issue 2: Substring False Positives (RESOLVED)

**Problem:** Single-word commands like "copy" could match "photocopy"
**Solution:** Use explicit multi-word phrases like "copy that" instead of single words.

These phrases are unambiguous and won't appear in natural dictation, so simple `.contains()` matching is safe.

### Issue 3: "Paste on Partial" Duplication (DEFERRED TO BACKLOG)

**Problem:** Each partial contains COMPLETE text, not delta
```
Partial 1: "hel"     → If pasted: screen shows "hel"
Partial 2: "hello"   → If pasted: screen shows "helhello" (WRONG)
```

**This is V2/backlog** - too complex for initial version

### Issue 4: Command vs Dictation Ambiguity

**Problem:** User in Wake mode says "copy" - is it a command or are they trying to dictate?
**Answer:** In Wake mode, commands take priority. User should switch to On mode for dictation.

### Issue 5: Network Latency Variation

**Problem:** Partial → Turn delay varies with network conditions
**Mitigation:** Panel shows real-time partials so user has immediate feedback

---

## V1 Scope

### In Scope
- Menu bar app + floating panel + settings window
- Three modes: Off, On, Wake
- Command detection on partials (Wake mode)
- Text pasting on Turn events (On mode)
- Real-time panel display
- Command deduplication per utterance
- Word-boundary command matching

### Backlog (Future Versions)
- [ ] Paste on partial with delta tracking
- [ ] Command correction ("cancel", "no wait")
- [ ] Customizable command confirmation delay
- [ ] Partial-level visual feedback (word-by-word highlighting)
- [ ] Command chaining ("copy paste" as two commands)

---

## Floating Panel Window Configuration

Need to set window level to floating after window appears:
```swift
// In FloatingPanelView or via NSWindow access
if let window = NSApp.windows.first(where: { $0.title == "VoiceFlow" }) {
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isMovableByWindowBackground = true
    window.titlebarAppearsTransparent = true
    window.styleMask.remove(.titled)
}
```
