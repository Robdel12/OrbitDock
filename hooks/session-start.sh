#!/bin/bash
# Claude Code SessionStart hook
# Reads session JSON from stdin and inserts into SQLite
# Also detects git repo/branch and creates workstream records

set -e

LOG_FILE="$HOME/.claude/hooks/debug.log"
DB_PATH="$HOME/.orbitdock/orbitdock.db"
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

# Capture terminal info from environment
TERMINAL_SESSION_ID="${ITERM_SESSION_ID:-}"
TERMINAL_APP="${TERM_PROGRAM:-}"

# Current timestamp
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Initialize git-related variables
BRANCH=""
PROJECT_NAME=""
REPO_ROOT=""
GITHUB_OWNER=""
GITHUB_NAME=""
REPO_ID=""
WORKSTREAM_ID=""

# Check if we're in a git repo
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
  # Get the canonical repo root (handles worktrees)
  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "")

  # For worktrees, get the main repo path
  GIT_COMMON_DIR=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$GIT_COMMON_DIR" ] && [ "$GIT_COMMON_DIR" != ".git" ]; then
    # This is a worktree - get the main repo root
    MAIN_REPO_ROOT=$(dirname "$GIT_COMMON_DIR")
    if [ -d "$MAIN_REPO_ROOT" ]; then
      REPO_ROOT="$MAIN_REPO_ROOT"
    fi
  fi

  # Get current branch
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "")

  # Get remote URL and parse GitHub owner/name
  REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null || echo "")
  if [ -n "$REMOTE_URL" ]; then
    # Extract repo name
    PROJECT_NAME=$(basename -s .git "$REMOTE_URL")

    # Parse GitHub owner/name from URL
    # Handles: https://github.com/owner/repo.git and git@github.com:owner/repo.git
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
      GITHUB_OWNER="${BASH_REMATCH[1]}"
      GITHUB_NAME="${BASH_REMATCH[2]}"
    fi
  fi
fi

# Fallback to folder name for project name
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME=$(basename "$CWD")
fi

# Ensure tables exist (idempotent)
sqlite3 "$DB_PATH" << 'SCHEMA'
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS repos (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    github_owner TEXT,
    github_name TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workstreams (
    id TEXT PRIMARY KEY,
    repo_id TEXT NOT NULL REFERENCES repos(id),
    branch TEXT NOT NULL,
    directory TEXT,
    linear_issue_id TEXT,
    linear_issue_title TEXT,
    linear_issue_state TEXT,
    linear_issue_url TEXT,
    github_issue_number INTEGER,
    github_issue_title TEXT,
    github_issue_state TEXT,
    github_pr_number INTEGER,
    github_pr_title TEXT,
    github_pr_state TEXT,
    github_pr_url TEXT,
    github_pr_additions INTEGER,
    github_pr_deletions INTEGER,
    review_state TEXT,
    review_approvals INTEGER DEFAULT 0,
    review_comments INTEGER DEFAULT 0,
    stage TEXT DEFAULT 'working',
    session_count INTEGER DEFAULT 0,
    total_session_seconds INTEGER DEFAULT 0,
    commit_count INTEGER DEFAULT 0,
    last_activity_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(repo_id, branch)
);
SCHEMA

# If we have a repo root, find or create repo and workstream
if [ -n "$REPO_ROOT" ]; then
  # Generate repo ID from path hash
  REPO_ID=$(echo -n "$REPO_ROOT" | shasum -a 256 | cut -c1-16)

  # Find or create repo
  sqlite3 "$DB_PATH" << EOF
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
INSERT INTO repos (id, name, path, github_owner, github_name, created_at)
VALUES ('$REPO_ID', '$PROJECT_NAME', '$REPO_ROOT', $([ -n "$GITHUB_OWNER" ] && echo "'$GITHUB_OWNER'" || echo "NULL"), $([ -n "$GITHUB_NAME" ] && echo "'$GITHUB_NAME'" || echo "NULL"), '$NOW')
ON CONFLICT(path) DO UPDATE SET
  github_owner = COALESCE(excluded.github_owner, repos.github_owner),
  github_name = COALESCE(excluded.github_name, repos.github_name);
EOF

  # Get the actual repo ID (in case it already existed)
  REPO_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM repos WHERE path = '$REPO_ROOT'")

  # Create workstream if branch is not main/master
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ] && [ "$BRANCH" != "master" ] && [ "$BRANCH" != "develop" ]; then
    # Generate workstream ID
    WORKSTREAM_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Parse Linear issue ID from branch name (e.g., viz-42-description -> VIZ-42)
    LINEAR_ISSUE_ID=""
    if [[ "$BRANCH" =~ ([a-zA-Z]+-[0-9]+) ]]; then
      LINEAR_ISSUE_ID=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
    fi

    # Find or create workstream
    sqlite3 "$DB_PATH" << EOF
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
INSERT INTO workstreams (id, repo_id, branch, directory, linear_issue_id, stage, session_count, total_session_seconds, commit_count, review_approvals, review_comments, last_activity_at, created_at, updated_at)
VALUES ('$WORKSTREAM_ID', '$REPO_ID', '$BRANCH', '$CWD', $([ -n "$LINEAR_ISSUE_ID" ] && echo "'$LINEAR_ISSUE_ID'" || echo "NULL"), 'working', 1, 0, 0, 0, 0, '$NOW', '$NOW', '$NOW')
ON CONFLICT(repo_id, branch) DO UPDATE SET
  directory = COALESCE(excluded.directory, workstreams.directory),
  session_count = workstreams.session_count + 1,
  last_activity_at = '$NOW',
  updated_at = '$NOW';
EOF

    # Get the actual workstream ID
    WORKSTREAM_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM workstreams WHERE repo_id = '$REPO_ID' AND branch = '$BRANCH'")
  fi
fi

# Insert or update session
sqlite3 "$DB_PATH" << EOF
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
INSERT INTO sessions (id, project_path, project_name, branch, model, transcript_path, status, started_at, last_activity_at, terminal_session_id, terminal_app, workstream_id)
VALUES ('$SESSION_ID', '$CWD', '$PROJECT_NAME', '$BRANCH', '$MODEL', '$TRANSCRIPT_PATH', 'active', '$NOW', '$NOW', '$TERMINAL_SESSION_ID', '$TERMINAL_APP', $([ -n "$WORKSTREAM_ID" ] && echo "'$WORKSTREAM_ID'" || echo "NULL"))
ON CONFLICT(id) DO UPDATE SET
  status = 'active',
  last_activity_at = '$NOW',
  terminal_session_id = '$TERMINAL_SESSION_ID',
  terminal_app = '$TERMINAL_APP',
  workstream_id = COALESCE(excluded.workstream_id, sessions.workstream_id);
EOF

echo "[$(date)] Created/updated session $SESSION_ID, repo_id=$REPO_ID, workstream_id=$WORKSTREAM_ID" >> "$LOG_FILE"

# Notify the app via Darwin notification (instant, non-blocking)
notifyutil -p com.commandcenter.session.updated 2>/dev/null &

exit 0
