# Cosmic Harbor Design System — Complete Reference

This is the exhaustive reference for OrbitDock's design system. The SKILL.md provides quick
lookup; this document provides the full specification, rationale, and implementation details.

For the canonical narrative version, see [docs/design-system.md](../../../docs/design-system.md).

---

## 1. Design Philosophy

### Mission Control Aesthetic

OrbitDock's visual language draws from aerospace control rooms and sci-fi command interfaces.
The goal is **professional density** — showing maximum useful information with zero wasted
space, while maintaining clear visual hierarchy so nothing competes for attention.

The app icon establishes the vocabulary:
- **Deep black canvas** — the void of space, maximum contrast backdrop
- **Glowing cyan orbital ring** — the brand accent, implies motion and purpose
- **Capsule in orbit** — agents are spacecraft; OrbitDock is where they dock
- **Crosshair targeting lines** — precision, control, mission-critical awareness
- **Docking station cradle** — a harbor, a home base

This vocabulary translates to UI as: dark backgrounds, cyan accent light, circular status
indicators, precise grid alignment, and structured containment.

### The Three Laws of Cosmic Harbor

1. **Light is information.** On a dark canvas, brightness correlates directly with urgency
   and importance. The brightest element on screen is always the thing that needs attention.
   Ended sessions dim. Active sessions glow. Permission requests pulse.

2. **Color is semantic.** Every color communicates meaning. Cyan means "OrbitDock / active."
   Coral means "needs permission." Purple means "agent asked a question." There are no
   decorative colors. If something is colored, it's telling you something.

3. **Space is hierarchy.** Generous spacing between groups, tight spacing within groups.
   The eye naturally clusters elements that are close together. Use this instead of borders
   whenever possible.

---

## 2. Complete Color Specification

### 2.1 Brand Colors

```
accent         = rgb(84, 174, 229)   = #54AEE5   — Primary brand, interactive elements
accentGlow     = rgb(89, 204, 250)   = #59CCFA   — Brighter for luminance/hover effects
accentMuted    = rgb(51, 128, 153)   = #338099   — Subtle tints, secondary badges
```

**Usage rules:**
- `accent` is the default for all interactive elements: links, buttons, active borders, toggles
- `accentGlow` is only for hover states and glow effects — never for static elements
- `accentMuted` is for backgrounds of badges and low-emphasis accent areas

### 2.2 Background System

Four-tier depth system with subtle indigo undertones:

```
backgroundCode      = rgb(10, 10, 13)    = #0A0A0D   — Deepest: code block interiors
backgroundPrimary   = rgb(15, 14, 17)    = #0F0E11   — Main canvas
backgroundSecondary = rgb(21, 20, 22)    = #151416   — Elevated: sidebars, headers
backgroundTertiary  = rgb(28, 27, 31)    = #1C1B1F   — Cards, tool cards, panels
panelBackground     = rgb(14, 14, 18)    = #0E0E12   — Slide-in panels (indigo cast)
```

**Design rationale:** Pure gray backgrounds feel cold and sterile. The slight indigo shift
(blue channel consistently 2-4 points higher than red/green) creates warmth that prevents
eye fatigue during long sessions without being visibly colored.

### 2.3 Text Hierarchy

```
textPrimary    = white @ 0.92   — Headings, session names, key values
textSecondary  = white @ 0.65   — Labels, descriptions, supporting text
textTertiary   = white @ 0.50   — Timestamps, counts, metadata
textQuaternary = white @ 0.38   — Hints, divider text, lowest priority
```

**WCAG contrast ratios on backgroundPrimary (#0F0E11):**
- textPrimary: ~15.3:1 (exceeds AAA 7:1)
- textSecondary: ~10.2:1 (exceeds AAA)
- textTertiary: ~7.6:1 (exceeds AA 4.5:1)
- textQuaternary: ~5.6:1 (exceeds AA)

**Critical implementation note:** SwiftUI's built-in `.foregroundStyle(.secondary)`,
`.tertiary`, and `.quaternary` resolve to system opacity values that are far too dim on
dark backgrounds (as low as 20% opacity). Always use the explicit `Color.text*` tokens.

### 2.4 Status Colors

The five-state status system is the most important color subsystem. Requirements:
- Must be instantly distinguishable at small sizes (8pt dots)
- Must be distinguishable by people with protanopia and deuteranopia
- Each state has a unique SF Symbol icon as non-color fallback

```
statusWorking    = rgb(84, 174, 229)   = #54AEE5  — cyan    — bolt.fill
statusPermission = rgb(242, 140, 107)  = #F28C6B  — coral   — lock.fill
statusQuestion   = rgb(191, 128, 242)  = #BF80F2  — purple  — questionmark.bubble.fill
statusReply      = rgb(115, 178, 255)  = #73B2FF  — blue    — bubble.left
statusEnded      = rgb(107, 102, 115)  = #6B6673  — gray    — moon.fill
statusError      = rgb(242, 102, 115)  = #F26673  — red     — exclamationmark.triangle.fill
```

**Urgency classification:**
- URGENT (Permission, Question): Bright, saturated, positioned first, counted in attention badge
- ACTIVE (Working): Brand cyan, calm "everything's fine" signal
- PASSIVE (Reply): Soft blue, gentle prompt without alarm
- INACTIVE (Ended): Desaturated gray, fades into background

### 2.5 Feedback Colors

For general UI states outside session status:

```
feedbackPositive = rgb(89, 209, 140)   = #59D18C  — green  — Success, saved, connected
feedbackCaution  = rgb(242, 191, 77)   = #F2BF4D  — amber  — Warning, approaching limits
feedbackWarning  = rgb(255, 153, 77)   = #FF994D  — orange — Bash errors, elevated warnings
feedbackNegative = rgb(242, 102, 115)  = #F26673  — red    — Error, disconnected, failure
```

**Status vs Feedback rule:** `status*` colors are ONLY for session states. `feedback*` colors
are for everything else (save confirmations, connection state, validation errors, etc.).
Never use `feedbackPositive` for a session state. Never use `statusWorking` for a save confirmation.

### 2.6 Model Colors

```
modelOpus   = rgb(179, 115, 242)  = #B373F2  — Cosmic purple
modelSonnet = rgb(102, 165, 255)  = #66A5FF  — Nebula blue
modelHaiku  = rgb(77, 217, 204)   = #4DD9CC  — Aqua teal
```

### 2.7 Provider Colors

```
providerClaude = accent            = #54AEE5  — Orbit cyan
providerCodex  = rgb(74, 198, 142) = #4AC68E  — Emerald green
providerGemini = rgb(102, 128, 230)= #6680E6  — Indigo
```

### 2.8 Tool Colors

Each tool type has a unique color for visual differentiation in tool cards and badges:

```
toolRead     = rgb(115, 178, 255)  = #73B2FF  — Soft blue
toolWrite    = rgb(255, 153, 77)   = #FF994D  — Orange
toolBash     = rgb(89, 216, 140)   = #59D88C  — Green
toolSearch   = rgb(166, 128, 242)  = #A680F2  — Purple
toolTask     = rgb(128, 140, 255)  = #808CFF  — Periwinkle
toolWeb      = accent              = #54AEE5  — Cyan
toolQuestion = rgb(255, 178, 77)   = #FFB24D  — Warm yellow
toolMcp      = rgb(140, 178, 217)  = #8CB2D9  — Slate blue
toolSkill    = rgb(217, 140, 229)  = #D98CE5  — Pink
toolPlan     = rgb(102, 191, 140)  = #66BF8C  — Mint
toolTodo     = rgb(178, 204, 115)  = #B2CC73  — Lime
```

### 2.9 MCP Server Colors

```
serverGitHub  = rgb(153, 128, 255)  = #9980FF  — Purple
serverLinear  = rgb(102, 140, 255)  = #668CFF  — Blue
serverChrome  = rgb(255, 153, 64)   = #FF9940  — Orange
serverSlack   = rgb(242, 102, 153)  = #F26699  — Pink
serverApple   = rgb(115, 191, 255)  = #73BFFF  — Light blue
serverDefault = accentMuted         = #338099  — Muted cyan
```

### 2.10 Autonomy Spectrum

Cool-to-warm gradient representing increasing risk level:

```
autonomyLocked       = rgb(51, 191, 207)   = #33BFCF  — Coolest (safest)
autonomyGuarded      = accent              = #54AEE5  — Cool
autonomyAutonomous   = rgb(89, 209, 140)   = #59D18C  — Neutral (green)
autonomyOpen         = rgb(242, 191, 77)   = #F2BF4D  — Warm (amber)
autonomyFullAuto     = rgb(255, 153, 77)   = #FF994D  — Warmer (orange)
autonomyUnrestricted = rgb(255, 115, 102)  = #FF7366  — Hottest (red)
```

This heat-map progression provides visceral, intuitive feedback about risk without
requiring the user to read labels.

### 2.11 Effort Levels

```
effortNone    = rgb(107, 102, 115)  = #6B6673  — Gray
effortMinimal = rgb(51, 191, 207)   = #33BFCF  — Teal
effortLow     = accent              = #54AEE5  — Cyan
effortMedium  = rgb(89, 209, 140)   = #59D18C  — Green
effortHigh    = rgb(242, 191, 77)   = #F2BF4D  — Amber
effortXHigh   = rgb(255, 140, 89)   = #FF8C59  — Orange
```

### 2.12 Composer Borders

Input mode communicated through border color:

```
composerPrompt = accent           = #54AEE5  — Cyan (default)
composerSteer  = toolWrite        = #FF994D  — Orange (mid-turn guidance)
composerReview = statusQuestion   = #BF80F2  — Purple (review feedback)
composerShell  = shellAccent      = #4DC766  — Green (terminal mode)
shellAccent    = rgb(77, 199, 102)= #4DC766  — Terminal green
```

### 2.13 Diff Colors

```
# Background washes (low-opacity tints)
diffAddedBg         = rgba(31, 66, 38, 0.30)
diffRemovedBg       = rgba(77, 31, 31, 0.30)

# Left edge bar indicators (saturated, opaque)
diffAddedEdge       = rgb(77, 199, 102)    = #4DC766
diffRemovedEdge     = rgb(217, 90, 90)     = #D95A5A

# Text/prefix accent colors
diffAddedAccent     = rgb(102, 242, 128)   = #66F280
diffRemovedAccent   = rgb(255, 128, 128)   = #FF8080

# Word-level inline highlights (subtle)
diffAddedHighlight  = rgba(102, 242, 128, 0.25)
diffRemovedHighlight= rgba(255, 128, 128, 0.25)
```

### 2.14 Syntax Highlighting

```
syntaxKeyword  = rgb(191, 128, 242)  = #BF80F2  — Nebula purple
syntaxString   = rgb(242, 166, 102)  = #F2A666  — Solar orange
syntaxNumber   = rgb(178, 217, 128)  = #B2D980  — Starchart lime
syntaxComment  = rgb(102, 128, 153)  = #668099  — Distant star gray
syntaxType     = accent              = #54AEE5  — Orbit cyan (brand!)
syntaxFunction = rgb(229, 217, 140)  = #E5D98C  — Signal yellow
syntaxProperty = rgb(140, 191, 255)  = #8CBFFF  — Atmosphere blue
syntaxText     = rgb(220, 222, 230)  = #DCDEE6  — Starlight
```

### 2.15 Markdown Theme Colors

```
markdownInlineCode = rgb(242, 179, 115)  = #F2B373  — Warm signal orange
markdownLink       = accent              = #54AEE5  — Orbit cyan
markdownBlockquote = rgb(153, 128, 242)  = #9980F2  — Nebula purple
```

### 2.16 Surface & Interaction States

Built from accent at varying opacities for consistent interaction feedback:

```
surfaceHover    = accent @ 0.06   — Mouse hover highlight
surfaceBorder   = accent @ 0.10   — Default subtle border
surfaceSelected = accent @ 0.12   — Selected item background
surfaceActive   = accent @ 0.20   — Active/pressed state
surfaceElevated = white @ 0.04    — Raised surface (turn cards)
rowHighlight    = rgba(38, 46, 72, 0.35) — Row highlight (indigo-tinted)
```

### 2.17 Glow Effects

```
# CSS box-shadow format
glow-accent         = 0 0 20px rgba(84, 174, 229, 0.15)
glow-accent-strong  = 0 0 30px rgba(84, 174, 229, 0.25)
glow-permission     = 0 0 20px rgba(242, 140, 107, 0.15)
glow-question       = 0 0 20px rgba(191, 128, 242, 0.15)
glow-positive       = 0 0 20px rgba(89, 209, 140, 0.15)
```

### 2.18 Language Badge Colors

```
langSwift      = rgb(255, 140, 77)   = #FF8C4D  — Orange
langJavaScript = rgb(242, 217, 102)  = #F2D966  — Yellow
langPython     = rgb(102, 165, 255)  = #66A5FF  — Blue
langRuby       = rgb(242, 102, 102)  = #F26666  — Red
langGo         = accent              = #54AEE5  — Cyan
langRust       = rgb(242, 140, 77)   = #F28C4D  — Orange
langBash       = rgb(89, 217, 140)   = #59D98C  — Green
langJSON       = rgb(179, 128, 242)  = #B380F2  — Purple
langHTML       = rgb(242, 115, 102)  = #F27366  — Red
langCSS        = rgb(102, 140, 255)  = #668CFF  — Blue
langSQL        = accent              = #54AEE5  — Cyan
```

---

## 3. Typography System

Full reference in [docs/typography.md](../../../docs/typography.md).

### 3.1 Type Scale

```swift
enum TypeScale {
  static let mini: CGFloat = 9        // Tiny badge labels
  static let micro: CGFloat = 10      // Token counts, utility meta
  static let caption: CGFloat = 12    // Button text, line numbers
  static let label: CGFloat = 12      // Role labels, form labels
  static let body: CGFloat = 13       // Standard UI text
  static let code: CGFloat = 13       // Monospaced inline code
  static let subhead: CGFloat = 14    // Secondary emphasis
  static let title: CGFloat = 15      // Control text
  static let reading: CGFloat = 15    // User prompts, prose
  static let chatLabel: CGFloat = 12  // "Assistant", "You" labels
  static let chatBody: CGFloat = 15   // Conversation prose
  static let chatHeading1: CGFloat = 22
  static let chatHeading2: CGFloat = 18
  static let chatHeading3: CGFloat = 16
  static let chatCode: CGFloat = 14   // Code in responses
  static let headline: CGFloat = 22   // Section headers
  static let large: CGFloat = 16      // Project names
  static let meta: CGFloat = 11       // Badges, compact names
}
```

### 3.2 Web CSS Type Scale

```css
--type-mini: 9px;
--type-micro: 10px;
--type-caption: 11px;
--type-meta: 12px;
--type-body: 13px;
--type-code: 13px;
--type-subhead: 14px;
--type-reading: 15px;
--type-title: 17px;
--type-large: 20px;
--type-headline: 24px;
```

### 3.3 Font Stacks

```css
--font-system: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
--font-mono: 'SF Mono', 'Fira Code', 'Cascadia Code', 'JetBrains Mono', monospace;
```

### 3.4 Line Heights

```swift
enum LineHeight {
  static let tight: CGFloat = 14      // Micro text (10pt)
  static let body: CGFloat = 18       // Standard body (13pt)
  static let code: CGFloat = 21       // Code blocks (13-14pt)
  static let reading: CGFloat = 22    // Chat prose (15pt)
  static let heading: CGFloat = 28    // Headlines (22pt)
}
```

### 3.5 Letter Spacing

```css
--letter-spacing-tight: -0.02em;   /* Headlines, large text */
--letter-spacing-wide: 0.05em;     /* Small caps, labels */
--letter-spacing-label: 0.06em;    /* All-caps section headers */
```

---

## 4. Spacing System

### 4.1 4pt Base Grid

```swift
enum Spacing {
  static let xxs: CGFloat = 2       // Bare minimum
  static let gap: CGFloat = 3       // Icon-to-text in mini badges
  static let xs: CGFloat = 4        // Tight padding
  static let sm_: CGFloat = 6       // Badge padding
  static let sm: CGFloat = 8        // Comfortable small
  static let md_: CGFloat = 10      // Section gaps
  static let md: CGFloat = 12       // Standard padding
  static let lg_: CGFloat = 14      // Panel inner padding
  static let lg: CGFloat = 16       // Large spacing
  static let section: CGFloat = 20  // Between major sections
  static let xl: CGFloat = 24       // Extra large
  static let xxl: CGFloat = 32      // Maximum breathing room
}
```

### 4.2 Edge Bar

```swift
enum EdgeBar {
  static let width: CGFloat = 3     // Left-edge status bars
}
```

Always 3pt. Never 2pt, never 4pt. This is a signature visual element.

---

## 5. Corner Radius System

```swift
enum Radius {
  static let xs: CGFloat = 2    // Progress bars, thin elements
  static let sm: CGFloat = 4    // Small interactive elements
  static let sm_: CGFloat = 5   // Badges, chips
  static let md: CGFloat = 6    // Standard cards, code blocks
  static let ml: CGFloat = 8    // Buttons, input fields
  static let lg: CGFloat = 10   // Large cards, panels
  static let xl: CGFloat = 14   // Extra large components
}
```

Web adds: `--radius-bubble: 16px` for message bubbles.

**Always use continuous corners** (`.continuous` corner style in SwiftUI). They produce
optically smoother curves than circular arcs and match Apple's design language.

---

## 6. Opacity Tiers

```swift
enum OpacityTier {
  static let tint: Double = 0.04     // Barely visible surface tints
  static let subtle: Double = 0.08   // Subtle hover backgrounds
  static let light: Double = 0.12    // Selected states, badge fills
  static let medium: Double = 0.20   // Active states
  static let strong: Double = 0.40   // Prominent overlays
  static let vivid: Double = 0.70    // Near-opaque overlays
}
```

---

## 7. Icon System

### 7.1 Icon Scale

```swift
enum IconScale {
  static let xs: CGFloat = 8    // Mini badge decorations
  static let sm: CGFloat = 9    // Compact badges, chevrons
  static let md: CGFloat = 10   // Standard tool card icons
  static let lg: CGFloat = 11   // Section headers, labels
  static let xl: CGFloat = 12   // Status indicators, banners
  static let xxl: CGFloat = 14  // Empty states, dialogs
  static let hero: CGFloat = 16 // Onboarding, hero moments
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

## 8. Shadow & Elevation

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

### 8.2 Shadow Tokens (Web)

```css
--shadow-sm: 0 1px 3px rgba(0,0,0,0.25), 0 1px 2px rgba(0,0,0,0.15);
--shadow-md: 0 4px 16px rgba(0,0,0,0.35), 0 2px 4px rgba(0,0,0,0.2);
--shadow-lg: 0 12px 40px rgba(0,0,0,0.45), 0 4px 12px rgba(0,0,0,0.25);
--shadow-dialog: 0 20px 60px rgba(0,0,0,0.5), var(--glow-accent);
--shadow-composer: 0 -4px 16px rgba(0,0,0,0.20);
```

---

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

```css
--transition-fast: 0.1s ease;
--transition-normal: 0.2s ease;
--transition-slow: 0.3s ease;
```

---

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

```css
.card {
  background: var(--color-bg-tertiary);
  border-radius: var(--radius-md);
  border: 1px solid var(--color-surface-border);
  box-shadow: var(--shadow-sm);
  padding: var(--space-md);
}
```

### 10.3 Button Variants

```css
/* Primary */
.button-primary {
  background: var(--color-accent);
  color: #fff;
  border: none;
  border-radius: var(--radius-md);
  padding: var(--space-xs) var(--space-md);
  font-weight: var(--font-weight-medium);
}
.button-primary:hover { background: var(--color-accent-glow); }

/* Secondary */
.button-secondary {
  background: var(--color-surface-elevated);
  color: var(--color-text-primary);
  border: 1px solid var(--color-surface-border);
}

/* Ghost */
.button-ghost {
  background: transparent;
  color: var(--color-accent);
  border: none;
}
.button-ghost:hover { background: var(--color-surface-hover); }

/* Danger */
.button-danger {
  background: color-mix(in srgb, var(--color-feedback-negative) 12%, transparent);
  color: var(--color-feedback-negative);
}
```

### 10.4 Permission Banner

```swift
HStack(spacing: Spacing.md) {
  Image(systemName: "exclamationmark.triangle.fill")
    .font(.system(size: TypeScale.large, weight: .semibold))
    .foregroundStyle(Color.statusPermission)

  VStack(alignment: .leading, spacing: Spacing.xs) {
    HStack(spacing: Spacing.sm_) {
      Text("Permission:").font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.statusPermission)
      Text(toolName).font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(.primary)
    }
    HStack(spacing: Spacing.sm_) {
      Image(systemName: info.icon).font(.system(size: TypeScale.meta, weight: .medium))
      Text(info.detail).font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
    }
    .foregroundStyle(.secondary)
  }
  Spacer()
}
.padding(Spacing.lg_)
.background(Color.statusPermission.opacity(OpacityTier.light),
  in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
.overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
  .stroke(Color.statusPermission.opacity(0.25), lineWidth: 1))
```

### 10.5 Status Badge (SessionStatusBadge)

Three sizes: mini (dot only), compact (small text), regular (icon + text), large (headers).

```swift
// Regular size
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
  .frame(width: size * 2.5, height: size * 2.5)  // Touch target padding
```

---

## 11. Cross-Platform Layout

### 11.1 Layout Modes

```swift
enum DashboardLayoutMode {
  case phoneCompact  // iPhone, any orientation
  case pad           // iPad, any orientation
  case desktop       // macOS
}
```

### 11.2 Breakpoints (Web)

```css
/* Reference — not usable in @media directly as CSS vars */
--bp-mobile: 480px;
--bp-tablet: 768px;
--bp-desktop: 1024px;
```

### 11.3 Z-Index Layers (Web)

```css
--z-sidebar-backdrop: 40;
--z-popover: 50;
--z-sidebar: 50;
--z-dropdown: 100;
--z-modal: 200;
--z-toast: 500;
--z-offline: 2000;
```

### 11.4 Platform-Specific Rules

| Feature | macOS | iPad | iPhone | Web |
|---------|-------|------|--------|-----|
| Hover states | Yes | No | No | Yes |
| Keyboard shortcuts | Full | Some | Minimal | Full |
| Sidebar | Always visible | Toggle | Sheet | Toggle/responsive |
| Density | High | Medium | Low | Responsive |
| Min touch target | 28pt | 44pt | 44pt | 44px |
| Fixed widths | Allowed | Guarded | Never | Responsive |
| Sheets | System | Detents | Detents + drag | Modal |
| Bottom actions | Toolbar | Flexible | safeAreaInset | Sticky footer |

---

## 12. Accessibility

### 12.1 Contrast Ratios

All text tiers verified against WCAG 2.1 on darkest background (#0A0A0D):

| Tier | Ratio | WCAG Level |
|------|-------|------------|
| textPrimary (0.92) | ~17:1 | AAA |
| textSecondary (0.65) | ~12:1 | AAA |
| textTertiary (0.50) | ~9:1 | AAA |
| textQuaternary (0.38) | ~6.8:1 | AA |

### 12.2 Color Vision Deficiency

Status colors are selected to remain distinguishable under protanopia (red-blind) and
deuteranopia (green-blind) simulations. Each status also has a unique SF Symbol icon as a
non-color signal channel.

### 12.3 Reduced Motion

```swift
// Native
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
  // Use .linear(duration: 0) or no animation
}
```

```css
/* Web */
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

### 12.4 Focus Indicators

```css
:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}
:focus:not(:focus-visible) {
  outline: none;
}
```

---

## 13. Implementation Files

| File | Path | Contents |
|------|------|----------|
| Theme.swift | `OrbitDockNative/OrbitDock/Theme.swift` | All Color extensions, Spacing, TypeScale, Radius, OpacityTier, EdgeBar, SessionDisplayStatus, component views |
| DesignTokens.swift | `OrbitDockNative/OrbitDock/DesignTokens.swift` | IconScale, LineHeight, ShadowToken, Shadow, Motion |
| tokens.css | `orbitdock-web/src/styles/tokens.css` | All CSS custom properties |
| global.css | `orbitdock-web/src/styles/global.css` | Base styles, scrollbar, selection, focus rings, reduced motion |

---

## 14. Gradients

```css
--gradient-surface: linear-gradient(180deg, rgba(255,255,255,0.03) 0%, rgba(255,255,255,0) 100%);
--gradient-accent-subtle: linear-gradient(135deg, rgba(84,174,229,0.05) 0%, rgba(84,174,229,0) 100%);
```

Use gradients sparingly. They add subtle dimensionality to elevated surfaces but should
never be the primary visual element.

---

## 15. Scrollbar Styling (Web)

```css
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.25); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.40); }
```

---

## 16. Selection Color

```css
::selection { background: rgba(84, 174, 229, 0.3); }
```

Uses the accent color at 30% opacity for text selection highlighting.
