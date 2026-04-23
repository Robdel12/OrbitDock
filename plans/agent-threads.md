# Agent Threads

## Goal

Make Codex and Claude workers feel like real child conversations in OrbitDock:
visible, inspectable, provider-honest, and steerable only when the server can
prove the provider/thread supports it.

The current worker sidecar is useful, but it flattens real agent work into
summary cards. This plan turns that sidecar into a first-class `agent-threads`
surface without overloading WebSocket or pushing provider inference into Swift.

## Invariants

- The Rust server owns agent-thread capabilities and transcript availability.
- HTTP owns agent-thread bootstrap, transcript reads, pagination, and mutations.
- WebSocket remains light: existing session/detail invalidations plus future
  targeted child-row deltas/refetch hints.
- Swift renders server truth and does not infer steerability from provider names,
  transcript presence, or worker status alone.
- Provider differences are product facts, not bugs. Codex can expose richer
  child-thread control than Claude; Claude can still provide a strong observer
  and transcript experience when transcript paths exist.

## Contract

Add a session-scoped resource:

- `GET /api/sessions/{session_id}/agent-threads`
- `GET /api/sessions/{session_id}/agent-threads/{thread_id}/conversation?limit=...&before_sequence=...`
- `POST /api/sessions/{session_id}/agent-threads/{thread_id}/message`

Summary rows include:

- thread identity and parent id
- provider, role, label, status, model, timestamps
- task/result/error summaries
- `conversation`: row counts, newest/oldest sequence, availability/freshness
- `capabilities`: `can_view_transcript`, `has_live_updates`, `accepts_user_input`,
  `can_interrupt`, `can_resume`, `can_close`, `interjection_mode`
- `limitations`: short provider-honest explanation when actions are disabled

For this first production pass:

- Codex direct child conversation viewing is supported through rollout transcript
  lookup.
- Codex child-thread input is parent-mediated while OrbitDock does not own a
  supported live child runtime handle.
- Claude transcript viewing is supported when a transcript path can be resolved.
- Claude interjection is parent-mediated because the current hook/CLI path does
  not expose a supported direct child input channel.

## UI

Use the worker sidecar as the entry point, then open the selected child thread
in OrbitDock's normal conversation surface:

- native roster remains compact and scannable
- selected agent thread routes the main pane to `ConversationView`
- agent-thread pages reuse normal conversation paging, row rendering, follow
  state, and jump-to-latest behavior
- the bespoke worker detail inspector remains for legacy subagent payloads, but
  agent-thread rows do not open a special transcript panel
- the direct parent composer is suppressed while a child thread is open so input
  is not accidentally sent to the wrong conversation
- provider capabilities stay on the server contract so a future normal-composer
  interjection path can be added without Swift guessing provider behavior

## Testing

Use the testing philosophy:

- test pure capability planning without provider mocks
- test HTTP outcomes for users: summaries expose correct capabilities and
  conversation pages return bounded rows
- test Swift presentation planning from protocol values rather than view internals
- avoid sleeps/polling; async tests wait on real returned values/events

## Checklist

- [x] Add typed protocol contracts for agent threads
- [x] Add server planner for provider capabilities and transcript metrics
- [x] Add HTTP endpoints and routing
- [x] Reuse existing subagent transcript parsing behind the new surface
- [x] Add Swift protocol/API client types
- [x] Add session API methods
- [x] Update worker scene model to load agent-thread details
- [x] Build conversation-first Agent Threads routing
- [x] Add Rust tests
- [x] Add Swift tests
- [x] Run Rust checks/tests
- [x] Run macOS build/tests
- [ ] Commit and open PR
