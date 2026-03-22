---
tracker: github

provider:
  strategy: single
  primary: claude
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
  #   states: [Ready, Backlog]
  #   project: YOUR_PROJECT
  #   team: YOUR_TEAM

orchestration:
  max_retries: 3
  stall_timeout: 600
  base_branch: main
  # state_on_dispatch: "In progress"   # tracker state when issue is dispatched
  # state_on_complete: "In review"     # tracker state when session completes (PR awaits human review)
---

You are working on GitHub issue `{{ issue.identifier }}`: {{ issue.title }}

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
3. Create a PR when complete and comment on the issue with the PR link.
4. Keep commits clean and focused.
