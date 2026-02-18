# VoiceFlow Terminal Newline/Enter - Complete Debug Summary

**Date:** 2026-02-18 (spanning sessions from 2026-02-17 to 2026-02-18)
**Build range:** 138 → 150
**Ticket:** VoiceFlow-qs3 (recurring)

---

## Latest Data Point (2026-02-18)

- In a delay-only test configuration, newline behavior succeeded reliably in terminal testing.
- Active config during this test:
  - `terminalAtomicTrailingSubmitEnabled = false` (temporary test toggle)
  - `terminal_submit_delay_ms = 4000`
  - `terminal_simple_submit_enabled = true`
  - `terminal_simple_submit_pause_ms = 3200`
- Follow-up insight: standalone `"new line"` utterances likely do not need the full long delay, while mixed text+newline turns may still need delayed submit protection.
- Additional A/B threshold test (same session, delay-only mode):
  - Tested shorter profile:
    - `terminal_submit_delay_ms = 3000`
    - `terminal_simple_submit_pause_ms = 2400`
    - Result: **failed** (user observed out-of-order newline behavior).
  - Reverted to:
    - `terminal_submit_delay_ms = 4000`
    - `terminal_simple_submit_pause_ms = 3200`
    - Result: restored known-working profile.

### Experimental AX Submit Branch (2026-02-18)

- Branch: `experiment/ax-terminal-submit`
- Added an experimental terminal Enter submit path that tries Accessibility actions first (`kAXConfirmAction`, then `kAXPressAction`) on the focused element, with immediate fallback to the existing CGEvent Return path when AX actions are unsupported.
- Hooked into:
  - trailing newline submit in terminal typing path
  - buffered newline flush path
  - explicit "press enter" command path
- Added setting/toggle + persistence key:
  - `terminal_accessibility_submit_enabled` (default `true` on this experiment branch)
- Build status: compiles and app bundle builds; manual reliability validation still required.

---

## The Two Requirements

### Requirement 1: "newline" keyword must reliably submit text in terminal TUIs

When the user says `"this is a test newline"`, VoiceFlow must:
1. Type `this is a test` into the terminal
2. Press Enter/Return to submit it

This works perfectly in regular terminals (bash, zsh prompts) and GUI text fields. **It fails intermittently in Claude Code** (which uses ink/React for its TUI). The text appears but Enter either:
- Fires before the text is rendered (out-of-order)
- Doesn't fire at all (lost)
- Fires but the TUI doesn't process it (not ready)

**The problem is specific to Claude Code's ink/React TUI framework**, not terminals in general.

### Requirement 2: "say newline" must type the literal text "newline"

The word "say" before a keyword should escape it, causing the keyword to be typed as literal text instead of executing its action. "say newline" should type the word "newline", not press Enter.

This was **SOLVED in Build 144** with inline "say" escape support. Not the focus of ongoing debugging.

---

## Architecture Overview

The relevant code flow for "this is a test newline":

```
AssemblyAI speech → handleLiveDictationTurn() → applyKeywordReplacementsFromWords()
  → "newline" detected as trailing keyword
  → appendNewline(isTrailing: true)
  → [HERE IS WHERE THE APPROACHES DIVERGE]
  → typeText() → performTerminalTyping() on terminalTypingQueue
  → flushBufferedTerminalNewlines() at end-of-turn
```

Key file: `Sources/Models/AppState.swift` (~6000+ lines)

### The Split-Turn Problem

AssemblyAI sometimes delivers "this is a test newline" as ONE utterance, and sometimes splits it into TWO:
- Utterance 1: "this is a test" (endOfTurn)
- Utterance 2: "newline" (endOfTurn, arrives 1-3 seconds later)

Both cases must be handled. The split-turn case is harder because the newline arrives as a completely separate event with no text.

---

## Every Approach Tried

### Approach 1: Per-character CGEvents (original, pre-Build 138)
**How it works:** Each character posted as individual CGEvent keyboard events. Return key posted as separate event after text.
**Why it failed:** Characters travel HID→Terminal→PTY→stdin one at a time. Terminal TUI (Claude Code ink/React) may not have finished rendering the text before the Return event arrives. No delay between text and Return.
**Status:** ABANDONED

### Approach 2: AppleScript `keystroke return` (Build ~137)
**How it works:** Used AppleScript to send Enter key to terminal.
**Why it failed:** AppleScript has high latency (~100ms per invocation) and unreliable delivery to terminal apps. Still had ordering issues.
**Status:** ABANDONED

### Approach 3: CGEvent with explicit `\r` (carriage return) (Build ~137-138)
**How it works:** Set Unicode string to `\r` (0x0D) on the Return CGEvent for terminal apps.
**Why it failed:** Fixed the character encoding (terminals expect `\r` not just keycode 36), but didn't fix the timing/ordering issue.
**Status:** KEPT (the `\r` encoding is still used), but timing problem remained

### Approach 4: Fixed delay before Return (Builds 137-138)
**How it works:** Added configurable delays (100ms, 200ms, 500ms tested) before sending Return key after text.
**Why it failed:** Too short = still out of order. Too long = noticeable lag. Claude Code's ink/React has VARIABLE latency, so no single delay value works reliably.
**Status:** ABANDONED as primary approach

### Approach 5: Clipboard paste via Cmd+V (Build 139)
**How it works:** Copy text to clipboard, simulate Cmd+V to paste, then restore clipboard.
**Why it failed:** Multiple race conditions:
- Clipboard restore happens before terminal reads the paste (clobbers the text)
- Multiple rapid utterances overwrite each other's clipboard content
- User's clipboard gets disrupted
- Even with async restore (1s delay), timing was unreliable
**Status:** ABANDONED

### Approach 6: CGEvent Unicode injection (Build 142) - TEXT DELIVERY SOLVED
**How it works:** `CGEventKeyboardSetUnicodeString` sends multi-character strings in a single keyboard event. Text chunked into ≤20 UTF-16 units per event. All terminal operations serialized on `terminalTypingQueue` via `performTerminalTyping()`.
**Result:** TEXT DELIVERY works reliably. Characters arrive in order. No clipboard involvement.
**Status:** KEPT - this is the current text injection mechanism

**But the Return/Enter timing problem remained.** The text is delivered correctly, but the Return key (sent as a separate CGEvent after the text) still fires before Claude Code's TUI is ready.

### Approach 7: Buffered flush with elapsed-time delay (Builds 142-144)
**How it works:** Trailing newlines stripped from text, stored in `bufferedTerminalNewlines` counter. At end-of-turn, `flushBufferedTerminalNewlines()` waits until `terminalFlushMinSinceLastEvent` (900ms) has elapsed since the last keystroke event, then sends Return.
**Why it failed:** 900ms wasn't enough for Claude Code. Also, in split-turn case, by the time the "newline" utterance arrives (1-2s later), the elapsed-time check passes immediately because enough time has already passed since the text was typed.
**Status:** PARTIALLY WORKS (sometimes succeeds, sometimes fails)

### Approach 8: Configurable terminal submit delay (Build 145)
**How it works:** Added `terminalSubmitDelayMs` setting (default 1500ms, range 300-5000ms) with UI slider in Settings. Flush waits at least this long since the last keystroke.
**Why it failed:** Same split-turn timing issue. When "newline" arrives as a separate utterance 2+ seconds after the text, the elapsed time already exceeds 1500ms, so the delay check passes immediately and Return fires.
**Status:** PARTIALLY WORKS

### Approach 9: Split-turn protection via `lastTerminalTextTypeCompletionTime` (Build 146)
**How it works:** Tracks when the last `typeText` call completed for terminal. In flush, if `!didTypeDictationThisUtterance` (newline-only turn) and last text was typed within 3s (`terminalSplitNewlineFollowupWindow`), enforce full `terminalSubmitDelayMs` (1500ms) delay from the START of the flush.
**Why it failed:** This adds 1.5s from flush start, but the text was already 1-2s old. Total time from text to Return = 2.5-3.5s. This SHOULD be enough, but Claude Code still sometimes doesn't process the Return correctly. The intermittent nature suggests the TUI has variable readiness times.
**Status:** PARTIALLY WORKS (improved but still intermittent)

### Approach 10: Absolute 800ms minimum for newline-only utterances (Build 147)
**How it works:** Third layer of protection - when a newline-only utterance is detected, enforce an absolute 800ms minimum delay from the start of the flush, regardless of other timing calculations.
**Why it failed:** 800ms is still too short. And the fundamental issue remains: the flush is a SEPARATE operation from the text typing, creating a window for timing races.
**Status:** PARTIALLY WORKS

### Approach 11: Atomic delivery - keep `\n` in text for typeText (Builds 148-149)
**How it works:** Instead of stripping trailing `\n` and buffering it for flush, keep the `\n` in the text so `typeText()` handles text+Return in a single serialized operation on `terminalTypingQueue`. The trailing Return uses the full `terminalSubmitDelayMs` delay.
**Why it failed (Build 148):** Changed the wrong code path. The trailing newline was being stripped and buffered in `applyKeywordReplacementsFromWords()` → `appendNewline(isTrailing: true)` (line ~2161) BEFORE it reached the code I modified at lines 3208/3350.
**Fix attempt (Build 149):** Fixed `appendNewline()` to add `\n` to output for terminal mode instead of buffering. The `\n` now flows through to `typeText()`. Logs confirm `typeText` receives text with `\n` (e.g., "this is a test\n").
**Current status:** Still not working reliably. The Return IS being sent (confirmed by logs showing the `\n` in typeText input), but Claude Code's TUI still doesn't process it correctly.
**Status:** CURRENT APPROACH (Build 150, with 2500ms delay)

### Approach 12: Increased delay to 2500ms (Build 150)
**How it works:** Same as Approach 11, but with `terminalSubmitDelayMs` increased from 1500ms to 2500ms.
**Status:** JUST DEPLOYED, not yet thoroughly tested

---

## What We Know For Sure

1. **Text injection works** - CGEvent Unicode injection delivers text reliably and in order
2. **Return key events work** - The Return CGEvent IS being posted (confirmed by logs)
3. **The issue is Claude Code-specific** - Regular terminal prompts and other TUI apps work fine
4. **The issue is intermittent** - Sometimes it works, sometimes it doesn't
5. **Longer delays help** - Going from 900ms to 1500ms improved success rate but didn't eliminate failures
6. **The split-turn case is harder** - When AssemblyAI splits "text newline" into two utterances, timing is less predictable
7. **The serialization is correct** - `terminalTypingQueue` properly serializes text+Return operations

## What We Don't Know

1. **Why does Claude Code sometimes not process the Return?** Is it:
   - Input buffer not ready?
   - ink/React render cycle in progress?
   - Terminal PTY buffer issue?
   - Focus/input field state issue?
2. **What is Claude Code's actual input processing latency?** We've tried 900ms, 1500ms, 2500ms - is there a threshold?
3. **Would a fundamentally different approach work better?** E.g.:
   - Sending `\r` as part of the Unicode injection (same CGEvent as text)
   - Using the Accessibility API to set the text field value directly
   - Using `osascript` to tell the terminal to execute a command
   - Writing directly to the terminal's PTY file descriptor

---

## Key Code Locations (AppState.swift)

| Function | Line ~# | Purpose |
|----------|---------|---------|
| `applyKeywordReplacementsFromWords()` | ~2096 | Keyword detection, `appendNewline()` |
| `appendNewline(isTrailing:)` | ~2154 | Decides: buffer newline or include in output |
| `handleLiveDictationTurn()` | ~3170 | Formatted/unformatted turn handling |
| `typeText()` | ~5525 | Main text injection, terminal/non-terminal paths |
| `performTerminalTyping()` | ~5476 | Serialization wrapper for `terminalTypingQueue` |
| `postUnicodeStringEvent()` | ~5502 | CGEvent Unicode injection |
| `flushBufferedTerminalNewlines()` | ~5730 | Buffered Return delivery (old approach, still used for split-turn) |
| `terminalSubmitDelayMs` | line 304 | Configurable delay (default 2500ms) |
| `terminalTypingQueue` | line ~708 | Serial DispatchQueue for terminal operations |

## Key Constants

| Name | Value | Purpose |
|------|-------|---------|
| `terminalSubmitDelayMs` | 2500 (was 1500) | Delay before trailing Return |
| `terminalFlushBaseDelay` | 0.60s | Base delay in flush |
| `terminalInlineReturnMinDelay` | 0.45s | Delay for middle (non-trailing) Returns |
| `terminalNewlineOnlyAbsoluteMinDelay` | 0.80s | Absolute min for newline-only utterances |
| `terminalSplitNewlineFollowupWindow` | 3.0s | Window for detecting split-turn newlines |
| `terminalPostReturnDelay` | varies | Delay after Return for TUI processing |
| `terminalUnicodeChunkLength` | 120 | Max chars per Unicode injection event |

---

## Session References

### Claude Code Sessions (today, working on VoiceFlow)
- **Main session (this one):** `9c4b9b2d-cb88-42d8-9c51-d49c1ff181ff` (continued from compaction)
  - Previous session: `f293c824-c96a-4f3e-9717-0d91a3672903`
- **Session logs dir:** `~/.claude/projects/-Users-jacobcole-code/`

### Codex Session
- **tmux session:** `voiceflow-dev` pane 0, title "Codex: VoiceFlow fixes"
- **Context remaining:** ~71%
- **Work done by Codex:**
  - Analyzed all 4 original issues
  - Implemented serial `terminalTypingQueue`
  - Implemented CGEvent Unicode injection (replacing clipboard paste)
  - Added `didDetectSay` flag for inline "say" escape
  - Added configurable `terminalSubmitDelayMs` with Settings slider
  - Added split-turn protection (`lastTerminalTextTypeCompletionTime`)
  - Added absolute minimum delay for newline-only utterances
  - Confirmed via analysis: "No threading/ordering bug - code is deterministic. Root cause is target-app readiness."

### Git Log (relevant commits)
```
77fd507 fix: three-layer newline protection for terminal TUIs (Builds 145-147)
e2c08a3 feat: CGEvent Unicode injection for terminal typing + inline "say" escape (Build 144)
9c2753e fix: improve newline timing for terminal TUIs (Claude Code)
5610cfd fix: use CGEvent for terminal Return key delivery instead of AppleScript
```

Builds 148-150 are uncommitted.

---

## VoiceFlow Log Evidence

From Build 149 logs (atomic delivery confirmed working):
```
[11:49:02 PM] 🎯 Keyword: New line
[11:49:02 PM] Live typing delta (final): "this is a test\n"
[11:49:02 PM] Posting CGKEvents for: "this is a test\n" (15 chars)
```
The `\n` IS in the text passed to typeText. But the user reported the newline still didn't work reliably.

Split-turn example (text and newline as separate utterances):
```
[11:49:34 PM] Posting CGKEvents for: " okay what folders..." (75 chars)  [no \n]
[11:49:37 PM] Posting CGKEvents for: "\n" (1 chars)  [standalone newline 3s later]
```

---

## Side Effects, Collateral Issues & Debugging Problems

### Issues Caused By Our Changes

1. **Clipboard pasting wrong contents (Build 140)** - The clipboard paste approach (Approach 5) introduced a race condition where VoiceFlow would restore the user's clipboard BEFORE the terminal app read the paste. Result: the terminal would paste the user's OLD clipboard contents instead of the dictated text. User reported: "its wrongly pasting clipboard contents now". Fixed in Build 141 by moving restore to async 1s delay, but this didn't fully solve it — led to abandoning clipboard entirely.

2. **User's clipboard disrupted** - During the clipboard paste era (Builds 139-141), VoiceFlow would overwrite the user's clipboard with dictated text and attempt to restore it. Even with restoration, rapid utterances could clobber each other's clipboard state. This was a major UX regression.

3. **Standalone "say" consumed as command prefix (Build 142-143)** - Codex's initial "say" escape implementation consumed standalone "say" (just the word by itself) as a command prefix, preventing it from being typed as text. User reported: "i think it completely standalone 'say' should transcribe normally but it's not right now". Fixed by adding `hasWordsAfterSay` check.

4. **"say" only worked at start of utterance (Build 143)** - The initial "say" escape only detected "say" as the first word. User wanted it anywhere: "so it works correctly at the beginning but i want it to work in the middle of an utterance or anywhere". Fixed in Build 144 with inline one-shot escape in `applyKeywordReplacementsFromWords`.

5. **Cross-utterance pending "say" behavior removed** - Codex initially kept `didDetectSay` pending across turns, which caused unexpected literal typing in subsequent utterances. Removed cross-turn persistence.

6. **Build 148 changed wrong code path (wasted iteration)** - Modified the trailing newline check at lines 3208/3350, but the actual newline buffering happened upstream in `appendNewline()` at line 2161 inside `applyKeywordReplacementsFromWords()`. The change had NO EFFECT because the `\n` was already consumed before reaching the modified code. Discovered and fixed in Build 149.

7. **UserDefaults persisting old delay values** - When default `terminalSubmitDelayMs` was changed from 1500 to 2500, users with existing UserDefaults still have the old 1500ms value. The new default only applies to fresh installs or after clearing UserDefaults.

### Debugging Difficulties

8. **NSLog output not visible in `log show`** - VoiceFlow uses NSLog for diagnostic logging, but `log show --predicate 'process == "VoiceFlow"'` returned nothing. Multiple predicate variations tried (process name, PID, message content). Had to discover the VoiceFlow CLI `log` command (`VoiceFlow log 80`) as the only way to read logs.

9. **Old logs from dead process misleading** - `/tmp/voiceflow-debug.log` stopped updating when a new VoiceFlow build started (new PID), but the file still existed with stale data. This caused confusion when reading logs that appeared current but were from a previous build.

10. **Double "New line" keyword log entries** - Logs show `🎯 Keyword: New line` appearing TWICE for each newline. Not confirmed whether this is a bug (double detection) or expected (logging from two stages of processing). Doesn't appear to cause functional issues.

11. **iTerm2 detected as "browser app"** - Logs show "Using 2ms inter-character delay for browser app" when typing into iTerm2. The `getInterCharacterDelay()` function appears to incorrectly classify iTerm2 as a browser app. This doesn't affect terminal mode (inter-char delay is only used in non-terminal per-char CGEvent path), but is a latent bug.

### Beads Tickets Created/Updated

| Ticket | Type | Status | Description |
|--------|------|--------|-------------|
| VoiceFlow-qs3 | bug (recurring) | open | Newline/Enter unreliable in Claude Code TUI |
| VoiceFlow-p1gg | feature | open | "Copy to recent" voice command |
| VoiceFlow-vw2w | bug (recurring) | open | "say" escape mode |
| VoiceFlow-xce | bug (recurring) | open | "say" escape mode |
| VoiceFlow-f0d | bug | closed | Original newline issue |

---

## Ideas Not Yet Tried

1. **Include `\r` directly in the Unicode injection payload** - Instead of sending text and Return as separate CGEvents, include `\r` (U+000D) as part of the Unicode string in the same CGEvent. This makes text+Return truly atomic at the kernel event level.

2. **Write directly to the terminal's PTY** - Bypass CGEvents entirely. Find the PTY file descriptor for the terminal and write the text + `\r` directly. This is how actual keyboard input ends up - going through CGEvents adds indirection.

3. **Use Accessibility API** - Set the input field value via AX API, then trigger submit. This bypasses the keyboard event pipeline entirely.

4. **Adaptive delay** - Measure how long Claude Code takes to render text, and dynamically adjust the Return delay based on observed latency.

5. **Retry mechanism** - After sending Return, check if the text was actually submitted (e.g., by monitoring the terminal output). If not, retry.

6. **Much longer delay (5000ms+)** - As a diagnostic: if 5000ms works 100% of the time, it confirms the issue is purely timing and we can then binary search for the minimum reliable delay.
