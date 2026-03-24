---
name: design-system
description: >-
  Cosmic Harbor design system for OrbitDock. Covers the full visual language: color tokens
  (status, feedback, tool, model, autonomy, diff, syntax), spacing (4pt grid), typography scale,
  corner radii, elevation/shadow/glow, opacity tiers, motion presets, icon sizing, component
  patterns (badges, cards, buttons, banners, session rows, composer), interaction patterns
  (urgency hierarchy, progressive disclosure), cross-platform layout rules (phoneCompact, pad,
  desktop), and accessibility standards (WCAG contrast, reduced motion, VoiceOver). Use when
  creating or modifying any UI — native Swift or web — to ensure visual consistency across all
  OrbitDock clients.
compatibility: >-
  Any AI coding agent working on OrbitDock UI code. Applies to SwiftUI (iOS 17+/macOS 14+),
  UIKit, AppKit, and web (CSS/JS) codebases.
metadata:
  author: orbitdock
  version: "1.0"
  theme: cosmic-harbor
---

# Cosmic Harbor Design System

This skill provides the design language and token system for all OrbitDock UI work.

## Core Principles

1. **Mission Control, Not a Toy** — Aerospace control room density. Zero ambiguity about what needs attention. Space theme expressed through color and light, never decorative illustration.
2. **Calm Density** — Information-dense without being overwhelming. Dark backgrounds recede, content floats forward, color is semantic only.
3. **Status at a Glance** — "What needs my attention?" answered in <1 second. Brightness = urgency.
4. **Platform-Native, Visually Unified** — Same tokens and identity everywhere. Different interaction ergonomics per platform.

## Visual Identity

Derived from the app icon: **light on dark, motion within structure, a harbor for things in flight.**

- **The Orbit** — Cyan accent (`#54AEE5`) is the signature brand motif: links, active states, working status, code types
- **Color Temperature** — Warm charcoal with indigo undertones (not pure gray) prevents eye fatigue
- **Light as Information** — On a dark canvas, the brightest elements are always the ones that need action

## Token Quick Reference

### Status Colors (The Five States)

| State | Color | Hex | Icon | Urgent? |
|-------|-------|-----|------|---------|
| Working | Cyan | `#54AEE5` | `bolt.fill` | No |
| Permission | Coral | `#F28C6B` | `lock.fill` | Yes |
| Question | Purple | `#BF80F2` | `questionmark.bubble.fill` | Yes |
| Reply | Soft blue | `#73B2FF` | `bubble.left` | No |
| Ended | Warm gray | `#6B6673` | `moon.fill` | No |

### Background Depth (darkest to lightest)

`backgroundCode` (#0A0A0D) → `backgroundPrimary` (#0F0E11) → `backgroundSecondary` (#151416) → `backgroundTertiary` (#1C1B1F)

### Text Hierarchy

| Token | Opacity | Usage |
|-------|---------|-------|
| `textPrimary` | 0.92 | Headings, session names |
| `textSecondary` | 0.65 | Labels, descriptions |
| `textTertiary` | 0.50 | Timestamps, counts |
| `textQuaternary` | 0.38 | Hints, lowest priority |

**Never** use SwiftUI `.foregroundStyle(.tertiary)` or `.quaternary` — invisible on dark theme.

### Spacing (4pt grid)

`xxs(2)` `gap(3)` `xs(4)` `sm_(6)` `sm(8)` `md_(10)` `md(12)` `lg_(14)` `lg(16)` `section(20)` `xl(24)` `xxl(32)`

### Radius

`xs(2)` `sm(4)` `sm_(5)` `md(6)` `ml(8)` `lg(10)` `xl(14)` — always use `.continuous` corners.

### Motion

| Preset | Usage |
|--------|-------|
| `snappy` (0.20, 0.90) | Hover, press, toggle |
| `standard` (0.25, 0.85) | Expand/collapse, navigation |
| `gentle` (0.35, 0.80) | Panel slides, content entry |
| `bouncy` (0.30, 0.70) | Sheet present, picker |

### Opacity Tiers

`tint(0.04)` `subtle(0.08)` `light(0.12)` `medium(0.20)` `strong(0.40)` `vivid(0.70)`

## Rules That Prevent Bugs

1. **No ad-hoc colors** — Every color comes from `Theme.swift` / `tokens.css`. Zero hex literals in views.
2. **No ad-hoc spacing** — Every padding/margin uses `Spacing.*` / `--space-*` tokens.
3. **No ad-hoc radii** — Every corner radius uses `Radius.*` / `--radius-*` tokens.
4. **No ad-hoc animations** — Every animation uses `Motion.*` / `--transition-*` presets.
5. **Surfaces from accent** — Hover/selected/active backgrounds are `accent.opacity(OpacityTier.*)`, not custom colors.
6. **Edge bars are 3pt** — `EdgeBar.width` / `--edge-bar-width`, never 2pt or 4pt.
7. **Status has 5 states only** — Working, Permission, Question, Reply, Ended. No custom status colors.
8. **Feedback vs Status** — `feedback*` colors for general UI (save/error/warning). `status*` colors for session states only.

## Component Patterns

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

```css
.badge {
  display: inline-flex;
  align-items: center;
  gap: var(--space-xs);
  padding: 3px var(--space-sm);
  border-radius: 999px;
  font-size: var(--type-micro);
  font-weight: var(--font-weight-semibold);
  background: color-mix(in srgb, var(--badge-color) 15%, transparent);
  color: var(--badge-color);
}
```

### Card

```swift
content
  .padding(Spacing.md)
  .background(Color.backgroundTertiary)
  .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
    .stroke(Color.surfaceBorder, lineWidth: 1))
```

```css
.card {
  background: var(--color-bg-tertiary);
  border-radius: var(--radius-md);
  border: 1px solid var(--color-surface-border);
  box-shadow: var(--shadow-sm);
  padding: var(--space-md);
}
```

### Permission Banner

```swift
HStack(spacing: Spacing.md) {
  Image(systemName: "exclamationmark.triangle.fill")
    .foregroundStyle(Color.statusPermission)
  VStack(alignment: .leading, spacing: Spacing.xs) { /* tool info */ }
}
.padding(Spacing.lg_)
.background(Color.statusPermission.opacity(OpacityTier.light),
  in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
```

## Cross-Platform Layout

| Rule | Detail |
|------|--------|
| Start with `phoneCompact` | Scale up to pad/desktop, never scale down |
| No unguarded fixed widths | Use `.ifMacOS {}` for desktop-only frames |
| iOS sheets need detents | `.presentationDetents([.medium, .large])` + drag indicator |
| Touch targets | 44pt minimum on iOS, 28pt on macOS |
| Bottom actions on iPhone | `safeAreaInset(edge: .bottom)`, not floating in scroll |
| Truncation | `.lineLimit(1)` + `.truncationMode(.middle)` on all paths/identifiers |

## Accessibility

- All text tiers exceed WCAG AA contrast on darkest backgrounds
- Every status color has a unique icon fallback (not color-dependent)
- Respect `prefers-reduced-motion` / `isReduceMotionEnabled`
- Decorative elements use `.accessibilityHidden(true)`

## When to Apply

- Creating any new SwiftUI view, UIKit cell, or web component
- Choosing colors, spacing, typography, or corner radii for any element
- Adding status indicators, badges, or feedback states
- Building cross-platform shared views
- Reviewing PRs for design token compliance
- Working with `Theme.swift`, `DesignTokens.swift`, `tokens.css`, or `global.css`

## Deep Reference

See [references/REFERENCE.md](references/REFERENCE.md) for the complete design system
specification with full color tables, detailed component recipes, interaction pattern
guidelines, and the design philosophy.

Also see [docs/design-system.md](../../docs/design-system.md) for the narrative design
system document.

## Implementation Files

| File | Path | Contents |
|------|------|----------|
| Theme.swift | `OrbitDockNative/OrbitDock/Theme.swift` | All Color extensions, Spacing, TypeScale, Radius, OpacityTier, EdgeBar, component views |
| DesignTokens.swift | `OrbitDockNative/OrbitDock/DesignTokens.swift` | IconScale, LineHeight, ShadowToken, Shadow, Motion |
| tokens.css | `orbitdock-web/src/styles/tokens.css` | All CSS custom properties |
| global.css | `orbitdock-web/src/styles/global.css` | Base styles, scrollbar, selection, focus rings, reduced motion |
