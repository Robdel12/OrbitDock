# AppKit Conversation 60 FPS Rebuild Plan

> Purpose: replace patchy row-height invalidation and nested dynamic row behavior with a deterministic, high-performance AppKit timeline architecture.
> Scope: macOS conversation rendering layer only.

---

## Why We Are Doing This

The current implementation got us close, but it still has architectural instability:

- clipping when expandable content changes height
- brittle behavior around turn roll-up and tool-card expansion
- CPU spikes from repeated re-measure/re-layout patterns
- too much layout state living inside row views instead of a central state model

We need one canonical render pipeline where data, layout, and row invalidation are deterministic.

---

## Outcome We Want

Ship a macOS conversation timeline that:

- scrolls smoothly at 60 FPS on large transcripts
- never clips expandable content
- supports infinite history prepend without viewport jumps
- uses targeted invalidation (only rows that changed)
- keeps row identity stable across updates
- is simple to reason about and test

---

## Architecture Principles (Non-Negotiable)

1. **Single virtualization surface**
- Use one `NSTableView` as the timeline surface.
- No nested list virtualization inside rows.

2. **Flat projection model**
- Convert source conversation data into a flat `[TimelineRow]`.
- Avoid giant “super rows” that own large dynamic subtrees.

3. **Central UI state**
- Expand/collapse/roll-up state lives in a shared store, not local row `@State`.
- Row views become dumb renderers.

4. **Deterministic height cache**
- Height key: `(rowID, widthBucket, layoutHash)`.
- If key unchanged, height is reused.
- If key changes, only that row is invalidated.

5. **Stable identity**
- Every row has immutable identity derived from session data + semantic row role.
- Never generate runtime IDs for diffing.

6. **Anchor-preserving pagination**
- Prepending history preserves visual anchor using row ID + delta offset restore.

7. **Main thread protection**
- Expensive text/diff/media measurement runs off-main where safe.
- Main thread does O(1) lookups and minimal view updates.

---

## Data Model and Core Types

Create a dedicated conversation timeline module with these types:

### 1) Source + UI State

- `ConversationSourceState`
  - raw transcript messages
  - turn metadata
  - session status metadata
- `ConversationUIState`
  - expanded tool cards by ID
  - expanded roll-up groups by ID
  - expanded markdown blocks by ID
  - pinned-bottom state
  - scroll anchor state

### 2) Projection Types

- `TimelineRowID` (stable, hashable)
- `TimelineRowKind`
  - examples: `loadMore`, `messageCount`, `turnHeader`, `message`, `tool`, `rollupSummary`, `liveIndicator`, `bottomSpacer`
- `TimelineRow`
  - `id`
  - `kind`
  - `payload`
  - `layoutHash`
  - `renderHash`

### 3) Diff + Cache Types

- `ProjectionResult`
  - `rows`
  - `insertions/deletions/moves/reloads`
  - `dirtyRowIDs`
- `HeightCacheKey`
  - `rowID`
  - `widthBucket`
  - `layoutHash`

---

## Rendering Pipeline (End State)

1. `Reducer` applies action to `ConversationSourceState + ConversationUIState`.
2. `Projector` builds flat rows and computes diff + dirty rows.
3. `NSTableView` adapter applies structural updates in batch.
4. Height cache invalidates only dirty rows.
5. `noteHeightOfRows(withIndexesChanged:)` called for affected indexes only.
6. Scroll anchoring logic restores viewport when prepending or toggling sections.

---

## Height Strategy

### Immediate Rules

- Remove all implicit “measure from accidental live view state” behavior.
- Height requests must go through one deterministic `HeightEngine`.

### HeightEngine Responsibilities

- Compute/cache row height by key.
- Return cached value immediately on cache hit.
- Support async precompute for expensive text/diff rows.
- Publish invalidation events when width bucket or layout hash changes.

### Text + Diff Measurement

- Use headless measurement objects off-main for precompute where possible.
- For unsupported cases, fallback to measured-on-main once, then cache.
- Never tie height authority to transient local SwiftUI state.

---

## Scroll and Pagination Strategy

### Pinned to Bottom

- If pinned and new rows append, keep bottom anchored.
- If user scrolls up, pinned mode disengages.

### Prepending History

Before prepend:
- capture top visible semantic row ID
- capture visual delta from row top to viewport top

After prepend:
- resolve new index of captured row ID
- restore offset using captured visual delta
- no animated jump

### Expansion / Collapse

- Expanding row groups inserts/removes rows via projection diff.
- Preserve user viewport anchor unless pinned-bottom is active.

---

## Execution Plan (Phase-by-Phase)

Each phase is designed to be picked up and completed independently in one focused PR.

---

## Phase 1: Timeline Domain Model

**Goal:** define the canonical data model for source state, UI state, and projected rows.

**Primary files:**
- `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionTypes.swift`
- `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView.swift`

**Tasks:**
- add `ConversationSourceState`
- add `ConversationUIState`
- add `TimelineRowID`, `TimelineRowKind`, `TimelineRow`
- add row hash contracts: `renderHash` and `layoutHash`
- define `ProjectionResult` contract used by the table adapter

**Validation:**
- `make build`
- iOS compile check:
  - `xcodebuild -project OrbitDock/OrbitDock/OrbitDock.xcodeproj -scheme "OrbitDock iOS" -destination "generic/platform=iOS" build`

**Phase complete when:**
- model types compile cleanly
- no behavior changes yet

---

## Phase 2: Projector + Reducer

**Goal:** produce deterministic rows from `source + ui` and keep all expansion/rollup decisions in state.

**Primary files:**
- add `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationTimelineProjector.swift`
- add `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationTimelineReducer.swift`
- tests in `OrbitDock/OrbitDockTests/`

**Tasks:**
- implement reducer actions:
  - `appendMessages`
  - `prependMessages`
  - `toggleToolCard`
  - `toggleRollup`
  - `toggleMarkdown`
  - `setPinnedToBottom`
  - `widthChanged`
- implement pure projector:
  - input: source + ui
  - output: rows + dirty row IDs + structural diff metadata
- flatten turn rendering into semantic rows (header/message/tool/rollup summary/footer)

**Validation:**
- `make test-unit`
- add unit tests for deterministic projection output

**Phase complete when:**
- same input state always yields same projected rows and hashes
- rollup/expand behavior is projector-driven, not view-driven

---

## Phase 3: AppKit Table Adapter Rewrite

**Goal:** drive `NSTableView` entirely from `ProjectionResult` and targeted row updates.

**Primary files:**
- `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView.swift`

**Tasks:**
- replace ad hoc update paths with adapter-driven structural updates
- centralize `TimelineRowID -> row index` mapping
- apply inserts/deletes/moves/reloads from projection result in batch updates
- remove patch-era invalidation hooks that bypass projector ownership

**Validation:**
- `make build`
- manual interaction pass:
  - stream updates
  - tool card expand/collapse
  - turn rollup expand/collapse

**Phase complete when:**
- no full-table `reloadData()` for routine updates
- no blank rendering state during interaction

---

## Phase 4: Deterministic Height Engine

**Goal:** make row heights stable and cacheable with deterministic invalidation.

**Primary files:**
- add `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationHeightEngine.swift`
- `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView.swift`

**Tasks:**
- implement `HeightCacheKey(rowID, widthBucket, layoutHash)`
- implement `HeightEngine` for lookup/store/invalidate
- route all height invalidation through one path:
  - `noteHeightOfRows(withIndexesChanged:)`
- remove any implicit dependence on live view-local state for authoritative height decisions

**Validation:**
- `make build`
- expand/collapse stress pass on dense transcripts

**Phase complete when:**
- no clipping on expansion/rollup interactions
- height cache hit behavior is observable in logs/signposts

---

## Phase 5: Scroll Anchor + Prepend Correctness

**Goal:** prepend older history with no viewport jump and preserve pinned-bottom behavior.

**Primary files:**
- `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView.swift`

**Tasks:**
- capture anchor before prepend:
  - top visible semantic row ID
  - visual delta from row top to viewport top
- after prepend, restore using resolved row index + delta
- keep append path separate for pinned-bottom behavior

**Validation:**
- manual prepend loop test
- verify exact reading-position preservation

**Phase complete when:**
- prepend is visually stable every time
- pinned-bottom append remains reliable

---

## Phase 6: Perf + Cleanup

**Goal:** harden for production and remove remaining cruft.

**Primary files:**
- `OrbitDock/OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView.swift`
- `OrbitDock/OrbitDock/OrbitDock/Views/WorkStreamEntry.swift`
- `OrbitDock/OrbitDock/OrbitDock/Views/TurnGroupView.swift`

**Tasks:**
- instrument with `os_signpost`:
  - projection time
  - diff apply time
  - height lookup/miss
  - prepend anchor restore
- remove obsolete patch-era paths and dead code
- audit row-level animations for scrolling CPU impact

**Validation:**
- `make fmt`
- `make lint`
- `make build`
- manual perf pass on long transcripts

**Phase complete when:**
- no known clipping/crash/blank states
- no remaining duplicate code paths for row invalidation

---

## Testing Requirements Across All Phases

- unit:
  - reducer transitions
  - projector determinism
  - row identity stability
  - height key/hash correctness
  - anchor restore math
- integration:
  - append/prepend/update with mixed tools + markdown + diff cards
  - width changes and split-view resizing
- ui/perf:
  - scroll stress test on large transcript
  - repeated expand/collapse in dense tool sections

---

## Final Definition of Done

- no clipping cases in expandable content
- deterministic row projection and stable IDs
- targeted row invalidation only
- prepend preserves viewport anchor
- pinned-bottom behavior is reliable
- smooth scrolling on large histories
- codepath is simpler than baseline and test-backed

---

## Immediate Next Step

Start Phase 1 in a single PR:

- define domain types
- wire type usage in conversation controller
- keep runtime behavior unchanged
