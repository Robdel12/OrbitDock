/// Generate a default MISSION.md template for a mission.
///
/// The template uses Liquid syntax (`{{ }}` / `{% %}`) for variable interpolation
/// at dispatch time. The YAML front matter configures the orchestrator with
/// `MissionConfig` keys at the top level.
pub fn default_mission_template(provider: &str, tracker: &str) -> String {
    let (states_hint, dispatch_state, complete_state, issue_label) = match tracker {
        "github" => (
            r#"[Ready, Backlog]"#,
            "In progress",
            "In review",
            "GitHub issue",
        ),
        _ => (
            r#"[Todo, "In Progress"]"#,
            "In Progress",
            "In Review",
            "Linear issue",
        ),
    };

    format!(
        r#"---
tracker: {tracker}

provider:
  strategy: single
  primary: {provider}
  max_concurrent: 3

# agent:
#   claude:
#     # model: claude-sonnet-4-6
#     # effort: high
#     permission_mode: acceptEdits      # mission-safe default (agents run headless)
#   codex:
#     # model: gpt-5.3-codex
#     # effort: medium
#     approval_policy: never           # fullAuto — sandbox provides safety
#     sandbox_mode: workspace-write    # mission-safe default

trigger:
  kind: polling
  interval: 60
  # filters:
  #   labels: []
  #   states: {states_hint}
  #   project: YOUR_PROJECT
  #   team: YOUR_TEAM

orchestration:
  max_retries: 3
  stall_timeout: 600
  base_branch: main
  state_on_dispatch: "{dispatch_state}"
  state_on_complete: "{complete_state}"
---

You are working on {issue_label} `{{{{ issue.identifier }}}}`: {{{{ issue.title }}}}

{{% if attempt > 1 %}}
**Retry attempt #{{{{ attempt }}}}** — check the existing branch state and any previous workpad comments before resuming.
{{% endif %}}

## Issue

| Field | Value |
|-------|-------|
| Identifier | `{{{{ issue.identifier }}}}` |
| Title | {{{{ issue.title }}}} |
| Status | {{{{ issue.state }}}} |
| URL | {{{{ issue.url }}}} |

{{% if issue.description %}}
### Description

{{{{ issue.description }}}}
{{% endif %}}

## Workflow

You are working in a git worktree on branch `mission/{{{{ issue.identifier | downcase }}}}`.

1. **Read project guidelines** — check for AGENTS.md, CLAUDE.md, or similar files first.
2. **Sync with latest `main`** — before writing code, fetch the latest changes and rebase your worktree branch onto `origin/main` (or the configured base branch). Prefer `git pull --rebase` / `git fetch` + `git rebase`. Do not create merge commits.
3. **Post your workpad** — use your mission tools to post a plan on the issue before writing code.
4. **Understand the codebase** — explore the relevant code before making changes.
5. **Implement** — make focused, minimal changes. Run tests and linters.
6. **Commit** — keep commits clean and atomic. Update your workpad as you go.
7. **Create a PR** targeting `main` when complete. Attach it to the issue.

## Rules

- Work autonomously end-to-end. Do not ask for human follow-up.
- Stop early only for true blockers (missing auth, permissions, secrets).
- Do not expand scope. File follow-up issues for anything tangential.
- Keep the workpad updated — it is the primary way humans track your progress.
- Prefer rebases over merges when syncing with the base branch.
- **NEVER create merge commits.** Keep mission branches linear.
- **NEVER merge PRs.** Create the PR, verify CI passes, and address any review feedback — but leave merging to a human.
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_includes_provider() {
        let tmpl = default_mission_template("codex", "linear");
        assert!(tmpl.contains("primary: codex"));
        assert!(!tmpl.contains("PROVIDER_PLACEHOLDER"));
    }

    #[test]
    fn template_has_front_matter() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.starts_with("---\n"));
        assert!(tmpl.matches("---").count() >= 2);
    }

    #[test]
    fn template_has_top_level_schema() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(!tmpl.contains("orbitdock:"));
        assert!(tmpl.contains("provider:"));
        assert!(tmpl.contains("strategy: single"));
        assert!(tmpl.contains("trigger:"));
        assert!(tmpl.contains("orchestration:"));
    }

    #[test]
    fn template_has_liquid_variables() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("{{ issue.identifier }}"));
        assert!(tmpl.contains("{{ issue.title }}"));
        assert!(tmpl.contains("{% if attempt > 1 %}"));
    }

    #[test]
    fn template_has_workflow_structure() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("## Workflow"));
        assert!(tmpl.contains("## Rules"));
        assert!(tmpl.contains("workpad"));
    }

    #[test]
    fn template_parses_as_valid_mission_file() {
        let tmpl = default_mission_template("claude", "linear");
        let def = crate::domain::mission_control::config::parse_mission_file(&tmpl).unwrap();
        assert_eq!(def.config.tracker, "linear");
        assert_eq!(def.config.provider.strategy, "single");
        assert_eq!(def.config.provider.primary, "claude");
        assert_eq!(def.config.provider.max_concurrent, 3);
        assert_eq!(def.config.trigger.kind, "polling");
        assert_eq!(def.config.trigger.interval, 60);
        assert_eq!(def.config.orchestration.max_retries, 3);
        assert_eq!(def.config.orchestration.stall_timeout, 600);
        assert_eq!(def.config.orchestration.base_branch, "main");
        assert_eq!(def.config.orchestration.state_on_dispatch, "In Progress");
        assert_eq!(def.config.orchestration.state_on_complete, "In Review");
    }
}
