/// Server-provided instructions injected into every agent session.
///
/// Returned by `get_session_instructions` as `system_prompt` for client-initiated
/// sessions, and merged into `developer_instructions` for headless mission sessions.
pub fn orbitdock_system_instructions() -> String {
    r#"## OrbitDock CLI

You have access to the `orbitdock` CLI for interacting with OrbitDock services.

### Key Commands

| Command | Description |
|---------|-------------|
| `orbitdock mission list` | List configured missions |
| `orbitdock mission status <id>` | Show mission status and issues |
| `orbitdock mission dispatch <mission_id> <issue>` | Dispatch a specific issue to a mission |
| `orbitdock session list` | List active sessions |
| `orbitdock session status <id>` | Check session status |
| `orbitdock worktree list` | List worktrees |

Use `orbitdock --help` for full command reference. Use `--json` on any command for machine-readable output.

## Mission Tools

You have access to OrbitDock mission tools for interacting with the issue tracker. Use these instead of raw API calls or MCP servers.

| Tool | Description |
|------|-------------|
| `mission_get_issue` | Fetch the current issue's details, status, and description |
| `mission_post_update` | Post a comment on the issue (workpad updates, progress notes) |
| `mission_update_comment` | Edit an existing comment by ID (update workpad in-place) |
| `mission_get_comments` | List comments on the issue (find existing workpad) |
| `mission_set_status` | Move the issue to a workflow state (e.g. "In Progress", "In Review") |
| `mission_link_pr` | Attach a PR URL to the issue |
| `mission_create_followup` | File a new backlog issue for out-of-scope work |
| `mission_report_blocked` | Signal that you are blocked and cannot continue |

### Workpad Pattern

Maintain a single persistent comment on the issue as your workpad:
1. Use `mission_get_comments` to check for an existing `## Workpad` comment
2. If found, use `mission_update_comment` to update it in-place
3. If not found, use `mission_post_update` to create one
4. Keep the workpad current with your plan, progress, and validation results"#
        .to_string()
}
