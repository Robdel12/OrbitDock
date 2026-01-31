#!/bin/bash
# Lightweight tool tracker for Command Center dashboard
# Runs async so doesn't block Claude Code
# Also detects branch changes after Bash commands

DB_PATH="$HOME/.orbitdock/orbitdock.db"
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Helper function with WAL mode and busy timeout for concurrent access
# Filter out PRAGMA output (wal, 5000)
run_sql() {
  sqlite3 "$DB_PATH" "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; $1" 2>/dev/null | grep -v -E '^(wal|5000)$'
}

# Detect new branch creation and create workstream
# Only triggers when: creating a new branch FROM main/master AND session doesn't have a workstream yet
detect_branch_creation() {
  [ -z "$TOOL_INPUT" ] && return

  # Check if this is a branch creation command
  local NEW_BRANCH=""
  local WORKTREE_PATH=""

  # git checkout -b <branch> or git checkout -B <branch>
  if [[ "$TOOL_INPUT" =~ git[[:space:]]+(checkout)[[:space:]]+-[bB][[:space:]]+([^[:space:]]+) ]]; then
    NEW_BRANCH="${BASH_REMATCH[2]}"
  # git switch -c <branch> or git switch -C <branch> or git switch --create <branch>
  elif [[ "$TOOL_INPUT" =~ git[[:space:]]+(switch)[[:space:]]+(-[cC]|--create)[[:space:]]+([^[:space:]]+) ]]; then
    NEW_BRANCH="${BASH_REMATCH[3]}"
  # git worktree add -b <branch> <path> or git worktree add <path> -b <branch>
  elif [[ "$TOOL_INPUT" =~ git[[:space:]]+worktree[[:space:]]+add ]]; then
    if [[ "$TOOL_INPUT" =~ -b[[:space:]]+([^[:space:]]+) ]]; then
      NEW_BRANCH="${BASH_REMATCH[1]}"
    fi
    # Extract worktree path (first non-flag argument after "add")
    if [[ "$TOOL_INPUT" =~ git[[:space:]]+worktree[[:space:]]+add[[:space:]]+(-b[[:space:]]+[^[:space:]]+[[:space:]]+)?([^-][^[:space:]]*) ]]; then
      WORKTREE_PATH="${BASH_REMATCH[2]}"
    fi
  fi

  # No branch creation detected
  [ -z "$NEW_BRANCH" ] && return

  # Skip if it's a main branch
  case "$NEW_BRANCH" in
    main|master|develop|development) return ;;
  esac

  # Check if session already has a workstream (sticky - don't override)
  EXISTING_WS=$(run_sql "SELECT workstream_id FROM sessions WHERE id = '$SESSION_ID';")
  [ -n "$EXISTING_WS" ] && return

  # Get the repo root
  local CHECK_DIR="$CWD"
  [ -n "$WORKTREE_PATH" ] && CHECK_DIR="$WORKTREE_PATH"

  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  GIT_COMMON_DIR=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$GIT_COMMON_DIR" ] && [ "$GIT_COMMON_DIR" != ".git" ]; then
    MAIN_REPO_ROOT=$(dirname "$GIT_COMMON_DIR")
    [ -d "$MAIN_REPO_ROOT" ] && REPO_ROOT="$MAIN_REPO_ROOT"
  fi

  [ -z "$REPO_ROOT" ] && return

  # Get or create repo
  REPO_ID=$(run_sql "SELECT id FROM repos WHERE path = '$REPO_ROOT';")
  if [ -z "$REPO_ID" ]; then
    REPO_ID=$(echo -n "$REPO_ROOT" | shasum -a 256 | cut -c1-16)
    REPO_NAME=$(basename "$REPO_ROOT")

    # Parse GitHub info from remote
    REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null)
    GITHUB_OWNER=""
    GITHUB_NAME=""
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
      GITHUB_OWNER="${BASH_REMATCH[1]}"
      GITHUB_NAME="${BASH_REMATCH[2]}"
    fi

    run_sql "INSERT OR IGNORE INTO repos (id, name, path, github_owner, github_name, created_at) VALUES ('$REPO_ID', '$REPO_NAME', '$REPO_ROOT', $([ -n "$GITHUB_OWNER" ] && echo "'$GITHUB_OWNER'" || echo "NULL"), $([ -n "$GITHUB_NAME" ] && echo "'$GITHUB_NAME'" || echo "NULL"), '$NOW');"
    REPO_ID=$(run_sql "SELECT id FROM repos WHERE path = '$REPO_ROOT';")
  fi

  # Check if workstream already exists for this branch
  EXISTING_WORKSTREAM=$(run_sql "SELECT id FROM workstreams WHERE repo_id = '$REPO_ID' AND branch = '$NEW_BRANCH';")
  if [ -n "$EXISTING_WORKSTREAM" ]; then
    # Link session to existing workstream
    run_sql "UPDATE sessions SET workstream_id = '$EXISTING_WORKSTREAM', branch = '$NEW_BRANCH' WHERE id = '$SESSION_ID';"
    echo "[$(date)] Linked session to existing workstream $EXISTING_WORKSTREAM for branch $NEW_BRANCH" >> "$HOME/.claude/hooks/debug.log"
    return
  fi

  # Parse Linear issue from branch name
  LINEAR_ISSUE_ID=""
  if [[ "$NEW_BRANCH" =~ ([a-zA-Z]+-[0-9]+) ]]; then
    LINEAR_ISSUE_ID=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
  fi

  # Create new workstream
  WORKSTREAM_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  DIRECTORY="${WORKTREE_PATH:-$CWD}"

  run_sql "INSERT INTO workstreams (id, repo_id, branch, directory, linear_issue_id, stage, session_count, total_session_seconds, commit_count, review_approvals, review_comments, last_activity_at, created_at, updated_at)
           VALUES ('$WORKSTREAM_ID', '$REPO_ID', '$NEW_BRANCH', '$DIRECTORY', $([ -n "$LINEAR_ISSUE_ID" ] && echo "'$LINEAR_ISSUE_ID'" || echo "NULL"), 'working', 1, 0, 0, 0, 0, '$NOW', '$NOW', '$NOW');"

  # Link session to new workstream
  run_sql "UPDATE sessions SET workstream_id = '$WORKSTREAM_ID', branch = '$NEW_BRANCH' WHERE id = '$SESSION_ID';"

  echo "[$(date)] Created workstream $WORKSTREAM_ID for new branch $NEW_BRANCH (Linear: $LINEAR_ISSUE_ID)" >> "$HOME/.claude/hooks/debug.log"
}

case "$EVENT" in
  "PreToolUse")
    # Update last tool and set working status
    run_sql "UPDATE sessions SET last_tool = '$TOOL_NAME', last_tool_at = '$NOW', work_status = 'working' WHERE id = '$SESSION_ID';"
    notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    ;;
  "PostToolUse")
    # Keep last tool, update activity time
    run_sql "UPDATE sessions SET last_activity_at = '$NOW', tool_count = tool_count + 1 WHERE id = '$SESSION_ID';"

    # After Bash commands, detect branch creation
    if [ "$TOOL_NAME" = "Bash" ]; then
      detect_branch_creation
    fi

    notifyutil -p com.commandcenter.session.updated 2>/dev/null &
    ;;
esac

exit 0
