/// Generate a default MISSION.md template for a mission.
///
/// The template uses Liquid syntax (`{{ }}` / `{% %}`) for variable interpolation
/// at dispatch time. The YAML front matter configures the orchestrator with
/// `MissionConfig` keys at the top level.
pub fn default_mission_template(provider: &str) -> String {
    let body = r#"---
tracker: linear

provider:
  strategy: single
  primary: PROVIDER_PLACEHOLDER
  max_concurrent: 3

# agent:
#   claude:
#     # model: claude-sonnet-4-6
#     # effort: high
#     permission_mode: auto            # mission-safe default (agents run headless)
#   codex:
#     # model: gpt-5.3-codex
#     # effort: medium
#     approval_policy: on-request      # mission-safe default
#     sandbox_mode: workspace-write    # mission-safe default

trigger:
  kind: polling
  interval: 60
  # filters:
  #   labels: []
  #   states: [Todo, "In Progress"]
  #   project: YOUR_PROJECT
  #   team: YOUR_TEAM

orchestration:
  max_retries: 3
  stall_timeout: 600
  base_branch: main
  # state_on_dispatch: "In Progress"   # tracker state when issue is dispatched
  # state_on_complete: "In Review"     # tracker state when session completes (PR awaits human review)
---

You are working on Linear issue `{{ issue.identifier }}`: {{ issue.title }}

{% if attempt > 1 %}
This is retry attempt #{{ attempt }}. Resume from the current workspace state.
{% endif %}

## Issue Context

- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Status: {{ issue.state }}
- URL: {{ issue.url }}

{% if issue.description %}
## Description

{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Git Workflow

You are working in a git worktree. Your branch is `mission/{{ issue.identifier | downcase }}`.
Create a PR targeting `main` when complete.

## Getting Started

If the repository contains AGENTS.md or CLAUDE.md, read those files first for project-specific guidelines.
You have full CLI access — use `git`, build tools, test runners, and any project-specific tooling.

## Instructions

1. Work autonomously end-to-end. Do not ask for human follow-up.
2. Stop early only for true blockers (missing auth, permissions, secrets).
3. Create a PR when complete and comment on the Linear issue with the PR link.
4. Keep commits clean and focused.
"#;
    body.replace("PROVIDER_PLACEHOLDER", provider)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_includes_provider() {
        let tmpl = default_mission_template("codex");
        assert!(tmpl.contains("primary: codex"));
        assert!(!tmpl.contains("PROVIDER_PLACEHOLDER"));
    }

    #[test]
    fn template_has_front_matter() {
        let tmpl = default_mission_template("claude");
        assert!(tmpl.starts_with("---\n"));
        assert!(tmpl.matches("---").count() >= 2);
    }

    #[test]
    fn template_has_top_level_schema() {
        let tmpl = default_mission_template("claude");
        assert!(!tmpl.contains("orbitdock:"));
        assert!(tmpl.contains("provider:"));
        assert!(tmpl.contains("strategy: single"));
        assert!(tmpl.contains("trigger:"));
        assert!(tmpl.contains("orchestration:"));
    }

    #[test]
    fn template_has_liquid_variables() {
        let tmpl = default_mission_template("claude");
        assert!(tmpl.contains("{{ issue.identifier }}"));
        assert!(tmpl.contains("{{ issue.title }}"));
        assert!(tmpl.contains("{% if attempt > 1 %}"));
    }

    #[test]
    fn template_parses_as_valid_mission_file() {
        let tmpl = default_mission_template("claude");
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
    }
}
