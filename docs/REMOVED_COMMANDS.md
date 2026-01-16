# Removed Voice Commands

This document tracks voice commands that have been removed from VoiceFlow defaults due to safety concerns (false positive triggers during natural speech).

## Removed Commands

### User-Configurable Commands (VoiceCommand.swift defaults)

| Command | Action | Removal Date | Reason |
|---------|--------|--------------|--------|
| `save that` | ⌘S | 2026-01-15 | Common phrase in speech: "I'll save that for later" |
| `go back` | ⌘← | 2026-01-15 | Common phrase: "let me go back to what I was saying" |
| `go forward` | ⌘→ | 2026-01-15 | Common phrase: "I'll go forward with the plan" |
| `scroll up` | ↑ | 2026-01-15 | Common phrase: "scroll up on the page" (describing, not commanding) |
| `scroll down` | ↓ | 2026-01-15 | Common phrase: "scroll down to see more" (describing, not commanding) |

**Safer alternatives added:**
- `navigate back` (⌘←) - replaces "go back"
- `navigate forward` (⌘→) - replaces "go forward"

### System Commands (AppState.swift)

| Command | Action | Removal Date | Reason |
|---------|--------|--------------|--------|
| `wake` (single word) | Switch to On mode | 2026-01-15 | Triggers on "stay awake", "wide awake", etc. |
| `no wait` | Cancel last command | 2026-01-15 | Triggers on "no wait, let me think..." |

**Note:** Multi-word versions remain safe:
- `wake up` - still works
- `cancel that` - still works

## Why Commands Get Removed

Commands are removed when they match common phrases in natural speech. VoiceFlow uses `findMatches()` which searches for commands anywhere in an utterance, not just at the start. This means:

- "I'm trying to stay **awake**" → triggers "wake"
- "**No wait**, let me reconsider" → triggers "no wait"
- "Should I **go back** to the original?" → triggers "go back"

## Future: Timestamp-Based Pause Detection

See ticket **VoiceFlow-z8ic** for a planned feature that uses word timestamps to detect if a command was preceded by a pause. This would allow commands like "go back" to work safely when spoken after a deliberate pause, while not triggering mid-sentence.

Algorithm concept:
```swift
func isPrecededByPause(wordIndex: Int, words: [TranscriptWord], threshold: Double = 0.3) -> Bool {
    guard wordIndex > 0,
          let prevEnd = words[wordIndex - 1].endTime,
          let currStart = words[wordIndex].startTime else {
        return wordIndex == 0  // First word counts as pause-preceded
    }
    return (currStart - prevEnd) >= threshold
}
```

All speech engines (AssemblyAI, Deepgram, Apple Speech) provide word-level timestamps, so this feature can work universally.

## Re-adding Commands

Users can re-add any removed command through Settings → Voice Commands. The defaults are just starting points - users have full control over their command vocabulary.
