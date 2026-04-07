# Data Flow: Conversation Message Path

This document provides a deep-dive trace of the "Send Message" lifecycle, from the user interaction in the SwiftUI client to the durable persistence in the SQLite database, and finally the real-time feedback loop via WebSockets.

## 1. Client-Side Trigger (SwiftUI)

The journey begins in the **`ConversationViewModel`**.

* **Action**: The user enters text and submits.
* **Mechanism**: The ViewModel calls the `SessionStore` to execute an HTTP `POST` request.
* **Immediate UI Update**: The client does not wait for the full round-trip to the LLM. It expects an authoritative `user_row` back from the initial HTTP response to immediately render the message in the timeline with a "pending" or "sent" state.

## [_Internal Reference: OrbitDockNative/OrbitDock/Views/Conversation/ConversationViewModel.swift_]

## 2. HTTP Entry Point (Rust Server)

The request hits the Axum-based web server.

* **Route**: `POST /api/sessions/{session_id}/messages`
* **Handler**: `post_session_message` in `transport/http/session_actions.rs`.
* **Logic**:
    1. **Validation**: Ensures the message isn't empty and contains valid attachments/mentions.
    2. **ID Generation**: Creates a unique `message_id` (prefixed with `user-http-`).
    3. **Dispatch**: Hands off the request to the `message_dispatch` module.
    4. **Immediate Response**: Returns `202 ACCEPTED` along with the `user_row`. This is critical for low-latency perceived performance.

## 3. Message Dispatch (The Orchestrator)

The `runtime/message_dispatch.rs` module acts as the brain of the operation.

* **Session Verification**: Confirms the `SessionActor` is active and healthy.
* **Policy Application**: Uses `plan_send_message` to resolve the "effective" model and effort level (e.g., handling user overrides vs. profile defaults).
* **Resource Materialization**: Converts high-level image/mention references into concrete, server-side paths or IDs.
* **Connector Handoff**: The message is wrapped in a `CodexAction` or `ClaudeAction` and sent via an `mpsc` channel to the specific connector's event loop.

## 4. The Session Actor & Domain (Source of Truth)

The **`SessionActor`** (`runtime/session_actor.rs`) is the single authority for a session's state.

* **Sequential Processing**: The actor receives the `SendMessage` command and processes it within its own dedicated Tokio task, ensuring all state transitions are linear and thread-safe.
* **Domain Transition**: The session object (`domain/sessions/session.rs`) updates its internal state (e.g., incrementing message counts, updating `last_activity_at`).
* **Connector Execution**: The connector (e.g., `CodexConnector`) receives the command, communicates with the LLM provider, and eventually receives a response.
* **Event Loop**: The connector sends a `ProcessEvent` (like `Input::RowCreated`) back to the `SessionActor` once the LLM response is ready.

## 5. Persistence (The Durable Record)

Nothing is "real" until it is in the database.

* **Command Pattern**: The `SessionActor` issues a `PersistCommand` to the `PersistenceWriter`.
* **Batching**: The `PersistenceWriter` (`infrastructure/persistence/writer.rs`) batches these commands to minimize SQLite contention.
* **SQL Execution**: The `messages.rs` module performs the final `INSERT` into the `messages` table, storing the `row_data` as a JSON blob. This includes the `sequence` number, which is the authoritative ordering key.

## 6. Real-time Broadcast (The Feedback Loop)

Once the data is safe, the client must be notified.

* **WebSocket Signal**: The `SessionActor` broadcasts a `ServerMessage::ConversationRowsChanged` event.
* **Incremental Delta**: Instead of sending the whole conversation, the server sends a "delta" containing only the new or updated rows.
* **Client Reconciliation**: The `ConversationViewModel` receives this delta via its WebSocket stream and performs an in-memory "upsert" to its local `rowEntries` array, causing the SwiftUI view to update seamlessly.

---

## Summary Diagram

```mermaid
sequenceDiagram
    participant UI as SwiftUI Client
    participant HTTP as HTTP API (Axum)
    participant Dispatch as Message Dispatch
    participant Actor as Session Actor (Rust)
    participant Conn as Connector (LLM)
    participant DB as SQLite (Persistence)
    participant WS as WebSocket

    UI->>HTTP: POST /messages
    HTTP->>Dispatch: dispatch_send_message()
    Dispatch->>Actor: SendMessage(cmd)
    Actor-->>HTTP: 202 Accepted (user_row)
    HTTP-->>UI: 202 Accepted (user_row)
    Note over UI: Message appears in UI immediately
    
    Actor->>Conn: Execute LLM Call
    Conn-->>Actor: LLM Response
    Actor->>DB: PersistCommand (Insert Row)
    DB-->>Actor: Success
    Actor->>WS: Broadcast: ConversationRowsChanged(delta)
    WS-->>UI: WS Delta (upsert)
    Note over UI: UI updates with Assistant response
```
