#!/bin/bash
# Claude Code SessionStart hook
# Reads session JSON from stdin and inserts into SQLite

set -e

LOG_FILE="$HOME/.claude/hooks/debug.log"
DB_PATH="$HOME/.claude/dashboard.db"
INPUT=$(cat)

# Debug logging
echo "[$(date)] SessionStart triggered" >> "$LOG_FILE"
echo "$INPUT" | jq '.' >> "$LOG_FILE" 2>/dev/null || echo "$INPUT" >> "$LOG_FILE"

# Extract fields from JSON
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
MODEL=$(echo "$INPUT" | jq -r '.model // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Exit if no session_id
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Get git branch if in a git repo
BRANCH=""
if [ -d "$CWD/.git" ] || git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")
fi

# Capture terminal info from environment
TERMINAL_SESSION_ID="${ITERM_SESSION_ID:-}"
TERMINAL_APP="${TERM_PROGRAM:-}"

# Derive project name from git remote or folder name
PROJECT_NAME=""
if [ -d "$CWD/.git" ] || git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
  REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null || echo "")
  if [ -n "$REMOTE_URL" ]; then
    # Extract repo name from URL (handles both HTTPS and SSH)
    PROJECT_NAME=$(basename -s .git "$REMOTE_URL")
  fi
fi

# Fallback to folder name
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME=$(basename "$CWD")
fi

# Current timestamp
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Insert or update session (use INSERT OR REPLACE for resume cases)
sqlite3 "$DB_PATH" << EOF
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
INSERT INTO sessions (id, project_path, project_name, branch, model, transcript_path, status, started_at, last_activity_at, terminal_session_id, terminal_app)
VALUES ('$SESSION_ID', '$CWD', '$PROJECT_NAME', '$BRANCH', '$MODEL', '$TRANSCRIPT_PATH', 'active', '$NOW', '$NOW', '$TERMINAL_SESSION_ID', '$TERMINAL_APP')
ON CONFLICT(id) DO UPDATE SET
  status = 'active',
  last_activity_at = '$NOW',
  terminal_session_id = '$TERMINAL_SESSION_ID',
  terminal_app = '$TERMINAL_APP';
EOF

exit 0
