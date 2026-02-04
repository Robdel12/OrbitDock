# Codex App-Server Full Integration Plan

> Transform OrbitDock into the ultimate Codex command center by leveraging every capability the app-server API provides.

## Current State

We have a working foundation:
- ✅ Thread create/resume/read/list (basic)
- ✅ Turn start/interrupt
- ✅ Model list
- ✅ Item events (messages, tools, files, MCP calls, web search)
- ✅ Approval submissions (exec, patch, userInput)
- ✅ Token usage and rate limit events (logged, not displayed)
- ✅ File logging for debugging (`~/.orbitdock/codex-server.log`)

---

## Tier 1: Polish & Quick Wins

### 1.1 Token Usage Display
**API**: `thread/tokenUsage/updated` event (already receiving)

Show real-time token consumption per session:
```
┌─────────────────────────────────────┐
│ Tokens: 12,450 / 128,000 (9.7%)    │
│ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ Input: 8,200 │ Output: 4,250       │
│ Cached: 2,100 (25% savings)        │
└─────────────────────────────────────┘
```

**Implementation**:
- Store `totalTokenUsage` in Session model or MessageStore
- Add `CodexTokenUsageView` component
- Display in session header or sidebar

**Files to modify**:
- `Session.swift` - Add token usage properties
- `DatabaseManager.swift` - Migration for token columns
- `CodexEventHandler.swift` - Update session on token events
- `SessionDetailView.swift` - Add usage display
- New: `Views/Codex/CodexTokenUsageView.swift`

---

### 1.2 Rate Limits Display
**API**: `account/rateLimits/updated` event (already receiving)

Show ChatGPT quota status:
```
┌─────────────────────────────────────┐
│ Rate Limits                         │
│ Primary (5h):   ████████░░ 78%     │
│ Secondary (7d): ██░░░░░░░░ 23%     │
│ Resets in: 2h 34m                   │
└─────────────────────────────────────┘
```

**Implementation**:
- Already have `CodexRateLimits` struct
- Add to session detail or global status bar
- Calculate reset time from `resetsAt` timestamp

**Files to modify**:
- `CodexEventHandler.swift` - Store rate limits
- `SessionDetailView.swift` or `HeaderView.swift` - Display
- New: `Views/Codex/CodexRateLimitsView.swift`

---

### 1.3 Model Picker
**API**: `model/list` (already implemented)

Let users choose model when creating sessions or per-turn:
```
┌─────────────────────────────────────┐
│ Model: ▼                            │
│ ┌─────────────────────────────────┐ │
│ │ ● o3 (default)                  │ │
│ │   o4-mini                       │ │
│ │   o4-mini-high                  │ │
│ │   gpt-4.1                       │ │
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

**Implementation**:
- Fetch models on session creation
- Store selected model in session
- Allow override per-turn (Tier 2)

**Files to modify**:
- `CodexAppServerClient.swift` - Already has `listModels()`
- New: `Views/Codex/CodexModelPicker.swift`
- `CodexNewSessionView.swift` - Add picker

---

### 1.4 MCP Server Status
**API**: `mcpServerStatus/list`

Show connected MCP servers and their tools:
```
┌─────────────────────────────────────┐
│ MCP Servers                         │
│ ● linear-server (connected)         │
│   Tools: 42 │ Resources: 3          │
│ ● github (connected)                │
│   Tools: 28 │ OAuth: ✓              │
│ ○ slack (failed)                    │
│   Error: Auth required              │
└─────────────────────────────────────┘
```

**New types needed**:
```swift
struct MCPServerStatusListResult: Decodable {
  let servers: [MCPServerInfo]
}

struct MCPServerInfo: Decodable {
  let name: String
  let state: String  // "connected", "starting", "failed"
  let error: String?
  let tools: [MCPTool]?
  let resources: [MCPResource]?
  let authStatus: MCPAuthStatus?
}
```

**Files to modify**:
- `CodexProtocol.swift` - Add MCP types
- `CodexAppServerClient.swift` - Add `listMCPServers()`
- New: `Views/Codex/MCPServerStatusView.swift`

---

## Tier 2: High Impact Features

### 2.1 Plan Visualization
**API**: `turn/plan/updated` event

This is the killer feature - show the agent's thinking in real-time:
```
┌─────────────────────────────────────┐
│ Agent Plan                          │
│ ✅ 1. Read existing test files      │
│ ✅ 2. Analyze test patterns         │
│ 🔄 3. Write new test cases          │
│    └─ Currently: Adding edge cases  │
│ ⏳ 4. Run test suite                │
│ ⏳ 5. Fix any failures              │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct TurnPlanUpdatedEvent: Decodable {
  let threadId: String?
  let plan: AgentPlan?
}

struct AgentPlan: Decodable {
  let steps: [PlanStep]
}

struct PlanStep: Decodable, Identifiable {
  let id: String
  let description: String
  let status: PlanStepStatus  // pending, inProgress, completed, failed
  let substeps: [PlanStep]?
}

enum PlanStepStatus: String, Decodable {
  case pending, inProgress, completed, failed
}
```

**Implementation**:
- Parse `turn/plan/updated` events
- Store current plan in MessageStore or separate PlanStore
- Display as collapsible view in session detail
- Animate status transitions

**Files to modify**:
- `CodexProtocol.swift` - Add plan types
- `CodexEventHandler.swift` - Handle plan events
- New: `Views/Codex/CodexPlanView.swift`
- `SessionDetailView.swift` - Integrate plan view

---

### 2.2 Aggregated Diff View
**API**: `turn/diff/updated` event

Show unified diff across ALL file changes in a turn:
```
┌─────────────────────────────────────┐
│ Changes in this turn (3 files)      │
├─────────────────────────────────────┤
│ src/api/auth.ts        +42  -12    │
│ src/utils/validate.ts  +18  -3     │
│ tests/auth.test.ts     +85  -0     │
├─────────────────────────────────────┤
│ [View Unified Diff] [Apply All]    │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct TurnDiffUpdatedEvent: Decodable {
  let threadId: String?
  let turnId: String?
  let diff: String?  // Unified diff format
  let files: [DiffFileSummary]?
}

struct DiffFileSummary: Decodable {
  let path: String
  let additions: Int
  let deletions: Int
  let status: String  // added, modified, deleted
}
```

**Implementation**:
- Parse diff events
- Store aggregated diff per turn
- Syntax-highlighted diff viewer
- File tree with change indicators

**Files to modify**:
- `CodexProtocol.swift` - Add diff types
- `CodexEventHandler.swift` - Handle diff events
- New: `Views/Codex/CodexDiffView.swift`
- New: `Views/Codex/DiffSyntaxHighlighter.swift`

---

### 2.3 Thread Archive Management
**API**: `thread/archive`, `thread/unarchive`

Archive old sessions, restore when needed:
```
┌─────────────────────────────────────┐
│ Session Actions                     │
│ [Archive Session]                   │
│ [View Archived Sessions]            │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Archived Sessions (23)              │
│ ○ Auth refactor - 3 days ago        │
│ ○ Bug fix #142 - 1 week ago         │
│ ○ API migration - 2 weeks ago       │
│ [Restore] [Delete Permanently]      │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct ThreadArchiveParams: Codable {
  let threadId: String
}

struct ThreadArchiveResult: Decodable {
  let success: Bool
}
```

**Implementation**:
- Add archive/unarchive methods to client
- Update session list filtering
- Add archive UI in session actions
- Archived sessions view

**Files to modify**:
- `CodexProtocol.swift` - Add archive types
- `CodexAppServerClient.swift` - Add archive methods
- `CodexDirectSessionManager.swift` - Archive/unarchive logic
- New: `Views/Codex/ArchivedSessionsView.swift`

---

### 2.4 Per-Turn Configuration Overrides
**API**: `turn/start` with config overrides

Allow adjusting settings per-message:
```
┌─────────────────────────────────────┐
│ Message Options (optional)          │
│ Model: [o3 ▼] Effort: [medium ▼]   │
│ Sandbox: [workspace-write ▼]        │
└─────────────────────────────────────┘
│ Type your message...                │
│                          [Send ➤]   │
└─────────────────────────────────────┘
```

**Extended TurnStartParams**:
```swift
struct TurnStartParams: Codable {
  let threadId: String
  let input: [UserInputItem]

  // Optional overrides
  let model: String?
  let effort: String?  // "low", "medium", "high"
  let cwd: String?
  let sandboxPolicy: SandboxPolicy?
  let summaryStyle: String?
}
```

**Implementation**:
- Extend input bar with optional config
- Collapsible "advanced options" section
- Pass overrides to turn/start

**Files to modify**:
- `CodexProtocol.swift` - Extend TurnStartParams
- `CodexInputBar.swift` - Add config options
- `CodexDirectSessionManager.swift` - Pass overrides

---

## Tier 3: Power Features

### 3.1 Thread Fork
**API**: `thread/fork`

Branch a conversation to try alternatives:
```
┌─────────────────────────────────────┐
│ Fork Session                        │
│                                     │
│ Create a branch from turn 5?        │
│ This lets you try a different       │
│ approach without losing progress.   │
│                                     │
│ [Cancel]              [Fork →]      │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct ThreadForkParams: Codable {
  let threadId: String
  let afterTurnIndex: Int?  // Fork point
}

struct ThreadForkResult: Decodable {
  let thread: ThreadInfo  // New forked thread
}
```

**Implementation**:
- Add fork button to session actions
- Show fork point selector (which turn)
- Create new session linked to parent
- Visual indicator of forked sessions

**Files to modify**:
- `CodexProtocol.swift` - Add fork types
- `CodexAppServerClient.swift` - Add `forkThread()`
- `Session.swift` - Add `forkedFromId` property
- `DatabaseManager.swift` - Migration for fork tracking
- New: `Views/Codex/ThreadForkView.swift`

---

### 3.2 Thread Rollback
**API**: `thread/rollback`

Undo turns when things go wrong:
```
┌─────────────────────────────────────┐
│ Rollback Session                    │
│                                     │
│ Undo the last 2 turns?              │
│ This will remove:                   │
│ • Turn 7: "Add error handling"      │
│ • Turn 6: "Refactor auth module"    │
│                                     │
│ ⚠️ This cannot be undone            │
│                                     │
│ [Cancel]           [Rollback →]     │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct ThreadRollbackParams: Codable {
  let threadId: String
  let turns: Int  // Number of turns to rollback
}

struct ThreadRollbackResult: Decodable {
  let success: Bool
  let remainingTurns: Int
}
```

**Implementation**:
- Add rollback option to session actions
- Show preview of what will be removed
- Confirmation dialog with warning
- Update local message store after rollback

**Files to modify**:
- `CodexProtocol.swift` - Add rollback types
- `CodexAppServerClient.swift` - Add `rollbackThread()`
- `CodexDirectSessionManager.swift` - Rollback logic
- `MessageStore.swift` - Remove rolled-back messages
- New: `Views/Codex/ThreadRollbackView.swift`

---

### 3.3 Code Review Mode
**API**: `review/start`

Run Codex reviewer for code changes:
```
┌─────────────────────────────────────┐
│ Start Code Review                   │
│                                     │
│ Review Target:                      │
│ ● Uncommitted changes               │
│ ○ Branch diff (vs main)             │
│ ○ Specific commit                   │
│ ○ Custom diff                       │
│                                     │
│ [Cancel]         [Start Review →]   │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct ReviewStartParams: Codable {
  let threadId: String
  let target: ReviewTarget
}

enum ReviewTarget: Codable {
  case uncommittedChanges
  case baseBranch(String)
  case commit(String)
  case custom(diff: String)
}

struct ReviewStartResult: Decodable {
  let reviewId: String
}
```

**Implementation**:
- Add "Review" button to session actions
- Target picker UI
- Review results display (findings, suggestions)
- Integration with existing message view

**Files to modify**:
- `CodexProtocol.swift` - Add review types
- `CodexAppServerClient.swift` - Add `startReview()`
- New: `Views/Codex/CodeReviewView.swift`
- New: `Views/Codex/ReviewTargetPicker.swift`

---

### 3.4 Skills Management
**API**: `skills/list`, `skills/config/write`

Discover and toggle available skills:
```
┌─────────────────────────────────────┐
│ Available Skills                    │
│                                     │
│ ✓ git-commit      Built-in          │
│ ✓ review-pr       Built-in          │
│ ○ deploy          Custom            │
│ ✓ run-tests       Project           │
│                                     │
│ Skill Details:                      │
│ git-commit: Create commits with     │
│ conventional commit format          │
│                                     │
│ [Save Changes]                      │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct SkillsListParams: Codable {
  let cwd: String?
}

struct SkillsListResult: Decodable {
  let skills: [Skill]
}

struct Skill: Decodable, Identifiable {
  let id: String
  let name: String
  let description: String?
  let source: SkillSource  // builtin, project, user
  let enabled: Bool
  let path: String?
}

struct SkillConfigWriteParams: Codable {
  let path: String
  let enabled: Bool
}
```

**Implementation**:
- Skills list view with toggle switches
- Group by source (built-in, project, user)
- Skill detail view with description
- Enable/disable persistence

**Files to modify**:
- `CodexProtocol.swift` - Add skill types
- `CodexAppServerClient.swift` - Add skill methods
- New: `Views/Codex/SkillsManagerView.swift`
- New: `Views/Codex/SkillDetailView.swift`

---

### 3.5 Sandbox Policy Picker
**API**: `thread/start` and `turn/start` with `sandboxPolicy`

Let users choose security posture:
```
┌─────────────────────────────────────┐
│ Sandbox Policy                      │
│                                     │
│ ○ Read Only                         │
│   Agent can only read files         │
│                                     │
│ ● Workspace Write (recommended)     │
│   Write within project directory    │
│                                     │
│ ○ Full Access ⚠️                    │
│   Unrestricted system access        │
│                                     │
│ Advanced:                           │
│ □ Network access                    │
│ Writable roots: [+ Add path]        │
└─────────────────────────────────────┘
```

**Implementation**:
- Sandbox picker component
- Integration with session creation
- Per-turn override option
- Warning dialogs for dangerous policies

**Files to modify**:
- `CodexProtocol.swift` - Already has SandboxPolicy
- New: `Views/Codex/SandboxPolicyPicker.swift`
- `CodexNewSessionView.swift` - Integrate picker
- `CodexInputBar.swift` - Per-turn override

---

## Tier 4: Complete Experience

### 4.1 Configuration UI
**API**: `config/read`, `config/value/write`, `config/batchWrite`

View and edit Codex configuration from OrbitDock:
```
┌─────────────────────────────────────┐
│ Codex Configuration                 │
│                                     │
│ General                             │
│ Default Model: [o3 ▼]              │
│ Approval Policy: [unless-trusted ▼]│
│                                     │
│ Sandbox                             │
│ Default Policy: [workspace-write ▼]│
│ Network Access: [✓]                 │
│                                     │
│ MCP Servers                         │
│ [Configure MCP →]                   │
│                                     │
│ [Reset to Defaults] [Save]          │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct ConfigReadResult: Decodable {
  let config: CodexConfig
}

struct CodexConfig: Decodable {
  let model: String?
  let approvalPolicy: String?
  let sandboxPolicy: SandboxPolicy?
  let mcpServers: [String: MCPServerConfig]?
}

struct ConfigValueWriteParams: Codable {
  let key: String
  let value: AnyCodable
}
```

**Files to modify**:
- `CodexProtocol.swift` - Add config types
- `CodexAppServerClient.swift` - Add config methods
- New: `Views/Codex/CodexConfigView.swift`

---

### 4.2 Collaboration Modes
**API**: `collaborationMode/list`

Different interaction styles:
```
┌─────────────────────────────────────┐
│ Collaboration Mode                  │
│                                     │
│ ● Standard                          │
│   Normal conversational coding      │
│                                     │
│ ○ Pair Programming                  │
│   Step-by-step with explanations    │
│                                     │
│ ○ Review Mode                       │
│   Focus on code review feedback     │
│                                     │
│ ○ Teaching Mode                     │
│   Detailed explanations, learning   │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct CollaborationModeListResult: Decodable {
  let modes: [CollaborationMode]
}

struct CollaborationMode: Decodable, Identifiable {
  let id: String
  let name: String
  let description: String?
}
```

**Files to modify**:
- `CodexProtocol.swift` - Add collaboration mode types
- `CodexAppServerClient.swift` - Add `listCollaborationModes()`
- New: `Views/Codex/CollaborationModePicker.swift`

---

### 4.3 Quick Command Execution
**API**: `command/exec`

Run single commands without creating a thread:
```
┌─────────────────────────────────────┐
│ Quick Command                       │
│ ┌─────────────────────────────────┐ │
│ │ npm run test                    │ │
│ └─────────────────────────────────┘ │
│ Working Dir: /Users/rob/project     │
│ Sandbox: [workspace-write ▼]        │
│                      [Execute ➤]    │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct CommandExecParams: Codable {
  let command: [String]
  let cwd: String
  let sandboxPolicy: SandboxPolicy?
}

struct CommandExecResult: Decodable {
  let exitCode: Int
  let stdout: String?
  let stderr: String?
}
```

**Files to modify**:
- `CodexProtocol.swift` - Add command exec types
- `CodexAppServerClient.swift` - Add `execCommand()`
- New: `Views/Codex/QuickCommandView.swift`

---

### 4.4 Feedback Submission
**API**: `feedback/upload`

Report issues directly from OrbitDock:
```
┌─────────────────────────────────────┐
│ Submit Feedback                     │
│                                     │
│ Classification:                     │
│ ○ Bug Report                        │
│ ● Feature Request                   │
│ ○ Performance Issue                 │
│ ○ Other                             │
│                                     │
│ Description:                        │
│ ┌─────────────────────────────────┐ │
│ │ It would be great if...         │ │
│ └─────────────────────────────────┘ │
│                                     │
│ □ Include session logs              │
│                                     │
│ [Cancel]              [Submit →]    │
└─────────────────────────────────────┘
```

**New types**:
```swift
struct FeedbackUploadParams: Codable {
  let classification: String
  let reason: String?
  let includeLogs: Bool?
}

struct FeedbackUploadResult: Decodable {
  let success: Bool
  let feedbackId: String?
}
```

**Files to modify**:
- `CodexProtocol.swift` - Add feedback types
- `CodexAppServerClient.swift` - Add `submitFeedback()`
- New: `Views/Codex/FeedbackView.swift`

---

## Implementation Order

### Phase 1: Foundation Polish (Week 1)
1. Token usage display (1.1)
2. Rate limits display (1.2)
3. Model picker (1.3)
4. MCP server status (1.4)

### Phase 2: Core Features (Week 2)
5. Plan visualization (2.1) ⭐ High priority
6. Aggregated diff view (2.2)
7. Thread archive management (2.3)
8. Per-turn config overrides (2.4)

### Phase 3: Power User (Week 3)
9. Thread fork (3.1)
10. Thread rollback (3.2)
11. Code review mode (3.3)
12. Sandbox policy picker (3.5)

### Phase 4: Complete Experience (Week 4)
13. Skills management (3.4)
14. Configuration UI (4.1)
15. Collaboration modes (4.2)
16. Quick command execution (4.3)
17. Feedback submission (4.4)

---

## Testing Strategy

### Unit Tests
- Protocol encoding/decoding
- Event parsing for all new event types
- State machine transitions

### Integration Tests
- Mock app-server for E2E flows
- Plan updates → UI updates
- Fork/rollback → message sync

### Manual Testing Checklist
- [ ] Token usage updates in real-time
- [ ] Rate limit warnings appear correctly
- [ ] Model picker shows available models
- [ ] Plan view animates step progress
- [ ] Diff view syntax highlights correctly
- [ ] Archive/unarchive round-trips
- [ ] Fork creates linked session
- [ ] Rollback removes correct turns
- [ ] Review mode produces findings
- [ ] Skills toggle persists
- [ ] Config changes apply

---

## UI/UX Considerations

### Design Principles
- Progressive disclosure: Advanced features hidden by default
- Contextual actions: Show relevant options based on state
- Real-time feedback: Animate state changes
- Error recovery: Clear paths when things fail

### Accessibility
- VoiceOver labels for all interactive elements
- Keyboard navigation for all features
- High contrast mode support
- Reduce motion option

### Performance
- Lazy load heavy views (diff viewer, skills list)
- Debounce rapid event updates
- Virtualize long lists
- Cache model/skill lists

---

## Migration Notes

### Database Schema Updates
```sql
-- Token tracking
ALTER TABLE sessions ADD COLUMN codex_input_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN codex_output_tokens INTEGER;
ALTER TABLE sessions ADD COLUMN codex_cached_tokens INTEGER;

-- Fork tracking
ALTER TABLE sessions ADD COLUMN forked_from_session_id TEXT;
ALTER TABLE sessions ADD COLUMN fork_turn_index INTEGER;

-- Archive status (synced from server)
ALTER TABLE sessions ADD COLUMN codex_archived INTEGER DEFAULT 0;
```

### Backwards Compatibility
- All new features are additive
- Existing sessions continue to work
- New columns have sensible defaults
