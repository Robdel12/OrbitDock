# Repository Guidelines

## Overview
OrbitDock is a multi-provider AI agent monitoring dashboard. It supports Claude Code (via Swift CLI hooks) and Codex CLI (via Rust server rollout watching + direct codex-core integration).

## Project Structure & Module Organization
- `OrbitDock/OrbitDock/` is the macOS SwiftUI app (views, models, services, database layer).
- `OrbitDock/OrbitDockCore/` is a Swift Package containing the CLI hook handler and shared database code.
- `migrations/` contains numbered SQL files for database schema changes.
- `docs/` holds additional documentation; `orbitdock.png` is a repository asset.

## Build & Development Commands
- SwiftUI app build (standard): `make build` (wraps `xcodebuild -project OrbitDock/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' build`).
- Unit tests (standard, no UI tests): `make test-unit`.
- UI tests (standard): `make test-ui`.
- All app tests: `make test-all`.
- Rust server build: `make rust-build`.
- Rust workspace check: `make rust-check`.
- Rust workspace tests: `make rust-test`.
- Format all code: `make fmt` (or `make swift-fmt` / `make rust-fmt`).
- Lint all code: `make lint` (or `make swift-lint` / `make rust-lint`).
- SwiftUI app in Xcode: open `OrbitDock/OrbitDock.xcodeproj` and build/run (Cmd+R).
- CLI standalone: `cd OrbitDock/OrbitDockCore && swift build`
- Test CLI: `echo '{"session_id":"test","cwd":"/tmp"}' | .build/debug/orbitdock-cli session-start`

## Coding Style & Naming Conventions
- Swift is formatted with SwiftFormat; see `.swiftformat` (2-space indentation, max width 120).
- Prefer descriptive, domain-based naming (e.g., `SessionRowView`, `TranscriptParser`, `StatusTrackerCommand`).

## Testing Guidelines
- Swift tests are under `OrbitDock/OrbitDockTests/`; prefer `make test-unit` for non-UI tests and `make test-ui` for UI automation.
- CLI can be tested by piping JSON to stdin and checking database state.

## Commit & Pull Request Guidelines
- Commits use gitmoji prefix plus a short, present-tense summary (e.g., `✨ Add reset times...`).
- PRs should include a clear description, test coverage notes, and UI screenshots for SwiftUI changes.
- Link related issues or include a short rationale if no issue exists.

## Architecture & App-Specific Notes
- The app reads AI agent session data from a local SQLite DB and JSONL transcripts.
- Claude Code sessions: populated via Swift CLI hooks configured in `~/.claude/settings.json`.
- Codex sessions: unified through `orbitdock-server` (direct sessions + rollout-watched CLI sessions).
- Review `README.md` and `CLAUDE.md` for schema, paths, and update flow.
- `CLAUDE.md` documents UI theme constraints and data consistency rules (e.g., WAL mode, status colors).

## Debugging Quick Reference
- Database: `~/.orbitdock/orbitdock.db`
- CLI log: `~/.orbitdock/cli.log`
- Codex app log: `~/.orbitdock/logs/codex.log`
- Rust server log: `~/.orbitdock/logs/server.log`

Useful commands:
- `sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, provider, codex_integration_mode, status, work_status FROM sessions ORDER BY datetime(last_activity_at) DESC LIMIT 20;"`
- `tail -f ~/.orbitdock/logs/server.log | jq .`
- `tail -f ~/.orbitdock/logs/server.log | jq 'select(.event == "session.resume.connector_failed")'`
- `tail -f ~/.orbitdock/logs/server.log | jq 'select(.component == "websocket")'`
- `tail -f ~/.orbitdock/logs/server.log | jq 'select(.session_id == "your-session-id")'`
- `tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'`
- `tail -f ~/.orbitdock/logs/codex.log | jq .`
- `tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error" or .level == "warning")'`

Rust server logging env vars:
- `ORBITDOCK_SERVER_LOG_FILTER` (preferred) or `RUST_LOG` to control verbosity/filtering.
- `ORBITDOCK_SERVER_LOG_FORMAT=json|pretty` (default `json`).
- `ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START=1` to clear `server.log` at startup.
