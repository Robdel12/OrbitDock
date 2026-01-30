#!/bin/bash
# Claude Code Status Tracker Hook
# Handles: UserPromptSubmit, Stop, Notification

# Don't use set -e to avoid breaking tool execution
DB_PATH="$HOME/.claude/dashboard.db"
INPUT=$(cat)

# Extract fields silently
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)

# Exit silently if no session_id
[ -z "$SESSION_ID" ] && exit 0

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Helper function with WAL mode and busy timeout
run_sql() {
  sqlite3 "$DB_PATH" "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; $1" 2>/dev/null
}

case "$EVENT" in
  "UserPromptSubmit")
    run_sql "UPDATE sessions SET work_status = 'working', last_activity_at = '$NOW', prompt_count = prompt_count + 1 WHERE id = '$SESSION_ID';"
    notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    ;;
  "Stop")
    run_sql "UPDATE sessions SET work_status = 'waiting', last_activity_at = '$NOW' WHERE id = '$SESSION_ID';"
    notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    ;;
  "Notification")
    NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
    if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
      run_sql "UPDATE sessions SET work_status = 'waiting', last_activity_at = '$NOW' WHERE id = '$SESSION_ID';"
      notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    elif [ "$NOTIF_TYPE" = "permission_prompt" ]; then
      run_sql "UPDATE sessions SET work_status = 'permission', last_activity_at = '$NOW' WHERE id = '$SESSION_ID';"
      notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    fi
    ;;
esac

exit 0
