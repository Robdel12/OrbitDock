# OrbitDock: Mission Control for AI-Assisted Product Development

## The Problem

Building multiple SaaS products (Vizzly, Snoot, Moonbun, Backchannel, Pitstop) with AI agents means:

- Scattered terminal windows and tabs
- Mental overhead tracking which agent is doing what
- Context lost between sessions
- Linear tickets disconnected from the actual work
- No unified view of "what's the state of this multi-week project?"
- Multiple AI providers (Claude, Codex) with different rate limits to track

The work happens in fragments. The organization lives in your head.

## The Vision

OrbitDock is **mission control for AI-assisted product development**. It's where you:

1. **See all your agents** - Claude Code, Codex CLI, all in one place
2. **Manage quests** - Flexible work containers that span tickets, branches, and conversations
3. **Preserve context** - Decisions, pivots, blockers persist across sessions
4. **Connect the dots** - Linear tickets, GitHub PRs, AI sessions, your intent
5. **Track rate limits** - Monitor usage across all providers

## Core Concepts

### Quest
A quest is a **flexible work container** you define. It might be:
- "State machine refactor" (weeks long, multiple tickets, several pivots)
- "Add OAuth support" (spans design, implementation, testing)
- "Performance optimization sprint" (exploration, profiling, fixes)

A quest can have:
- **0-N linked tickets** - Linear issues, GitHub issues (optional)
- **0-N sessions** - Claude conversations (optional)
- **0-N branches** - Feature branches (optional)
- **Links** - PRs, plan files, any relevant URLs
- **Inbox items** - Quick notes and ideas

Quests are opt-in. You create them when you want to organize work, not auto-generated.

### Global Inbox
Quick capture for ideas that float free until you're ready to organize:
- Rough notes while working
- Ideas for future sessions
- Blockers to address later
- Attach to quests when ready (or never)

### Agent Sessions
AI agents work on your code. Sessions can be:
- Linked to a quest (organized work)
- Standalone (ad-hoc tasks)

OrbitDock shows you what each agent is doing, what needs attention, and preserves the conversation history.

### Multi-Product
You manage multiple products. Each has:
- Its own repos
- Its own agents/sessions
- Its own quests

OrbitDock gives you the unified view across all of them.

## North Star UX

Open OrbitDock and immediately see:
- Which quests need attention
- What agents are actively working
- Where you left off yesterday
- What's blocked, what's ready for review

Click into a quest and see:
- Linked sessions with their transcripts
- Connected PRs and issues
- Inbox items and notes
- The "story" of how this feature came to be

## What This Is NOT

- Not a replacement for Linear (ticket management)
- Not a replacement for GitHub (code management)
- Not a Claude UI (that's the terminal)

It's the **orchestration layer** that connects them and gives you the 10,000-foot view while preserving the ground-level context.

---

*"A cosmic harbor for AI agent sessions - spacecraft docked at your mission control center."*

## Multi-Provider Philosophy

OrbitDock treats all AI coding agents as first-class citizens:
- **Claude Code** - Full integration via lifecycle hooks
- **Codex CLI** - Native FSEvents watching of rollout files
- **Future providers** - Pluggable architecture via `UsageServiceRegistry`

The goal is one unified dashboard regardless of which AI you're working with.
