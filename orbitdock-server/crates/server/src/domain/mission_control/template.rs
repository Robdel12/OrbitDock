/// Generate a default MISSION.md template for a mission.
///
/// The template uses Liquid syntax (`{{ }}` / `{% %}`) for variable interpolation
/// at dispatch time. The YAML front matter configures the orchestrator with
/// `MissionConfig` keys at the top level.
pub fn default_mission_template(provider: &str, tracker: &str) -> String {
    let (states_hint, dispatch_state, complete_state, issue_label, tracker_label) = match tracker {
        "github" => (
            r#"[Ready, Backlog]"#,
            "In progress",
            "In review",
            "GitHub issue",
            "GitHub",
        ),
        _ => (
            r#"[Todo, "In Progress"]"#,
            "In Progress",
            "In Review",
            "Linear issue",
            "Linear",
        ),
    };

    format!(
        r#"---
# ── Tracker ────────────────────────────────────────────────────────────
# Which issue tracker to poll. Values: linear, github
tracker: {tracker}

# ── Provider ───────────────────────────────────────────────────────────
# Controls which AI provider(s) execute missions.
provider:
  # strategy: single | priority | round_robin
  #   single      — all issues go to `primary`
  #   priority    — fill `primary` first, overflow to `secondary`
  #   round_robin — alternate between `primary` and `secondary`
  strategy: single
  # primary: claude | codex
  primary: {provider}
  # secondary: claude | codex          # required for priority / round_robin
  # max_concurrent_primary: 3          # max sessions on primary before overflow (priority only)
  max_concurrent: 3

# ── Agent settings (per-provider) ──────────────────────────────────────
# Uncomment and configure the provider(s) you use. Missions run headless,
# so defaults are tuned for autonomous, unattended operation.
#
# agent:
#   claude:
#     model: claude-sonnet-4-6           # any Claude model ID
#     effort: high                       # low | medium | high
#     permission_mode: acceptEdits       # plan | default | auto-edit | auto | bypass
#     # allowed_tools: ["Bash(git:*)"]   # only allow these tools (default for missions)
#     # disallowed_tools: ["Bash(rm:*)"] # block these tools (default for missions)
#     # skills: [testing-philosophy]     # inject skills from ~/.claude/skills/<name>/SKILL.md
#   codex:
#     model: gpt-5.3-codex               # any Codex model ID
#     effort: medium                     # low | medium | high
#     approval_policy: never             # untrusted | on-failure | on-request | never (fullAuto)
#     sandbox_mode: workspace-write      # workspace-write | danger-full-access
#     # collaboration_mode: default      # default | plan
#     # multi_agent: false               # enable multi-agent mode
#     # personality: null                # personality preset
#     # service_tier: fast               # fast | flex
#     # developer_instructions: ""       # custom developer instructions
#     # skills: [testing-philosophy]     # attach skills from ~/.codex/skills/<name>/SKILL.md

# ── Trigger ────────────────────────────────────────────────────────────
# How and when Mission Control looks for new issues.
trigger:
  # kind: polling | manual_only
  kind: polling
  interval: 60                           # polling interval in seconds
  # filters:                             # narrow which issues get picked up
  #   labels: [agent-ready]              # only issues with these labels
  #   states: {states_hint}
  #   project: YOUR_PROJECT              # {tracker_label} project key
  #   team: YOUR_TEAM                    # {tracker_label} team key

# ── Orchestration ──────────────────────────────────────────────────────
# Runtime behavior for dispatched sessions.
orchestration:
  max_retries: 3                         # max retry attempts per issue
  stall_timeout: 600                     # kill + retry after N seconds of inactivity
  base_branch: main                      # base branch for worktrees
  # worktree_root_dir: .orbitdock-worktrees  # override worktree location
  state_on_dispatch: "{dispatch_state}"  # tracker state set when dispatched
  state_on_complete: "{complete_state}"  # tracker state set when session completes
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
- Use gitmoji in commit messages and PR titles (e.g. ✨, 🐛, ♻️, 🔧).
- Prefer rebases over merges when syncing with the base branch.
- **NEVER create merge commits.** Keep mission branches linear.
- **NEVER merge PRs.** Create the PR, verify CI passes, and address any review feedback — but leave merging to a human.
- Write detailed PR descriptions: summarize what changed and why, call out new tests, non-obvious decisions, and anything a reviewer wouldn't expect.
- Use gitmoji in PR titles (e.g. ✨, 🐛, ♻️, 🔧).
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

    // ── Commented option docs ─────────────────────────────────────────

    #[test]
    fn template_documents_provider_strategy_options() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("single"));
        assert!(tmpl.contains("priority"));
        assert!(tmpl.contains("round_robin"));
        assert!(tmpl.contains("secondary:"));
        assert!(tmpl.contains("max_concurrent_primary:"));
    }

    #[test]
    fn template_documents_agent_claude_options() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("permission_mode:"));
        assert!(tmpl.contains("plan | default | auto-edit | auto | bypass"));
        assert!(tmpl.contains("allowed_tools:"));
        assert!(tmpl.contains("disallowed_tools:"));
        assert!(tmpl.contains("effort:"));
        assert!(tmpl.contains("low | medium | high"));
        assert!(tmpl.contains("skills:"));
    }

    #[test]
    fn template_documents_agent_codex_options() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("approval_policy:"));
        assert!(tmpl.contains("untrusted | on-failure | on-request | never"));
        assert!(tmpl.contains("sandbox_mode:"));
        assert!(tmpl.contains("workspace-write | danger-full-access"));
        assert!(tmpl.contains("collaboration_mode:"));
        assert!(tmpl.contains("multi_agent:"));
        assert!(tmpl.contains("service_tier:"));
        assert!(tmpl.contains("developer_instructions:"));
    }

    #[test]
    fn template_documents_trigger_options() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("polling | manual_only"));
        assert!(tmpl.contains("labels:"));
        assert!(tmpl.contains("states:"));
        assert!(tmpl.contains("project:"));
        assert!(tmpl.contains("team:"));
    }

    #[test]
    fn template_documents_orchestration_options() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("worktree_root_dir:"));
        assert!(tmpl.contains("stall_timeout:"));
        assert!(tmpl.contains("state_on_dispatch:"));
        assert!(tmpl.contains("state_on_complete:"));
    }

    #[test]
    fn template_github_tracker_uses_github_hints() {
        let tmpl = default_mission_template("claude", "github");
        assert!(tmpl.contains("tracker: github"));
        assert!(tmpl.contains("GitHub issue"));
        assert!(tmpl.contains("GitHub project key"));
        assert!(tmpl.contains("GitHub team key"));
        assert!(tmpl.contains("[Ready, Backlog]"));
    }

    #[test]
    fn template_linear_tracker_uses_linear_hints() {
        let tmpl = default_mission_template("claude", "linear");
        assert!(tmpl.contains("tracker: linear"));
        assert!(tmpl.contains("Linear issue"));
        assert!(tmpl.contains("Linear project key"));
        assert!(tmpl.contains("Linear team key"));
    }

    #[test]
    fn template_github_parses_as_valid_mission_file() {
        let tmpl = default_mission_template("codex", "github");
        let def = crate::domain::mission_control::config::parse_mission_file(&tmpl).unwrap();
        assert_eq!(def.config.tracker, "github");
        assert_eq!(def.config.provider.primary, "codex");
        assert_eq!(def.config.orchestration.state_on_dispatch, "In progress");
        assert_eq!(def.config.orchestration.state_on_complete, "In review");
    }
}
