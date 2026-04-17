# OrbitDock: Products & Value Propositions

> Mission control for AI coding agents. Orchestrate, review, and steer your fleet of AI agents from anywhere — on your phone, your laptop, or any server.

---

## What OrbitDock Is

OrbitDock is an **agent orchestration platform** for AI-assisted product development. It provides a unified dashboard to run, review, and manage Claude Code and Codex CLI sessions — no matter where they're running.

The system has three parts:

1. **Rust Server** (`orbitdock-server/`): A standalone binary that runs agent sessions, serves an HTTP API and WebSocket for realtime updates, and stores durable business state in SQLite.

2. **Native Client Apps** (`OrbitDockNative/`): macOS and iOS/iPadOS applications built with Swift/SwiftUI. They connect to any OrbitDock server via HTTP + WebSocket.

3. **Web App** (`orbitdock-web/`): A future web frontend for the same agent orchestration features.

---

## The Problem OrbitDock Solves

When building multiple products (Vizzly, Snoot, Moonbun, Backchannel, Pitstop) with AI agents, you face:

- Scattered terminal windows and tabs across machines
- Mental overhead tracking which agent is doing what
- Context lost between sessions
- Linear tickets disconnected from the actual work
- No unified view of "what's the state of this multi-week project?"
- Multiple AI providers (Claude, Codex) with different rate limits to track

The work happens in fragments. The organization lives in your head.

OrbitDock unifies that chaos.

---

## Core Capabilities

### 1. Session Monitoring

Track every agent session in real time:

- **Multi-provider support** — Claude Code and Codex CLI from one dashboard
- **Dual integration modes** — Passive (hook-based / FSEvents file watching) and Direct (bidirectional control)
- **Live session updates** — Conversations stream via WebSocket, no polling
- **5 status states** — Working, Permission, Question, Reply, Ended
- **Activity banners** — See what tool the agent is currently using
- **Token and cost tracking** — Per-session and per-turn usage stats
- **Subagent tracking** — See when Claude spawns Explore, Plan, or other agents

### 2. Unified Dashboard

Open OrbitDock and immediately see:

- Which quests need attention
- What agents are actively working
- Where you left off yesterday
- What's blocked, what's ready for review

The dashboard merges sessions from multiple connected servers into one view.

### 3. Code Review Canvas

Review agent changes with a magit-style interface:

- Browse changed files with add/update/delete indicators
- Unified diffs with syntax highlighting
- Inline comment threads — drag to select, write feedback
- Comment-to-steer — send structured feedback to the agent
- Resolved comment markers and mark selection
- Split layout — conversation + review side by side

### 4. Approval Oversight

When an agent needs approval:

- **Risk classifier** — Low/Normal/High risk detection, DESTRUCTIVE badge for dangerous patterns
- **Diff preview** — See file changes before approving
- **Keyboard triage** — `y` approve, `n` deny, `!` always allow
- **Deny with reason** — Explain why, optionally interrupt the turn
- **Approval history** — Session-scoped and global approval history sidebar

### 5. Direct Claude Control

Full control over Claude Code sessions:

- Create sessions with project directory picker
- Model picker — Sonnet 4.5, Opus 4.6, Haiku 4.5, or custom
- Permission modes — Default, Accept Edits, Plan (read-only), Bypass Permissions
- Send messages and steer mid-turn
- Take over passive sessions promoted to direct control
- Resume ended sessions

### 6. Direct Codex Control

Full control over Codex sessions:

- Create sessions with project path and model selection
- Send messages and steer mid-turn
- Approve/deny tools inline
- Interrupt turns or undo last turn
- Shell mode — `!command` prefix to run shell commands
- Fork and branch session conversations

### 7. Multi-Server Architecture

Connect to multiple servers at once:

- **Local server** — Your laptop running `orbitdock`
- **Remote server** — VPS, cloud instance, Raspberry Pi
- **Multi-server merge** — Sessions from every endpoint merge into one dashboard
- **Endpoint-scoped identity** — Duplicate session IDs across servers are isolated

### 8. Mission Control

Autonomous issue-driven agent orchestration:

- Point at Linear or GitHub, agents start working issues on their own
- Pull eligible issues, create per-issue git worktrees, dispatch agents
- Concurrency limits, retry logic, provider failover — all configurable
- Dashboard shows the full pipeline, hands-off orchestration until you step in

### 9. Usage Tracking

Monitor usage across all providers:

- Rate limit monitoring for Claude and Codex
- Per-session token counts and context window fill indicators
- Cost tracking where applicable

### 10. Notifications

Stay informed:

- Toast notifications in-app
- macOS system notifications for permission/question states
- Push approvals and questions to your phone

---

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      OrbitDock Clients                        │
│         (macOS/iOS apps, Web app — future)                   │
└──────────────────────────┬──────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┬────────────────┐
         │                 │                 │                │
   ┌─────▼───────┐  ┌──────▼─────┐  ┌───────▼────────┐  ┌───▼──────┐
   │   Server 1  │  │  Server 2  │  │  Server 3      │  │  Server N │
   │             │  │            │  │                 │  │           │
   │ Claude +    │  │ Claude +   │  │ Claude +       │  │ Claude +  │
   │ Codex       │  │ Codex      │  │ Codex          │  │ Codex     │
   │   sessions  │  │   sessions │  │   sessions     │  │   sessions│
   └─────────────┘  └────────────┘  └────────────────┘  └───────────┘
         │                 │                 │                │
         └─────────────────┼─────────────────┴────────────────┘
                           │
         ┌─────────────────▼─────────────────────────────────┐
         │         SQLite Database (per server)               │
         │         Authoritative business state               │
         └───────────────────────────────────────────────────┘
```

### Transport Rules

- **HTTP** — Initial reads, mutations, and fire-and-forget actions. Bootstrap path for all surfaces.
- **WebSocket** — Realtime updates, replay from known revision, subscriptions, turn interaction, server-pushed events.

### Server-Authoritative State

The Rust server owns durable session and approval truth. The Swift client renders server state, not reconstructs business logic by scanning history or guessing queue state.

### SQLite Ownership

Only the Rust server reads from and writes to SQLite directly. The app and CLI go through server APIs.

---

## Products

### OrbitDock Server

The Rust backend behind OrbitDock. It handles realtime session management over WebSocket, serves REST APIs for reads, mutations, and async actions, runs Codex sessions directly via codex-core, and keeps business logic in a pure state machine.

**Features**:

- Standalone binary you can drop on any macOS or Linux box
- HTTP API and WebSocket for client connections
- SQLite with WAL mode, migrations baked in at compile time
- Codex sessions via embedded codex-core
- Claude Code via lifecycle hooks
- Structured JSON logging to file
- TLS support via rustls
- Cloudflare Tunnel integration for zero-config HTTPS
- Prometheus metrics endpoint

**Installation**:

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

### OrbitDock macOS/iOS/iPad App

Native apps built with Swift/SwiftUI. Not an Electron wrapper.

**Features**:

- Full keyboard navigation and Emacs bindings on macOS
- Touch-optimized on iOS
- Real-time WebSocket updates
- Push notifications
- Review diffs and approve tool calls from the couch
- Connect to any server (local, remote, cloud)

### OrbitDock Web App

Future web frontend for the same agent orchestration features. Currently in development.

### OrbitDock CLI

Command-line interface for server management:

- `orbitdock status`, `orbitdock doctor`, `orbitdock start`, `orbitdock stop`
- `orbitdock mission enable/list/status/pause/resume/disable/dispatch`
- `orbitdock tunnel`, `orbitdock remote-setup`
- `orbitdock auth`, `orbitdock pair`
- `orbitdock usage`, `orbitdock hook-forward`

---

## How It Works

### Boot Sequence

1. **Install the server** — Run the installer script or `make rust-build`
2. **Start or verify the server** — `orbitdock status`, `orbitdock doctor`
3. **Open the app** — Download from Releases or build from source
4. **Authenticate your providers** — Sign in with ChatGPT for Codex, set API key for Claude Code
5. **Create a session** — Click **New** in the top bar, pick provider and project

### Passive vs Direct Control

OrbitDock supports two integration modes:

- **Passive** — The underlying provider session is live, but OrbitDock monitors via hooks. You can take over and convert to direct control.
- **Direct** — OrbitDock owns the live control path. You create, steer, approve, interrupt sessions directly from the app.

### Mission Control Flow

1. Mission polls issue tracker (Linear, GitHub)
2. Eligible issues go through eligibility engine (priority + date sorting)
3. Per-issue git worktrees are created
4. Provider selection based on strategy (single, priority, round_robin)
5. Agents dispatched with configured model/effort/permissions
6. Sessions run, OrbitDock monitors via hooks or direct control
7. Results reported back, issues updated in tracker

---

## Key Principles

### Server-Authoritative State

The Rust server owns durable session and approval truth. The Swift client renders server state, not reconstructs business logic by scanning history or guessing queue state. If the client needs new durable truth, change the server contract.

### HTTP And WebSocket Split

- **Default to REST** for client-initiated reads and mutations
- **Use WebSocket** for subscriptions, streaming turn interaction, server-pushed real-time events
- **WS events are triggers, not state** — A WS event tells the client **something changed**. The client should re-fetch the HTTP snapshot to get authoritative state

### SQLite Ownership

Only the Rust server reads from and writes to SQLite directly. The app and CLI should go through server APIs.

### Single Source of Truth

Every UI surface follows one pattern:

1. HTTP snapshot on view appear — the view model fetches its data and owns it
2. WS subscription while the view is on screen — events trigger a re-fetch, not a state mutation
3. View model is the single source of truth for that surface

---

## Keyboard Navigation

### macOS App

| Shortcut | Action |
|----------|--------|
| ⌘K | Quick Switcher |
| ⌘T | Focus Terminal |
| ⌘0 | Go to Dashboard |
| ⌘D | Toggle split (conversation + review) |
| ⌘⇧D | Review only layout |
| ⌘⇧T | Toggle Shell Mode |
| ⌘⌥1-3 | Rail presets: Plan/Review/Triage focused |
| ⌘⌥R | Toggle turn sidebar |
| ⌘R | Rename session |
| ⌘, | Settings |
| ↑/↓ | Navigate sessions |
| C-n/C-p | Next/Previous (Emacs) |
| Enter | Select |
| Escape | Close/Back |

### Approval Card

| Key | Action |
|-----|--------|
| y | Approve once |
| Y | Allow for session |
| ! | Always allow |
| n | Deny |
| N | Deny & stop |
| d | Deny with reason |

### Review Canvas

| Key | Action |
|-----|--------|
| C-n/C-p | Navigate lines |
| n/p or C-f/C-b | Jump sections |
| TAB | Collapse/expand |
| RET | Open in editor |
| q | Close review |
| f | Follow mode |
| C-space | Set mark |
| c | Open composer |
| r | Resolve/reopen comment |
| S | Send comments to model |

---

## Design

### Cosmic Harbor Theme

Deep space aesthetic optimized for OLED displays:

- 5 status colors — Distinct colors per state for instant recognition
- Model badges — Opus (purple), Sonnet (blue), Haiku (teal)
- Spring animations — Smooth transitions throughout the UI
- Custom design tokens — Full color system in Theme.swift

---

## Security & Privacy

- **Self-hosted** — Your agents, your infrastructure, your data
- **Encryption** — Auth tokens encrypted at rest
- **Authentication** — Bearer token auth on HTTP routes, token on WebSocket
- **TLS** — Native TLS support, Cloudflare Tunnel for zero-config HTTPS
- **Local-first** — SQLite database on the server, no cloud sync

---

## Deployment

### Local Development

```bash
# Install the server
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
orbitdock setup --local

# Open the app
# Download from Releases or build from source
```

### Remote Server

```bash
# On the server
orbitdock setup server
orbitdock tunnel          # Cloudflare Tunnel
# or
orbitdock start --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem

# On your client
orbitdock install-hooks --server-url https://your-server.example.com
# or in the app
Settings → Servers → Add endpoint
```

### Cloud Deployment

Recommended setups:

- **Cloudflare Tunnel** — Zero-config HTTPS exposure
- **Reverse proxy** — Nginx, Caddy, etc. with TLS termination
- **Raspberry Pi** — Self-host on a Pi in the closet
- **VPS** — Run on a cloud instance, connect via Cloudflare Tunnel or direct bind

See [docs/OPERATIONS.md](docs/OPERATIONS.md#deployment) for the full guide.

---

## Quick Summary

OrbitDock is:

- **Mission control for AI coding agents** — Orchestrate, review, and steer your fleet of AI agents from anywhere
- **Multi-server** — Connect your laptop, VPS, and Raspberry Pi at once
- **Multi-provider** — Claude Code and Codex CLI from one place
- **Direct control** — Send messages, steer mid-turn, approve tools, interrupt sessions
- **Code review** — Magit-style diffs with inline comments that steer the agent
- **Approval triage** — Diff previews, risk classification, keyboard shortcuts
- **Usage tracking** — Rate limit monitoring for Claude and Codex
- **Live monitoring** — Every session across every project, updating in real time
- **Native apps** — Swift on macOS, SwiftUI on iOS — not an Electron wrapper
- **Open source** — MIT license, free to use, self-hosted

---

## Related Documentation

- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) — Project shape, commands, testing, and day-to-day workflow
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Client and server architecture guardrails
- [FEATURES.md](docs/FEATURES.md) — Full feature list with keyboard shortcuts
- [docs/web-testing-strategy.md](docs/web-testing-strategy.md) — Testing principles and hard lines
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — Deployment, persistence, debugging, and troubleshooting
- [docs/data-flow.md](docs/data-flow.md) — REST/WS data contract and surface model
- [orbitdock-server/README.md](orbitdock-server/README.md) — Server CLI reference
- [orbitdock-server/docs/API.md](orbitdock-server/docs/API.md) — HTTP and WebSocket contract

---

## License

[MIT](LICENSE)
