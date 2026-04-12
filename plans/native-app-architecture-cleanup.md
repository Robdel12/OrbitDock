# Native App Architecture Cleanup

Date: 2026-04-11
Status: Active

## Context

- OrbitDock's native app still has architecture drift that shows up as duplicate bootstrap work, stale live updates, and feature surfaces that refresh for the wrong reasons.
- The docs are now aligned around the target model in [docs/ARCHITECTURE.md](/Users/robertdeluca/Developer/OrbitDock/docs/ARCHITECTURE.md:1), [docs/data-flow.md](/Users/robertdeluca/Developer/OrbitDock/docs/data-flow.md:1), and [docs/GETTING_STARTED.md](/Users/robertdeluca/Developer/OrbitDock/docs/GETTING_STARTED.md:1).
- The next step is to make the code match that model instead of continuing to patch symptoms one view at a time.

## Target Model

The cleanup is converging on four rules:

1. Scene owners resolve stable dependencies before mounting child features.
2. Each rendered surface has one owner, one HTTP bootstrap path, and one realtime follow-up path.
3. `SessionStore` stays transport-only: typed HTTP clients, reconnect/replay handling, and targeted async streams.
4. SwiftUI stays structurally stable: small dedicated views, explicit dependency injection, no placeholder runtime stores, no broad fan-out as the default.

This aligns with the plugin-native guidance we want to follow:

- `build-ios-apps:swiftui-view-refactor`
- `build-ios-apps:swiftui-ui-patterns`
- `build-macos-apps:swiftui-patterns`
- `build-macos-apps:view-refactor`

## What We Already Finished

- [x] Rewrote the architecture docs so they are the source of truth for native ownership and transport boundaries.
- [x] Removed repo guidance that pointed at the deprecated local Swift skills.
- [x] Removed the deprecated local Swift skills from `~/.codex/skills`.

That means this plan starts from implementation, not from documentation cleanup.

## Current Architectural Problems

### 1. Session detail still owns too much

- [SessionDetailView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailView.swift:1) is still doing too much composition and lifecycle wiring in one place.
- [SessionDetailViewModel.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailViewModel.swift:1) still carries ownership concerns that belong closer to the scene boundary.

### 2. Feature view models still have unstable startup patterns

- Several feature view models still begin life around placeholder store assumptions or delayed bind/bootstrap patterns.
- That makes SwiftUI identity and lifecycle behavior harder to reason about, especially during selection changes and send/update flows.

### 3. Broad per-session invalidation is still masking surface contracts

- Review, control deck, skills, and MCP surfaces still rely too much on generic session-wide change streams.
- That creates duplicate work, accidental refresh storms, and unclear ownership.

### 4. The largest macOS files are still too monolithic

- The session detail and control deck stack still carry too much view, effect, and composition logic in oversized files.
- That fights the plugin-native pattern of small, explicit views with clear ownership.

## Execution Strategy

We should do this as a small number of high-leverage slices instead of a giant refactor.

### Slice 1: Stabilize session-detail scene ownership

Goal:

- make the selected-session subtree mount once against stable dependencies
- remove placeholder production-store behavior from the session-detail stack
- make conversation, review, and other child surfaces receive explicit runtime dependencies

Primary files:

- [OrbitDockWindowRoot.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/OrbitDockWindowRoot.swift:1)
- [SessionDetailView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailView.swift:1)
- [SessionDetailViewModel.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailViewModel.swift:1)
- [ConversationViewModel.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Conversation/ConversationViewModel.swift:1)
- [ReviewCanvasViewModel.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Review/ReviewCanvasViewModel.swift:1)

Done when:

- [x] feature view models no longer rely on placeholder runtime stores in production paths for session detail, conversation, review, skills, and MCP
- [x] the selected session subtree is resolved from the scene boundary before children bind
- [ ] session switching no longer causes avoidable remount churn

### Slice 2: Replace broad invalidation with surface-specific follow-up

Goal:

- move non-conversation surfaces off generic `sessionChanges(for:)` where a narrower contract exists
- add targeted streams or explicit invalidation APIs where missing

Primary files:

- [SessionStore.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/SessionStore.swift:1)
- [SessionStore+Events.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/SessionStore+Events.swift:1)
- [ReviewCanvas.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Review/ReviewCanvas.swift:1)
- [ControlDeckScreen.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/ControlDeckScreen.swift:1)
- [SkillsTab.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/Capabilities/SkillsTab.swift:1)
- [McpServersTab.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/Capabilities/McpServersTab.swift:1)

Done when:

- [x] each surface listens to its own follow-up contract for control deck, review, skills, and MCP
- [x] generic session-wide refresh is no longer the default for feature tabs
- [ ] live updates do not require leaving and re-entering a view

### Slice 3: Break up the largest scene and control-deck files

Goal:

- make the top-level macOS files read like composition, not like mixed composition plus controller logic
- move toward the plugin-native small-view structure without changing behavior first

Primary files:

- [SessionDetailView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailView.swift:1)
- [SessionDetailViewModel.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailViewModel.swift:1)
- [ControlDeckScreen.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/ControlDeckScreen.swift:1)
- [ControlDeckViewModel.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/ControlDeckViewModel.swift:1)
- [ControlDeckStatusBar.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/ControlDeckStatusBar.swift:1)

Done when:

- [ ] scene root files are materially smaller
- [ ] the composition flow is readable from top to bottom
- [ ] feature-specific sections and chrome live in focused files

### Slice 4: Remove remaining SwiftUI lifecycle and identity traps

Goal:

- remove `AnyView`
- replace effectful `.onAppear` flows in core surfaces with `.task` or scene-owned startup
- clean up obvious UI-adjacent async/lifecycle patterns that still read like controller code

Primary files:

- [ControlDeckStatusBar.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/ControlDeckStatusBar.swift:1)
- session-detail, conversation, review, and control-deck surfaces as identified during slices 1 to 3

Done when:

- [ ] core surfaces no longer rely on `AnyView`
- [ ] lifecycle-bound async work is owned by `.task` or the scene boundary
- [ ] view code reads like UI plus orchestration, not embedded controller logic

## Immediate Work Order

1. Finish Slice 1 first.
2. While doing Slice 1, record every remaining generic invalidation consumer we hit naturally.
3. Move into Slice 2 immediately after scene ownership stabilizes.
4. Do decomposition only after ownership and invalidation are cleaner.

## Verification

Build and tests:

- [ ] `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme 'OrbitDock Unit Tests' -destination 'platform=macOS' -derivedDataPath /tmp/OrbitDockDerivedData test`
- [ ] `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme 'OrbitDock Unit Tests' -destination 'platform=macOS' -derivedDataPath /tmp/OrbitDockDerivedData test -only-testing:OrbitDockTests/SessionStoreReconnectRecoveryTests`

Manual checks:

- [ ] selecting a session produces one conversation bootstrap, not repeated GET fan-out
- [ ] sending a message updates the conversation live without leaving and re-entering
- [ ] review, control deck, skills, and MCP surfaces refresh only when their own surface changes
- [ ] fast session switching does not leak stale state across sessions or endpoints
- [ ] macOS split-view selection and keyboard navigation remain stable

## Risks

- [ ] We may uncover places where the existing transport contract is still too broad for a clean surface owner.
  Mitigation: add the narrowest missing stream instead of pushing more product state into `SessionStore`.
- [ ] Decomposition could accidentally mix cleanup work with behavior changes.
  Mitigation: keep Slice 3 behavior-preserving and verify after each extraction.
- [ ] Existing dirty worktree changes may overlap with some native files.
  Mitigation: make focused commits and work carefully around unrelated edits.

## Definition Of Done

- [ ] Core session surfaces have explicit owners and stable dependency injection.
- [ ] No production feature path starts from placeholder runtime-store ownership.
- [ ] Surface refresh behavior matches the docs.
- [ ] The duplicate bootstrap and stale live-update classes of bugs are covered by regression tests.
- [ ] The native app is moving with plugin-native SwiftUI/macOS patterns instead of fighting them.
