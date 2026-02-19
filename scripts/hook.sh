#!/bin/bash
# OrbitDock hook — forwards Claude Code hook events to the Rust server via HTTP POST.
# Usage: echo '{"session_id":"..."}' | hook.sh <type>
#
# Types: claude_session_start, claude_session_end, claude_status_event,
#        claude_tool_event (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest),
#        claude_subagent_event
#
# If the server is unreachable, events are spooled to ~/.orbitdock/spool/ as JSON files.
# The server drains the spool on startup so no events are lost.

TYPE="$1"
[ -z "$TYPE" ] && exit 0

PAYLOAD=$(cat)
[ -z "$PAYLOAD" ] && exit 0

# Inject "type" field and terminal env vars (session-start only) via jq
if command -v jq >/dev/null 2>&1; then
  BODY=$(echo "$PAYLOAD" | jq -c --arg t "$TYPE" \
    --arg tsid "${ITERM_SESSION_ID:-}" \
    --arg tapp "${TERM_PROGRAM:-}" \
    '. + {type: $t} + (if $t == "claude_session_start" then
      {terminal_session_id: (if $tsid == "" then null else $tsid end),
       terminal_app: (if $tapp == "" then null else $tapp end)}
    else {} end)')
else
  # Fallback: inject type via string concatenation (no jq)
  BODY=$(echo "$PAYLOAD" | sed "s/^{/{\"type\":\"$TYPE\",/")
fi

SPOOL_DIR="$HOME/.orbitdock/spool"

if ! curl -s -X POST --connect-timeout 2 --max-time 5 \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  "http://127.0.0.1:4000/api/hook" >/dev/null 2>&1; then
  mkdir -p "$SPOOL_DIR"
  echo "$BODY" > "$SPOOL_DIR/$(date +%s)-$$.json"
fi
