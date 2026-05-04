# Cosmic Harbor Design System — Complete Reference

This is the exhaustive reference for OrbitDock's design system. `SKILL.md` is the quick
working guide. This file carries the full specification, rationale, and implementation detail
for Codex and any other agents working in this repo.

For the canonical narrative version, see [docs/design-system.md](../../../docs/design-system.md).

---

## 1. Design Philosophy

### Mission Control Aesthetic

OrbitDock's visual language draws from aerospace control rooms and sci-fi command interfaces.
The goal is professional density: maximum useful information, zero wasted space, and clear
hierarchy so nothing competes for attention.

The app icon establishes the vocabulary:
- Deep black canvas: the void of space, maximum-contrast backdrop
- Glowing cyan orbital ring: the brand accent, implying motion and purpose
- Capsule in orbit: agents are spacecraft; OrbitDock is where they dock
- Crosshair targeting lines: precision, control, mission-critical awareness
- Docking station cradle: a harbor, a home base

This vocabulary translates into dark backgrounds, cyan accent light, circular status
indicators, precise grid alignment, and structured containment.

### The Three Laws of Cosmic Harbor

1. Light is information. On a dark canvas, brightness correlates directly with urgency and importance. The brightest element on screen is the thing that needs attention.
2. Color is semantic. Every color communicates meaning. There are no decorative colors.
3. Space is hierarchy. Generous spacing between groups, tight spacing within groups. Use spacing to imply structure before adding borders.

---

## 2. Complete Color Specification

### 2.1 Brand Colors

```text
accent         = rgb(84, 174, 229)   = #54AEE5   — Primary brand, interactive elements
accentGlow     = rgb(89, 204, 250)   = #59CCFA   — Brighter for luminance and hover effects
accentMuted    = rgb(51, 128, 153)   = #338099   — Subtle tints, secondary badges
```

Usage rules:
- `accent` is the default for links, buttons, active borders, and toggles
- `accentGlow` is for hover and glow states, not static elements
- `accentMuted` is for low-emphasis accent surfaces

### 2.2 Background System

Four-tier depth system with subtle indigo undertones:

```text
backgroundCode      = rgb(10, 10, 13)    = #0A0A0D   — Deepest: code block interiors
backgroundPrimary   = rgb(15, 14, 17)    = #0F0E11   — Main canvas
backgroundSecondary = rgb(21, 20, 22)    = #151416   — Elevated: sidebars, headers
backgroundTertiary  = rgb(28, 27, 31)    = #1C1B1F   — Cards, tool cards, panels
panelBackground     = rgb(14, 14, 18)    = #0E0E12   — Slide-in panels
```

Pure gray backgrounds feel cold and sterile. The indigo shift keeps the UI warm enough for long sessions without reading as visibly blue.

### 2.3 Text Hierarchy

```text
textPrimary    = white @ 0.92   — Headings, session names, key values
textSecondary  = white @ 0.65   — Labels, descriptions, supporting text
textTertiary   = white @ 0.50   — Timestamps, counts, metadata
textQuaternary = white @ 0.38   — Hints, divider text, lowest priority
```

WCAG contrast on `backgroundPrimary`:
- `textPrimary`: ~15.3:1
- `textSecondary`: ~10.2:1
- `textTertiary`: ~7.6:1
- `textQuaternary`: ~5.6:1

Critical implementation note: SwiftUI `.foregroundStyle(.secondary)`, `.tertiary`, and `.quaternary` resolve too dimly on OrbitDock’s dark backgrounds. Use explicit `Color.text*` tokens instead.

### 2.4 Status Colors

The five-state status system is the most important color subsystem. It must be distinguishable at small sizes and always have a non-color fallback icon.

```text
statusWorking    = rgb(84, 174, 229)   = #54AEE5  — cyan    — bolt.fill
statusPermission = rgb(242, 140, 107)  = #F28C6B  — coral   — lock.fill
statusQuestion   = rgb(191, 128, 242)  = #BF80F2  — purple  — questionmark.bubble.fill
statusReply      = rgb(115, 178, 255)  = #73B2FF  — blue    — bubble.left
statusEnded      = rgb(107, 102, 115)  = #6B6673  — gray    — moon.fill
statusError      = rgb(242, 102, 115)  = #F26673  — red     — exclamationmark.triangle.fill
```

Urgency classification:
- Urgent: Permission, Question
- Active: Working
- Passive: Reply
- Inactive: Ended

### 2.5 Feedback Colors

For UI states outside session status:

```text
feedbackPositive = rgb(89, 209, 140)   = #59D18C  — Success, saved, connected
feedbackCaution  = rgb(242, 191, 77)   = #F2BF4D  — Warning, approaching limits
feedbackWarning  = rgb(255, 153, 77)   = #FF994D  — Elevated warnings
feedbackNegative = rgb(242, 102, 115)  = #F26673  — Error, disconnected, failure
```

Status vs feedback rule:
- `status*` colors are only for session states
- `feedback*` colors are for everything else

### 2.6 Model Colors

```text
modelOpus   = rgb(179, 115, 242)  = #B373F2
modelSonnet = rgb(102, 165, 255)  = #66A5FF
modelHaiku  = rgb(77, 217, 204)   = #4DD9CC
```

### 2.7 Provider Colors

```text
providerClaude = accent             = #54AEE5
providerCodex  = rgb(74, 198, 142)  = #4AC68E
providerGemini = rgb(102, 128, 230) = #6680E6
```

### 2.8 Tool Colors

```text
toolRead     = rgb(115, 178, 255)  = #73B2FF
toolWrite    = rgb(255, 153, 77)   = #FF994D
toolBash     = rgb(89, 216, 140)   = #59D88C
toolSearch   = rgb(166, 128, 242)  = #A680F2
toolTask     = rgb(128, 140, 255)  = #808CFF
toolWeb      = accent              = #54AEE5
toolQuestion = rgb(255, 178, 77)   = #FFB24D
toolMcp      = rgb(140, 178, 217)  = #8CB2D9
toolSkill    = rgb(217, 140, 229)  = #D98CE5
toolPlan     = rgb(102, 191, 140)  = #66BF8C
toolTodo     = rgb(178, 204, 115)  = #B2CC73
```

### 2.9 MCP Server Colors

```text
serverGitHub  = rgb(153, 128, 255)  = #9980FF
serverLinear  = rgb(102, 140, 255)  = #668CFF
serverChrome  = rgb(255, 153, 64)   = #FF9940
serverSlack   = rgb(242, 102, 153)  = #F26699
serverApple   = rgb(115, 191, 255)  = #73BFFF
serverDefault = accentMuted         = #338099
```

### 2.10 Autonomy Spectrum

```text
autonomyLocked       = rgb(51, 191, 207)   = #33BFCF
autonomyGuarded      = accent              = #54AEE5
autonomyAutonomous   = rgb(89, 209, 140)   = #59D18C
autonomyOpen         = rgb(242, 191, 77)   = #F2BF4D
autonomyFullAuto     = rgb(255, 153, 77)   = #FF994D
autonomyUnrestricted = rgb(255, 115, 102)  = #FF7366
```

### 2.11 Effort Levels

```text
effortNone    = rgb(107, 102, 115)  = #6B6673
effortMinimal = rgb(51, 191, 207)   = #33BFCF
effortLow     = accent              = #54AEE5
effortMedium  = rgb(89, 209, 140)   = #59D18C
effortHigh    = rgb(242, 191, 77)   = #F2BF4D
effortXHigh   = rgb(255, 140, 89)   = #FF8C59
```

### 2.12 Composer Borders

```text
composerPrompt = accent            = #54AEE5
composerSteer  = toolWrite         = #FF994D
composerReview = statusQuestion    = #BF80F2
composerShell  = shellAccent       = #4DC766
shellAccent    = rgb(77, 199, 102) = #4DC766
```

### 2.13 Diff Colors

```text
diffAddedBg          = rgba(31, 66, 38, 0.30)
diffRemovedBg        = rgba(77, 31, 31, 0.30)
diffAddedEdge        = rgb(77, 199, 102)    = #4DC766
diffRemovedEdge      = rgb(217, 90, 90)     = #D95A5A
diffAddedAccent      = rgb(102, 242, 128)   = #66F280
diffRemovedAccent    = rgb(255, 128, 128)   = #FF8080
diffAddedHighlight   = rgba(102, 242, 128, 0.25)
diffRemovedHighlight = rgba(255, 128, 128, 0.25)
```

### 2.14 Syntax Highlighting

```text
syntaxKeyword  = rgb(191, 128, 242)  = #BF80F2
syntaxString   = rgb(242, 166, 102)  = #F2A666
syntaxNumber   = rgb(178, 217, 128)  = #B2D980
syntaxComment  = rgb(102, 128, 153)  = #668099
syntaxType     = accent              = #54AEE5
syntaxFunction = rgb(229, 217, 140)  = #E5D98C
syntaxProperty = rgb(140, 191, 255)  = #8CBFFF
syntaxText     = rgb(220, 222, 230)  = #DCDEE6
```

### 2.15 Markdown Theme Colors

```text
markdownInlineCode = rgb(242, 179, 115)  = #F2B373
markdownLink       = accent              = #54AEE5
markdownBlockquote = rgb(153, 128, 242)  = #9980F2
```

### 2.16 Surface and Interaction States

```text
surfaceHover    = accent @ 0.06   — Mouse hover highlight
surfaceBorder   = accent @ 0.10   — Default subtle border
surfaceSelected = accent @ 0.12   — Selected item background
surfaceActive   = accent @ 0.20   — Active and pressed state
surfaceElevated = white @ 0.04    — Raised surface
rowHighlight    = rgba(38, 46, 72, 0.35)
```

### 2.17 Glow Effects

```text
glow-accent        = 0 0 20px rgba(84, 174, 229, 0.15)
glow-accent-strong = 0 0 30px rgba(84, 174, 229, 0.25)
glow-permission    = 0 0 20px rgba(242, 140, 107, 0.15)
glow-question      = 0 0 20px rgba(191, 128, 242, 0.15)
glow-positive      = 0 0 20px rgba(89, 209, 140, 0.15)
```

### 2.18 Language Badge Colors

```text
langSwift      = rgb(255, 140, 77)   = #FF8C4D
langJavaScript = rgb(242, 217, 102)  = #F2D966
langPython     = rgb(102, 165, 255)  = #66A5FF
langRuby       = rgb(242, 102, 102)  = #F26666
langGo         = accent              = #54AEE5
langRust       = rgb(242, 140, 77)   = #F28C4D
langBash       = rgb(89, 217, 140)   = #59D98C
langJSON       = rgb(179, 128, 242)  = #B380F2
langHTML       = rgb(242, 115, 102)  = #F27366
langCSS        = rgb(102, 140, 255)  = #668CFF
langSQL        = accent              = #54AEE5
```

---

## 3. Typography System

Full reference in [docs/typography.md](../../../docs/typography.md).

### 3.1 Type Scale

```swift
enum TypeScale {
  static let mini: CGFloat = 9
  static let micro: CGFloat = 10
  static let caption: CGFloat = 12
  static let label: CGFloat = 12
  static let body: CGFloat = 13
  static let code: CGFloat = 13
  static let subhead: CGFloat = 14
  static let title: CGFloat = 15
  static let reading: CGFloat = 15
  static let chatLabel: CGFloat = 12
  static let chatBody: CGFloat = 15
  static let chatHeading1: CGFloat = 22
  static let chatHeading2: CGFloat = 18
  static let chatHeading3: CGFloat = 16
  static let chatCode: CGFloat = 14
  static let headline: CGFloat = 22
  static let large: CGFloat = 16
  static let meta: CGFloat = 11
}
```

### 3.4 Line Heights

```swift
enum LineHeight {
  static let tight: CGFloat = 14
  static let body: CGFloat = 18
  static let code: CGFloat = 21
  static let reading: CGFloat = 22
  static let heading: CGFloat = 28
}
```

## 4. Spacing System

### 4.1 4pt Base Grid

```swift
enum Spacing {
  static let xxs: CGFloat = 2
  static let gap: CGFloat = 3
  static let xs: CGFloat = 4
  static let sm_: CGFloat = 6
  static let sm: CGFloat = 8
  static let md_: CGFloat = 10
  static let md: CGFloat = 12
  static let lg_: CGFloat = 14
  static let lg: CGFloat = 16
  static let section: CGFloat = 20
  static let xl: CGFloat = 24
  static let xxl: CGFloat = 32
}
```

### 4.2 Edge Bar

```swift
enum EdgeBar {
  static let width: CGFloat = 3
}
```

Always 3pt. Never 2pt, never 4pt.

---

## 5. Corner Radius System

```swift
enum Radius {
  static let xs: CGFloat = 2
  static let sm: CGFloat = 4
  static let sm_: CGFloat = 5
  static let md: CGFloat = 6
  static let ml: CGFloat = 8
  static let lg: CGFloat = 10
  static let xl: CGFloat = 14
}
```

Always use continuous corners in SwiftUI.

---

## 6. Opacity Tiers

```swift
enum OpacityTier {
  static let tint: Double = 0.04
  static let subtle: Double = 0.08
  static let light: Double = 0.12
  static let medium: Double = 0.20
  static let strong: Double = 0.40
  static let vivid: Double = 0.70
}
```

---

## 7. Icon System

### 7.1 Icon Scale

```swift
enum IconScale {
  static let xs: CGFloat = 8
  static let sm: CGFloat = 9
  static let md: CGFloat = 10
  static let lg: CGFloat = 11
  static let xl: CGFloat = 12
  static let xxl: CGFloat = 14
  static let hero: CGFloat = 16
}
```

### 7.2 Status Icons

| Status | Icon |
|--------|------|
| Working | `bolt.fill` |
| Permission | `lock.fill` |
| Question | `questionmark.bubble.fill` |
| Reply | `bubble.left` |
| Ended | `moon.fill` |
| Error | `exclamationmark.triangle.fill` |

---

## 8. Shadow and Elevation

### 8.1 Shadow Tokens (Native)

```swift
enum Shadow {
  static let sm = ShadowToken(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
  static let md = ShadowToken(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
  static let lg = ShadowToken(color: .black.opacity(0.30), radius: 12, x: 0, y: 4)

  static func glow(color: Color, intensity: Double = 0.4) -> ShadowToken {
    ShadowToken(color: color.opacity(intensity), radius: 4, x: 0, y: 0)
  }
}
```

## 9. Motion System

```swift
enum Motion {
  static let snappy = Animation.spring(response: 0.20, dampingFraction: 0.90)
  static let standard = Animation.spring(response: 0.25, dampingFraction: 0.85)
  static let gentle = Animation.spring(response: 0.35, dampingFraction: 0.80)
  static let bouncy = Animation.spring(response: 0.30, dampingFraction: 0.70)
  static let hover = Animation.easeOut(duration: 0.15)
  static let fade = Animation.easeOut(duration: 0.25)
}
```

## 10. Component Recipes

### 10.1 Badge

```swift
HStack(spacing: Spacing.gap) {
  if let icon {
    Image(systemName: icon)
      .font(.system(size: IconScale.sm, weight: .semibold))
  }
  Text(label)
    .font(.system(size: TypeScale.mini, weight: .semibold))
}
.foregroundStyle(color)
.padding(.horizontal, Spacing.sm_)
.padding(.vertical, Spacing.gap)
.background(color.opacity(OpacityTier.light), in: Capsule())
```

### 10.2 Card

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

### 10.3 Permission Banner

```swift
HStack(spacing: Spacing.md) {
  Image(systemName: "exclamationmark.triangle.fill")
    .font(.system(size: TypeScale.large, weight: .semibold))
    .foregroundStyle(Color.statusPermission)

  VStack(alignment: .leading, spacing: Spacing.xs) {
    HStack(spacing: Spacing.sm_) {
      Text("Permission:")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.statusPermission)
      Text(toolName)
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(.primary)
    }
    HStack(spacing: Spacing.sm_) {
      Image(systemName: info.icon)
        .font(.system(size: TypeScale.meta, weight: .medium))
      Text(info.detail)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
    }
    .foregroundStyle(.secondary)
  }
  Spacer()
}
.padding(Spacing.lg_)
.background(
  Color.statusPermission.opacity(OpacityTier.light),
  in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
)
.overlay(
  RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    .stroke(Color.statusPermission.opacity(0.25), lineWidth: 1)
)
```

### 10.5 Status Badge

```swift
HStack(spacing: Spacing.xs) {
  Image(systemName: status.icon)
    .font(.system(size: IconScale.xs, weight: .bold))
  Text(status.label)
    .font(.system(size: TypeScale.micro, weight: .semibold))
}
.foregroundStyle(status.color)
.padding(.horizontal, Spacing.sm)
.padding(.vertical, Spacing.gap)
.background(status.color.opacity(OpacityTier.light), in: Capsule())
```

### 10.6 Status Dot

```swift
Circle()
  .fill(status.color)
  .frame(width: size, height: size)
  .shadow(
    color: showGlow && status != .ended
      ? Shadow.glow(color: status.color).color : .clear,
    radius: Shadow.glow(color: status.color).radius
  )
  .frame(width: size * 2.5, height: size * 2.5)
```

---

## 11. Cross-Platform Layout

### 11.1 Layout Modes

```swift
enum DashboardLayoutMode {
  case phoneCompact
  case pad
  case desktop
}
```

### 11.2 Platform-Specific Rules

| Feature | macOS | iPad | iPhone |
|---------|-------|------|--------|
| Hover states | Yes | No | No |
| Keyboard shortcuts | Full | Some | Minimal |
| Sidebar | Always visible | Toggle | Sheet |
| Density | High | Medium | Low |
| Min touch target | 28pt | 44pt | 44pt |
| Fixed widths | Allowed | Guarded | Never |
| Sheets | System | Detents | Detents and drag |
| Bottom actions | Toolbar | Flexible | `safeAreaInset` |

---

## 12. Accessibility

### 12.1 Contrast Ratios

All text tiers are verified against WCAG 2.1 on `#0A0A0D`:

| Tier | Ratio | WCAG Level |
|------|-------|------------|
| `textPrimary` | ~17:1 | AAA |
| `textSecondary` | ~12:1 | AAA |
| `textTertiary` | ~9:1 | AAA |
| `textQuaternary` | ~6.8:1 | AA |

### 12.2 Color Vision Deficiency

Status colors remain distinguishable under common red-green deficiencies, and each state has an icon fallback.

### 12.3 Reduced Motion

```swift
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
  // Use no animation or effectively instant transitions
}
```

### 12.4 Focus Indicators

Use system focus rings, enhanced with accent color where needed.

---

## 13. Implementation Files

| File | Path | Contents |
|------|------|----------|
| `Theme.swift` | `OrbitDockNative/OrbitDock/Theme.swift` | Colors, spacing, type, radii, opacity, edge bars, shared component styling |
| `DesignTokens.swift` | `OrbitDockNative/OrbitDock/DesignTokens.swift` | Icon scale, line height, shadow tokens, motion |

---
