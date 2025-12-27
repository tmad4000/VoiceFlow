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

## Landing the Plane (Session Completion)

**When ending a work session**, complete the steps below where applicable. Push is recommended, not mandatory.

**RECOMMENDED WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Push to remote (if desired/possible)**:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # should show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed (and pushed if you chose to)
7. **Hand off** - Provide context for next session

**If push is skipped or blocked:**
- Note the reason (e.g., no remote configured, permission error)
- Provide the exact next steps to finish the push
