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

## Running & Testing

```bash
# Build
xcodebuild -scheme VoiceFlow -configuration Debug -destination "platform=macOS" build

# Run (from DerivedData)
/Users/jacobcole/Library/Developer/Xcode/DerivedData/VoiceFlow-bqgsuxwfbyobzkahaxtmfvunkgwd/Build/Products/Debug/VoiceFlow
```
