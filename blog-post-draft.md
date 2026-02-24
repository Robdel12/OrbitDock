# Introducing OrbitDock: Code From Anywhere, With Your Agents Doing the Work

I wrote most of this post from my backyard, on my iPhone.

Not in a "technically possible" way. In a "this is just how I work now" way. My dev machines are running Claude Code and Codex sessions. OrbitDock's server is running somewhere they can reach. My phone — or iPad, or any Mac — connects to that server and gives me the full picture: what agents are doing, what needs my approval, what just finished.

That's the product. Let me explain how it works.

---

## The Server Goes Anywhere

OrbitDock has two pieces. The client — a native app for macOS, iOS, and iPad. And the server — a single Rust binary called `orbitdock-server`.

The server is the part that matters most right now, because it can go anywhere:

- **Your local machine** — run it as a launchd service, forget about it
- **A Raspberry Pi** on your home network
- **A VPS or cloud VM** — any Linux box with an open port
- **A Docker container** — single binary, minimal footprint
- **Your home server** — wherever Claude and Codex sessions are actually running

The binary handles everything: receives hook events from Claude Code over HTTP, manages Codex sessions, persists your conversation history to SQLite, and broadcasts real-time updates to connected clients over WebSocket.

Your apps connect to it wherever it lives. Switch from Mac to iPhone to iPad and you're looking at the same live state. Nothing to sync. Nothing to hand off. The server is the source of truth.

---

## Why This Matters

AI coding agents need to run somewhere that has access to your codebase — usually your dev machine or a remote environment. But you don't always want to be sitting at that machine.

With OrbitDock, the server lives next to your agents. The app lives wherever you are. That gap is WebSocket — fast, persistent, real-time.

Right now, the most common setup is a local server running on a Mac via launchd. But remote setup is first-class too. You can connect one or many endpoints at the same time (local machine, laptop, Pi, cloud), pick a default endpoint per device for create flows, and keep a unified dashboard across all connected servers.

Running your agents on a beefier machine, a VPS with the right API keys, or a home server that stays on 24/7? That's the whole point.

---

## The Apps

All three clients — macOS, iOS, iPad — are native. Not Electron, not a web view. Real SwiftUI apps with real performance.

The conversation views are built on NSTableView (macOS) and UICollectionView (iOS) — the platform-native scroll infrastructure. Smooth even in long sessions with dense tool usage.

The iPad and iOS apps aren't cut-down versions. They show the full dashboard, session timelines, approval cards, and the composer. The same controls you use on Mac work on touch. From the backyard, from a coffee shop, from a flight — wherever you are when an agent finishes a big task and needs your review.

---

## What You're Looking At

The dashboard organizes your sessions by project directory. At a glance you can see what's running, what needs attention, and what's done.

Status is color-coded so you can read the room instantly:

- **Cyan** — Agent is actively working
- **Coral** — Waiting on your approval to use a tool
- **Purple** — Agent asked you a question
- **Blue** — Waiting for your next prompt
- **Gray** — Session finished

Permission requests and questions surface to the top automatically. If you're on a different session when something needs attention, a notification appears in the corner — just the session name and what it's waiting on.

---

## Approvals From Your Phone

This is the part that surprised me the most when it started working.

An agent hits a tool approval. I get a notification. I open OrbitDock on my phone, see the full context — what tool, what arguments, what risk level — and tap to approve or deny. The agent continues.

OrbitDock classifies risk automatically. Commands like `rm -rf`, `git push --force`, `DROP TABLE`, and `sudo` are flagged before you confirm. File patches show the full diff inline.

If you deny something, you can explain why. That reason goes back to the agent so it can adjust.

On macOS, approval triage has full keyboard shortcuts: `y` to approve, `n` to deny, `!` for high-risk confirmation, `d` to view the diff. On iOS, it's tap targets sized for thumbs.

---

## The Conversation Timeline

Every session has a full conversation view — messages, tool calls, outputs, diffs. All of it, in order, with proper rendering for code blocks and structured outputs.

Tool cards expand inline. You can see exactly what the agent read, wrote, ran, and found. No digging through logs.

---

## The Workflow Stuff (Coming Back Into Focus)

The features above — server portability, native apps, approvals from anywhere — have been the main focus lately. But OrbitDock started as a workflow tool, and that's still the long game.

A few things that are already there and will continue to get sharper:

**Review canvas** — a Magit-style unified diff of everything an agent touched. All files, one scrollable view. You can leave inline comments and send them back to the agent as structured feedback.

**Quick Switcher (⌘K)** — fuzzy search across all sessions. Jump anywhere, trigger actions, no mouse needed.

**Direct session control** — start new Claude Code or Codex sessions from within the app, set permission modes, steer a turn mid-execution, fork conversations.

**Usage tracking** — real-time rate limit gauges for Claude (5h and 7d windows) and Codex. Useful when you're running several agents at once.

These exist today. They'll keep getting better as the remote access foundation solidifies.

---

## How It Hooks Into Claude Code

OrbitDock installs a hook script at `~/.orbitdock/hook.sh`. Claude Code calls that script on every session event — start, stop, tool use, approvals, prompts, compaction. The script POSTs to the server over HTTP.

The server persists everything to SQLite and broadcasts over WebSocket. Your connected apps update in real time, no polling.

One command sets it up: `orbitdock-server install-hooks`. It merges the hooks into your existing `~/.claude/settings.json` without touching anything else.

---

## How It Hooks Into Codex

Codex doesn't have a hook system, so OrbitDock watches the session files directly via FSEvents. The server tails Codex's rollout files as they're written, parses the events, and ingests them the same way Claude Code sessions flow in.

Same dashboard, same conversation view, same approval flow. Different integration mechanism, same result.

---

## Data Stays Yours

There's no cloud component. No account. No telemetry. Your session history lives in a SQLite database on whatever machine runs the server. The app never talks to anything except your server.

If you're running the server on your local machine, the database is at `~/.orbitdock/orbitdock.db`. If you're running it on a remote host, same deal — it's on that machine, not anyone else's.

---

## The Setup

Launch OrbitDock for the first time. Two options:

1. **Install locally** — the app installs the server binary, sets up launchd, installs the Claude Code hooks. Takes about 30 seconds. After that it just runs.

2. **Connect to remote** — enter the host and port of wherever your server is already running. That's it.

For development, `cargo run -p orbitdock-server` starts the server. The app detects it and skips the install flow.

---

## What's Next

The remote server story is the focus right now — making it easy to run the server anywhere and connect to it from any device. The workflow and review features are going to get a lot of attention after that.

If you're running AI agents and want a better way to stay on top of them — especially from your phone or iPad while you're away from your desk — this is what OrbitDock is built for.

---

*OrbitDock is a native macOS, iOS, and iPad app. The server is a standalone Rust binary that runs anywhere.*
