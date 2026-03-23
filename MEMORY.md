# Project Memory Map

Use this file as the index for where durable project memory lives.

## 1) Experiment Evidence (What happened)
- Use `NEWLINE_DEBUG_SUMMARY.md` for newline/terminal behavior findings.
- Add dated entries with exact config values and pass/fail outcomes.

## 2) Work Tracking (What remains)
- Use beads issues for open work, status, and decisions.
- Canonical store is `.beads/issues.jsonl`.
- Commands:
  - `bd ready`
  - `bd show <id>`
  - `bd update <id> --notes "<new data point>"`
  - `bd close <id>`

## 3) Workflow Defaults (How we run)
- Use `AGENTS.md` for session rules and canonical dev run mode.
- Use `README.md` for developer setup and run commands.

## 4) Session Handoff (How we resume)
- At end of a session, write:
  - key result
  - exact build/config tested
  - what passed/failed
  - next concrete action
- Put these in:
  - `NEWLINE_DEBUG_SUMMARY.md` (behavior details)
  - relevant bead issue notes (actionable next step)

## 5) Timestamp Markers (Debug Correlation)
- Use timestamp markers whenever reporting or reproducing an issue.
- Voice command:
  - `debug marker <note>`
  - `voiceflow debug marker <note>`
- CLI helper:
  - `./scripts/debug-marker.sh "<note>"`
- Marker lines are written to:
  - `~/Library/Logs/VoiceFlow/voiceflow.log`

## Ground Rule
- Chat history is not durable memory.
- If a result matters, write it to files/issues in this map the same day.
