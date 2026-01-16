# VoiceFlow Project Context

## Issue Tracking

This project uses **beads** for issue tracking with prefix `VoiceFlow-`.

When asked to "make a ticket" or "create an issue" for this project:
- Use `bd create --title="..." --type=<type> --priority=<N>`
- Types: task, feature, bug, epic, chore
- Priorities: 0 (critical) to 4 (minimal), default is 2

Common ticket commands:
```bash
bd list --status=open          # See open issues
bd ready                       # Issues ready to work on
bd close <id>                  # Close completed issue
bd update <id> --status=in_progress  # Start work
```

## Project Overview

VoiceFlow is a macOS voice-to-text dictation app with:
- Real-time speech-to-text (AssemblyAI, Deepgram, Apple Speech)
- Voice command recognition ("command open", "new line", etc.)
- Claude Code integration via "command" voice trigger
- Floating panel UI with minimal/full modes

## Key Files

- `Sources/Models/AppState.swift` - Main app state and voice command logic
- `Sources/Services/ClaudeCodeService.swift` - Claude CLI integration
- `Sources/Views/FloatingPanelView.swift` - Main UI panel
- `Sources/Views/CommandPanelView.swift` - Claude Code chat panel

## Claude Code CLI Integration

The command panel uses Claude Code CLI for multi-turn conversations. Key pattern:

```bash
# First message - capture session_id from JSON response
claude --print --output-format stream-json "message"

# Subsequent messages - use --resume for true context continuity
claude --resume <session_id> --print --output-format stream-json "followup"
```

**Why this matters:**
- `--resume` preserves full conversation context including tool memory
- Prompt caching kicks in for repeated conversation prefix (cheaper, faster)
- Don't inject history as text in prompts - defeats caching and truncates

See ticket **VoiceFlow-ta46** for current implementation status.

## Version Management

**Increment build number on every code change.** This helps track which build is running.

Version info in `Sources/Version.swift`:
```swift
enum AppVersion {
    static let version = "0.2.0"  // Semantic version - bump for releases
    static let build = 43          // Build number - increment on every change
}
```

Version is displayed in the floating panel's "..." menu as "VoiceFlow v0.2.0 (43)".

## Running & Testing

```bash
# Build (SPM)
swift build

# Run (from DerivedData or build output)
.build/debug/VoiceFlow
# or
/Users/jacobcole/Library/Developer/Xcode/DerivedData/VoiceFlow-bqgsuxwfbyobzkahaxtmfvunkgwd/Build/Products/Debug/VoiceFlow
```

## Related Projects & Prior Art

VoiceFlow draws inspiration from established voice control software:

### Dragon NaturallySpeaking (Nuance)
- Industry standard for professional dictation since 1997
- Excellent accuracy after training, extensive vocabulary customization
- Windows-focused, expensive licensing, declining macOS support
- VoiceFlow differentiator: modern cloud ASR, AI integration, developer-focused

### Talon Voice (https://talonvoice.com)
- Free/donation-based voice control for coding and accessibility
- Powerful scripting via Python, eye tracking support
- Active community creating custom commands/grammars
- VoiceFlow differentiator: simpler setup, cloud ASR options, Claude integration

### Utter Command (Redstart Systems)
- Voice command layer that works with Dragon
- Pioneered "command grammar" patterns for efficient voice control
- Designed by Kim Patch for RSI/accessibility users
- VoiceFlow draws from: command prefix patterns, modal voice commands

### Other Notable Projects
- **Whisper.cpp** - Local Whisper model inference (potential offline mode)
- **Caster** - Open-source Dragon/Talon alternative
- **Voice Control (macOS built-in)** - Apple's accessibility voice control
- **Nerd Dictation** - Linux offline dictation using Vosk

### Command Pattern Analysis

#### Dragon NaturallySpeaking Patterns
- **Inline commands**: "new paragraph", "cap [word]", "all caps [word]"
- **Selection**: "select [text]", "select through [text]"
- **Correction**: "scratch that", "undo that", "spell that"
- **Navigation**: "go to beginning", "move down 5 lines"
- **Dictation box**: buffer text then transfer to target app

#### Talon Voice Patterns
- **Phonetic alphabet**: "air bat cap drum" for a-b-c-d
- **Formatters**: "snake hello world" → hello_world, "camel" → helloWorld
- **Chaining**: multiple commands in sequence without pauses
- **Context-aware**: different commands active in different apps
- **Noise words**: "pad" for space, "slap" for enter

#### Utter Command Patterns
- **Command prefix**: "do [action]" to distinguish from dictation
- **Numbered choices**: "pick 3" to select from disambiguation list
- **Compound commands**: "do save close" for multiple actions
- **Natural phrases**: "go to end of line" vs cryptic shortcuts
- **Chunking**: group related commands under memorable prefixes

### Design Principles from Prior Art
1. **Modal commands** (Talon/Utter) - "command" prefix to enter command mode
2. **Continuous dictation** (Dragon) - natural speech flow with punctuation
3. **Escape hatches** (all) - ways to type literal text that sounds like commands
4. **Visual feedback** (accessibility) - always show what was recognized
5. **Phonetic disambiguation** (Talon) - unambiguous spoken forms for symbols
6. **Context sensitivity** (all) - different commands in different apps/modes
7. **Correction workflows** (Dragon) - "scratch that" and selection commands
8. **Command chaining** (Talon) - rapid multi-command sequences
