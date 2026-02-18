# Agent Instructions
This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.
## Quick Reference
```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Canonical Dev Run Mode
- Use `VoiceFlow-Dev.app` for day-to-day development/testing.
- Build/run with:
  ```bash
  ./build_dev.sh
  open VoiceFlow-Dev.app
  ```
- Do **not** launch `.build/arm64-apple-macosx/debug/VoiceFlow` directly for normal testing.
- Rationale:
  - keeps one stable app identity (`com.jacobcole.voiceflow.dev`) for TCC/Accessibility
  - avoids repeated Accessibility re-prompts from ad-hoc binary churn
  - keeps dev settings separate from release settings

## Memory Locations
- `MEMORY.md` is the index for durable project memory.
- `NEWLINE_DEBUG_SUMMARY.md` stores newline/terminal experiment evidence.
- beads (`.beads/issues.jsonl`) stores actionable status and follow-ups.

## Landing the Plane (Session Completion)
**When ending a work session**, complete the steps below where applicable. Push is recommended, not mandatory.
**RECOMMENDED WORKFLOW:**
- **File issues for remaining work** - Create issues for anything that needs follow-up
- **Run quality gates** (if code changed) - Tests, linters, builds
- **Update issue status** - Close finished work, update in-progress items
- **Push to remote (if desired/possible)**:
  ```bash
  git pull --rebase
  bd sync
  git push
  git status  # should show "up to date with origin"
  ```
- **Clean up** - Clear stashes, prune remote branches
- **Verify** - All changes committed (and pushed if you chose to)
- **Hand off** - Provide context for next session
**If push is skipped or blocked:**
- Note the reason (e.g., no remote configured, permission error)
- Provide the exact next steps to finish the push
