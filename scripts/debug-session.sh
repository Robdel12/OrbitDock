#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <session-id> [tail-lines]"
  echo "Example: $0 5aa8812d-da99-4974-b4bf-7b5647441be2 150"
  exit 1
fi

SESSION_ID="$1"
TAIL_LINES="${2:-120}"

if ! [[ "$TAIL_LINES" =~ ^[0-9]+$ ]]; then
  echo "tail-lines must be a positive integer"
  exit 1
fi

DB_PATH="${ORBITDOCK_DB_PATH:-$HOME/.orbitdock/orbitdock.db}"
APP_LOG="${ORBITDOCK_APP_LOG:-$HOME/.orbitdock/logs/app.log}"
CODEX_LOG="${ORBITDOCK_CODEX_LOG:-$HOME/.orbitdock/logs/codex.log}"
CLI_LOG="${ORBITDOCK_CLI_LOG:-$HOME/.orbitdock/cli.log}"
SERVER_LOG="${ORBITDOCK_SERVER_LOG:-$HOME/.orbitdock/logs/server.log}"

for bin in sqlite3 rg; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Missing required command: $bin"
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Database not found: $DB_PATH"
  exit 1
fi

SESSION_SQL="$(printf "%s" "$SESSION_ID" | sed "s/'/''/g")"

run_sql() {
  local sql="$1"
  sqlite3 \
    -cmd ".timeout 5000" \
    -cmd ".headers on" \
    -cmd ".mode column" \
    "$DB_PATH" \
    "$sql"
}

print_log_section() {
  local title="$1"
  local path="$2"
  local pattern="$3"

  echo "== $title =="
  if [ ! -f "$path" ]; then
    echo "Not found: $path"
    echo
    return
  fi

  rg -n --color never -S "$pattern" "$path" | tail -n "$TAIL_LINES" || true
  echo
}

echo "== Debug Target =="
echo "Session: $SESSION_ID"
echo "Database: $DB_PATH"
echo "App log: $APP_LOG"
echo "Codex log: $CODEX_LOG"
echo "CLI log: $CLI_LOG"
echo "Server log: $SERVER_LOG"
echo

echo "== Session Row =="
run_sql "
SELECT
  id,
  provider,
  status,
  work_status,
  codex_integration_mode,
  claude_integration_mode,
  COALESCE(project_path, '') AS project_path,
  COALESCE(transcript_path, '') AS transcript_path,
  COALESCE(summary, '') AS summary,
  COALESCE(custom_name, '') AS custom_name,
  COALESCE(first_prompt, '') AS first_prompt,
  COALESCE(last_message, '') AS last_message,
  COALESCE(input_tokens, 0) AS input_tokens,
  COALESCE(output_tokens, 0) AS output_tokens,
  COALESCE(cached_tokens, 0) AS cached_tokens,
  COALESCE(last_activity_at, 0) AS last_activity_at_epoch
FROM sessions
WHERE id = '$SESSION_SQL';
"
echo

echo "== Message Counts =="
run_sql "
SELECT
  COUNT(*) AS total_messages,
  COUNT(DISTINCT id) AS distinct_ids,
  SUM(CASE WHEN TRIM(COALESCE(id, '')) = '' THEN 1 ELSE 0 END) AS empty_ids,
  SUM(CASE WHEN TRIM(COALESCE(content, '')) = '' THEN 1 ELSE 0 END) AS empty_content
FROM messages
WHERE session_id = '$SESSION_SQL';
"
echo

echo "== Duplicate Message IDs (DB) =="
run_sql "
SELECT
  id,
  COUNT(*) AS copies
FROM messages
WHERE session_id = '$SESSION_SQL'
GROUP BY id
HAVING COUNT(*) > 1
ORDER BY copies DESC, id
LIMIT 25;
"
echo

echo "== Message Type Breakdown =="
run_sql "
SELECT
  type,
  COUNT(*) AS count,
  SUM(CASE WHEN TRIM(COALESCE(content, '')) = '' THEN 1 ELSE 0 END) AS empty_content
FROM messages
WHERE session_id = '$SESSION_SQL'
GROUP BY type
ORDER BY count DESC, type;
"
echo

echo "== Recent Messages (DB) =="
run_sql "
SELECT
  sequence,
  id,
  type,
  LENGTH(COALESCE(content, '')) AS content_len,
  LENGTH(COALESCE(tool_output, '')) AS output_len,
  COALESCE(tool_name, '') AS tool_name,
  timestamp
FROM messages
WHERE session_id = '$SESSION_SQL'
ORDER BY sequence DESC
LIMIT 50;
"
echo

print_log_section \
  "App Log (filtered)" \
  "$APP_LOG" \
  "$SESSION_ID|conversation state|fallback_render_all_messages|refresh_messages|load_messages|duplicate_ids|empty_ids"

print_log_section \
  "Codex Log (filtered)" \
  "$CODEX_LOG" \
  "$SESSION_ID|conversation state|Normalized messages|fallback_render_all_messages|refresh_messages|load_messages"

print_log_section \
  "CLI Log (filtered)" \
  "$CLI_LOG" \
  "$SESSION_ID"

print_log_section \
  "Server Log (filtered)" \
  "$SERVER_LOG" \
  "$SESSION_ID|restore\\.session\\.registered|messageAppended|messageUpdated|sessionSnapshot|sessionDelta|ws\\.subscribe|approvalRequested|turnDiffSnapshot|LoadTranscriptAndSync"
