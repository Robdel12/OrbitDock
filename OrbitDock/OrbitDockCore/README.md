# OrbitDockCore & CLI

Swift package containing shared code and the CLI hook handler for OrbitDock.

## Package Structure

```
OrbitDockCore/
├── Package.swift
└── Sources/
    ├── OrbitDockCore/          # Shared library
    │   ├── Database/           # SQLite operations
    │   ├── Git/                # Git utilities
    │   └── Models/             # Input models
    └── OrbitDockCLI/           # CLI executable
        └── Commands/
            ├── SessionStartCommand.swift   # session-start
            ├── SessionEndCommand.swift     # session-end
            ├── StatusTrackerCommand.swift  # status-tracker
            ├── ToolTrackerCommand.swift    # tool-tracker
            └── SubagentTrackerCommand.swift # subagent-tracker
```

## Building

```bash
# Build debug
swift build

# Build release
swift build -c release

# Run CLI
.build/debug/orbitdock-cli --help
```

## Xcode Integration

To embed the CLI in the OrbitDock app bundle:

### 1. Add Package to Xcode Project

1. Open `OrbitDock.xcodeproj` in Xcode
2. File → Add Package Dependencies...
3. Click "Add Local..."
4. Select the `OrbitDockCore` folder
5. Add `OrbitDockCore` library to the OrbitDock target

### 2. Add Build Script Phase

1. Select the OrbitDock target
2. Go to Build Phases
3. Click "+" → New Run Script Phase
4. Drag it AFTER "Compile Sources" and "Link Binary With Libraries"
5. Name it "Build & Embed CLI"
6. Set shell to `/bin/bash`
7. Add this script:

```bash
"${SRCROOT}/Scripts/build-cli.sh"
```

8. Uncheck "Based on dependency analysis" (force run every build)

### 3. Verify

1. Build the project (Cmd+R)
2. Right-click the built app → Show Package Contents
3. Navigate to Contents/MacOS/
4. Verify `orbitdock-cli` exists alongside `OrbitDock`

## CLI Commands

The CLI handles Claude Code hooks via stdin JSON:

| Command | Hooks Handled | Purpose |
|---------|---------------|---------|
| `session-start` | SessionStart | Create session, capture model/source/permission_mode |
| `session-end` | SessionEnd | Mark session ended with reason |
| `status-tracker` | UserPromptSubmit, Stop, Notification, PreCompact | Status transitions & compaction |
| `tool-tracker` | PreToolUse, PostToolUse, PostToolUseFailure | Tool usage & permission clearing |
| `subagent-tracker` | SubagentStart, SubagentStop | Track spawned agents (Explore, Plan) |

### Example Usage

```bash
# Session lifecycle
echo '{"session_id":"abc","cwd":"/path","source":"startup","model":"claude-sonnet-4"}' | orbitdock-cli session-start
echo '{"session_id":"abc","cwd":"/path","reason":"logout"}' | orbitdock-cli session-end

# Status tracking
echo '{"session_id":"abc","cwd":"/path","hook_event_name":"Stop"}' | orbitdock-cli status-tracker
echo '{"session_id":"abc","cwd":"/path","hook_event_name":"PreCompact","trigger":"auto"}' | orbitdock-cli status-tracker

# Tool tracking
echo '{"session_id":"abc","cwd":"/path","hook_event_name":"PreToolUse","tool_name":"Bash"}' | orbitdock-cli tool-tracker

# Subagent tracking
echo '{"session_id":"abc","cwd":"/path","hook_event_name":"SubagentStart","agent_id":"xyz","agent_type":"Explore"}' | orbitdock-cli subagent-tracker
```

### Debugging

All CLI commands log to `~/.orbitdock/cli.log`:

```bash
tail -f ~/.orbitdock/cli.log
```

## User Configuration

Users add hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli session-start",
        "async": true
      }]
    }]
  }
}
```

See the full configuration template in the app's Settings → Setup tab.
