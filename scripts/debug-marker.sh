#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${HOME}/Library/Logs/VoiceFlow/voiceflow.log"
mkdir -p "$(dirname "$LOG_FILE")"

# macOS date(1) doesn't support nanoseconds; ISO-8601 UTC is sufficient for triage markers.
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOTE="${*:-manual marker}"
NOTE="${NOTE//$'\n'/ }"
NOTE="${NOTE//\"/\'}"

printf '[MARKER %s] source=cli note="%s"\n' "$TIMESTAMP" "$NOTE" >> "$LOG_FILE"
echo "[debug-marker] wrote marker at $TIMESTAMP"
echo "[debug-marker] log: $LOG_FILE"
