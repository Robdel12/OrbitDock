# OrbitDock Features

A quick rundown of everything OrbitDock can do.

## Session Monitoring

- **Multi-provider support** - Claude Code and Codex CLI, tracked from one dashboard
- **Live session updates** - Watch conversations unfold in real-time
- **5 distinct status states** - Working, Permission, Question, Reply, Ended
- **Activity banners** - See what tool the agent is currently using
- **Token & cost tracking** - Per-session and aggregate stats

## Dashboard

- **Active sessions view** - All running sessions at a glance
- **Session history** - Browse ended sessions by project
- **Command bar** - Today's stats, usage gauges, model distribution
- **Quests tab** - Flexible work containers with linked sessions
- **Keyboard navigation** - Arrow keys + Emacs bindings (C-n, C-p)

## Conversation View

- **Full transcript display** - Messages, tool calls, and results
- **Rich tool cards** - Read, Edit, Write, Bash, Glob, Grep, Task, MCP, and more
- **Pending approvals** - See exactly what the agent wants to run
- **Code diffs** - Before/after visualization for edits
- **Syntax highlighting** - Code blocks with copy buttons
- **Auto-scroll** - Follows new messages, pause when you scroll up

## Quick Switcher (⌘K)

- **Unified search** - Sessions, commands, and dashboard access
- **Full keyboard navigation** - Arrow keys, Enter to select, Escape to close
- **Inline actions** - Focus terminal, rename, copy resume command
- **Recent sessions** - Quick access to recently ended work

## Quest System

- **Flexible work containers** - Group sessions, PRs, and issues however you want
- **Global inbox** - Quick capture ideas and notes, attach later
- **High-confidence links** - Only captures created PRs/issues (no false positives)
- **QuickSwitcher commands** - Create quests, capture to inbox, link sessions
- **Status tracking** - Active, Paused, Completed states

## Usage Monitoring

- **Claude rate limits** - 5-hour and 7-day window tracking
- **Codex rate limits** - Primary and secondary windows
- **Menu bar gauges** - Quick usage check without opening the app
- **Auto-refresh** - Updates every 60 seconds

## Terminal Integration

- **Focus terminal** - ⌘T jumps to the iTerm2 tab
- **Resume sessions** - Copy resume command for ended sessions
- **Terminal session tracking** - Links sessions to their terminal tabs

## Notifications

- **Toast notifications** - In-app alerts when sessions need attention
- **System notifications** - macOS notifications for permission/question states
- **Configurable sounds** - Choose your notification style

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

- **Cosmic Harbor theme** - Deep space aesthetic optimized for OLED
- **5 status colors** - Cyan, coral, purple, blue, gray
- **Model badges** - Opus (purple), Sonnet (blue), Haiku (teal)
- **Smooth animations** - Spring-based transitions throughout
