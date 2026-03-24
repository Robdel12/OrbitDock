# Sample MISSION.md

This is an example `MISSION.md` file for Mission Control. Place it in the root of your repository.

The YAML front matter configures the orchestrator using top-level keys. The body is a Liquid template that gets rendered per-issue at dispatch time.

## Basic (single provider)

```yaml
---
tracker: linear

provider:
  strategy: single
  primary: claude
  max_concurrent: 3

agent:
  claude:
    model: claude-sonnet-4-6
    effort: high
    permission_mode: auto-edit

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

## With skills

```yaml
---
agent:
  claude:
    model: claude-sonnet-4-6
    skills:
      - testing-philosophy
  codex:
    model: gpt-5.3-codex
    skills:
      - testing-philosophy
      - react-best-practices
---
```

Skills listed under `agent.<provider>.skills` are loaded at mission dispatch time. Missing skills are logged and skipped — the mission still dispatches.

- **Codex**: Skills are attached natively to the initial `SendMessage`. Each name resolves first from `~/.codex/skills/{name}/SKILL.md`, then falls back to repo-local `.codex/skills/{name}/SKILL.md`.
- **Claude**: Skill content is read and prepended to the initial prompt (Claude has no native `skills` parameter). Resolution checks `~/.claude/skills/{name}/SKILL.md` first, then repo-local `.claude/skills/{name}/SKILL.md`.

## Priority mode (Claude primary, Codex overflow)

```yaml
---
tracker: linear

provider:
  strategy: priority
  primary: claude
  secondary: codex
  max_concurrent: 5
  max_concurrent_primary: 3

agent:
  claude:
    model: claude-sonnet-4-6
    effort: high
    permission_mode: auto-edit
  codex:
    model: gpt-5.3-codex
    effort: medium
    approval_policy: on-request
    sandbox_mode: workspace-write

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
provider:
  strategy: round_robin
  primary: claude
  secondary: codex
  max_concurrent: 4

agent:
  claude:
    model: claude-sonnet-4-6
  codex:
    model: gpt-5.3-codex
---
```

Alternates between Claude and Codex for each dispatched issue.

## Manual-only trigger

```yaml
---
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
| `agent.claude` | `model` | — | Claude model ID |
| `agent.claude` | `effort` | — | Reasoning effort (low/medium/high) |
| `agent.claude` | `permission_mode` | — | Permission mode (plan/default/auto-edit/auto/bypass) |
| `agent.claude` | `allowed_tools` | `[]` | Only allow these tools |
| `agent.claude` | `disallowed_tools` | `[]` | Block these tools |
| `agent.claude` | `skills` | `[]` | Skills to inject into initial prompt (e.g. `[testing-philosophy]`) |
| `agent.codex` | `model` | — | Codex model ID |
| `agent.codex` | `effort` | — | Reasoning effort |
| `agent.codex` | `approval_policy` | — | Approval policy (untrusted/on-failure/on-request/never) |
| `agent.codex` | `sandbox_mode` | — | Sandbox mode (workspace-write/danger-full-access) |
| `agent.codex` | `multi_agent` | — | Enable multi-agent mode |
| `agent.codex` | `collaboration_mode` | — | Collaboration mode (default/plan) |
| `agent.codex` | `personality` | — | Personality preset |
| `agent.codex` | `service_tier` | — | Service tier (fast/flex) |
| `agent.codex` | `developer_instructions` | — | Custom developer instructions |
| `agent.codex` | `skills` | `[]` | Skills to attach to initial prompt (e.g. `[testing-philosophy]`) |
| `trigger` | `kind` | `polling` | `polling` or `manual_only` |
| `trigger` | `interval` | `60` | Polling interval in seconds |
| `trigger.filters` | `labels` | `[]` | Only issues with these labels |
| `trigger.filters` | `states` | `[]` | Only issues in these states |
| `trigger.filters` | `project` | — | Linear/GitHub project key |
| `trigger.filters` | `team` | — | Linear team key |
| `orchestration` | `max_retries` | `3` | Max retry attempts per issue |
| `orchestration` | `stall_timeout` | `600` | Kill + retry after this many seconds of inactivity |
| `orchestration` | `base_branch` | `main` | Base branch for worktrees |
| `orchestration` | `worktree_root_dir` | — | Optional override for worktree location |
| `orchestration` | `state_on_dispatch` | `In Progress` | Tracker state when issue is dispatched |
| `orchestration` | `state_on_complete` | `In Review` | Tracker state when session completes |

## Template Variables

| Variable | Description |
|----------|-------------|
| `{{ issue.identifier }}` | Issue key (e.g. PROJ-123) |
| `{{ issue.title }}` | Issue title |
| `{{ issue.description }}` | Issue description (may be empty) |
| `{{ issue.state }}` | Current tracker state |
| `{{ issue.url }}` | Link to issue in tracker |
| `{{ attempt }}` | Retry attempt number (1 on first try) |
