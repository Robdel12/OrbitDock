# OrbitDock: Mission Control for AI-Assisted Product Development

## The Problem

Building multiple SaaS products (Vizzly, Snoot, Moonbun, Backchannel, Pitstop) with AI agents means:

- Scattered terminal windows and tabs
- Mental overhead tracking which agent is doing what
- Context lost between sessions
- Linear tickets disconnected from the actual work
- No unified view of "what's the state of this multi-week project?"

The work happens in fragments. The organization lives in your head.

## The Vision

OrbitDock is **mission control for AI-assisted product development**. It's where you:

1. **See all your agents** - What's working, what's waiting, what needs attention
2. **Manage workstreams** - Multi-week projects that span tickets, branches, and conversations
3. **Preserve context** - Decisions, pivots, blockers persist across sessions
4. **Connect the dots** - Linear tickets ↔ GitHub PRs ↔ Claude sessions ↔ your intent

## Core Concepts

### Workstream
A workstream is a **body of work**, not just a branch. It might be:
- "State machine refactor" (weeks long, multiple tickets, several pivots)
- "Add OAuth support" (spans design, implementation, testing)
- "Performance optimization sprint" (exploration, profiling, fixes)

A workstream has:
- **Linked tickets** - Linear issues, GitHub issues
- **Sessions** - Claude conversations, with summaries
- **Decisions & pivots** - Why we changed direction
- **Artifacts** - PRs, commits, test results
- **Stage** - Planning → Working → Testing → Review → Shipped

### Agent Awareness
Claude knows its workstream. It can:
- Ask "What am I working on? What happened last time?"
- Log decisions and blockers
- See linked tickets and their status
- Resume with full context

### Multi-Product
You manage multiple products. Each has:
- Its own repos
- Its own agents/sessions
- Its own workstreams

OrbitDock gives you the unified view across all of them.

## North Star UX

Open OrbitDock and immediately see:
- Which workstreams need attention
- What agents are actively working
- Where you left off yesterday
- What's blocked, what's ready for review

Click into a workstream and see:
- The full journey: tickets → sessions → PRs → decisions
- Resume any session with context preserved
- The "story" of how this feature came to be

## What This Is NOT

- Not a replacement for Linear (ticket management)
- Not a replacement for GitHub (code management)
- Not a Claude UI (that's the terminal)

It's the **orchestration layer** that connects them and gives you the 10,000-foot view while preserving the ground-level context.

---

*"A cosmic harbor for AI agent sessions - spacecraft docked at your mission control center."*
