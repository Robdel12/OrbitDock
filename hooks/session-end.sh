#!/bin/bash
# Claude Code SessionEnd hook
# Updates session status to ended in SQLite

set -e

LOG_FILE="$HOME/.claude/hooks/debug.log"
DB_PATH="$HOME/.claude/dashboard.db"
INPUT=$(cat)

# Debug logging
echo "[$(date)] SessionEnd triggered" >> "$LOG_FILE"
echo "$INPUT" | jq '.' >> "$LOG_FILE" 2>/dev/null || echo "$INPUT" >> "$LOG_FILE"

# Extract fields from JSON
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Exit if no session_id
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Current timestamp
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Update session status
sqlite3 "$DB_PATH" << EOF
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
UPDATE sessions
SET status = 'ended',
    ended_at = '$NOW',
    end_reason = '$REASON',
    last_activity_at = '$NOW'
WHERE id = '$SESSION_ID';
EOF

# Optional: Parse transcript for stats (tokens, tools used)
# This can be enhanced later to extract more detailed activity
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Count approximate messages/activity
  LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo "0")

  # Could parse JSONL for tool usage, but keeping it simple for now
  # Future: extract tool_use events and insert into activities table
fi

# Notify the app via Darwin notification (instant, non-blocking)
notifyutil -p com.commandcenter.session.updated 2>/dev/null &

exit 0
