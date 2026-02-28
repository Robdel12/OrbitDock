# UI Cross-Platform Guidelines

This document defines how OrbitDock UI should be built across iPhone, iPad, and macOS.

The short version:
- Build phone-compact first.
- Scale up to iPad and desktop.
- Keep one visual system (tokens, spacing, typography, component behavior).

## Why This Exists

We have mixed layout patterns in the codebase right now. Some views are already mobile-aware, while others still assume desktop-sized containers.

This guideline makes "mobile-first + cross-platform" explicit so new UI stays consistent and old UI is easier to refactor.

## Supported Layout Modes

Use these modes as the baseline model:

1. `phoneCompact`
2. `pad`
3. `desktop`

Reference implementation: `Views/Dashboard/DashboardLayoutMode.swift`.

## Core Rules (Non-Negotiable)

1. Start with `phoneCompact`.
2. Add `pad` and `desktop` as progressive enhancements, not separate designs.
3. Do not use raw fixed widths for shared views (`.frame(width: 320/340/420/...)`) unless they are behind `.ifMacOS { ... }`.
4. Every sheet must have an iOS presentation strategy.
5. iPhone sheets must define explicit detents + drag indicator.
6. iPad/macOS sheets may use wider layouts where needed.
7. Use theme tokens only (`Spacing`, `TypeScale`, `Radius`, `Color.*`) for all spacing/typography/colors.
8. Avoid pointer/keyboard-only interaction as the only path (hover-only affordances, keypress-only confirmation).
9. Bottom actions on iPhone should be pinned with `safeAreaInset(edge: .bottom)`, not floating in long scroll content.
10. All long paths/identifiers must truncate safely (`.lineLimit`, `.truncationMode(.middle)`).

## Canonical Patterns

### 1) Cross-platform container split

```swift
Group {
  #if os(iOS)
    if horizontalSizeClass == .compact {
      compactLayout
    } else {
      regularLayout
    }
  #else
    regularLayout
  #endif
}
```

### 2) Desktop width constraints

```swift
.ifMacOS { view in
  view.frame(width: 420)
}
```

Do not apply this width directly to iOS unless there is an explicit compact fallback.

### 3) iOS sheet behavior

```swift
.sheet(isPresented: $showSheet) {
  SheetContent()
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
}
```

For short forms, include a height detent first (for example `.height(380)`), then `.medium`.

### 4) Popover behavior

Use `platformPopover` instead of raw `.popover` for controls that must work on both macOS and iOS.

## Design System Rules

1. Colors: use `Theme.swift` semantic colors.
2. Typography: use `TypeScale` tiers, not ad hoc sizes unless there is a clear reason.
3. Spacing: use `Spacing` tokens.
4. Radius: use `Radius` tokens with continuous corners.
5. Status colors: use semantic status colors (`.statusWorking`, `.statusPermission`, etc.).

## iPhone + iPad Behavior Expectations

1. iPhone compact should default to single-column flow.
2. iPhone compact should use navigation title + toolbar actions.
3. iPhone compact should use scrollable content with pinned footer actions.
4. iPad should prefer two-pane or expanded card layouts when space allows.
5. iPad should keep touch targets and spacing comfortable; do not blindly reuse tiny desktop controls.
6. macOS can add hover, keyboard shortcuts, and pointer affordances as enhancements, not as the only path.

## PR Checklist (UI Changes)

1. Phone-compact screenshot/video included.
2. iPad screenshot/video included (or explicit reason not applicable).
3. macOS screenshot/video included (if shared view).
4. No unguarded fixed-width shared container frames.
5. iOS sheets include detents + drag indicator.
6. Long text/path truncation verified.
7. Dynamic Type and orientation sanity checked.

## Current Hotspot Status (As Of 2026-02-28)

The previous highest-confidence desktop-first hotspots were migrated:

1. `CreateWorktreeSheet` now has a compact iPhone flow with detents and toolbar actions.
Path: `OrbitDock/OrbitDock/Views/Worktrees/CreateWorktreeSheet.swift`.
2. `WorktreeListView` now has a compact iPhone layout with pinned bottom actions and mobile-safe row cards.
Path: `OrbitDock/OrbitDock/Views/Worktrees/WorktreeListView.swift`.
3. `NewClaudeSessionSheet` now has iOS scroll-based form content and compact-friendly framing.
Path: `OrbitDock/OrbitDock/Views/Claude/NewClaudeSessionSheet.swift`.
4. `DirectSessionComposer` fork-worktree sheets now avoid unguarded fixed-width layouts and include iOS detents.
Path: `OrbitDock/OrbitDock/Views/Codex/DirectSessionComposer.swift`.
5. `RenameSessionSheet` now has a compact iPhone navigation layout.
Path: `OrbitDock/OrbitDock/Views/Components/RenameSessionSheet.swift`.
6. `ClaudePermissionPicker` now uses `platformPopover` with iOS-friendly container behavior.
Path: `OrbitDock/OrbitDock/Views/Claude/ClaudePermissionPicker.swift`.
7. `SessionDetailView` turn sidebar now presents as a sheet on compact layouts.
Path: `OrbitDock/OrbitDock/Views/SessionDetailView.swift`.

Continue auditing new UI work against the PR checklist above to prevent desktop-first regressions.
