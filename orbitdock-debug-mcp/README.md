# OrbitDock MCP

MCP for pair-debugging Codex sessions. Allows an LLM to interact with the **same** Codex session you're viewing in OrbitDock.

## Architecture

```
MCP (Node.js)  →  HTTP :19384  →  OrbitDock  →  Codex app-server
```

Commands route through OrbitDock's HTTP bridge to `CodexDirectSessionManager`. Same session, no state sync issues.

## Tools

| Tool | Description |
|------|-------------|
| `list_sessions` | List active Codex sessions |
| `send_message` | Send a user prompt (starts a turn) |
| `interrupt_turn` | Stop the current turn |
| `approve` | Approve/reject pending tool executions |
| `check_connection` | Verify OrbitDock is running |

## Setup

```bash
npm install
```

Configured in `.mcp.json` (project root).

## Requirements

- **OrbitDock must be running** - MCPBridge starts on port 19384

## Debugging

For database/log inspection, use CLI:

```bash
sqlite3 ~/.orbitdock/orbitdock.db "SELECT * FROM sessions"
tail -f ~/.orbitdock/codex-events.log | jq .
```
