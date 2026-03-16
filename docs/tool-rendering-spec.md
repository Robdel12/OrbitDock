# Tool Rendering Specification

Source-of-truth contract for all provider tool types. Defines data contracts, display tiers, rendering specs, and visual design for both compact and expanded states.

Both providers (Claude and Codex) normalize to this shared protocol via `ToolFamily` + `ToolKind` enums.

## Wire Contract

Tool rows on the wire use `ToolRowSummary` — **no raw invocation/result payloads**. The server computes a `ToolDisplay` struct with all rendering metadata (summary, subtitle, glyph, output preview, diff preview, display tier, tool type). The client renders from `ToolDisplay` directly with zero tool-specific branching for compact cards.

Expanded view content is fetched on demand via REST `GET /rows/{id}/content` → `ServerRowContent { inputDisplay, outputDisplay, diffDisplay: [DiffLine]?, language, startLine: u32? }`.

The "Invocation Payload" and "Result Payload" tables below describe the **server-internal** data shapes used to compute `ToolDisplay`. They are not sent on the wire.

---

## Terminology

| Term | Definition |
|------|-----------|
| **ToolKind** | Fine-grained tool identifier (e.g., `Bash`, `Read`, `Edit`). Drives rendering dispatch. |
| **ToolFamily** | Semantic category grouping (e.g., `Shell`, `FileRead`, `FileChange`). Used for color/icon defaults. |
| **Display Tier** | Visual weight: `prominent` > `standard` > `compact` > `minimal`. Controls padding, font size, background tint. |
| **Compact Card** | Collapsed single-line row: icon + summary + metadata + chevron. Always visible in timeline. |
| **Inline Preview** | Optional strip below compact card showing live/output preview. Visible when collapsed. |
| **Expanded View** | Full content view shown on tap. Content fetched on-demand via REST (`ServerRowContent`). |
| **`tool_type`** | String dispatch key sent from server in `ToolDisplay`. Maps to client-side `@ViewBuilder` switch. |

## Display Tiers

| Tier | Padding | Font Size | Background | Used By |
|------|---------|-----------|------------|---------|
| `prominent` | Full | Standard | Accent-tinted | AskUserQuestion |
| `standard` | Full | Standard | Card default | Bash, Edit, Write, Agent, WebSearch, WebFetch, MCP, Handoff, Image |
| `compact` | Reduced | Standard | Card default | Read, Glob, Grep, ToolSearch |
| `minimal` | Minimal | Smaller icon | Card default | Plan (Enter/Exit/Update), Todo, CompactContext, Hook, Config, TaskOutput, TaskStop |

## Status Lifecycle

All tools progress through: `pending` → `running` → `completed` | `failed` | `cancelled` | `blocked` | `needsInput`

**Universal status rendering:**
- **Pending**: Idle, no special indicator
- **Running**: `ProgressView` spinner in compact header, type-specific "alive" indicator in expanded
- **Completed**: Duration badge in right meta, green checkmark where applicable
- **Failed**: Red edge bar stroke, `feedbackNegative` tint on error content, exit code or error message surfaced
- **Cancelled/Blocked**: Gray indicators

---

## Tool Catalog

### 1. Bash

| Field | Value |
|-------|-------|
| ToolKind | `Bash` |
| ToolFamily | `Shell` |
| tool_type | `"bash"` |
| Display Tier | Standard |
| Accent | `Color.toolBash` |
| Glyph | `terminal` |
| Summary Font | Monospace |
| Client View | `BashExpandedView` |

**Invocation Payload** (`CommandExecutionPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `command` | `String` | Shell command to execute |
| `cwd` | `String?` | Working directory |
| `input` | `String?` | Stdin input |

**Result Payload** (`CommandExecutionPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `output` | `String?` | Stdout/stderr combined |
| `exit_code` | `i32?` | Process exit code (0 = success) |

**Compact Card:**
- `terminal` icon + command as monospace subtitle (truncated to ~80 chars) + duration badge
- Running: pulsing green dot + last live output line
- Failed: red `EXIT N` pill inline

**Inline Preview:**
- Running: `liveOutputStrip` — green dot + last output line, monospace
- Completed: `outputPreviewStrip` — first line of output, monospace
- Failed: last error line in `feedbackNegative` tint

**Expanded View:**
- Slim `TerminalChrome` (~18pt) with CWD in center (graceful nil)
- `$ command` with bash syntax highlighting, continuous with chrome
- "Output" section: label + line count badge + exit code pill. ANSI-parsed content. Truncate >50 lines with "Show all N lines" disclosure.
- Failed: red exit code pill, red-tinted output bg
- Running: pulsing left edge, ProgressView until output arrives

---

### 2. Read

| Field | Value |
|-------|-------|
| ToolKind | `Read` |
| ToolFamily | `FileRead` |
| tool_type | `"read"` |
| Display Tier | Compact |
| Accent | `Color.toolRead` |
| Glyph | `doc.plaintext` |
| Summary Font | System |
| Client View | `ReadExpandedView` |

**Invocation Payload** (`FileReadPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `path` | `String?` | Absolute file path |
| `language` | `String?` | Detected language |

**Result Payload** (`FileReadPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `content` | `String?` | File contents (may include line numbers) |

**Server `ServerRowContent` extras for Read:**
| Field | Type | Description |
|-------|------|-------------|
| `start_line` | `u32?` | First line number (extracted from `cat -n` format). Defaults to 1 if absent. |

**Compact Card:**
- `doc.plaintext` icon + filename (last 2 path segments) + language badge + "N lines" right meta

**Expanded View:**
- `FileTabHeader`: language icon + full path + language capsule + "N lines" badge
- Line-numbered syntax-highlighted content with gutter divider
- Alternating stripe banding every 5 lines
- Partial content: "Showing lines 1-100 of 2000" indicator when offset/limit present

---

### 3. Edit

| Field | Value |
|-------|-------|
| ToolKind | `Edit` |
| ToolFamily | `FileChange` |
| tool_type | `"edit"` |
| Display Tier | Standard |
| Accent | `Color.toolWrite` |
| Glyph | `pencil.line` |
| Summary Font | System |
| Client View | `EditExpandedView` |

**Invocation Payload** (`FileChangePayload`):
| Field | Type | Description |
|-------|------|-------------|
| `path` | `String?` | File path being edited |
| `diff` | `String?` | Unified diff |
| `summary` | `String?` | Human-readable change summary |
| `additions` | `u32?` | Lines added |
| `deletions` | `u32?` | Lines removed |

**Compact Card:**
- `pencil.line` icon + filename + `MicroDiffStatsBar` + language badge
- Inline: `diffPreviewStrip` — first changed line + `+N -M` stats

**Expanded View:**
- `FileTabHeader` with "NEW FILE" green badge when all-additions (no deletions)
- `DiffStatsBar` (proportional green/red bar)
- Diff lines with edge bar coloring, `+/-` prefix, word-level diff highlighting
- Hunk separators (`···`) between discontinuous diff regions
- Syntax highlighting within diff lines

---

### 4. Write

| Field | Value |
|-------|-------|
| ToolKind | `Write` |
| ToolFamily | `FileChange` |
| tool_type | `"write"` |
| Display Tier | Standard |
| Accent | `Color.feedbackPositive` |
| Glyph | `doc.badge.plus` |
| Summary Font | System |
| Client View | `WriteExpandedView` |

**Invocation Payload** (`FileChangePayload`):
| Field | Type | Description |
|-------|------|-------------|
| `path` | `String?` | File path being created |
| `diff` | `String?` | Content as all-additions diff |

**Compact Card:**
- `doc.badge.plus` icon (green) + filename + "NEW" green capsule badge + language badge

**Expanded View:**
- `FileTabHeader` with green icon + "NEW FILE" badge + language capsule
- Content rendered as clean code (NOT `+`-prefixed diff). Line numbers + syntax highlighting, same as Read.
- Stats footer: "Created · N lines · Language"

**Note:** Server must send `tool_type: "write"` (not `"edit"`) for Write tools. Requires `tool_display.rs` change.

---

### 5. NotebookEdit

| Field | Value |
|-------|-------|
| ToolKind | `NotebookEdit` |
| ToolFamily | `FileChange` |
| tool_type | `"edit"` |
| Display Tier | Standard |
| Accent | `Color.toolWrite` |
| Glyph | `rectangle.split.3x1` |
| Client View | `EditExpandedView` |

Uses `EditExpandedView` with notebook-specific `FileTabHeader` icon. The `.ipynb` extension triggers `rectangle.split.3x1` glyph. Diff rendering is identical to Edit.

---

### 6. Glob

| Field | Value |
|-------|-------|
| ToolKind | `Glob` |
| ToolFamily | `Search` |
| tool_type | `"glob"` |
| Display Tier | Compact |
| Accent | `Color.toolSearch` |
| Glyph | `folder.badge.gearshape` |
| Summary Font | System |
| Client View | `GlobExpandedView` |

**Invocation Payload** (`SearchInvocationPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `query` | `String` | Glob pattern (e.g., `**/*.swift`) |
| `scope` | `String?` | Search scope/base directory |

**Result Payload** (`SearchResultPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `matches` | `Vec<String>` | Matching file paths |
| `total_matches` | `u32?` | Total match count |

**Compact Card:**
- `folder.badge.gearshape` icon + pattern (wildcard segments highlighted in accent) + "N matches" badge

**Expanded View:**
- Pattern header with highlighted wildcards + scope directory
- `FileTypeDistributionBar` — segmented proportional bar by file extension, color-coded by language
- Collapsible file tree with indentation guides, file count badges per directory
- "Collapse all" / "Expand all" toggle

---

### 7. Grep

| Field | Value |
|-------|-------|
| ToolKind | `Grep` |
| ToolFamily | `Search` |
| tool_type | `"grep"` |
| Display Tier | Compact |
| Accent | `Color.toolSearch` |
| Glyph | `magnifyingglass` |
| Summary Font | System |
| Client View | `GrepExpandedView` |

**Invocation Payload** (`SearchInvocationPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `query` | `String` | Search pattern (regex) |
| `scope` | `String?` | Search scope |

**Result Payload** (`SearchResultPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `matches` | `Vec<String>` | Matching lines (`file:line:content` format) |
| `total_matches` | `u32?` | Total match count |

**Compact Card:**
- `magnifyingglass` icon + pattern + "N results" badge

**Expanded View:**
- `SearchBarVisual` with "N matches in M files" count
- Results grouped by file, collapsible with match count badge per file
- Groups sorted by match count (most matches first)
- Pattern highlighting in matching lines

---

### 8. ToolSearch

| Field | Value |
|-------|-------|
| ToolKind | `ToolSearch` |
| ToolFamily | `Search` |
| tool_type | `"toolSearch"` |
| Display Tier | Compact |
| Accent | `Color.toolMcp` |
| Glyph | `puzzlepiece.extension` |
| Client View | `ToolSearchExpandedView` |

**Compact Card:**
- `puzzlepiece.extension` icon + query + "N tools" badge

**Expanded View:**
- `SearchBarVisual` + tool cards with icon/name/description
- Category pills: "Built-in" (blue) vs "MCP" (purple)

---

### 9. WebSearch

| Field | Value |
|-------|-------|
| ToolKind | `WebSearch` |
| ToolFamily | `Web` |
| tool_type | `"webSearch"` |
| Display Tier | Standard |
| Accent | `Color.toolWeb` |
| Glyph | `globe` |
| Client View | `WebSearchExpandedView` |

**Invocation Payload** (`WebSearchPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `query` | `String` | Search query |

**Result Payload** (`WebSearchPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `results` | `Vec<String>` | Search results (JSON or text blocks) |

**Compact Card:**
- `magnifyingglass.circle` icon + query + "N results" badge

**Expanded View:**
- `SearchBarVisual` with result count
- Result cards: domain badge + numbered title + query-highlighted snippet + truncated URL
- Edge-barred card layout with `toolWeb` accent
- Running: shimmer placeholder cards

---

### 10. WebFetch

| Field | Value |
|-------|-------|
| ToolKind | `WebFetch` |
| ToolFamily | `Web` |
| tool_type | `"webFetch"` |
| Display Tier | Standard |
| Accent | `Color.toolWeb` |
| Glyph | `globe` |
| Client View | `WebFetchExpandedView` |

**Invocation Payload** (`WebFetchPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `url` | `String` | URL to fetch |
| `title` | `String?` | Page title |

**Result Payload** (`WebFetchPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `content` | `String?` | Page content |

**Compact Card:**
- `globe` icon + domain extracted from URL + content length indicator

**Expanded View:**
- `URLBarVisual` with lock icon, bold host, gray path
- Response metadata strip: "~N KB"
- Content-type-aware rendering: JSON → `JSONTreeView`, markdown → body text, else monospace

---

### 11. Agent (SpawnAgent)

| Field | Value |
|-------|-------|
| ToolKind | `SpawnAgent` |
| ToolFamily | `Agent` |
| tool_type | `"task"` |
| Display Tier | Standard |
| Accent | `Color.toolTask` (per-type: Explore=`toolSearch`, Plan=`toolPlan`) |
| Glyph | `bolt.fill` |
| Client View | `TaskExpandedView` |
| Sub-kinds | `SendAgentInput`, `ResumeAgent`, `WaitAgent`, `CloseAgent` — all map to `tool_type: "task"` |

**Invocation Payload** (`WorkerInvocationPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `worker_id` | `String?` | Unique agent ID |
| `label` | `String?` | Display label |
| `agent_type` | `String?` | "Explore", "Plan", "general-purpose" |
| `task_summary` | `String?` | Brief description |
| `input` | `String?` | Full prompt/instructions |

Additional fields from raw invocation JSON:
| Field | Type | Description |
|-------|------|-------------|
| `description` | `String?` | Agent task description |
| `prompt` | `String?` | Full agent prompt |
| `model` | `String?` | Model override ("sonnet", "opus", "haiku") |
| `run_in_background` | `Bool?` | Background execution flag |
| `isolation` | `String?` | "worktree" for isolated git worktree |

**Result Payload** (`WorkerResultPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `worker_id` | `String?` | Agent ID |
| `summary` | `String?` | Result summary |
| `output` | `String?` | Full result output |

**Compact Card:**
- Agent type colored badge (Explore/Plan/General) + description + status dot + duration

**Expanded View:**
- Identity header: agent type badge + icon + status indicator + metadata pills (worktree, background, model, duration)
- Mission section: left-edge-barred prompt display. Truncate >5 lines with "Show full prompt" disclosure.
- Result section: smart rendering — JSON → `JSONTreeView`, prose → body font (not monospace)
- Running: pulsing status dot, elapsed time counter after 5s

---

### 12. AskUserQuestion

| Field | Value |
|-------|-------|
| ToolKind | `AskUserQuestion` |
| ToolFamily | `Question` |
| tool_type | `"question"` |
| Display Tier | Prominent |
| Accent | `Color.toolQuestion` |
| Glyph | `questionmark.bubble` |
| Client View | `QuestionExpandedView` |

**Invocation Payload** (`QuestionToolPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `question_id` | `String?` | Unique question identifier |
| `prompt` | `String?` | The question text |

**Result Payload** (`QuestionToolPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `response` | `Value?` | User's response (JSON) |

**Compact Card:**
- `questionmark.bubble` icon + question text (truncated) + answered/pending indicator
- Prominent tier: accent-tinted background

**Expanded View:**
- Question: `toolQuestion`-tinted bubble with left edge bar, body font
- Answered: green checkmark badge, response in `statusReply`-tinted bubble
- Pending: pulsing amber dot, "Awaiting response..." placeholder
- Connecting vertical line between Q and A sections

---

### 13. EnterPlanMode

| Field | Value |
|-------|-------|
| ToolKind | `EnterPlanMode` |
| ToolFamily | `Plan` |
| tool_type | `"plan"` |
| Display Tier | Minimal |
| Accent | `Color.toolPlan` |
| Glyph | `map` |
| Client View | `PlanExpandedView` (enter branch) |

**Invocation Payload** (`PlanModePayload`):
| Field | Type | Description |
|-------|------|-------------|
| `mode` | `String?` | Plan mode type |
| `summary` | `String?` | Planning summary |
| `explanation` | `String?` | Why entering plan mode |

**Compact Card:**
- `map` icon + "Entering Plan Mode" + `toolPlan` tint

**Expanded View:**
- "PLANNING PHASE" banner with left edge bar
- Allowed tools/prompts list if available
- Summary/explanation text

---

### 14. ExitPlanMode

| Field | Value |
|-------|-------|
| ToolKind | `ExitPlanMode` |
| ToolFamily | `Plan` |
| tool_type | `"plan"` |
| Display Tier | Minimal |
| Accent | `Color.feedbackPositive` |
| Glyph | `checkmark.circle` |
| Client View | `PlanExpandedView` (exit branch) |

**Invocation Payload** (`PlanModePayload`):
| Field | Type | Description |
|-------|------|-------------|
| `mode` | `String?` | Plan mode type |
| `summary` | `String?` | Plan completion summary |

**Compact Card:**
- `checkmark.circle` icon + "Plan Complete" + green accent

**Expanded View:**
- "PLAN EXECUTED" banner with checkmark, green-tinted bg
- Plan file path breadcrumb if available
- Plan content preview (first ~10 lines with disclosure)

---

### 15. UpdatePlan

| Field | Value |
|-------|-------|
| ToolKind | `UpdatePlan` |
| ToolFamily | `Plan` |
| tool_type | `"plan"` |
| Display Tier | Minimal |
| Accent | `Color.toolPlan` |
| Glyph | `map` |
| Client View | `PlanExpandedView` (update branch) |

**Invocation Payload** (`PlanModePayload`):
| Field | Type | Description |
|-------|------|-------------|
| `steps` | `Vec<PlanStepPayload>` | Plan steps with status |

**PlanStepPayload**:
| Field | Type | Description |
|-------|------|-------------|
| `id` | `String?` | Step identifier |
| `title` | `String` | Step description |
| `status` | `PlanStepStatus` | `Pending`, `InProgress`, `Completed`, `Failed`, `Cancelled` |
| `detail` | `String?` | Additional detail |

**Compact Card:**
- `map` icon + "Step 3/7" progress + mini progress bar

**Expanded View:**
- `ProgressSummaryBar`: "3 of 7 complete"
- Timeline step list with vertical connecting line:
  - Completed: `checkmark.circle.fill` green
  - In-progress: `circle.dotted` cyan with glow
  - Pending: `circle` gray

---

### 16. TodoWrite

| Field | Value |
|-------|-------|
| ToolKind | `TodoWrite` |
| ToolFamily | `Todo` |
| tool_type | `"todo"` |
| Display Tier | Minimal |
| Accent | `Color.toolTodo` |
| Glyph | `checklist` |
| Client View | `TodoExpandedView` |

**Invocation Payload** (`TodoPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `operation` | `String?` | "create", "update", "delete" |
| `items` | `Vec<TodoItemPayload>` | Todo items |

**TodoItemPayload**:
| Field | Type | Description |
|-------|------|-------------|
| `content` | `String` | Item text |
| `status` | `String?` | "pending", "in_progress", "completed" |
| `priority` | `String?` | "high", "medium", "low" |

**Compact Card:**
- `checklist` icon + "3/5 done" progress + micro progress bar

**Expanded View:**
- Operation header: "Updated 2 items" / "Added 3 items"
- `ProgressSummaryBar` color-segmented
- Items ordered: in-progress → pending → completed (muted)
- Priority: high items get `feedbackWarning` exclamation dot

---

### 17. CompactContext

| Field | Value |
|-------|-------|
| ToolKind | `CompactContext` |
| ToolFamily | `Context` |
| tool_type | `"compactContext"` |
| Display Tier | Minimal |
| Accent | `Color.accent` |
| Glyph | `arrow.triangle.2.circlepath` |
| Client View | `CompactContextExpandedView` |

**Invocation Payload** (`ContextCompactionPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `summary` | `String?` | What was compacted |
| `compacted_items` | `u32?` | Number of items compacted |
| `savings_summary` | `String?` | Human-readable savings |

**Compact Card:**
- `arrow.triangle.2.circlepath` icon + "Context compacted" + savings summary

**Expanded View:**
- Before/after token savings bars (proportional width)
- Savings callout: "Saved ~35K tokens (44%)" in green
- Summary text + compacted items count

---

### 18. ViewImage

| Field | Value |
|-------|-------|
| ToolKind | `ViewImage` |
| ToolFamily | `Image` |
| tool_type | `"image"` |
| Display Tier | Standard |
| Accent | `Color.toolRead` |
| Glyph | `photo` |
| Client View | `ImageExpandedView` |

**Invocation Payload** (`ImageViewPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `image_paths` | `Vec<String>` | File paths to images |
| `caption` | `String?` | Image caption |

**Compact Card:**
- `photo` icon + filename + format badge (PNG/JPG/SVG)

**Expanded View:**
- File header: path + format badge + dimensions badge ("1920x1080")
- Image display: `aspectRatio(.fit)`, max height 400pt, rounded border
- Multiple images: horizontal scroll gallery with "1 of 3" counter
- Caption in `textTertiary` italic below image

---

### 19. ImageGeneration

| Field | Value |
|-------|-------|
| ToolKind | `ImageGeneration` |
| ToolFamily | `Image` |
| tool_type | `"image"` |
| Display Tier | Standard |
| Accent | `Color.accent` |
| Glyph | `sparkles` |
| Client View | `ImageExpandedView` |

**Invocation Payload** (`ImageGenerationPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `prompt` | `String?` | Generation prompt |
| `image_urls` | `Vec<String>` | Generated image URLs |
| `revised_prompt` | `String?` | Model-revised prompt |

**Expanded View:**
- Generation prompt as quoted block above image
- Revised prompt diff if different from original
- Image display same as ViewImage

---

### 20. EnterWorktree

| Field | Value |
|-------|-------|
| ToolKind | `EnterWorktree` |
| ToolFamily | `Agent` |
| tool_type | `"worktree"` |
| Display Tier | Standard |
| Accent | `Color.gitBranch` |
| Glyph | `arrow.triangle.branch` |
| Client View | `WorktreeExpandedView` |

**Invocation fields (from raw JSON):**
| Field | Type | Description |
|-------|------|-------------|
| `path` | `String?` | Worktree filesystem path |
| `branch` | `String?` | Git branch name |

**Compact Card:**
- `arrow.triangle.branch` icon + branch name as `gitBranch`-colored badge

**Expanded View:**
- Path field row + branch badge with fork icon (⑂)

---

### 21. HookNotification

| Field | Value |
|-------|-------|
| ToolKind | `HookNotification` |
| ToolFamily | `Hook` |
| tool_type | `"hook"` |
| Display Tier | Minimal |
| Accent | Server-provided glyph color |
| Glyph | `link` |
| Client View | `HookExpandedView` |

**Invocation Payload** (`HookPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `hook_name` | `String?` | Hook identifier |
| `event_name` | `String?` | Triggering event |
| `phase` | `String?` | Execution phase |
| `status` | `String?` | Hook status |
| `source_path` | `String?` | Hook script path |
| `summary` | `String?` | Human-readable summary |
| `output` | `String?` | Hook stdout |
| `duration_ms` | `u64?` | Execution time |
| `entries` | `Vec<HookOutputEntry>` | Structured output entries |

**HookOutputEntry:**
| Field | Type | Description |
|-------|------|-------------|
| `kind` | `String?` | Entry type (pass/fail/info) |
| `label` | `String?` | Entry label |
| `value` | `String?` | Entry value |

**Compact Card:**
- `link` icon + hook name + event + duration

**Expanded View:**
- Hook/Event/Phase field rows
- Duration field row if available
- Structured entries list with status icons (check/x/circle) + label + value

---

### 22. HandoffRequested

| Field | Value |
|-------|-------|
| ToolKind | `HandoffRequested` |
| ToolFamily | `Handoff` |
| tool_type | `"handoff"` |
| Display Tier | Standard |
| Accent | `Color.statusReply` |
| Glyph | `arrow.triangle.branch` |
| Client View | `HandoffExpandedView` |

**Invocation Payload** (`HandoffPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `target` | `String?` | Target agent/tool |
| `summary` | `String?` | Handoff summary |
| `body` | `String?` | Full handoff content |
| `transcript_excerpt` | `String?` | Relevant conversation excerpt |

**Compact Card:**
- `arrow.triangle.branch` icon + target name as `statusReply`-colored badge

**Expanded View:**
- Flow arrow: "Current" → target name
- Body/summary as prose text
- Transcript excerpt as muted inset quote

---

### 23. Config

| Field | Value |
|-------|-------|
| ToolKind | `Config` |
| ToolFamily | `Config` |
| tool_type | `"config"` |
| Display Tier | Minimal |
| Accent | Neutral |
| Glyph | `gearshape` |
| Client View | `ConfigExpandedView` |

**Invocation Payload** (`ConfigPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `key` | `String?` | Configuration key |
| `value` | `Value?` | Configuration value (JSON) |
| `summary` | `String?` | Human-readable summary |

**Compact Card:**
- `gearshape` icon + config key name

**Expanded View:**
- Config key as header
- JSON/key-value rendering for value

---

### 24. MCP (Generic)

| Field | Value |
|-------|-------|
| ToolKind | `McpToolCall` |
| ToolFamily | `Mcp` |
| tool_type | `"mcp"` |
| Display Tier | Standard |
| Accent | `Color.toolMcp` (per-server override via `ToolCardStyle.mcpServerColor`) |
| Glyph | `puzzlepiece.extension` (per-server override via `ToolCardStyle.mcpServerIcon`) |
| Client View | `MCPExpandedView` |

**Invocation Payload** (`McpToolPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `server` | `String` | MCP server name |
| `tool_name` | `String` | Tool function name |
| `input` | `Value?` | Raw JSON input |

**Result Payload** (`McpToolPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `output` | `Value?` | Raw JSON output |

**Known MCP Server Styles:**
| Server | Color | Icon |
|--------|-------|------|
| GitHub | `serverGitHub` | `chevron.left.forwardslash.chevron.right` |
| Linear | `serverLinear` | `list.bullet.rectangle` |
| Chrome | `serverChrome` | `globe` |
| Slack | `serverSlack` | `bubble.left.and.bubble.right` |
| Cupertino | `serverApple` | `apple.logo` |
| Default | `serverDefault` | `puzzlepiece.extension` |

**Compact Card:**
- `ServerBadge` inline + tool function name as monospace subtitle

**Expanded View:**
- Server + tool identity header: `ServerBadge` + tool name
- Smart input rendering via `SmartJSONView`:
  - Simple (<5 top-level keys, no nesting): key-value field list
  - Complex (nested/arrays): `JSONTreeView`
  - Single string: body text
- Smart output rendering: same heuristic
- Error detection: `"error"` key → red-tinted block

---

### 25. Generic

| Field | Value |
|-------|-------|
| ToolKind | `Generic` |
| ToolFamily | `Generic` |
| tool_type | falls through to default |
| Display Tier | Standard |
| Accent | Neutral |
| Glyph | `gearshape` |
| Client View | `GenericExpandedView` |

**Invocation Payload** (`GenericInvocationPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `tool_name` | `String` | Raw tool name |
| `raw_input` | `Value?` | Raw JSON input |

**Result Payload** (`GenericResultPayload`):
| Field | Type | Description |
|-------|------|-------------|
| `tool_name` | `String` | Raw tool name |
| `raw_output` | `Value?` | Raw JSON output |
| `summary` | `String?` | Result summary |

**Expanded View:**
- `SmartJSONView` for input and output
- Diff detection fallback to `EditExpandedView`
- Intentional catch-all for unknown/new tools

---

## Provider Mappings

### Claude → ToolKind

| Claude Tool Name | ToolKind | ToolFamily |
|-----------------|----------|------------|
| `Bash` / `bash` | `Bash` | `Shell` |
| `Read` / `FileRead` | `Read` | `FileRead` |
| `Edit` / `FileEdit` / `MultiEdit` | `Edit` | `FileChange` |
| `Write` / `FileWrite` | `Write` | `FileChange` |
| `NotebookEdit` | `NotebookEdit` | `FileChange` |
| `Glob` / `glob` | `Glob` | `Search` |
| `Grep` / `grep` | `Grep` | `Search` |
| `ToolSearch` | `ToolSearch` | `Search` |
| `WebSearch` / `websearch` | `WebSearch` | `Web` |
| `WebFetch` / `webfetch` | `WebFetch` | `Web` |
| `Agent` / `agent` / `task` | `SpawnAgent` | `Agent` |
| `AskUserQuestion` | `AskUserQuestion` | `Question` |
| `EnterPlanMode` | `EnterPlanMode` | `Plan` |
| `ExitPlanMode` | `ExitPlanMode` | `Plan` |
| `TodoWrite` | `TodoWrite` | `Todo` |
| `CompactContext` | `CompactContext` | `Context` |
| `mcp__*` | `McpToolCall` | `Mcp` |
| (default) | `Generic` | `Generic` |

### Codex → ToolKind

| Codex Event | ToolKind | ToolFamily |
|-------------|----------|------------|
| `ExecCommandBegin/End` | `Bash` | `Shell` |
| `PatchApplyBegin/End` | `Edit` | `FileChange` |
| `McpToolCallBegin/End` | `McpToolCall` | `Mcp` |
| `WebSearchBegin/End` | `WebSearch` | `Web` |
| `ViewImageToolCall` | `ViewImage` | `Image` |
| `DynamicToolCallRequest/Response` | `DynamicToolCall` | `Generic` |
| `TerminalInteraction` | `Bash` | `Shell` |

---

## Shared Components

| Component | File | Used By |
|-----------|------|---------|
| `FileTabHeader` | `Components/FileTabHeader.swift` | Read, Edit, Write, Image, NotebookEdit |
| `FileTypeDistributionBar` | `Components/FileTypeDistributionBar.swift` | Glob |
| `SmartJSONView` | `Components/SmartJSONView.swift` | MCP, Config, Generic |
| `TerminalChrome` | `Components/TerminalChrome.swift` | Bash |
| `SearchBarVisual` | `Components/SearchBarVisual.swift` | Grep, WebSearch, ToolSearch |
| `URLBarVisual` | `Components/URLBarVisual.swift` | WebFetch |
| `DiffStatsBar` | `Components/DiffStatsBar.swift` | Edit |
| `MicroDiffStatsBar` | `Components/DiffStatsBar.swift` | Edit (compact inline) |
| `JSONTreeView` | `Components/JSONTreeView.swift` | MCP, WebFetch, Config, Generic |
| `ServerBadge` | `Components/ServerBadge.swift` | MCP |
| `FileTreeBuilder` | `Components/FileTreeBuilder.swift` | Glob |
| `WordLevelDiff` | `Components/WordLevelDiff.swift` | Edit |
| `ProgressSummaryBar` | `Components/ProgressSummaryBar.swift` | Todo, Plan |
| `ANSIColorParser` | `Components/ANSIColorParser.swift` | Bash |
| `SyntaxHighlighter` | (shared utility) | Read, Edit, Write, Bash |
| `CodeViewport` | `Components/CodeViewport.swift` | Read, Edit, Write |
| `DiffChangeStrip` | `Components/DiffChangeStrip.swift` | Edit (large diffs >30 lines) |
| `ToolCardStyle` | `ToolCardStyle.swift` | All (color/icon fallbacks, `looksLikeJSON` utility) |
