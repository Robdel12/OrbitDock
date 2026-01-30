#!/bin/bash
# Lightweight tool tracker for Command Center dashboard
# Runs async so doesn't block Claude Code

DB_PATH="$HOME/.claude/dashboard.db"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Helper function with WAL mode and busy timeout for concurrent access
run_sql() {
  sqlite3 "$DB_PATH" "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; $1" 2>/dev/null
}

case "$EVENT" in
  "PreToolUse")
    # Update last tool and set working status
    run_sql "UPDATE sessions SET last_tool = '$TOOL_NAME', last_tool_at = '$NOW', work_status = 'working' WHERE id = '$SESSION_ID';"
    ;;
  "PostToolUse")
    # Keep last tool, update activity time
    run_sql "UPDATE sessions SET last_activity_at = '$NOW', tool_count = tool_count + 1 WHERE id = '$SESSION_ID';"
    ;;
esac

exit 0
