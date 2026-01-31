# OrbitDock MCP Server & Hooks

Node.js-based hooks and MCP server for OrbitDock - giving Claude awareness of workstreams.

## Installation

```bash
./install.sh
```

This sets up:
- Claude Code hooks for session tracking
- MCP server with workstream tools

## Architecture

```
src/
├── db.js           # SQLite wrapper (shared)
├── git.js          # Git utilities (shared)
├── workstream.js   # Workstream logic (shared)
├── server.js       # MCP server
└── hooks/
    ├── session-start.js
    ├── session-end.js
    ├── tool-tracker.js
    └── status-tracker.js
```

All hooks are thin wrappers that call into the shared modules, making the logic:
- **Testable** - Pure functions with injected dependencies
- **Reusable** - Same code for hooks and MCP server
- **Maintainable** - One place for business logic

## MCP Tools

### `get_workstream_context`

Returns context about the current workstream:
- Name, branch, stage
- Linked tickets
- Recent notes and decisions
- Unresolved blockers
- Session history

### `add_workstream_note`

Add a note to the current workstream:
- `note` - General observation
- `decision` - Technical decision with reasoning
- `blocker` - Something blocking progress
- `pivot` - Change in approach
- `milestone` - Significant progress

### `link_ticket`

Link a ticket to the current workstream:
- Linear issues
- GitHub issues
- GitHub PRs

## Database

Location: `~/.orbitdock/orbitdock.db`

Uses SQLite with WAL mode for concurrent access from hooks and the macOS app.

## Development

```bash
# Test imports
node -e "import('./src/db.js').then(() => console.log('OK'))"

# Run server directly
node src/server.js

# Test a hook
echo '{"session_id":"test","cwd":"/tmp"}' | node src/hooks/session-start.js
```
