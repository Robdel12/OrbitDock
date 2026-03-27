# Local Development

Use this doc when you need to run OrbitDock locally, find server-owned files, or remember which CLI command does what.

If you're looking for architecture rules, start with [CLIENT_DESIGN_PRINCIPLES.md](CLIENT_DESIGN_PRINCIPLES.md), [SWIFT_CLIENT_ARCHITECTURE.md](SWIFT_CLIENT_ARCHITECTURE.md), and [data-flow.md](data-flow.md) instead.

## What Runs Where

OrbitDock is a native SwiftUI client talking to a separate Rust server.

- the app uses REST for queries and mutations
- the app uses WebSocket for real-time events and interactive session traffic
- the server owns the database, auth, hooks, and provider integration

## Daily Commands

From the repo root:

```bash
make build
make build-ios
make test-unit
make rust-build
make rust-check
make rust-check-workspace
make rust-test
make rust-run
make rust-run-debug
make cli ARGS='session list'
```

Rust workflow policy still applies here: use `make rust-*` targets instead of plain `cargo`.
Those targets also auto-enable `sccache` when it is installed and keep Rust artifacts under the shared repo cache.
Shared Make configuration lives at the repo root, and target families are split under `make/*.mk`.

## Local Server Setup

For local development:

1. Run `orbitdock init`
2. Run `make rust-run`
3. Open the app and connect to the local endpoint

`orbitdock init` creates the data directory, runs migrations, and provisions the local auth token used by hook forwarding and app setup.

Interactive `make rust-run`, `make rust-run-lan`, and `make rust-run-debug` open the in-process dev console by default when attached to a TTY. Set `ORBITDOCK_DEV_CONSOLE=0` if you want the plain terminal experience.

For LAN testing, use `make rust-run-lan`.

When the server binds to `0.0.0.0:4000`, treat that as a listen address only.
Local clients, hooks, and CLI commands should still connect to `http://127.0.0.1:4000` on the same machine, or to the machine's actual LAN/Tailscale address from another device.

## App Install Flow

When the native app installs or configures a local server, the flow is:

1. Find the `orbitdock` binary
2. Copy it to `~/.orbitdock/bin/` when needed
3. Run `orbitdock ensure-path`
4. Run `orbitdock init`
5. Run `orbitdock install-hooks`
6. Run `orbitdock install-service --enable`
7. Wait for the health check
8. Read the local auth token and connect

`ServerManager` shells out to the server CLI for service management. The app does not build launchd plists itself.

## Important File Locations

All server paths resolve from one data directory:

- `--data-dir`
- `ORBITDOCK_DATA_DIR`
- default `~/.orbitdock`

Common paths:

- server binary: `~/.orbitdock/bin/orbitdock`
- database: `<data_dir>/orbitdock.db`
- auth config: `<data_dir>/hook-forward.json`
- encryption key: `<data_dir>/encryption.key`
- server log: `<data_dir>/logs/server.log`
- codex log: `<data_dir>/logs/codex.log`
- hook spool: `<data_dir>/spool/`
- managed sync spool: `<data_dir>/sync-spool/<workspace_id>/`
- codex rollout watcher state: `<data_dir>/codex-rollout-state.json`
- launchd plist: `~/Library/LaunchAgents/com.orbitdock.server.plist`

Read-only external inputs:

- Claude transcripts: `~/.claude/projects/<project-hash>/<session-id>.jsonl`
- Codex sessions: `~/.codex/sessions/**/rollout-*.jsonl`

## Hook Transport

Claude Code hooks use `orbitdock hook-forward <type>`. That command injects the event type and POSTs to `/api/hook`.

Hook transport config lives in `<data_dir>/hook-forward.json`.

Hook mapping:

| Claude Hook | Type |
|---|---|
| `SessionStart` | `claude_session_start` |
| `SessionEnd` | `claude_session_end` |
| `UserPromptSubmit`, `Stop`, `Notification`, `PreCompact` | `claude_status_event` |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` | `claude_tool_event` |
| `SubagentStart`, `SubagentStop` | `claude_subagent_event` |

## CLI Basics

The `orbitdock` binary covers both server admin and client-facing operations.

Useful commands:

```bash
# Server admin
orbitdock init
orbitdock install-hooks
orbitdock start
orbitdock start --managed --workspace-id <WORKSPACE_ID> --sync-url <CONTROL_PLANE_URL> --sync-token <TOKEN>
orbitdock install-service --enable
orbitdock status

# Health and status
orbitdock health
orbitdock server status

# Sessions
orbitdock session list
orbitdock session get <ID>
orbitdock session send <ID> "message"
orbitdock session watch <ID>
orbitdock session interrupt <ID>
orbitdock session end <ID>

# Supporting
orbitdock approval list
orbitdock model list
orbitdock usage show
orbitdock worktree list

# Mission provider management
orbitdock mission provider get
orbitdock mission provider set local
orbitdock mission provider set daytona
orbitdock mission provider config get daytona-api-url
orbitdock mission provider config set daytona-api-url https://daytona.example.com
orbitdock mission provider config set daytona-api-key <TOKEN>
orbitdock mission provider config set public-server-url https://orbitdock.example.com
orbitdock mission provider test
```

Output is human-readable in a TTY and JSON when piped or when you pass `--json`.

Mission provider config commands report the effective value source.
If an `ORBITDOCK_DAYTONA_*` or `ORBITDOCK_PUBLIC_SERVER_URL` env var is set, the command output shows `source=env` to make it clear that persisted settings are currently overridden.

## Managed Mode

Managed mode is the advanced server startup path for remote or provisioned workspaces.

Use it when a workspace should keep local SQLite as its source of truth and replicate committed persistence upstream to a control-plane OrbitDock server.

Example:

```bash
orbitdock start \
  --managed \
  --workspace-id workspace-123 \
  --sync-url https://orbitdock.example.com \
  --sync-token odtk_example_secret
```

Managed mode is not part of the normal local app install flow. For local development on your own machine, keep using plain `orbitdock start` or the `make rust-run*` targets.

## Mission Control

Mission Control is configured with repo-local `MISSION.md`.

The mission-owned provider CLI is the right place to manage remote workspace provider defaults and preflight checks.
For example, a Daytona setup flow can stay entirely in the CLI:

```bash
orbitdock mission provider set daytona
orbitdock mission provider config set daytona-api-url https://daytona.example.com
orbitdock mission provider config set daytona-api-key <TOKEN>
orbitdock mission provider config set public-server-url https://orbitdock.example.com
orbitdock mission provider test
```

`orbitdock mission provider test` is a preflight check. For Daytona it verifies that the configured control plane is reachable, but it does not create a sandbox or run a full end-to-end mission.

Use these docs when you need more detail:

- [sample-mission.md](sample-mission.md)
- [DEPLOYMENT.md](DEPLOYMENT.md) for install and remote setup

## Claude Agent SDK Source Of Truth

When you need to reason about Claude Agent SDK behavior, inspect the shipped SDK source in:

`orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/`

Use the installed source as the primary reference for plan mode, permissions, hooks, and tool schemas. Treat external docs as secondary if they disagree.
