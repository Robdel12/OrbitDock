/// Server-provided instructions injected into every agent session.
///
/// Returned by `get_session_instructions` as `system_prompt` for client-initiated
/// sessions, and merged into `developer_instructions` for headless mission sessions.
pub fn orbitdock_system_instructions() -> String {
    r#"## OrbitDock CLI

You have the `orbitdock` CLI available for inspecting and controlling OrbitDock
from within this session. Pass `--json` to any command for machine-readable output.

### Sessions

| Command | Description |
|---------|-------------|
| `orbitdock session list` | List all active and recent sessions |
| `orbitdock session get <id>` | Show session details (add `-m` for messages) |
| `orbitdock session create -p claude --cwd /path` | Create a new session |
| `orbitdock session send <id> "message"` | Send a message to another session |

### Mission Control

| Command | Description |
|---------|-------------|
| `orbitdock mission list` | List configured missions |
| `orbitdock mission status <id>` | Show mission status, issue pipeline, and session mapping |
| `orbitdock mission dispatch <mission_id> <issue>` | Dispatch a specific issue — spawns a new session in a worktree |
| `orbitdock mission pause <id>` | Pause a mission (stops new dispatches) |
| `orbitdock mission resume <id>` | Resume a paused mission |

### Worktrees & Git

| Command | Description |
|---------|-------------|
| `orbitdock worktree list` | List managed git worktrees |

### Models & Usage

| Command | Description |
|---------|-------------|
| `orbitdock model list` | List available models |
| `orbitdock usage summary` | Show token usage and rate limit status |

### Introspection

| Command | Description |
|---------|-------------|
| `orbitdock health` | Check server health |
| `orbitdock server info` | Show server configuration |

Use `orbitdock --help` or `orbitdock <command> --help` for full details."#
        .to_string()
}

/// Mission-specific instructions appended to `orbitdock_system_instructions()`
/// for headless mission sessions. Covers mission tools, workpad pattern, and
/// autonomous workflow guidance.
pub fn mission_agent_instructions() -> String {
    r#"## Mission Tools

You have OrbitDock mission tools for interacting with the issue tracker.
Use these instead of raw API calls — they are pre-configured with your
issue context.

| Tool | Description |
|------|-------------|
| `mission_get_issue` | Fetch the current issue details, status, labels, and description |
| `mission_post_update` | Post a comment on the issue (progress notes, handoff summaries) |
| `mission_update_comment` | Edit an existing comment by ID (update workpad in-place) |
| `mission_get_comments` | List comments on the issue |
| `mission_set_status` | Move the issue to a workflow state (e.g. "In Progress", "In Review") |
| `mission_link_pr` | Attach a PR URL to the issue |
| `mission_create_followup` | File a new backlog issue for out-of-scope work |
| `mission_report_blocked` | Signal that you are blocked and cannot continue |

### Workpad Pattern

Maintain a single persistent comment on the issue as your workpad:
1. Use `mission_get_comments` to check for an existing `## Workpad` comment
2. If found, use `mission_update_comment` to update it in-place
3. If not found, use `mission_post_update` to create one
4. Keep the workpad current with your plan, progress, and validation results

### Autonomous Workflow

- You are running unattended in an isolated git worktree
- Work end-to-end without asking for human follow-up
- Use `mission_report_blocked` only for true blockers (missing auth, secrets, permissions)
- Create a PR when complete, then use `mission_link_pr` to attach it to the issue
- Use `mission_set_status` to move the issue to "In Review" when done
- If you discover out-of-scope work, use `mission_create_followup` instead of expanding scope"#
        .to_string()
}
