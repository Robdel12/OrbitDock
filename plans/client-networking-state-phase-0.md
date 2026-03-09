# Client Networking Rewrite Phase 0

Phase 0 locks the architecture before code movement begins.

This document is the concrete design spec for the client networking and state rewrite. It exists so that any developer or LLM can pick up Phase 1 or later without re-deriving the architecture from scratch.

This phase is complete when:

- the target store graph is explicit
- the ownership model is explicit
- the transport contracts are explicit
- the deletion map is explicit
- later phases can implement without preserving old patterns

---

## Phase 0 Decisions

These decisions are locked in.

### 1. One State Authority Per Endpoint

Each configured server endpoint gets exactly one authoritative client state owner:

- `EndpointStore`

No other type is allowed to own canonical endpoint state.

### 2. One App-Level Projection Owner

Cross-endpoint UI state is projected by:

- `AppStore`

`AppStore` does not duplicate server entities. It derives them from endpoint stores.

### 3. REST and WebSocket Are Transports, Not Stores

- `APIClient` remains transport-only.
- `EventStream` remains transport-only.

Neither type mutates UI-facing state directly.

### 4. Views Never Talk to the Network

No SwiftUI view may call `APIClient` directly once migrated.

Views can:

- observe state
- send intents
- render operation status

Views cannot:

- fetch data
- mutate data directly
- reload after mutation
- coordinate replay or reconnect behavior

### 5. No Legacy Compatibility Paths

We are not preserving:

- direct view-to-API mutations
- `NotificationCenter`-driven state propagation
- copied aggregate session snapshots
- dual store ownership for the same entities
- bootstrap branches that exist only to paper over ambiguous contracts

---

## Locked Client Architecture

## Root Ownership

The root app owns:

- `AppStore`
- `ServerRuntimeRegistry` only if it is reduced to endpoint lifecycle/configuration orchestration

The root app does not inject an active endpoint `SessionStore` into the environment anymore.

### Proposed Root Graph

```swift
@MainActor
@Observable
final class AppStore {
  var endpoints: [UUID: EndpointStore] = [:]
  var selectedSessionRef: SessionRef?
  var dashboardFilter: UnifiedEndpointFilter = .all

  var dashboard: DashboardProjection { ... }
  var quickSwitcher: QuickSwitcherProjection { ... }
  var endpointHealth: [EndpointHealthProjection] { ... }

  func selectSession(_ ref: SessionRef) { ... }
  func endpointStore(for endpointId: UUID) -> EndpointStore? { ... }
}
```

```swift
@MainActor
@Observable
final class EndpointStore {
  let endpoint: ServerEndpoint
  let apiClient: APIClient
  let eventStream: EventStream

  var state: EndpointState

  func connect() { ... }
  func disconnect() { ... }
  func hydrateSessions() async { ... }
  func subscribe(sessionId: String) { ... }
  func unsubscribe(sessionId: String) { ... }

  // Intents
  func createSession(...) async throws { ... }
  func sendMessage(...) async throws { ... }
  func resolveApproval(...) async throws { ... }
  func createReviewComment(...) async throws { ... }
  func createWorktree(...) async throws { ... }
}
```

### Locked Ownership Rule

- `AppStore` owns endpoint stores.
- `EndpointStore` owns endpoint state.
- Domain state lives under `EndpointState`.
- Views and feature subviews never own canonical server state.

---

## Locked Domain State Layout

`EndpointState` is the only persistent state graph for one endpoint.

```swift
struct EndpointState {
  var connection: ConnectionState
  var serverInfo: ServerInfoState
  var sessionsIndex: SessionsIndexState
  var sessions: [String: SessionState]
  var conversations: [String: ConversationState]
  var approvals: [String: ApprovalState]
  var reviews: [String: ReviewState]
  var worktreesByRepoRoot: [String: WorktreeState]
  var account: AccountState
  var models: ModelsState
  var skills: [String: SkillsState]
  var mcp: [String: McpState]
  var subagents: [String: SubagentState]
  var shell: [String: ShellState]
}
```

### Session Domain

```swift
struct SessionState {
  var summary: SessionSummaryState
  var detail: SessionDetailState
  var lifecycle: SessionLifecycleState
  var operationState: SessionOperationState
  var revisions: SessionRevisionState
}
```

### Conversation Domain

```swift
struct ConversationState {
  var messages: [TranscriptMessage]
  var totalMessageCount: Int
  var oldestLoadedSequence: UInt64?
  var newestLoadedSequence: UInt64?
  var hasMoreHistoryBefore: Bool
  var loading: ConversationLoadingState
  var revision: UInt64?
}
```

### Approval Domain

```swift
struct ApprovalState {
  var pending: ServerApprovalRequest?
  var history: [ServerApprovalHistoryItem]
  var version: UInt64
  var operation: ApprovalOperationState
}
```

### Review Domain

```swift
struct ReviewState {
  var comments: [ServerReviewComment]
  var revision: UInt64?
  var operation: ReviewOperationState
}
```

### Worktree Domain

```swift
struct WorktreeState {
  var repoRoot: String
  var items: [ServerWorktreeSummary]
  var revision: UInt64?
  var operation: WorktreeOperationState
}
```

### Important Rule

If a field affects rendering, it must live in one domain state bucket. It cannot be copied into multiple client-owned caches as an optimization shortcut.

---

## Locked Intent Model

All mutating actions are store intents.

### Session Lifecycle Intents

- `createSession`
- `resumeSession`
- `takeoverSession`
- `endSession`
- `renameSession`
- `updateSessionConfig`
- `forkSession`
- `forkSessionToWorktree`
- `forkSessionToExistingWorktree`

### Conversation Intents

- `hydrateConversation`
- `loadOlderMessages`
- `sendMessage`
- `steerTurn`
- `interruptSession`
- `compactContext`
- `undoLastTurn`
- `rollbackTurns`
- `rewindFiles`

### Approval Intents

- `hydrateApprovalHistory`
- `approveTool`
- `answerQuestion`
- `deleteApproval`
- `markSessionRead`

### Review Intents

- `hydrateReviewComments`
- `createReviewComment`
- `updateReviewComment`
- `deleteReviewComment`

### Worktree Intents

- `hydrateWorktrees`
- `discoverWorktrees`
- `createWorktree`
- `removeWorktree`

### Secondary Intents

- models/account
- MCP
- skills
- permission rules
- shell
- subagent tools
- server role
- client primary claim

No phase is allowed to introduce a new networking path that bypasses an intent.

---

## Locked REST Contract Matrix

This is the Phase 0 classification for current API surface. Later phases implement against this matrix.

## Sessions and Conversation

| Endpoint | Contract | Initiating client updates from | Other clients update from |
|---|---|---|---|
| `GET /api/sessions` | hydrate | REST response | their own hydrate or replicated list events |
| `GET /api/sessions/{id}` | hydrate | REST response | n/a |
| `GET /api/sessions/{id}/conversation` | hydrate | REST response | n/a |
| `GET /api/sessions/{id}/messages` | hydrate | REST response | n/a |
| `POST /api/sessions` | response + replication | REST response summary | WS |
| `POST /api/sessions/{id}/resume` | response + replication | REST response summary | WS |
| `POST /api/sessions/{id}/takeover` | response + replication | REST response summary | WS |
| `PATCH /api/sessions/{id}/name` | response + replication | REST response summary/delta | WS |
| `PATCH /api/sessions/{id}/config` | response + replication | REST response summary/delta | WS |
| `POST /api/sessions/{id}/fork*` | response + replication | REST response summary | WS |
| `POST /api/sessions/{id}/end` | response + replication | REST response | WS |

## Turn and Conversation Actions

| Endpoint | Contract | Initiating client updates from | Other clients update from |
|---|---|---|---|
| `POST /api/sessions/{id}/messages` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/steer` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/interrupt` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/compact` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/undo` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/rollback` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/rewind-files` | accepted + eventual WS | WS | WS |
| `POST /api/sessions/{id}/stop-task` | accepted + eventual WS | WS | WS |

## Approvals

| Endpoint | Contract | Initiating client updates from | Other clients update from |
|---|---|---|---|
| `GET /api/approvals` | hydrate | REST response | n/a |
| `DELETE /api/approvals/{id}` | response + replication | REST response | WS |
| `POST /api/sessions/{id}/approve` | response + replication | REST response plus version | WS |
| `POST /api/sessions/{id}/answer` | response + replication | REST response plus version | WS |
| `POST /api/sessions/{id}/mark-read` | response + replication | REST response unread count | WS |

## Review

| Endpoint | Contract | Initiating client updates from | Other clients update from |
|---|---|---|---|
| `GET /api/sessions/{id}/review-comments` | hydrate | REST response | n/a |
| `POST /api/sessions/{id}/review-comments` | response + replication | REST response comment | WS |
| `PATCH /api/review-comments/{id}` | response + replication | REST response comment | WS |
| `DELETE /api/review-comments/{id}` | response + replication | REST response deleted identity | WS |

## Worktrees

| Endpoint | Contract | Initiating client updates from | Other clients update from |
|---|---|---|---|
| `GET /api/worktrees` | hydrate | REST response | n/a |
| `POST /api/worktrees/discover` | hydrate | REST response | n/a |
| `POST /api/worktrees` | response + replication | REST response worktree | WS |
| `DELETE /api/worktrees/{id}` | response + replication | REST response removed identity | WS |

## Secondary Domains

| Endpoint group | Contract |
|---|---|
| models/account/config reads | hydrate |
| models/account/config writes | response + replication when cross-client visible |
| skills/MCP reads | hydrate |
| skills/MCP refresh or toggle operations | response + replication or accepted + eventual WS, chosen explicitly per endpoint |
| shell execute/cancel | accepted + eventual WS |
| image upload/download | response-authoritative for upload metadata; hydrate for downloads |

---

## Locked WebSocket Event Taxonomy

The new client will reconcile against domain events, not legacy message shapes.

## Sessions

- `sessions_list_replaced`
- `session_upserted`
- `session_removed`
- `session_state_changed`

## Conversation

- `conversation_snapshot_replaced`
- `conversation_message_appended`
- `conversation_message_updated`
- `conversation_replayed`

## Approvals

- `approval_state_changed`
- `approval_history_deleted`

## Review

- `review_comment_created`
- `review_comment_updated`
- `review_comment_deleted`
- `review_comments_replaced`

## Worktrees

- `worktrees_replaced`
- `worktree_created`
- `worktree_updated`
- `worktree_removed`

## Secondary

- `models_replaced`
- `account_state_changed`
- `server_info_updated`
- `shell_started`
- `shell_completed`
- `skills_replaced`
- `mcp_state_changed`

### Locked Rule

If an event cannot be applied by a single domain reconciler without special-case cross-domain guessing, the event shape is wrong.

---

## Locked File and Type Direction

This is the proposed file structure for the rewrite.

```text
OrbitDock/OrbitDock/
├── State/
│   ├── AppStore.swift
│   ├── EndpointStore.swift
│   ├── EndpointState.swift
│   ├── Sessions/
│   │   ├── SessionsIndexState.swift
│   │   ├── SessionState.swift
│   │   ├── SessionReducers.swift
│   │   └── SessionIntents.swift
│   ├── Conversation/
│   │   ├── ConversationState.swift
│   │   ├── ConversationReducers.swift
│   │   └── ConversationIntents.swift
│   ├── Approvals/
│   ├── Review/
│   ├── Worktrees/
│   ├── Models/
│   ├── Account/
│   ├── MCP/
│   └── Skills/
└── Services/Server/
    ├── APIClient.swift
    ├── EventStream.swift
    └── ServerProtocol.swift
```

This file layout is allowed to evolve slightly, but the architectural boundaries are not allowed to collapse back into one giant store file.

---

## Deletion Map

These are current client artifacts that should not survive the rewrite as-is.

### Delete Entirely

- `OrbitDock/OrbitDock/Services/Server/UnifiedSessionsStore.swift`
- `Notification.Name.serverSessionsDidChange`
- core `NotificationCenter` session propagation paths

### Replace, Then Delete

- `OrbitDock/OrbitDock/Services/Server/SessionStore.swift`
- `OrbitDock/OrbitDock/Services/Server/ConversationStore.swift`
- active-endpoint-as-global-environment store injection pattern

### Remove Direct View Networking

These direct networking callsites are not allowed in the final architecture:

- worktree mutations in `WorktreeListView`
- review comment mutations in `ReviewCanvas`
- review/worktree mutation calls in `SessionDetailView`
- direct send-message calls after create session in `NewSessionSheet`

### Collapse Into Store Intents

- current view-managed refresh logic
- current manual "subscribe and then separately fetch related state" patterns
- current bootstrap branching in `subscribeToSession`

---

## Current-State Audit Notes That Drive This Design

These findings are why the rewrite is structured this way.

### Direct View Networking Exists Today

Current examples:

- direct worktree calls in `WorktreeListView`
- direct review comment calls in `ReviewCanvas`
- direct review/worktree calls in `SessionDetailView`

This means view behavior is coupled to server timing and hidden store assumptions. That is explicitly disallowed in the rewrite.

### Aggregation Is Currently Manual

`ContentView` currently reloads aggregate UI state from manual notifications instead of observing the true underlying stores directly.

That makes stale global UI likely whenever a state mutation path forgets to publish that notification.

### Some Current REST Endpoints Are Contractually Ambiguous

Examples in current code:

- worktree discover returns data but is often treated like a mutation
- worktree create returns data without guaranteed replication semantics
- review comment update/delete mutate state without guaranteed live replication

Phase 1 fixes the server contract so the new client does not need guesswork.

---

## Locked Testing Strategy for Later Phases

Every later phase must test with the following shape.

### Reducer and Reconciler Unit Tests

Use pure input/output tests for:

- revision gating
- stale event rejection
- list replacement
- upsert/delete logic
- projection logic

### Store Integration Tests

Use the real store with transport-boundary doubles only.

Good examples:

- "create review comment appears immediately for the initiating client and then replicates to another subscribed client"
- "reconnect with higher revision ignores stale replay frames"
- "approval decision clears the current request and promotes the next request when version allows"

Bad examples:

- "handleApprovalRequested calls helper X"
- "array count increments by one inside method Y"

### UI Tests

Reserve UI tests for high-value workflows:

- dashboard session visibility
- session detail conversation behavior
- approval overlays
- review canvas updates
- worktree sheet updates

Wait on visible state or deterministic events, not time.

---

## Phase 0 Checklist

- [x] Inventory every current REST endpoint and classify it.
- [x] Inventory every current WS event and define target domain ownership.
- [x] Define new store boundaries and ownership rules.
- [x] Define the new intent model.
- [x] Define the file/type direction for the rewrite.
- [x] Define the deletion map.
- [x] Define the rules later phases are not allowed to violate.

Phase 0 is complete.

---

## Next Phase Entry Condition

Phase 1 may begin only after this is accepted as the source of truth for the rewrite.

Phase 1 should not start by editing SwiftUI views. It should start by hardening server contracts so the new client can be built on top of explicit behavior instead of reverse-engineered behavior.
