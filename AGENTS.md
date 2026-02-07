# Repository Guidelines

## Overview
OrbitDock is a multi-provider AI agent monitoring dashboard. It supports Claude Code (via Swift CLI hooks) and Codex CLI (via Rust server rollout watching + direct codex-core integration).

## Project Structure & Module Organization
- `CommandCenter/` is the macOS SwiftUI app (views, models, services, database layer).
- `CommandCenter/OrbitDockCore/` is a Swift Package containing the CLI hook handler and shared database code.
- `migrations/` contains numbered SQL files for database schema changes.
- `docs/` holds additional documentation; `orbitdock.png` is a repository asset.

## Build & Development Commands
- SwiftUI app: open `CommandCenter/CommandCenter.xcodeproj` in Xcode and build/run (Cmd+R).
- CLI standalone: `cd CommandCenter/OrbitDockCore && swift build`
- Test CLI: `echo '{"session_id":"test","cwd":"/tmp"}' | .build/debug/orbitdock-cli session-start`

## Coding Style & Naming Conventions
- Swift is formatted with SwiftFormat; see `.swiftformat` (2-space indentation, max width 120).
- Prefer descriptive, domain-based naming (e.g., `SessionRowView`, `TranscriptParser`, `StatusTrackerCommand`).

## Testing Guidelines
- Swift tests are under `CommandCenter/CommandCenterTests/`; run via Xcode (Cmd+U).
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
- `tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'`
- `tail -f ~/.orbitdock/logs/codex.log | jq .`
- `tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error" or .level == "warning")'`
