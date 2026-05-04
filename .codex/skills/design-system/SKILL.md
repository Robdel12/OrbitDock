---
name: design-system
description: >-
  Cosmic Harbor design system for OrbitDock. Covers the full visual language:
  color tokens (status, feedback, tool, model, autonomy, diff, syntax),
  spacing (4pt grid), typography scale, corner radii, elevation/shadow/glow,
  opacity tiers, motion presets, icon sizing, component patterns, interaction
  patterns, cross-platform layout rules, and accessibility standards. Use when
  creating or modifying any OrbitDock UI in SwiftUI, UIKit, or AppKit so
  changes stay visually consistent and token-driven.
---

# Cosmic Harbor Design System

Use this skill for any OrbitDock UI work: new views, styling changes, layout adjustments,
component refinements, token updates, or design reviews.

This skill is adapted for Codex and the rest of the agents working in this repo. It should
help you move quickly without inventing a parallel design language or copying existing visual
mistakes forward.

This is the fast path, not the handbook. For deeper detail, open:

- `docs/design-system.md` for the canonical design system
- `docs/typography.md` when text treatment or hierarchy matters
- `docs/UI_CROSS_PLATFORM_GUIDELINES.md` for platform-specific ergonomics
- `docs/CLIENT_DESIGN_PRINCIPLES.md` and `docs/SWIFT_CLIENT_ARCHITECTURE.md` when shared SwiftUI structure is involved
- `reference.md` in this skill when you need the copied long-form spec

## Workflow

1. Open `docs/design-system.md` first for any non-trivial UI change.
2. Check the nearby implementation before inventing a new component shape or token.
3. If the current UI conflicts with the design system, prefer fixing the mismatch over preserving it.
4. If the real gap is a missing token, add it in the canonical token file first, then consume it from the view.
5. Read only the sections relevant to the task so the skill stays cheap in context.

## Core Principles

1. **Mission Control, Not a Toy**: dense, precise, urgency-first, never decorative sci-fi fluff
2. **Calm Density**: information-rich without visual panic; whitespace separates groups, not every border
3. **Status at a Glance**: the user should know what needs attention in under a second
4. **Platform-Native, Visually Unified**: same tokens and hierarchy everywhere, ergonomics tuned per platform

## Token Quick Reference

### Status Colors

| State | Color | Hex | Icon | Urgent? |
|-------|-------|-----|------|---------|
| Working | Cyan | `#54AEE5` | `bolt.fill` | No |
| Permission | Coral | `#F28C6B` | `lock.fill` | Yes |
| Question | Purple | `#BF80F2` | `questionmark.bubble.fill` | Yes |
| Reply | Soft blue | `#73B2FF` | `bubble.left` | No |
| Ended | Warm gray | `#6B6673` | `moon.fill` | No |

### Background Depth

`backgroundCode` -> `backgroundPrimary` -> `backgroundSecondary` -> `backgroundTertiary`

### Text Hierarchy

| Token | Opacity | Usage |
|-------|---------|-------|
| `textPrimary` | 0.92 | Headings, key values, session names |
| `textSecondary` | 0.65 | Labels, descriptions |
| `textTertiary` | 0.50 | Metadata, counts, timestamps |
| `textQuaternary` | 0.38 | Hints, lowest-priority text |

Never use SwiftUI `.foregroundStyle(.tertiary)` or `.quaternary` on OrbitDock dark surfaces.

### Spacing

`xxs(2)` `gap(3)` `xs(4)` `sm_(6)` `sm(8)` `md_(10)` `md(12)` `lg_(14)` `lg(16)` `section(20)` `xl(24)` `xxl(32)`

### Radius

`xs(2)` `sm(4)` `sm_(5)` `md(6)` `ml(8)` `lg(10)` `xl(14)` with continuous corners

### Motion

| Preset | Usage |
|--------|-------|
| `snappy` | Hover, press, toggle |
| `standard` | Expand/collapse, navigation |
| `gentle` | Panel slides, content entry |
| `bouncy` | Sheet presentation, playful emphasis |

## Rules That Prevent Bugs

1. No ad-hoc colors. Every color comes from `Theme.swift`.
2. No ad-hoc spacing. Use tokenized spacing values only.
3. No ad-hoc radii. Use tokenized corner radii only.
4. No ad-hoc animations. Use motion presets only.
5. Status uses the defined five-state system. Do not invent extra UI status colors casually.
6. `feedback*` colors are for general UI feedback, not session state.
7. Long paths, identifiers, and model names must truncate safely.
8. Shared layouts start from `phoneCompact` and scale up.
9. Dark mode only. Do not introduce light-mode branches.
10. No hover-only affordances as the sole interaction path.

## Component Patterns

Reuse nearby OrbitDock patterns before introducing a new component shape.

### Badge

```swift
HStack(spacing: Spacing.gap) {
  Image(systemName: icon).font(.system(size: IconScale.sm, weight: .semibold))
  Text(label).font(.system(size: TypeScale.mini, weight: .semibold))
}
.foregroundStyle(color)
.padding(.horizontal, Spacing.sm_)
.padding(.vertical, Spacing.gap)
.background(color.opacity(OpacityTier.light), in: Capsule())
```

### Card

```swift
content
  .padding(Spacing.md)
  .background(Color.backgroundTertiary)
  .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  .overlay(
    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      .stroke(Color.surfaceBorder, lineWidth: 1)
  )
```

### Permission Banner

```swift
HStack(spacing: Spacing.md) {
  Image(systemName: "exclamationmark.triangle.fill")
    .foregroundStyle(Color.statusPermission)
  VStack(alignment: .leading, spacing: Spacing.xs) { /* tool info */ }
}
.padding(Spacing.lg_)
.background(
  Color.statusPermission.opacity(OpacityTier.light),
  in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
)
```

## Cross-Platform Layout

| Rule | Detail |
|------|--------|
| Start with `phoneCompact` | Scale up to pad and desktop, not the other way around |
| No unguarded fixed widths | Gate desktop-only sizing explicitly |
| iOS sheets need detents | Include drag indicator too |
| Touch targets | 44pt minimum on iOS, 28pt minimum on macOS |
| Bottom actions on iPhone | Use `safeAreaInset(edge: .bottom)` |
| Truncation | Use safe line limits and middle truncation for identifiers |

## Accessibility

- Text tiers must maintain the documented contrast on dark backgrounds
- Every status color needs a non-color signal, usually an icon
- Respect reduced motion on native platforms
- Decorative elements should be hidden from accessibility APIs
- Do not make hover the only way to discover or perform an action
- Prefer safe truncation and bottom-pinned actions on iPhone shared views

## Codex-Specific Guidance

- Open the design docs before editing UI, but only read the sections relevant to the task
- Prefer extending existing OrbitDock patterns over inventing a parallel style language
- If the current code violates the design system, fix the mismatch instead of copying it forward
- If a missing token is the real issue, add it in the canonical token file first, then use it from the component
- When reviewing UI changes, check token compliance, urgency hierarchy, truncation safety, reduced motion, and platform fit before polishing details
- Keep the source of truth in repo docs and token files, not in scattered component-local comments or magic values

See `reference.md` for the longer copied reference, and `docs/design-system.md` for the canonical repo version.
