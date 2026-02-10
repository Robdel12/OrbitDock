# OrbitDock Server

Mission control for AI coding agents. A Rust server that provides real-time session management via WebSocket.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  OrbitDock Server (Rust + Tokio)                 │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Axum HTTP/WebSocket                     │  │
│  │   GET /ws → WebSocket upgrade                             │  │
│  │   GET /health → Health check                              │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              Session Management (per-session tasks)        │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                      Connectors                            │  │
│  │  CodexConnector (subprocess → future: direct codex-rs)    │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Crates

- `orbitdock-server` - Main server binary
- `orbitdock-protocol` - Shared types (Server ↔ Client)
- `orbitdock-connectors` - AI provider connectors (Claude, Codex)

## Building

### Development

```bash
cargo build
cargo run
```

### Release (Universal Binary)

```bash
./build-universal.sh
```

Creates a universal binary at `target/universal/orbitdock-server` that runs on both Intel and Apple Silicon Macs.

## Protocol

Communication uses JSON over WebSocket on `ws://127.0.0.1:4000/ws`.

### Client → Server Messages

```json
{ "type": "subscribe_list" }
{ "type": "subscribe_session", "session_id": "..." }
{ "type": "create_session", "provider": "codex", "cwd": "/path/to/project" }
{ "type": "send_message", "session_id": "...", "content": "..." }
{ "type": "approve_tool", "session_id": "...", "request_id": "...", "approved": true }
{ "type": "interrupt_session", "session_id": "..." }
```

### Server → Client Messages

```json
{ "type": "sessions_list", "sessions": [...] }
{ "type": "session_snapshot", "session": {...} }
{ "type": "session_delta", "session_id": "...", "changes": {...} }
{ "type": "message_appended", "session_id": "...", "message": {...} }
{ "type": "approval_requested", "session_id": "...", "request": {...} }
{ "type": "tokens_updated", "session_id": "...", "usage": {...} }
```

## Embedding in macOS App

The server is designed to be embedded in the OrbitDock.app bundle:

```swift
class ServerManager {
    private var process: Process?

    func start() throws {
        let serverPath = Bundle.main.path(forResource: "orbitdock-server", ofType: nil)!

        process = Process()
        process?.executableURL = URL(fileURLWithPath: serverPath)
        try process?.run()
    }
}
```

## Future: Direct Codex Integration

The server is written in Rust specifically to enable direct integration with codex-rs:

```toml
[dependencies]
codex-core = { git = "https://github.com/openai/codex" }
```

This will eliminate:
- Process spawning/management overhead
- JSON-RPC serialization
- stdio buffering issues
