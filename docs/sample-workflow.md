# Sample WORKFLOW.md

This is an example `WORKFLOW.md` file for Mission Control. Place it in the root of your repository.

The YAML front matter configures the orchestrator using a nested `orbitdock:` schema. The body is a Liquid template that gets rendered per-issue at dispatch time.

## Basic (single provider)

```yaml
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
    filters:
      labels: [bug, agent-ready]
      states: [Todo]
      project: PROJ
      team: Engineering

  orchestration:
    max_retries: 3
    stall_timeout: 600
    base_branch: main
---

You are working on Linear issue `{{ issue.identifier }}`: {{ issue.title }}

...prompt body...
```

## Priority mode (Claude primary, Codex overflow)

```yaml
---
orbitdock:
  tracker: linear

  provider:
    strategy: priority
    primary: claude
    secondary: codex
    max_concurrent: 5
    max_concurrent_primary: 3

  trigger:
    kind: polling
    interval: 30
    filters:
      labels: [agent-ready]
      states: [Todo, "In Progress"]

  orchestration:
    max_retries: 3
    stall_timeout: 600
    base_branch: main
---
```

With `strategy: priority`, the orchestrator dispatches to Claude first (up to `max_concurrent_primary: 3`). Once 3 Claude sessions are running, additional issues go to Codex until the total `max_concurrent: 5` is reached.

## Round-robin mode

```yaml
---
orbitdock:
  provider:
    strategy: round_robin
    primary: claude
    secondary: codex
    max_concurrent: 4
---
```

Alternates between Claude and Codex for each dispatched issue.

## Manual-only trigger

```yaml
---
orbitdock:
  trigger:
    kind: manual_only
---
```

Disables automatic polling. Issues are only dispatched when manually triggered.

## Schema Reference

| Section | Field | Default | Description |
|---------|-------|---------|-------------|
| `provider` | `strategy` | `single` | `single`, `priority`, or `round_robin` |
| `provider` | `primary` | `claude` | Primary provider (`claude` or `codex`) |
| `provider` | `secondary` | — | Secondary provider (used in priority/round_robin) |
| `provider` | `max_concurrent` | `3` | Max concurrent running sessions |
| `provider` | `max_concurrent_primary` | — | Max sessions on primary before overflow (priority only) |
| `trigger` | `kind` | `polling` | `polling` or `manual_only` |
| `trigger` | `interval` | `60` | Polling interval in seconds |
| `trigger.filters` | `labels` | `[]` | Only issues with these labels |
| `trigger.filters` | `states` | `[]` | Only issues in these states |
| `trigger.filters` | `project` | — | Linear/GitHub project key |
| `trigger.filters` | `team` | — | Linear team key |
| `orchestration` | `max_retries` | `3` | Max retry attempts per issue |
| `orchestration` | `stall_timeout` | `600` | Kill + retry after this many seconds of inactivity |
| `orchestration` | `base_branch` | `main` | Base branch for worktrees |

## Template Variables

| Variable | Description |
|----------|-------------|
| `{{ issue.identifier }}` | Issue key (e.g. PROJ-123) |
| `{{ issue.title }}` | Issue title |
| `{{ issue.description }}` | Issue description (may be empty) |
| `{{ issue.state }}` | Current tracker state |
| `{{ issue.url }}` | Link to issue in tracker |
| `{{ attempt }}` | Retry attempt number (1 on first try) |
