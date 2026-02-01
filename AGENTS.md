# Repository Guidelines

## Project Structure & Module Organization
- `CommandCenter/` is the macOS SwiftUI app (views, models, services, database layer, tests).
- `hooks/` contains Claude Code hook scripts plus tests and a small README for setup.
- `mcp-server/` hosts the Node MCP server entrypoint and README.
- `lib/` provides shared JS utilities and tests.
- `docs/` holds additional documentation; `orbitdock.png` is a repository asset.

## Build, Test, and Development Commands
- `npm run install-hooks` installs the Claude Code hooks via `install.js`.
- `npm start` runs the MCP server (`mcp-server/server.js`).
- `npm test` runs Node’s built-in test runner for `lib/*.test.js` and `hooks/*.test.js`.
- `npm run check` runs Biome (lint + format check); `npm run lint` applies fixes.
- SwiftUI app: open `CommandCenter/CommandCenter.xcodeproj` in Xcode and build/run (Cmd+R).

## Coding Style & Naming Conventions
- Swift is formatted with SwiftFormat; see `.swiftformat` (2-space indentation, max width 120).
- JavaScript uses Biome formatting (2-space indentation, single quotes, semicolons as needed).
- Prefer descriptive, domain-based naming (e.g., `SessionRowView`, `TranscriptParser`, `status-tracker`).

## Testing Guidelines
- JS tests live alongside sources: `lib/*.test.js`, `hooks/*.test.js`. Use `npm test`.
- Swift tests are under `CommandCenter/CommandCenterTests/`; run via Xcode (Cmd+U).
- If you change hook behavior or database fields, add or update tests where feasible.

## Commit & Pull Request Guidelines
- Recent commits use an emoji prefix plus a short, present-tense summary (e.g., `✨ Add reset times...`).
- PRs should include a clear description, test coverage notes, and UI screenshots for SwiftUI changes.
- Link related issues or include a short rationale if no issue exists.

## Architecture & App-Specific Notes
- The app reads Claude session data from a local SQLite DB and JSONL transcripts; review `README.md` and `CLAUDE.md` for schema, paths, and update flow.
- `CLAUDE.md` documents UI theme constraints and data consistency rules (e.g., WAL mode, status colors).
