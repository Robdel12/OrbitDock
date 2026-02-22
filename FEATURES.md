# OrbitDock Features

Everything OrbitDock can do, organized by area.

## Session Monitoring

- **Multi-provider support** — Claude Code and Codex tracked from one dashboard
- **Dual integration modes** — Passive (hook-based / FSEvents file watching) and Direct (bidirectional control) for both providers
- **Live session updates** — Conversations stream in real-time via WebSocket
- **5 status states** — Working (cyan), Permission (coral), Question (purple), Reply (blue), Ended (gray)
- **Activity banners** — See what tool the agent is currently using
- **Token and cost tracking** — Per-session and per-turn usage stats with context window fill indicator
- **Subagent tracking** — See when Claude spawns Explore, Plan, or other agents
- **Context compaction events** — Know when a session compacts its context window

## Dashboard

- **Project-grouped sessions** — Active agents grouped by project directory
- **Attention banner** — Sessions needing action surfaced at the top
- **Session history** — Browse ended sessions grouped by project
- **Live filters** — Filter by provider (All / Claude / Codex), sort active sessions, workbench filter
- **Command strip** — Today's stats, usage gauges, "New Claude Session" and "New Codex Session" buttons
- **Keyboard navigation** — Arrow keys + Emacs bindings (C-n, C-p, C-a, C-e)
- **Loading skeleton** — Smooth loading state before first data arrives

## Conversation View

- **Full transcript display** — Messages, tool calls, and results
- **Rich tool cards** — Read, Edit, Write, Bash, Glob, Grep, Task, MCP, WebFetch, WebSearch, Shell, Skills, PlanMode, TodoTask, AskUserQuestion, ToolSearch, and more
- **Code diffs** — Before/after visualization for edits
- **Syntax highlighting** — Code blocks with copy buttons
- **Auto-scroll** — Follows new messages, pauses when you scroll up
- **Turn grouping** — Messages grouped by turn with token counts
- **Fork origin banner** — When viewing a forked session, shows which session it was forked from with a clickable link
- **Layout modes** — Conversation only, split (conversation + review), or review only

## Review Canvas

A magit-style code review interface for reviewing agent changes:

- **File list navigator** — Browse changed files with add/update/delete indicators
- **Diff hunk view** — Unified diffs with syntax highlighting
- **Cursor navigation** — C-n/p (line), C-f/C-b or n/p (section jump), TAB (collapse), RET (open in editor), q (close), f (follow mode)
- **Inline comment threads** — Click + button or drag to select a range, then write a comment with optional tag
- **Comment-to-steer** — Select specific comments and send structured feedback to the agent (S key)
- **Resolved comment markers** — Resolved comments collapse into grouped markers, reopen with r key
- **Mark and range selection** — C-space sets mark, mouse drag for multi-line selection
- **Turn diff history** — View "All Changes" vs per-turn diffs
- **Split layout** — `⌘D` toggles conversation + review side by side, `⌘⇧D` for review-only
- **Diff available banner** — Auto-appears when new changes arrive with "Review Diffs" CTA

## Approval Oversight

- **Risk classifier** — Low/Normal/High risk detection with DESTRUCTIVE badge for patterns like `rm -rf`, `git push --force`, `DROP TABLE`, `sudo`
- **Risk severity strip** — Color-coded bar at top of approval card with shadow glow
- **Diff preview** — See file changes before approving patch executions
- **Keyboard triage** — `y` approve, `Y` allow for session, `!` always allow, `n` deny, `N` deny & stop, `d` toggle deny-with-reason panel
- **Deny with reason** — Text field to explain why, with "Interrupt turn" toggle
- **Approval history** — Turn sidebar tab showing session-scoped and global approval history
- **Takeover for passive sessions** — "Take Over & Review" / "Take Over & Answer" CTA promotes passive sessions to direct control

## Direct Claude Control

Full control over Claude Code sessions from the app:

- **Create sessions** — Start new Claude sessions with project directory picker
- **Model picker** — Sonnet 4.5, Opus 4.6, Haiku 4.5, or custom model input
- **Permission modes** — Default, Accept Edits, Plan (read-only), Bypass Permissions — settable at creation and live during a session
- **Tool restrictions** — Allowed and disallowed tool lists with Bash glob patterns (e.g., `Bash(git:*)`)
- **Send messages** — Chat directly with Claude
- **Steer mid-turn** — Inject guidance while Claude is working without stopping it
- **Take over passive sessions** — Promote hook-monitored sessions to direct control
- **Resume ended sessions** — Continue where a session left off

## Direct Codex Control

Full control over Codex sessions without leaving the app:

- **Create sessions** — Start new Codex sessions with project path and model selection
- **Send messages** — Chat directly with the Codex agent
- **Shell mode** — `⌘⇧T` toggle or `!command` prefix to run shell commands in the session's working directory
- **Steer mid-turn** — Inject guidance while the agent is working
- **Approve/deny tools** — Handle tool execution requests inline
- **Interrupt turns** — Stop the agent mid-turn
- **Undo last turn** — Roll back the most recent turn
- **Fork conversation** — Branch off a new session from the current conversation, optionally from a specific message
- **Compact context** — Trigger context compaction when token usage is high
- **Token context strip** — 3px progress bar showing context window fill, color-coded by utilization
- **Model and effort picker** — Switch models and reasoning effort on the fly
- **Autonomy picker** — 6 levels from Locked to Unrestricted
- **Skills picker** — Browse and attach skills to messages, `$skill-name` inline autocomplete
- **File mentions** — `@filename` autocomplete against project file index
- **Image attachments** — Attach images via file picker, paste from clipboard, or drag-and-drop
- **MCP servers tab** — View connected MCP servers and their tools
- **Resume ended sessions** — Continue where a session left off

## Turn Sidebar

Side panel for direct sessions with multiple tabs:

- **Approval history** — Past approval requests and decisions
- **Diff review** — Per-turn and cumulative diffs
- **Review comments** — Inline code annotations with selective send
- **Skills** — Browse and toggle skills
- **MCP servers** — Connected servers and their tools
- **Rail presets** — `⌘⌥1` Plan focused, `⌘⌥2` Review focused, `⌘⌥3` Triage

## Quick Switcher (⌘K)

- **Unified search** — Sessions, commands, and dashboard access
- **Full keyboard navigation** — Arrow keys, Enter to select, Escape to close
- **Inline actions** — Focus terminal, open in Finder, rename, copy resume command, close session
- **Recent sessions** — Collapsed section for recently ended sessions
- **Fork badges** — Visual indicator on forked sessions
- **Command mode** — Type `>` to filter commands (Go to Dashboard, Rename, Focus Terminal, etc.)

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

Control sessions from Claude Code (or any MCP client):

- **list_sessions** — List active sessions with provider filter and controllable-only flag
- **get_session** — Get details for a specific session
- **send_message** — Send prompts with optional model, effort, images, and file mentions
- **steer_turn** — Inject mid-turn guidance without stopping it
- **interrupt_turn** — Stop a running turn
- **approve** — Approve/deny/abort pending tool executions and questions
- **fork_session** — Fork a session's conversation, optionally from a specific message
- **set_permission_mode** — Change Claude permission mode live
- **list_models** — List available Codex models
- **check_connection** — Verify bridge connectivity

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘K | Quick Switcher |
| ⌘T | Focus Terminal |
| ⌘0 | Go to Dashboard |
| ⌘D | Toggle split (conversation + review) |
| ⌘⇧D | Review only layout |
| ⌘⇧T | Toggle Shell Mode |
| ⌘⌥1 | Rail preset: Plan focused |
| ⌘⌥2 | Rail preset: Review focused |
| ⌘⌥3 | Rail preset: Triage |
| ⌘⌥R | Toggle turn sidebar |
| ⌘R | Rename session (in Quick Switcher) |
| ⌘, | Settings |
| ↑/↓ | Navigate sessions |
| C-n/C-p | Next/Previous (Emacs) |
| Enter | Select |
| Escape | Close/Back |

**Approval card:**

| Key | Action |
|-----|--------|
| y | Approve once |
| Y | Allow for session |
| ! | Always allow |
| n | Deny |
| N | Deny & stop |
| d | Deny with reason |

**Review canvas:**

| Key | Action |
|-----|--------|
| C-n/C-p | Navigate lines |
| n/p or C-f/C-b | Jump sections |
| TAB | Collapse/expand |
| RET | Open in editor |
| q | Close review |
| f | Follow mode |
| C-space | Set mark |
| c | Open composer |
| r | Resolve/reopen comment |
| x/X | Toggle selection / Clear selections |
| S | Send comments to model |
| ]/[ | Jump to next/prev unresolved comment |

## Design

- **Cosmic Harbor theme** — Deep space aesthetic optimized for OLED displays
- **5 status colors** — Distinct colors per state for instant recognition
- **Model badges** — Opus (purple), Sonnet (blue), Haiku (teal)
- **Spring animations** — Smooth transitions throughout the UI
- **Custom design tokens** — Full color system in Theme.swift

## Platforms

- **macOS** — Native AppKit-backed conversation timeline with NSTableView for performance
- **iOS** — UICollectionView-backed timeline with compact layouts adapted for phone
