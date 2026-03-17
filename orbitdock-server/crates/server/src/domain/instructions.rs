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

Use `orbitdock --help` for full command reference. Use `--json` on any command for machine-readable output."#
        .to_string()
}
