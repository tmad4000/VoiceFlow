
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

### AssemblyAI Message Types (Streaming v3)

AssemblyAI's streaming API (v3) sends these message types:

| Message Type | Description | Key fields |
|--------------|-------------|------------|
| **Begin** | Session started | `id` |
| **Turn** | Streaming updates for the current utterance (interim + final) | `transcript`, `words`, `end_of_turn`, `turn_is_formatted` |
| **Termination** | Session ended | — |
| **Error** | Error details | `error` |

**Important semantics (v3):**
- There is **no separate "Partial" message**. A "partial" is a `Turn` with `end_of_turn = false`.
- `transcript` contains **only finalized words** and **never rewinds**; it grows as words become final.
- `words` includes `word_is_final`, so we can build a live hypothesis (final + non-final words) for the panel.
- If `format_turns=true`, the service emits an additional **formatted** `Turn` after endpointing; use `turn_is_formatted` to detect it.

**Example timeline for user saying "Hello world":**
```
t=0.1s  Turn (end_of_turn=false, turn_is_formatted=false)
        words: ["hel"(word_is_final=false)]
        transcript: ""
t=0.2s  Turn (end_of_turn=false, turn_is_formatted=false)
        words: ["hello"(word_is_final=true)]
        transcript: "hello"
t=0.3s  Turn (end_of_turn=false, turn_is_formatted=false)
        words: ["hello"(true), "wor"(false)]
        transcript: "hello"
t=0.4s  Turn (end_of_turn=true, turn_is_formatted=false)
        words: ["hello"(true), "world"(true)]
        transcript: "hello world"
t=0.55s Turn (end_of_turn=true, turn_is_formatted=true)  // only if format_turns=true
        transcript: "Hello world."
```

### V1 Processing Strategy

**Two-tier processing for V1:**

| Tier | Trigger | Action | Mode |
|------|---------|--------|------|
| **Command Detection** | Every unformatted Turn (`turn_is_formatted=false`) | Check for voice commands, execute immediately (dedupe per utterance) | Wake mode |
| **Text Pasting** | `end_of_turn=true` (and if `format_turns=true`, wait for `turn_is_formatted=true`) | Paste finalized text to active app | On mode |
| **Panel Display** | Every Turn | Build live text from `words` (final + non-final) | Both modes |

**Rationale:**
- Commands need maximum speed → process the Turn stream (ignore formatted duplicates)
- Text pasting needs accuracy → wait for `end_of_turn` (+ formatted Turn if enabled)
- Panel shows real-time feedback using `words`

---

## User Stories: Detailed Flow Analysis

### Story 1: Single Command - "tab back" in Wake mode

**User intent:** Switch to previous browser tab

**Timeline:**
```
t=0.0s  User starts speaking: "tab back"
t=0.1s  Turn (end_of_turn=false): words="tab"           → No match (looking for "tab back")
t=0.2s  Turn (end_of_turn=false): words="tab ba"        → No match
t=0.3s  Turn (end_of_turn=false): words="tab back"      → MATCH! Execute Ctrl+Shift+Tab
t=0.4s  Turn (end_of_turn=false): words="tab back"      → Already executed, skip
t=0.5s  Turn (end_of_turn=true):  transcript="tab back" → Reset executed commands set
t=0.6s  Turn (end_of_turn=true, turn_is_formatted=true): "Tab back." → Ignore for commands
```

**Expected behavior:** Command executes exactly once at t=0.3s

**Implementation requirement:**
- Track `executedCommandsThisUtterance: Set<String>`
- Add command phrase to set when executed
- Clear set on the first `end_of_turn=true` for that utterance
- Ignore `turn_is_formatted=true` for command detection to avoid double-fire

---

### Story 2: Command Design - Explicit Phrases (RESOLVED)

**Design decision:** Commands use explicit multi-word phrases and an optional prefix ("voiceflow") to reduce false positives, but this is not foolproof. The real safety boundaries are **mode** (Wake vs On) and **prefix** for instant execution.

**Benefits:**
- Multi-word phrases reduce accidental triggers compared to single words
- Prefix provides a near-zero false positive path for instant commands
- Consistent pattern users can learn quickly
- Commands are treated as intent-only (never pasted as dictation)

**Command execution modes:**

1. **With pause (default):** Say command, pause until endpointing (or ~500ms), then it executes
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
- Track time since last Turn *or* rely on `end_of_turn=true` for pause detection
- Check for "voiceflow" prefix → execute immediately
- Otherwise, wait for pause/end_of_turn before executing
- Ignore `turn_is_formatted=true` for command detection (avoid double-fire)
- Configurable pause duration (default 500ms) if not relying purely on endpointing

---

### Story 3: Multiple Commands in One Utterance - "undo that redo that"

**User intent:** Undo, then redo (two separate actions)

**Timeline:**
```
t=0.1s  Turn (end_of_turn=false): words="undo that"           → MATCH! Execute Cmd+Z
t=0.2s  Turn (end_of_turn=false): words="undo that redo"      → "undo that" already executed, skip
t=0.3s  Turn (end_of_turn=false): words="undo that redo that"  → "undo that" skip, "redo that" MATCH! Execute Cmd+Shift+Z
t=0.4s  Turn (end_of_turn=false): words="undo that redo that"  → Both already executed, skip
t=0.6s  Turn (end_of_turn=true):  transcript="undo that redo that" → Reset executed set
```

**Expected behavior:** Both commands execute exactly once, in order

**Implementation requirement:**
- Check ALL registered commands against each unformatted Turn
- Track each command separately in the executed set

---

### Story 4: Mode Switch - "microphone on" in Wake mode

**User intent:** Switch from Wake mode to On mode (start dictating)

**Timeline:**
```
t=0.0s  Mode: Wake
t=0.1s  Turn (end_of_turn=false): words="microphone"    → No match
t=0.2s  Turn (end_of_turn=false): words="microphone on" → MATCH! Set mode to On
t=0.2s  Mode: On (immediate)
t=0.3s  Turn (end_of_turn=false): words="microphone on" → Mode is On, command detection skipped
t=0.5s  Turn (end_of_turn=true):  transcript="microphone on" → DO NOT paste (command utterance)
t=0.6s  Turn (end_of_turn=true, turn_is_formatted=true): "Microphone on." → DO NOT paste
```

**Expected behavior:** Mode switches once, no text pasted

**Edge case consideration:** Should "microphone on" be pasted as text? No - it's a system command.

**Implementation requirement:**
- System commands (mode switches) should never paste their text
- Track that this utterance was a command, skip pasting on any `end_of_turn=true` Turn

---

### Story 5: Normal Dictation - "hello world" in On mode

**User intent:** Type "Hello world." into active application

**Timeline:**
```
t=0.0s  Mode: On
t=0.1s  Turn (end_of_turn=false): words="hel"               → Display in panel (hypothesis)
t=0.2s  Turn (end_of_turn=false): words="hello"             → Display in panel (updating)
t=0.3s  Turn (end_of_turn=false): words="hello wor"         → Display in panel
t=0.4s  Turn (end_of_turn=true):  transcript="hello world"  → WAIT (if format_turns=true)
t=0.5s  Turn (end_of_turn=true, turn_is_formatted=true): "Hello world." → PASTE to active app
```

**Expected behavior:**
- Panel shows real-time updates
- Text pasted once at end-of-turn (formatted if enabled)
- Proper punctuation and capitalization when using formatted Turn

---

### Story 6: Long Sentence Dictation

**User intent:** Dictate a full sentence

**Timeline:**
```
t=0.1s  Turn (end_of_turn=false): words="I need to"
t=0.2s  Turn (end_of_turn=false): words="I need to send"
t=0.3s  Turn (end_of_turn=false): words="I need to send an email"
t=0.4s  Turn (end_of_turn=false): words="I need to send an email to John"
t=0.5s  Turn (end_of_turn=false): words="I need to send an email to John about"
t=0.6s  Turn (end_of_turn=false): words="I need to send an email to John about the meeting"
t=0.8s  Turn (end_of_turn=true, turn_is_formatted=true): "I need to send an email to John about the meeting."
```

**Panel display:** Shows updating text in real-time
**Paste:** Only the final Turn with punctuation

---

### Story 7: Sequential Commands with Pauses

**User intent:** Execute "copy", pause, then "paste"

**Timeline:**
```
--- First utterance ---
t=0.1s  Turn (end_of_turn=false): words="copy"  → MATCH! Execute Cmd+C
t=0.3s  Turn (end_of_turn=true):  transcript="copy" → Reset executed set

--- Pause (user doing something) ---

--- Second utterance ---
t=2.0s  Turn (end_of_turn=false): words="paste" → MATCH! Execute Cmd+V
t=2.2s  Turn (end_of_turn=true):  transcript="paste" → Reset executed set
```

**Expected behavior:** Each command executes once, Turn events provide natural boundaries

---

### Story 8: Command in On Mode (should be ignored)

**User intent:** Dictate the words "I need to copy this"

**Timeline:**
```
t=0.0s  Mode: On
t=0.1s  Turn (end_of_turn=false): words="I need"            → Display
t=0.2s  Turn (end_of_turn=false): words="I need to"         → Display
t=0.3s  Turn (end_of_turn=false): words="I need to copy"    → Display (NOT a command - we're in On mode)
t=0.4s  Turn (end_of_turn=false): words="I need to copy this" → Display
t=0.6s  Turn (end_of_turn=true, turn_is_formatted=true): "I need to copy this." → PASTE full text
```

**Expected behavior:** No command executed, full text pasted

**Implementation requirement:** Command detection ONLY in Wake mode

---

### Story 9: Rapid Command Correction

**User intent:** Says "undo" but meant "redo", quickly corrects

**Timeline:**
```
t=0.1s  Turn (end_of_turn=false): words="und"                → No match
t=0.2s  Turn (end_of_turn=false): words="undo"               → MATCH! Execute Cmd+Z
t=0.3s  Turn (end_of_turn=false): words="undo no wait redo"  → "undo" already done, "redo" MATCH! Execute
```

**Problem:** User didn't want undo, but it executed before they could correct

**Possible solutions (future consideration):**
- Add brief delay before executing? (hurts responsiveness)
- "Cancel" voice command to undo last action?
- This might just be accepted behavior for voice control

---

## Known Issues & Edge Cases

### Issue 1: Command Multi-Fire (SOLVED in design)

**Problem:** Turn updates repeat cumulative hypotheses, so the same command can match multiple times
**Solution:** Track executed commands per utterance, reset on first `end_of_turn=true`, and ignore `turn_is_formatted=true` for command detection

### Issue 2: Substring False Positives (RESOLVED)

**Problem:** Single-word commands like "copy" can appear in dictation or as substrings
**Solution:** Use explicit multi-word phrases + optional "voiceflow" prefix, and only run command detection in Wake mode

### Issue 3: "Paste on Turn Updates" Duplication (DEFERRED TO BACKLOG)

**Problem:** Each Turn transcript is cumulative, not delta
```
Turn 1: transcript="hel"     → If pasted: screen shows "hel"
Turn 2: transcript="hello"   → If pasted: screen shows "helhello" (WRONG)
```

**This is V2/backlog** - requires delta tracking from `words` + `word_is_final`

### Issue 4: Command vs Dictation Ambiguity

**Problem:** User in Wake mode says "copy" - is it a command or are they trying to dictate?
**Answer:** In Wake mode, commands take priority. User should switch to On mode for dictation.

### Issue 5: Network Latency Variation

**Problem:** Unformatted → formatted Turn delay varies with network conditions
**Mitigation:** Panel uses live `words`; dictation waits for formatted end-of-turn when enabled

---

## V1 Scope

### In Scope
- Menu bar app + floating panel + settings window
- Three modes: Off, On, Wake
- Command detection on unformatted Turn updates (Wake mode)
- Text pasting on `end_of_turn=true` (formatted if enabled) in On mode
- Real-time panel display from `words`
- Command deduplication per utterance (reset on end_of_turn)
- Word-boundary command matching

### Backlog (Future Versions)
- [ ] Paste on Turn updates with delta tracking
- [ ] Command correction ("cancel", "no wait")
- [ ] Customizable command confirmation delay
- [ ] Word-level visual feedback (final vs non-final highlighting)
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
