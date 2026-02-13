# Server Architecture v2: Functional Core, Imperative Shell

## Overview

Redesign the OrbitDock Rust server around pure state machines, effect-as-data, and per-session actors. The goal: handle 100+ concurrent agents with zero cross-session contention, fully testable state transitions, and reconnection-resilient event streaming.

**Core principle:** State transitions are pure functions that return data describing what happened. Side effects are executed separately. The entire session lifecycle becomes a deterministic state machine.

---

## Current Architecture (Problems)

```
WebSocket Handler
  │  (acquires Arc<Mutex<AppState>>)
  │  (acquires Arc<Mutex<SessionHandle>>)
  │  (persists inline)
  │  (broadcasts inline — iterates Vec<mpsc::Sender>, awaits each)
  │  (holds locks across all of this)
  ▼
Everything serialized through two nested mutexes
```

**Issues at scale:**
- `Arc<Mutex<AppState>>` held across awaits — blocks ALL sessions during any single session's IO
- `select!` loop processes events + actions on same task — long connector calls starve event processing
- No revision numbers — can't detect missed events after reconnect
- Broadcast iterates subscribers and awaits each — one slow client blocks all others
- No event replay — reconnection sends full snapshot, losing any intermediate state
- 12 dictionaries leaked per ended session — memory grows unbounded

---

## Target Architecture

```
                    ┌─────────────────────┐
                    │   WebSocket Layer    │  Stateless. Validates, routes, returns.
                    │   (no locks held)    │  One task per connection.
                    └────────┬────────────┘
                             │ mpsc per session
                             ▼
                    ┌─────────────────────┐
                    │   Session Actor      │  Owns ALL state for one session.
                    │   (one per session)  │  Single-threaded. No mutexes.
                    │                     │  Pure transition + effect execution.
                    └────────┬────────────┘
                             │
                    ┌────────┴────────────┐
                    │                     │
                    ▼                     ▼
           ┌──────────────┐    ┌──────────────────┐
           │ Event Log    │    │ Persistence       │
           │ (per-session │    │ (batched, async)  │
           │  ring buffer)│    │                    │
           └──────────────┘    └──────────────────┘
                    │
                    ▼
           ┌──────────────┐
           │  broadcast   │  tokio::broadcast per session.
           │  channel     │  Clients subscribe, read at own pace.
           └──────────────┘
```

---

## The State Machine

### Work Phases

The current `WorkStatus` has 6 variants but the real state machine has 4 phases. `Permission`/`Question` are the same phase with different data. `Reply` is a UI concern, not server state.

```
                         ┌───────────────────────────────────────┐
                         │              Idle                      │
                         │  (waiting for user input)              │
                         └───┬──────────────────────────▲────▲───┘
                             │                          │    │
                   UserMessage/Steer              TurnCompleted
                   Undo/Compact/Rollback          TurnAborted
                             │                     Error
                             ▼                          │    │
                         ┌───────────────────────────────┴────┘
                         │            Working                   │
                         │  (agent processing)                  │
                         └───┬──────────────────────────────────┘
                             │                          ▲
                    ApprovalRequested              Approved
                             │                          │
                             ▼                          │
                         ┌──────────────────────────────┴───┐
                         │       AwaitingApproval            │
                         │  { request_id, type, amendment }  │
                         └───┬──────────────────────────────┘
                             │
                        Denied/Abort → Idle

              ─── Any Phase ──→  Ended { reason }
```

### Valid Transitions

| From | Input | To |
|------|-------|----|
| `Idle` | `UserSentMessage`, `UserSteered`, Undo, Compact, Rollback | `Working` (via connector TurnStarted) |
| `Working` | `TurnCompleted` | `Idle` |
| `Working` | `TurnAborted` | `Idle` |
| `Working` | `ApprovalRequested` | `AwaitingApproval` |
| `Working` | `Error` | `Idle` |
| `AwaitingApproval` | `UserApproved` (approved) | `Working` |
| `AwaitingApproval` | `UserApproved` (denied/abort) | `Idle` |
| Any | `SessionEnded` | `Ended` |
| `Ended` | `ResumeSession` | `Idle` |

### Invalid Transitions (Logged + Ignored)

- `TurnCompleted` when not `Working`
- `ApprovalRequested` when not `Working`
- `UserApproved` when not `AwaitingApproval`
- Any input when `Ended` (except `ResumeSession`)

---

## Core Types

### State

```rust
/// The session's work phase — the state machine
#[derive(Debug, Clone, PartialEq)]
enum WorkPhase {
    Idle,
    Working,
    AwaitingApproval {
        request_id: String,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
    },
    Ended {
        reason: String,
    },
}

/// Everything the pure transition function can see — no IO handles
#[derive(Debug, Clone)]
struct SessionState {
    id: String,
    revision: u64,
    phase: WorkPhase,
    messages: Vec<Message>,
    tokens: TokenUsage,
    meta: SessionMeta,
    current_diff: Option<String>,
    current_plan: Option<String>,
}

/// Rarely-changing metadata, separated for clarity
#[derive(Debug, Clone)]
struct SessionMeta {
    provider: Provider,
    project_path: String,
    project_name: Option<String>,
    model: Option<String>,
    custom_name: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    codex_integration_mode: Option<CodexIntegrationMode>,
    forked_from_session_id: Option<String>,
    started_at: String,
    last_activity_at: String,
}
```

### Inputs

```rust
/// All possible inputs to the state machine
enum Input {
    // From connector (codex-core events)
    TurnStarted,
    TurnCompleted,
    TurnAborted { reason: String },
    MessageCreated(Message),
    MessageUpdated { message_id: String, changes: MessageChanges },
    ApprovalRequested { request_id: String, approval_type: ApprovalType, command: Option<String>, file_path: Option<String>, diff: Option<String>, question: Option<String>, proposed_amendment: Option<Vec<String>> },
    TokensUpdated(TokenUsage),
    DiffUpdated(String),
    PlanUpdated(String),
    ThreadNameUpdated(String),
    SessionEnded { reason: String },
    ContextCompacted,
    UndoStarted { message: Option<String> },
    UndoCompleted { success: bool, message: Option<String> },
    ThreadRolledBack { num_turns: u32 },
    Error(String),

    // From client (WebSocket actions)
    UserSentMessage { content: String, model: Option<String>, effort: Option<String>, skills: Vec<SkillInput>, images: Vec<ImageInput>, mentions: Vec<MentionInput> },
    UserSteered { content: String, message_id: String },
    UserApproved { request_id: String, decision: ApprovalDecision },
    UserAnswered { request_id: String, answer: String },
    UserRenamed { name: Option<String> },
    UserChangedConfig { approval_policy: Option<String>, sandbox_mode: Option<String> },
    UserInterrupted,
    UserRequestedCompact,
    UserRequestedUndo,
    UserRequestedRollback { num_turns: u32 },
    UserEndedSession,
}
```

### Effects

```rust
/// Side effects produced by a transition — pure data, no IO
enum Effect {
    /// Write to SQLite (batched downstream)
    Persist(PersistOp),

    /// Broadcast to subscribed clients (carries the new revision)
    Emit(EventPayload),

    /// Command to the codex-core connector
    Connector(ConnectorCall),
}

enum PersistOp {
    UpdateSession { work_status: WorkStatus, last_activity_at: String },
    AppendMessage(Message),
    UpdateMessage { message_id: String, changes: MessageChanges },
    EndSession { reason: String },
    UpdateTokens(TokenUsage),
    UpdateTurnState { diff: Option<String>, plan: Option<String> },
    SetCustomName(Option<String>),
    SetConfig { approval_policy: Option<String>, sandbox_mode: Option<String> },
    RecordApproval { request_id: String, approval_type: ApprovalType, command: Option<String>, file_path: Option<String> },
    RecordApprovalDecision { request_id: String, decision: String },
}

enum ConnectorCall {
    SendMessage { content: String, model: Option<String>, effort: Option<String>, skills: Vec<SkillInput>, images: Vec<ImageInput>, mentions: Vec<MentionInput> },
    SteerTurn { content: String },
    Approve { request_id: String, decision: ApprovalDecision, proposed_amendment: Option<Vec<String>> },
    AnswerQuestion { request_id: String, answers: HashMap<String, String> },
    Interrupt,
    Compact,
    Undo,
    Rollback { num_turns: u32 },
    SetThreadName(String),
    UpdateConfig { approval_policy: Option<String>, sandbox_mode: Option<String> },
    ListSkills { cwds: Vec<String>, force_reload: bool },
    ListMcpTools,
    RefreshMcpServers,
    Shutdown,
}

/// What gets broadcast to clients + stored in the event log
struct SessionEvent {
    revision: u64,
    session_id: String,
    payload: EventPayload,
}

enum EventPayload {
    PhaseChanged { work_status: WorkStatus, last_activity_at: String },
    MessageAppended(Message),
    MessageUpdated { message_id: String, changes: MessageChanges },
    TokensUpdated(TokenUsage),
    ApprovalRequested(ApprovalRequest),
    ApprovalCleared,
    SessionEnded { reason: String },
    MetaChanged(MetaChanges),
    ContextCompacted,
    UndoStarted { message: Option<String> },
    UndoCompleted { success: bool, message: Option<String> },
    ThreadRolledBack { num_turns: u32 },
}
```

---

## The Pure Transition Function

Fully deterministic, fully testable, no async, no IO:

```rust
fn transition(state: SessionState, input: Input) -> (SessionState, Vec<Effect>) {
    let mut effects = Vec::new();
    let now = iso_now();

    let new_state = match (&state.phase, input) {
        // ── Turn lifecycle ──────────────────────────────────────

        (_, Input::TurnStarted) => {
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Working,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Working,
                last_activity_at: now.clone(),
            }));
            state.with_phase(WorkPhase::Working).tick(now)
        }

        (WorkPhase::Working, Input::TurnCompleted) => {
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            state.with_phase(WorkPhase::Idle).tick(now)
        }

        (WorkPhase::Working, Input::TurnAborted { .. }) | (_, Input::Error(_)) => {
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            state.with_phase(WorkPhase::Idle).tick(now)
        }

        // ── Approval flow ───────────────────────────────────────

        (WorkPhase::Working, Input::ApprovalRequested { request_id, approval_type, proposed_amendment, .. }) => {
            effects.push(Effect::Persist(PersistOp::RecordApproval { /* ... */ }));
            effects.push(Effect::Emit(EventPayload::ApprovalRequested(/* ... */)));
            state.with_phase(WorkPhase::AwaitingApproval {
                request_id,
                approval_type,
                proposed_amendment,
            }).tick(now)
        }

        (WorkPhase::AwaitingApproval { ref request_id, .. }, Input::UserApproved { decision, .. })
            if decision.is_approved() =>
        {
            effects.push(Effect::Connector(ConnectorCall::Approve { /* ... */ }));
            effects.push(Effect::Persist(PersistOp::RecordApprovalDecision { /* ... */ }));
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Working,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::ApprovalCleared));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Working,
                last_activity_at: now.clone(),
            }));
            state.with_phase(WorkPhase::Working).tick(now)
        }

        (WorkPhase::AwaitingApproval { .. }, Input::UserApproved { decision, .. }) => {
            // Denied or aborted
            effects.push(Effect::Connector(ConnectorCall::Approve { /* ... */ }));
            effects.push(Effect::Persist(PersistOp::RecordApprovalDecision { /* ... */ }));
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::ApprovalCleared));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            state.with_phase(WorkPhase::Idle).tick(now)
        }

        // ── Messages ────────────────────────────────────────────

        (_, Input::MessageCreated(msg)) => {
            effects.push(Effect::Persist(PersistOp::AppendMessage(msg.clone())));
            effects.push(Effect::Emit(EventPayload::MessageAppended(msg.clone())));
            state.with_message(msg).tick(now)
        }

        (_, Input::MessageUpdated { message_id, changes }) => {
            effects.push(Effect::Persist(PersistOp::UpdateMessage {
                message_id: message_id.clone(),
                changes: changes.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::MessageUpdated {
                message_id,
                changes,
            }));
            state.tick(now)
        }

        // ── Client actions ──────────────────────────────────────

        (_, Input::UserSentMessage { content, model, effort, skills, images, mentions }) => {
            let msg = Message::user(&state.id, &content);
            effects.push(Effect::Persist(PersistOp::AppendMessage(msg.clone())));
            effects.push(Effect::Emit(EventPayload::MessageAppended(msg)));
            effects.push(Effect::Connector(ConnectorCall::SendMessage {
                content, model, effort, skills, images, mentions,
            }));
            state.tick(now)
        }

        (_, Input::UserSteered { content, message_id }) => {
            // Steer message already appended by WebSocket layer; connector call here
            effects.push(Effect::Connector(ConnectorCall::SteerTurn { content }));
            state.tick(now)
        }

        (_, Input::UserInterrupted) => {
            effects.push(Effect::Connector(ConnectorCall::Interrupt));
            state.tick(now)
        }

        // ── Tokens & metadata ───────────────────────────────────

        (_, Input::TokensUpdated(usage)) => {
            effects.push(Effect::Persist(PersistOp::UpdateTokens(usage.clone())));
            effects.push(Effect::Emit(EventPayload::TokensUpdated(usage.clone())));
            state.with_tokens(usage)
        }

        (_, Input::DiffUpdated(diff)) => {
            effects.push(Effect::Persist(PersistOp::UpdateTurnState {
                diff: Some(diff.clone()), plan: None,
            }));
            state.with_diff(Some(diff))
        }

        (_, Input::ThreadNameUpdated(name)) => {
            effects.push(Effect::Persist(PersistOp::SetCustomName(Some(name.clone()))));
            effects.push(Effect::Emit(EventPayload::MetaChanged(MetaChanges {
                custom_name: Some(Some(name.clone())),
                ..Default::default()
            })));
            state.with_custom_name(Some(name)).tick(now)
        }

        // ── Terminal ────────────────────────────────────────────

        (_, Input::SessionEnded { reason }) => {
            effects.push(Effect::Persist(PersistOp::EndSession { reason: reason.clone() }));
            effects.push(Effect::Emit(EventPayload::SessionEnded { reason: reason.clone() }));
            state.with_phase(WorkPhase::Ended { reason }).tick(now)
        }

        // ── Undo / Rollback ─────────────────────────────────────

        (_, Input::UndoStarted { message }) => {
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Working,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Working,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::UndoStarted { message }));
            state.with_phase(WorkPhase::Working).tick(now)
        }

        (_, Input::UndoCompleted { success, message }) => {
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::UndoCompleted { success, message }));
            state.with_phase(WorkPhase::Idle).tick(now)
        }

        (_, Input::ThreadRolledBack { num_turns }) => {
            effects.push(Effect::Persist(PersistOp::UpdateSession {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::PhaseChanged {
                work_status: WorkStatus::Waiting,
                last_activity_at: now.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::ThreadRolledBack { num_turns }));
            state.with_phase(WorkPhase::Idle).tick(now)
        }

        // ── Pass-through actions (no state change) ──────────────

        (_, Input::UserRequestedCompact) => {
            effects.push(Effect::Connector(ConnectorCall::Compact));
            state
        }

        (_, Input::UserRequestedUndo) => {
            effects.push(Effect::Connector(ConnectorCall::Undo));
            state
        }

        (_, Input::UserRequestedRollback { num_turns }) => {
            effects.push(Effect::Connector(ConnectorCall::Rollback { num_turns }));
            state
        }

        (_, Input::UserEndedSession) => {
            effects.push(Effect::Connector(ConnectorCall::Shutdown));
            state
        }

        (_, Input::ContextCompacted) => {
            effects.push(Effect::Emit(EventPayload::ContextCompacted));
            state
        }

        (_, Input::UserChangedConfig { approval_policy, sandbox_mode }) => {
            effects.push(Effect::Persist(PersistOp::SetConfig {
                approval_policy: approval_policy.clone(),
                sandbox_mode: sandbox_mode.clone(),
            }));
            effects.push(Effect::Connector(ConnectorCall::UpdateConfig {
                approval_policy: approval_policy.clone(),
                sandbox_mode: sandbox_mode.clone(),
            }));
            effects.push(Effect::Emit(EventPayload::MetaChanged(MetaChanges {
                approval_policy: Some(approval_policy),
                sandbox_mode: Some(sandbox_mode),
                ..Default::default()
            })));
            state.tick(now)
        }

        (_, Input::UserRenamed { name }) => {
            effects.push(Effect::Persist(PersistOp::SetCustomName(name.clone())));
            effects.push(Effect::Connector(ConnectorCall::SetThreadName(
                name.clone().unwrap_or_default(),
            )));
            effects.push(Effect::Emit(EventPayload::MetaChanged(MetaChanges {
                custom_name: Some(name.clone()),
                ..Default::default()
            })));
            state.with_custom_name(name).tick(now)
        }

        // ── Invalid transitions ─────────────────────────────────

        (phase, input) => {
            warn!("Ignored input {:?} in phase {:?}", input, phase);
            state // no change, no effects
        }
    };

    // Increment revision once per emit
    let emit_count = effects.iter().filter(|e| matches!(e, Effect::Emit(_))).count() as u64;
    (new_state.with_revision(new_state.revision + emit_count), effects)
}
```

---

## The Actor (Imperative Shell)

```rust
struct SessionActor {
    state: SessionState,
    connector: CodexConnector,

    // Inbound
    inbox: mpsc::Receiver<SessionCommand>,
    event_rx: mpsc::Receiver<ConnectorEvent>,

    // Outbound
    event_bus: broadcast::Sender<SessionEvent>,
    persist_tx: mpsc::Sender<PersistCommand>,

    // Read-only snapshot for lock-free reads from WebSocket layer
    snapshot: Arc<ArcSwap<SessionSnapshot>>,

    // Bounded replay log for reconnecting clients
    event_log: VecDeque<SessionEvent>,
}

enum SessionCommand {
    Action(Input),
    Subscribe {
        since_revision: u64,
        reply_tx: oneshot::Sender<SubscribeResponse>,
    },
}

enum SubscribeResponse {
    Snapshot(SessionSnapshot),
    Replay(Vec<SessionEvent>),
}

impl SessionActor {
    async fn run(mut self) {
        loop {
            let input = tokio::select! {
                Some(event) = self.event_rx.recv() => {
                    Input::from_connector_event(event)
                }
                Some(cmd) = self.inbox.recv() => {
                    match cmd {
                        SessionCommand::Action(input) => input,
                        SessionCommand::Subscribe { since_revision, reply_tx } => {
                            self.handle_subscribe(since_revision, reply_tx);
                            continue;
                        }
                    }
                }
                else => break,
            };

            // Pure transition — no IO
            let (new_state, effects) = transition(self.state, input);
            self.state = new_state;

            // Execute effects — the only place IO happens
            for effect in effects {
                self.execute(effect).await;
            }

            // Update snapshot for lock-free reads
            self.snapshot.store(Arc::new(self.state.to_snapshot()));
        }
    }

    async fn execute(&mut self, effect: Effect) {
        match effect {
            Effect::Persist(op) => {
                let cmd = op.into_persist_command(&self.state.id);
                let _ = self.persist_tx.send(cmd).await;
            }
            Effect::Emit(payload) => {
                let event = SessionEvent {
                    revision: self.state.revision,
                    session_id: self.state.id.clone(),
                    payload,
                };
                // Ring buffer for replay
                self.event_log.push_back(event.clone());
                if self.event_log.len() > 1000 {
                    self.event_log.pop_front();
                }
                // Broadcast — non-blocking, returns immediately
                let _ = self.event_bus.send(event);
            }
            Effect::Connector(call) => {
                self.execute_connector_call(call).await;
            }
        }
    }

    fn handle_subscribe(&self, since_revision: u64, reply_tx: oneshot::Sender<SubscribeResponse>) {
        if since_revision == 0
            || !self.event_log.front().map_or(false, |e| e.revision <= since_revision + 1)
        {
            // Too far behind or first subscribe — send snapshot
            let snapshot = self.state.to_snapshot();
            let _ = reply_tx.send(SubscribeResponse::Snapshot(snapshot));
        } else {
            // Replay missed events
            let missed: Vec<_> = self.event_log.iter()
                .filter(|e| e.revision > since_revision)
                .cloned()
                .collect();
            let _ = reply_tx.send(SubscribeResponse::Replay(missed));
        }
    }
}
```

---

## Session Registry (Replaces AppState Mutex)

```rust
use dashmap::DashMap;
use arc_swap::ArcSwap;

struct SessionRegistry {
    sessions: DashMap<String, SessionHandle>,
    persist_tx: mpsc::Sender<PersistCommand>,
}

struct SessionHandle {
    inbox: mpsc::Sender<SessionCommand>,
    event_bus: broadcast::Sender<SessionEvent>,
    snapshot: Arc<ArcSwap<SessionSnapshot>>,
}

impl SessionRegistry {
    /// Route a client action — no locks, no awaiting IO
    fn send(&self, session_id: &str, input: Input) -> Result<(), Error> {
        let handle = self.sessions.get(session_id).ok_or(Error::NotFound)?;
        handle.inbox.try_send(SessionCommand::Action(input))
            .map_err(|_| Error::SessionBusy)?;
        Ok(())
    }

    /// Get a read-only snapshot — lock-free, zero contention
    fn snapshot(&self, session_id: &str) -> Option<Arc<SessionSnapshot>> {
        self.sessions.get(session_id).map(|h| h.snapshot.load_full())
    }

    /// Get session list — lock-free iteration
    fn list_summaries(&self) -> Vec<SessionSummary> {
        self.sessions.iter()
            .map(|entry| entry.value().snapshot.load().to_summary())
            .collect()
    }

    /// Subscribe to a session's event stream
    fn subscribe_events(&self, session_id: &str) -> Option<broadcast::Receiver<SessionEvent>> {
        self.sessions.get(session_id).map(|h| h.event_bus.subscribe())
    }
}
```

---

## Stateless WebSocket Handler

```rust
async fn handle_client_message(
    msg: ClientMessage,
    registry: &SessionRegistry,
    conn: &mut WsConnection,
) {
    match msg {
        ClientMessage::SendMessage { session_id, content, .. } => {
            // Just route to the actor's inbox. No lock. No persist.
            registry.send(&session_id, Input::UserSentMessage { content, .. })?;
        }

        ClientMessage::SubscribeSession { session_id } => {
            let (reply_tx, reply_rx) = oneshot::channel();
            registry.send(&session_id, SessionCommand::Subscribe {
                since_revision: conn.last_revision(&session_id),
                reply_tx,
            })?;

            // Get initial state (snapshot or replay)
            let response = reply_rx.await?;
            match response {
                SubscribeResponse::Snapshot(snap) => {
                    conn.send_snapshot(snap).await;
                }
                SubscribeResponse::Replay(events) => {
                    for event in events {
                        conn.send_event(event).await;
                    }
                }
            }

            // Attach live event stream
            let event_rx = registry.subscribe_events(&session_id)?;
            conn.attach_event_stream(session_id, event_rx);
        }

        ClientMessage::SubscribeList => {
            let summaries = registry.list_summaries();
            conn.send_sessions_list(summaries).await;
        }

        // All other actions: validate + route
        ClientMessage::ApproveTool { session_id, request_id, decision } => {
            registry.send(&session_id, Input::UserApproved { request_id, decision })?;
        }

        ClientMessage::SteerTurn { session_id, content } => {
            registry.send(&session_id, Input::UserSteered { content, .. })?;
        }

        // ... etc
    }
}
```

---

## Subscribe/Reconnect Protocol

```
Client                          Server
  │                               │
  │  Subscribe(session, rev=0)    │
  │──────────────────────────────►│
  │                               │  rev=0 means "give me everything"
  │  Snapshot(state, rev=147)     │
  │◄──────────────────────────────│
  │                               │
  │  Event(rev=148, msg added)    │
  │◄──────────────────────────────│
  │  Event(rev=149, status=work)  │
  │◄──────────────────────────────│
  │                               │
  │  ~~~ connection drops ~~~     │
  │                               │
  │  Subscribe(session, rev=149)  │  "I have up to 149"
  │──────────────────────────────►│
  │                               │  Server checks event_log:
  │  Event(rev=150, ...)          │  Still in buffer → replay
  │◄──────────────────────────────│
  │  Event(rev=151, ...)          │
  │◄──────────────────────────────│
  │                               │
  │  ~~~ long disconnect ~~~      │
  │                               │
  │  Subscribe(session, rev=149)  │
  │──────────────────────────────►│
  │                               │  Too far behind (150 not in buffer)
  │  Snapshot(state, rev=312)     │  Fallback to full snapshot
  │◄──────────────────────────────│
```

---

## Performance at 100 Agents

### Memory Budget

| Component | Per-session | At 100 sessions |
|-----------|-------------|-----------------|
| Actor task stack | ~8KB | ~800KB |
| `broadcast::Sender` | ~64 bytes | ~6.4KB |
| Event log (1000 events) | ~500KB | ~50MB |
| `ArcSwap<Snapshot>` | ~64 bytes | ~6.4KB |
| DashMap entry | ~128 bytes | ~12.8KB |
| Messages (avg 500 x 2KB) | ~1MB | ~100MB |
| **Total** | **~1.5MB** | **~150MB** |

### CPU

- `transition()` is nanoseconds (pure computation, no allocation in common case)
- `execute()` dominated by JSON serialization for broadcast
- Pre-serialize JSON once per event, send bytes to all subscribers
- Each actor is independently scheduled by tokio — no cross-session contention

### Contention

- **Zero cross-session contention** — each actor owns its state
- **DashMap** uses sharded locking — lookups are effectively lock-free on read path
- **`arc_swap`** reads are wait-free on x86 — snapshot access has zero contention
- **`tokio::broadcast`** is non-blocking for the sender — slow subscribers get `Lagged` error
- **Persistence channel** is the only shared resource (bounded mpsc, batched)

---

## Testing

The pure transition function enables deterministic unit tests with no IO:

```rust
#[test]
fn turn_completed_transitions_to_idle() {
    let state = SessionState::test().with_phase(WorkPhase::Working);
    let (new_state, effects) = transition(state, Input::TurnCompleted);

    assert_eq!(new_state.phase, WorkPhase::Idle);
    assert!(effects.iter().any(|e| matches!(e, Effect::Persist(PersistOp::UpdateSession { .. }))));
    assert!(effects.iter().any(|e| matches!(e, Effect::Emit(EventPayload::PhaseChanged { .. }))));
}

#[test]
fn approval_denied_returns_to_idle() {
    let state = SessionState::test().with_phase(WorkPhase::AwaitingApproval {
        request_id: "req-1".into(),
        approval_type: ApprovalType::Exec,
        proposed_amendment: None,
    });

    let (new_state, effects) = transition(state, Input::UserApproved {
        request_id: "req-1".into(),
        decision: ApprovalDecision::Denied,
    });

    assert_eq!(new_state.phase, WorkPhase::Idle);
    assert!(effects.iter().any(|e| matches!(e, Effect::Connector(ConnectorCall::Approve { .. }))));
}

#[test]
fn invalid_transition_is_noop() {
    let state = SessionState::test().with_phase(WorkPhase::Idle);
    let (new_state, effects) = transition(state.clone(), Input::TurnCompleted);

    assert_eq!(new_state.phase, state.phase);
    assert!(effects.is_empty());
}

#[test]
fn revision_increments_per_emit() {
    let state = SessionState::test().with_revision(10);
    let (new_state, effects) = transition(state, Input::TurnStarted);

    let emit_count = effects.iter().filter(|e| matches!(e, Effect::Emit(_))).count();
    assert_eq!(new_state.revision, 10 + emit_count as u64);
}
```

---

## Migration Path

This is incremental — each step ships independently and the system stays running.

### Phase 1: Revision tracking + event log (smallest diff, biggest robustness win) ✅ DONE

1. ✅ Add `revision: u64` to `SessionHandle` — increment on every broadcast
2. ✅ Include `revision` in snapshots + replayed events (live events skip revision — idempotent handlers make this safe)
3. ✅ Add `VecDeque<(u64, String)>` ring buffer (1000 events) to `SessionHandle` — pre-serialized with revision injected
4. ✅ Add `since_revision` to `SubscribeSession` — replay from log or send snapshot
5. ✅ Swift client: track `lastRevision` per session, send on subscribe

**Wire format change:** Optional `revision` field on `SessionState` (snapshots). Replayed events carry revision via injected JSON field.

### Phase 2: Replace broadcast mechanism

1. Replace `Vec<mpsc::Sender<ServerMessage>>` in `SessionHandle` with `broadcast::channel`
2. Each WebSocket connection spawns a receiver task that drains from broadcast
3. Handle `Lagged` error by requesting fresh snapshot
4. Remove the `unsubscribe_by_closed()` cleanup — `broadcast` handles this

### Phase 3: Extract pure transition function

1. Create `transition.rs` with the pure `fn transition(SessionState, Input) -> (SessionState, Vec<Effect>)`
2. Extract one match arm at a time from `handle_event` into the pure function
3. `handle_event` becomes: call `transition()`, then execute effects
4. Add unit tests for each transition
5. Keep `handle_action` for connector calls initially
6. **Fix dual user-message write path:** `UserSentMessage` transition owns message creation (emit + persist). Filter out the connector's `UserMessage` echo in the connector layer so it never becomes a `MessageCreated` input. Removes the content-based dedup hack in `codex_session.rs`.

### Phase 4: Session actor refactor

1. Create `SessionActor` struct that owns `SessionState` directly (no `Arc<Mutex<>>`)
2. Merge `event_rx` and `action_rx` into a single `inbox` channel
3. Remove `SessionHandle` mutex — actor is the only writer
4. Add `ArcSwap<SessionSnapshot>` for lock-free reads

### Phase 5: Replace AppState with SessionRegistry

1. Replace `Arc<Mutex<AppState>>` with `DashMap<String, SessionHandle>`
2. WebSocket handler becomes stateless routing — no locks held
3. Add `ArcSwap` snapshot reads for session list
4. Clean up ended sessions (remove from DashMap + clear all per-session state)

### Phase 6: Swift client updates

1. Track `lastRevision` per session in `ServerAppState`
2. Send `since_revision` in `subscribeSession` message
3. Handle replay response (apply events in order) vs snapshot response
4. Remove `messageRevisions` counter (server revision replaces it)
5. Add `Lagged` handling — request fresh snapshot

---

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| State machine style | Hand-rolled enum + pure function | 4 phases x 15 events is manageable; libraries add complexity without benefit at this scale |
| Typestate pattern | Skip | Runtime event dispatch means we always need a wrapper enum, defeating the purpose |
| Effect system | Enum of effect variants | Simple, exhaustive, no proc macros; effect executor is ~50 lines |
| Broadcast | `tokio::broadcast` | Non-blocking for sender; `Lagged` error handles slow subscribers automatically |
| State sharing | `arc_swap::ArcSwap` | Lock-free reads from WebSocket handlers; single writer (actor) updates atomically |
| Session registry | `DashMap` | Lock-free concurrent map; no global mutex needed for routing |
| Event log | `VecDeque` ring buffer (1000 events) | Cheap, bounded; covers most reconnection windows |
| Persistent data structures (`im` crate) | Skip | Sequential message iteration benefits from cache locality; single-writer actor doesn't need structural sharing |

---

## Dependencies to Add

```toml
[dependencies]
dashmap = "6"
arc-swap = "1"
# tokio::sync::broadcast is already in tokio
```

---

## Files Affected

### New files
- `crates/server/src/transition.rs` — Pure transition function + types
- `crates/server/src/actor.rs` — SessionActor impl
- `crates/server/src/registry.rs` — SessionRegistry (replaces state.rs)
- `crates/server/src/effects.rs` — Effect types + executor
- `crates/server/src/transition_tests.rs` — Unit tests for all transitions

### Modified files
- `crates/server/src/websocket.rs` — Simplify to stateless routing
- `crates/server/src/codex_session.rs` — Extract transition logic, simplify to actor setup
- `crates/server/src/session.rs` — Gradually replaced by actor.rs
- `crates/server/src/state.rs` — Gradually replaced by registry.rs
- `crates/server/src/main.rs` — Wire up registry instead of AppState
- `crates/protocol/src/server.rs` — Add `revision` field to events
- `crates/protocol/src/client.rs` — Add `since_revision` to SubscribeSession

### Swift files (Phase 6)
- `ServerConnection.swift` — Send `since_revision` on subscribe
- `ServerAppState.swift` — Track revision, handle replay response
- `ServerProtocol.swift` — Add revision field to event types
