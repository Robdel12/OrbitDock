# OrbitDock Features

Everything OrbitDock can do, organized by area.

## Session Monitoring

- **Multi-provider support** — Claude Code and Codex CLI tracked from one dashboard
- **Live session updates** — Conversations stream in real-time via WebSocket
- **5 status states** — Working (cyan), Permission (coral), Question (purple), Reply (blue), Ended (gray)
- **Activity banners** — See what tool the agent is currently using
- **Token and cost tracking** — Per-session and per-turn usage stats
- **Subagent tracking** — See when Claude spawns Explore, Plan, or other agents
- **Context compaction events** — Know when a session compacts its context window

## Dashboard

- **Active sessions view** — All running sessions at a glance with status colors
- **Session history** — Browse ended sessions grouped by project
- **Command bar** — Today's stats, usage gauges, model distribution
- **Keyboard navigation** — Arrow keys + Emacs bindings (C-n, C-p, C-a, C-e)
- **Work stream entries** — Live indicators for in-progress sessions

## Conversation View

- **Full transcript display** — Messages, tool calls, and results
- **Rich tool cards** — Read, Edit, Write, Bash, Glob, Grep, Task, MCP, WebFetch, WebSearch, Shell, Skills, PlanMode, TodoTask, AskUserQuestion, and more
- **Pending approvals** — See exactly what the agent wants to run
- **Code diffs** — Before/after visualization for edits
- **Syntax highlighting** — Code blocks with copy buttons
- **Auto-scroll** — Follows new messages, pauses when you scroll up
- **Turn grouping** — Messages grouped by turn with token counts

## Review Canvas

A magit-style code review interface for reviewing agent changes:

- **File list navigator** — Browse changed files with add/update/delete indicators
- **Diff hunk view** — Unified diffs with syntax highlighting
- **Inline comment threads** — Comment directly on specific lines
- **Comment-to-steer** — Comments are sent to the agent as guidance
- **Resolved comment markers** — Track which feedback has been addressed
- **Context collapse bars** — Collapse unchanged context to focus on changes
- **Review checklist** — Track review progress across files

## Approval Oversight

- **Diff preview** — See file changes before approving tool execution
- **Risk cues** — Visual indicators for destructive or sensitive operations
- **Keyboard triage** — `y` approve, `Y` approve for session, `!` approve always, `n` deny, `N` deny and explain
- **Approval history** — Sidebar rail showing past approvals in the session
- **Autonomy picker** — Set approval policy per session (suggest, auto-edit, full-auto)

## Direct Codex Control

Full control over Codex sessions without leaving the app:

- **Create sessions** — Start new Codex sessions with project path and model selection
- **Send messages** — Chat directly with the Codex agent
- **Shell execution** — Run shell commands in the session's working directory
- **Approve/deny tools** — Handle tool execution requests inline
- **Interrupt turns** — Stop the agent mid-turn
- **Model and effort picker** — Switch models and reasoning effort on the fly
- **Skills picker** — Browse and attach skills to messages
- **MCP servers tab** — View connected MCP servers and their tools
- **File mentions** — Attach files to messages with autocomplete

## Quick Switcher (⌘K)

- **Unified search** — Sessions, commands, and dashboard access
- **Full keyboard navigation** — Arrow keys, Enter to select, Escape to close
- **Inline actions** — Focus terminal, rename, copy resume command
- **Recent sessions** — Quick access to recently ended work

## Usage Monitoring

- **Claude rate limits** — 5-hour and 7-day window tracking via OAuth API
- **Codex rate limits** — Primary and secondary rate windows
- **Menu bar gauges** — Quick usage check without opening the app
- **Auto-refresh** — Updates every 60 seconds

## Terminal Integration

- **Focus terminal (⌘T)** — Jump to the iTerm2 tab running a session
- **Resume sessions** — Copy resume command for ended sessions

## Notifications

- **Toast notifications** — In-app alerts when sessions need attention
- **System notifications** — macOS notifications for permission/question states

## MCP Bridge

Control Codex sessions from Claude Code (or any MCP client):

- **List sessions** — See active Codex sessions
- **Send messages** — Send prompts to a running session
- **Approve/deny** — Handle pending tool approvals
- **Interrupt** — Stop a running turn
- **Health check** — Verify bridge connectivity

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘K | Quick Switcher |
| ⌘T | Focus Terminal |
| ⌘0 | Go to Dashboard |
| ⌘1 | Toggle Left Panel |
| ⌘, | Settings |
| ↑/↓ | Navigate sessions |
| C-n/C-p | Next/Previous (Emacs) |
| Enter | Select |
| Escape | Close/Back |

## Design

- **Cosmic Harbor theme** — Deep space aesthetic optimized for OLED displays
- **5 status colors** — Distinct colors per state for instant recognition
- **Model badges** — Opus (purple), Sonnet (blue), Haiku (teal)
- **Spring animations** — Smooth transitions throughout the UI
- **Custom design tokens** — Full color system in Theme.swift
