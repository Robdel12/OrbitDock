# OrbitDock MCP

MCP for pair-debugging OrbitDock sessions. Discover and control both Claude and Codex direct sessions in the same app state you're viewing.

## Architecture

```
MCP (Node.js)  →  HTTP :19384  →  OrbitDock  →  Rust server / provider runtimes
```

Commands route through OrbitDock's HTTP bridge to `ServerAppState`. Same session, no state sync issues.

## Tools

| Tool | Description |
|------|-------------|
| `list_sessions` | List active Claude and/or Codex sessions (with controllability metadata) |
| `get_session` | Get details for a specific session |
| `send_message` | Send a user prompt to a direct Codex or Claude session |
| `interrupt_turn` | Stop the current turn (direct Codex or Claude) |
| `approve` | Resolve pending approvals with explicit decisions, optional deny message and interrupt |
| `steer_turn` | Inject guidance into an active turn without stopping it |
| `fork_session` | Fork a session with conversation history |
| `set_permission_mode` | Change Claude session permission mode (default, acceptEdits, plan, bypassPermissions) |
| `list_models` | List available Codex models |
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
tail -f ~/.orbitdock/logs/server.log | jq .
```
