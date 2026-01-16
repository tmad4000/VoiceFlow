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

## Version Management

**Increment build number on every code change.** This helps track which build is running.

Version info in `Sources/Info.plist`:
- `CFBundleShortVersionString` - Semantic version (e.g., "0.2.0") - bump for releases
- `CFBundleVersion` - Build number (e.g., "42") - **increment on every change**

```bash
# Quick version bump (increment build number)
# Edit Sources/Info.plist and increment CFBundleVersion
```

Version is displayed in the floating panel's "..." menu.

## Running & Testing

```bash
# Build (SPM)
swift build

# Run (from DerivedData or build output)
.build/debug/VoiceFlow
# or
/Users/jacobcole/Library/Developer/Xcode/DerivedData/VoiceFlow-bqgsuxwfbyobzkahaxtmfvunkgwd/Build/Products/Debug/VoiceFlow
```
