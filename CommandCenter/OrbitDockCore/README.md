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
        └── Commands/           # Subcommands
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

1. Open `CommandCenter.xcodeproj` in Xcode
2. File → Add Package Dependencies...
3. Click "Add Local..."
4. Select the `OrbitDockCore` folder
5. Add `OrbitDockCore` library to the CommandCenter target

### 2. Add Build Script Phase

1. Select the CommandCenter target
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

## CLI Usage

The CLI handles Claude Code hooks via stdin JSON:

```bash
# Session lifecycle
echo '{"session_id":"abc","cwd":"/path"}' | orbitdock-cli session-start
echo '{"session_id":"abc","cwd":"/path","reason":"logout"}' | orbitdock-cli session-end

# Status tracking
echo '{"session_id":"abc","cwd":"/path","hook_event_name":"Stop"}' | orbitdock-cli status-tracker

# Tool tracking
echo '{"session_id":"abc","cwd":"/path","hook_event_name":"PreToolUse","tool_name":"Bash"}' | orbitdock-cli tool-tracker
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
