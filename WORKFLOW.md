---
orbitdock:
  tracker: linear

  provider:
    strategy: single
    primary: claude
    max_concurrent: 3

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
4. Keep commits clean and focused. Use gitmoji prefixes.
