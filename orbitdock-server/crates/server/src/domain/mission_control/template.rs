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
#[path = "template_tests.rs"]
mod tests;
