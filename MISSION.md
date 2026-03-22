---
tracker: github
provider:
  strategy: single
  primary: claude
  max_concurrent: 3
trigger:
  kind: polling
  interval: 30
  filters:
    labels:
    - agent-ready
    states:
    - Ready
    project: '3'
    team: Robdel12
orchestration:
  max_retries: 3
  stall_timeout: 600
  base_branch: main
  state_on_dispatch: In progress
  state_on_complete: In review
agent:
  claude:
    model: claude-opus-4-6
    permission_mode: bypassPermissions
    allow_bypass_permissions: true
  codex:
    approval_policy: on-request
    sandbox_mode: workspace-write
---

You are working on GitHub issue `{{ issue.identifier }}`: {{ issue.title }}

{% if attempt > 1 %}
**Retry attempt #{{ attempt }}** — check the existing branch state and any previous workpad comments before resuming.
{% endif %}

## Issue

| Field | Value |
|-------|-------|
| Identifier | `{{ issue.identifier }}` |
| Title | {{ issue.title }} |
| Status | {{ issue.state }} |
| URL | {{ issue.url }} |

{% if issue.description %}
### Description

{{ issue.description }}
{% endif %}

## Workflow

You are working in a git worktree on branch `mission/{{ issue.identifier | downcase }}`.

1. **Read project guidelines** — check for AGENTS.md, CLAUDE.md, or similar files first.
2. **Post your workpad** — use your mission tools to post a plan on the issue before writing code.
3. **Understand the codebase** — explore the relevant code before making changes.
4. **Implement** — make focused, minimal changes. Run tests and linters.
5. **Commit** — keep commits clean and atomic. Update your workpad as you go.
6. **Create a PR** targeting `main` when complete. Attach it to the issue.

## Rules

- Work autonomously end-to-end. Do not ask for human follow-up.
- Stop early only for true blockers (missing auth, permissions, secrets).
- Do not expand scope. File follow-up issues for anything tangential.
- Keep the workpad updated — it is the primary way humans track your progress.
- Use gitmoji in commit messages and PR titles (e.g. ✨, 🐛, ♻️, 🔧).
- **NEVER merge PRs.** Create the PR, verify CI passes, and address any review feedback — but leave merging to a human.