#!/bin/bash
# Claude Code Status Tracker Hook
# Handles: UserPromptSubmit, Stop, Notification

# Don't use set -e to avoid breaking tool execution
DB_PATH="$HOME/.orbitdock/orbitdock.db"
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

# Get the last tool used (to detect AskUserQuestion)
get_last_tool() {
  run_sql "SELECT last_tool FROM sessions WHERE id = '$SESSION_ID';" 2>/dev/null
}

case "$EVENT" in
  "UserPromptSubmit")
    # Clear attention state when user submits a prompt
    run_sql "UPDATE sessions SET
      work_status = 'working',
      attention_reason = 'none',
      pending_tool_name = NULL,
      pending_question = NULL,
      last_activity_at = '$NOW',
      prompt_count = prompt_count + 1
      WHERE id = '$SESSION_ID';"
    notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    ;;
  "Stop")
    # Check if last tool was AskUserQuestion
    LAST_TOOL=$(get_last_tool)
    if [ "$LAST_TOOL" = "AskUserQuestion" ]; then
      ATTENTION="awaitingQuestion"
    else
      ATTENTION="awaitingReply"
    fi
    run_sql "UPDATE sessions SET
      work_status = 'waiting',
      attention_reason = '$ATTENTION',
      last_activity_at = '$NOW'
      WHERE id = '$SESSION_ID';"
    notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    ;;
  "Notification")
    NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
    MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)

    if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
      # Check if last tool was AskUserQuestion
      LAST_TOOL=$(get_last_tool)
      if [ "$LAST_TOOL" = "AskUserQuestion" ]; then
        ATTENTION="awaitingQuestion"
      else
        ATTENTION="awaitingReply"
      fi
      run_sql "UPDATE sessions SET
        work_status = 'waiting',
        attention_reason = '$ATTENTION',
        last_activity_at = '$NOW'
        WHERE id = '$SESSION_ID';"
      notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    elif [ "$NOTIF_TYPE" = "permission_prompt" ]; then
      # Parse tool name from message: "Claude needs your permission to use Bash"
      TOOL_NAME=$(echo "$MESSAGE" | sed -n 's/.*permission to use \([A-Za-z]*\).*/\1/p')
      run_sql "UPDATE sessions SET
        work_status = 'permission',
        attention_reason = 'awaitingPermission',
        pending_tool_name = '$TOOL_NAME',
        last_activity_at = '$NOW'
        WHERE id = '$SESSION_ID';"
      notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    fi
    ;;
esac

exit 0
