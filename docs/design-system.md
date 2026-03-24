# OrbitDock Design System

**Cosmic Harbor** — A design language for mission control.

OrbitDock is where engineers orchestrate AI coding agents across projects, providers, and platforms. The design system exists to make that orchestration feel calm, confident, and immediate — whether you're triaging 12 active sessions on a 27" display or glancing at your phone to approve a bash command.

---

## Design Philosophy

### 1. Mission Control, Not a Toy

OrbitDock borrows from aerospace control rooms: dense information, clear hierarchy, zero ambiguity about what needs attention. The space theme is restraint-first — it sets tone through color and light, not through decorative illustration or gratuitous gradients.

The icon tells the story: a glowing orbital ring on deep black, a capsule in motion, a docking cradle waiting. That's the entire visual vocabulary — **light on dark, motion within structure, a harbor for things in flight.**

### 2. Calm Density

The app is text-heavy by nature: conversations, code diffs, tool logs, token counts. The design must be *information-dense without being overwhelming*. This means:

- Dark backgrounds that recede, letting content float forward
- Generous whitespace between sections, tight spacing within them
- Color used semantically (never decoratively)
- Progressive disclosure — show the summary, reveal the detail on demand

### 3. Status at a Glance

The most important design job is answering "what needs my attention right now?" in under one second. Every visual decision — status colors, glow effects, badge placement, sort order — serves this goal. If a user has to read text to understand urgency, the design has failed.

### 4. Platform-Native, Visually Unified

The *visual identity* is consistent everywhere. The *interaction patterns* respect each platform's conventions:

- macOS gets hover states, keyboard shortcuts, pointer precision, compact information density
- iPad gets comfortable touch targets, split views, and spatial layouts
- iPhone gets single-column flows, bottom actions, sheets with detents
- Web gets responsive layouts, keyboard navigation, and scrollbar styling

Same colors, same tokens, same hierarchy. Different ergonomics.

---

## Visual Identity

### The Orbit

The orbital ring from the app icon is the core brand element. It appears throughout the UI as:

- **Accent color** — The cyan that marks interactive elements, active states, and brand moments
- **Glow effects** — Subtle radiance around active sessions, focused inputs, and status indicators
- **Circular motifs** — Status dots, progress rings, the orbital metaphor of agents circling their work

### Color Temperature

The palette sits in the **cool-neutral to warm-charcoal** range. Backgrounds have subtle indigo undertones (not pure gray), giving the "deep space" feeling without being cold. This warmth prevents eye fatigue during long sessions.

### Light as Information

On a dark canvas, light carries meaning:

- **Bright elements demand attention** — status badges, permission banners, active glows
- **Dim elements provide context** — timestamps, token counts, ended sessions
- **The brightest things in the UI are always the things that need action**

---

## Color System

All colors are defined once in `Theme.swift` (native) and `tokens.css` (web). No ad-hoc hex values anywhere.

### Brand

| Token | Value | Usage |
|-------|-------|-------|
| `accent` | `#54AEE5` | Primary interactive color, links, active states, brand cohesion |
| `accentGlow` | `#59CCFA` | Hover/glow states, slightly brighter for luminance effects |
| `accentMuted` | `#338099` | Subtle accent tints, secondary badges, disabled accent states |

The accent is the orbital cyan from the app icon. It appears on links, active borders, the working status, code type annotations, and any element that says "this is OrbitDock."

### Backgrounds

Four-tier depth system. Each tier is a step closer to the viewer:

| Token | Hex | Usage |
|-------|-----|-------|
| `backgroundCode` | `#0A0A0D` | Deepest — code block interiors |
| `backgroundPrimary` | `#0F0E11` | Main canvas — content area |
| `backgroundSecondary` | `#151416` | Elevated — sidebars, headers |
| `backgroundTertiary` | `#1C1B1F` | Cards — tool cards, code blocks, panels |
| `panelBackground` | `#0E0E12` | Slide-in panels — subtle indigo cast |

The progression is subtle but consistent. Each step adds roughly `0.02-0.03` brightness with a slight indigo shift.

### Text Hierarchy

Four opacity tiers on white, engineered for WCAG readability on dark backgrounds:

| Token | Opacity | Usage | Min Contrast (on primary bg) |
|-------|---------|-------|------------------------------|
| `textPrimary` | 0.92 | Headings, session names, key values | ~15:1 |
| `textSecondary` | 0.65 | Labels, descriptions, supporting text | ~10:1 |
| `textTertiary` | 0.50 | Timestamps, counts, metadata | ~7.5:1 |
| `textQuaternary` | 0.38 | Hints, divider text, lowest priority | ~5.5:1 |

**Critical rule:** Never use SwiftUI's `.foregroundStyle(.tertiary)` or `.quaternary` — they resolve to invisible values on dark backgrounds. Always use the explicit `Color.text*` tokens.

### Status Colors (The Five States)

The most important color subsystem. These five colors must be instantly distinguishable:

| State | Token | Hex | Icon | Meaning |
|-------|-------|-----|------|---------|
| **Working** | `statusWorking` | `#54AEE5` (cyan) | `bolt.fill` | Agent actively processing |
| **Permission** | `statusPermission` | `#F28C6B` (coral) | `lock.fill` | Needs tool approval — URGENT |
| **Question** | `statusQuestion` | `#BF80F2` (purple) | `questionmark.bubble.fill` | Agent asked you something — URGENT |
| **Reply** | `statusReply` | `#73B2FF` (soft blue) | `bubble.left` | Awaiting your next prompt |
| **Ended** | `statusEnded` | `#6B6673` (warm gray) | `moon.fill` | Session finished |

Design rules for status:
- Permission and Question are the only "urgent" states — they should be visually louder
- Working is the calm "everything's fine" indicator
- Reply is a gentle prompt, not an alarm
- Ended should fade into the background

### Feedback Colors

For general UI states outside of session status:

| Token | Hex | Usage |
|-------|-----|-------|
| `feedbackPositive` | `#59D18C` | Success, saved, connected |
| `feedbackCaution` | `#F2BF4D` | Warning, approaching limits |
| `feedbackWarning` | `#FF994D` | Bash errors, elevated warnings |
| `feedbackNegative` | `#F26673` | Error, disconnected, failure |

### Model Colors

Each AI model has a signature color for instant recognition:

| Model | Token | Hex | Theme Name |
|-------|-------|-----|------------|
| Opus | `modelOpus` | `#B373F2` | Cosmic purple |
| Sonnet | `modelSonnet` | `#66A5FF` | Nebula blue |
| Haiku | `modelHaiku` | `#4DD9CC` | Aqua teal |

### Tool Colors

Each tool type has a unique color for visual differentiation in tool cards:

| Tool | Token | Hex |
|------|-------|-----|
| Read | `toolRead` | `#73B2FF` |
| Write | `toolWrite` | `#FF994D` |
| Bash | `toolBash` | `#59D88C` |
| Search | `toolSearch` | `#A680F2` |
| Task | `toolTask` | `#808CFF` |
| Web | `toolWeb` | `#54AEE5` |
| Question | `toolQuestion` | `#FFB24D` |
| MCP | `toolMcp` | `#8CB2D9` |
| Skill | `toolSkill` | `#D98CE5` |
| Plan | `toolPlan` | `#66BF8C` |
| Todo | `toolTodo` | `#B2CC73` |

### Autonomy Spectrum

A cool-to-warm gradient representing increasing risk:

| Level | Token | Hex | Temperature |
|-------|-------|-----|-------------|
| Locked | `autonomyLocked` | `#33BFCF` | Coolest (safest) |
| Guarded | `autonomyGuarded` | `#54AEE5` | Cool |
| Autonomous | `autonomyAutonomous` | `#59D18C` | Neutral |
| Open | `autonomyOpen` | `#F2BF4D` | Warm |
| Full Auto | `autonomyFullAuto` | `#FF994D` | Warmer |
| Unrestricted | `autonomyUnrestricted` | `#FF7366` | Hottest (riskiest) |

This heat-map progression gives visceral feedback about risk level without reading labels.

### Surfaces & Interaction States

Built from the accent color at varying opacities:

| Token | Value | Usage |
|-------|-------|-------|
| `surfaceHover` | accent @ 6% | Hover highlight |
| `surfaceBorder` | accent @ 10% | Default border tint |
| `surfaceSelected` | accent @ 12% | Selected row/item |
| `surfaceActive` | accent @ 20% | Active/pressed state |
| `surfaceElevated` | white @ 4% | Raised card surfaces |

### Diff Colors

Optimized for dark backgrounds with low-opacity washes and saturated edge indicators:

| Token | Value | Usage |
|-------|-------|-------|
| `diffAddedBg` | `rgba(31,66,38,0.30)` | Added line background wash |
| `diffRemovedBg` | `rgba(77,31,31,0.30)` | Removed line background wash |
| `diffAddedEdge` | `#4DC766` | Left edge bar for additions |
| `diffRemovedEdge` | `#D95A5A` | Left edge bar for removals |
| `diffAddedAccent` | `#66F280` | Added text/prefix |
| `diffRemovedAccent` | `#FF8080` | Removed text/prefix |
| `diffAddedHighlight` | accent green @ 25% | Word-level inline highlight |
| `diffRemovedHighlight` | accent red @ 25% | Word-level inline highlight |

### Syntax Highlighting

Cosmic-themed syntax colors that maintain readability without competing with content:

| Token | Hex | Role |
|-------|-----|------|
| `syntaxKeyword` | `#BF80F2` | Nebula purple |
| `syntaxString` | `#F2A666` | Solar orange |
| `syntaxNumber` | `#B2D980` | Starchart lime |
| `syntaxComment` | `#668099` | Distant star gray |
| `syntaxType` | `#54AEE5` | Orbit cyan (brand!) |
| `syntaxFunction` | `#E5D98C` | Signal yellow |
| `syntaxProperty` | `#8CBFFF` | Atmosphere blue |
| `syntaxText` | `#DCDEE6` | Starlight |

### Composer Borders

Input mode communicated through border color:

| Mode | Token | Color |
|------|-------|-------|
| Prompt | `composerPrompt` | Cyan (accent) |
| Steer | `composerSteer` | Orange (toolWrite) |
| Review | `composerReview` | Purple (statusQuestion) |
| Shell | `composerShell` | Green (terminal) |

### Glow Effects

Colored halos that reinforce status and draw attention:

| Token | Value | Usage |
|-------|-------|-------|
| `glow-accent` | cyan @ 15%, 20px radius | Active elements, focused input |
| `glow-accent-strong` | cyan @ 25%, 30px radius | Hero moments, dialogs |
| `glow-permission` | coral @ 15% | Permission banners |
| `glow-question` | purple @ 15% | Question banners |
| `glow-positive` | green @ 15% | Success states |

---

## Typography

Full reference in [typography.md](typography.md). Key principles here.

### Hierarchy Rule

The hierarchy is absolute: **conversation text is always the largest non-heading element**. Everything else is smaller. This makes the most important content (what the agent said, what you wrote) dominate the visual field.

```
22pt  Bold       — H1 headlines, section headers
18pt  Semibold   — H2 headings
16pt  Semibold   — H3 headings
15pt  Regular    — Body text, conversation prose, user messages
14pt  Regular    — Subheadings, chat code blocks
13pt  Regular    — Standard UI text, inline code
12pt  Semibold   — Labels, button text, role labels
11pt  Medium     — Metadata, timestamps, line numbers
10pt  Medium     — Token counts, mini badges
 9pt  Semibold   — Tiny badge labels
```

### Font Stacks

```
System:    SF Pro (Apple), Segoe UI (Windows), Roboto (Android)
Monospace: SF Mono, Fira Code, Cascadia Code, JetBrains Mono
```

### Weight Rules

| Weight | When to Use |
|--------|-------------|
| **Bold (700)** | H1 headings, diff +/- indicators only |
| **Semibold (600)** | H2/H3, labels, badge text, emphasis |
| **Medium (500)** | Metadata, buttons, secondary text |
| **Regular (400)** | Body text, code, everything else |

### Dark Theme Text Rules

- Never use pure white (`#FFFFFF`) for body text — it causes halation on dark backgrounds. Use `textPrimary` (92% white) instead.
- Code text uses a slightly different color (`syntaxText` / `#DCDEE6`) — subtly blue-shifted for readability against code backgrounds.
- Timestamps and metadata should use monospaced digits for alignment in lists.

---

## Spacing

4pt base grid. Everything aligns to multiples of 4, with a few 2pt and 6pt exceptions for micro-adjustments.

### Scale

| Token | Value | Usage |
|-------|-------|-------|
| `xxs` | 2pt | Bare minimum gaps, decorative spacing |
| `gap` | 3pt | Icon-to-text in mini badges |
| `xs` | 4pt | Tight padding, list item spacing |
| `sm_` | 6pt | Badge padding, relaxed intra-element |
| `sm` | 8pt | Comfortable small spacing |
| `md_` | 10pt | Medium minus — section gaps |
| `md` | 12pt | Standard padding |
| `lg_` | 14pt | Panel inner padding |
| `lg` | 16pt | Large spacing, panel margins |
| `section` | 20pt | Between major sections |
| `xl` | 24pt | Extra large margins |
| `xxl` | 32pt | Maximum breathing room |

### Spacing Philosophy

**Between groups: generous. Within groups: tight.**

A card has tight internal spacing (`sm`-`md`) but generous external margins (`lg`-`xl`). This creates clear visual grouping without explicit borders everywhere. The user's eye should automatically parse what belongs together.

### Content Spacing

| Element | Value |
|---------|-------|
| Between messages | 20pt vertical |
| Message horizontal margins | 32pt |
| User bubble padding | 18pt H, 14pt V |
| Code block padding | 14pt H, 10pt V |
| Paragraph bottom margin | 14pt |
| List item spacing | 4pt top, 4pt bottom |

---

## Corner Radius

### Scale

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 2pt | Progress bars, thin decorative elements |
| `sm` | 4pt | Small interactive elements |
| `sm_` | 5pt | Badges, chips |
| `md` | 6pt | Standard cards, code blocks |
| `ml` | 8pt | Buttons, input fields |
| `lg` | 10pt | Large cards, panels |
| `xl` | 14pt | Extra large components |
| `bubble` | 16pt | Message bubbles (web only) |

**Always use continuous corners** (`.continuous` in SwiftUI) — they're more optically pleasing than circular arcs and match Apple's design language.

---

## Elevation & Shadows

### Shadow Scale

| Token | Config | Usage |
|-------|--------|-------|
| `sm` | black 15%, 2px radius, y:1 | Chips, small badges |
| `md` | black 22%, 6px radius, y:2 | Cards, panels |
| `lg` | black 30%, 12px radius, y:4 | Modals, floating panels, toasts |
| `dialog` | black 50%, 60px + accent glow | Dialog overlays |
| `composer` | black 20%, 16px, y:-4 | Composer bar (upward shadow) |

### Glow as Elevation

In a dark UI, traditional drop shadows have limited impact — the background is already dark. Instead, OrbitDock uses **colored glow** as the primary elevation signal:

- Active sessions glow with their status color
- Focused inputs glow with accent cyan
- Permission banners glow with coral
- Dialogs glow with a subtle accent halo

This reinforces the "light as information" principle: elevated elements literally emit light.

---

## Opacity

### Semantic Tiers

| Token | Value | Usage |
|-------|-------|-------|
| `tint` | 4% | Barely visible surface tints |
| `subtle` | 8% | Subtle hover backgrounds |
| `light` | 12% | Selected state backgrounds, badge fills |
| `medium` | 20% | Active state backgrounds |
| `strong` | 40% | Prominent overlays |
| `vivid` | 70% | Near-opaque overlays |

Use these tokens instead of ad-hoc opacity values. They create consistent interaction feedback across all components.

---

## Motion

### Animation Presets

| Token | Config | Usage |
|-------|--------|-------|
| `snappy` | spring(0.20, 0.90) | Hover, press, toggle — instant feedback |
| `standard` | spring(0.25, 0.85) | Expand/collapse, selection, navigation |
| `gentle` | spring(0.35, 0.80) | Panel slides, content entry, messages |
| `bouncy` | spring(0.30, 0.70) | Picker selection, sheet present |
| `hover` | easeOut(0.15) | Micro opacity transitions |
| `fade` | easeOut(0.25) | Loading states, content fades |

### Motion Principles

1. **Motion serves function, not decoration.** Every animation communicates spatial relationship, state change, or causality.
2. **Fast by default.** Most transitions use `snappy` or `standard`. Use `gentle` only for large content shifts.
3. **Respect reduced motion.** All animations are wrapped in `@media (prefers-reduced-motion: reduce)` on web and checked with `UIAccessibility.isReduceMotionEnabled` on native.
4. **No timeouts or artificial delays.** Content appears as soon as it's ready. Loading states use skeleton shimmer, not spinners with minimum display times.

---

## Icon System

### SF Symbols (Native)

All icons use SF Symbols for native platforms. Seven size tiers:

| Token | Size | Usage |
|-------|------|-------|
| `xs` | 8pt | Mini badge decorations |
| `sm` | 9pt | Compact badges, chevrons |
| `md` | 10pt | Standard tool card icons |
| `lg` | 11pt | Section headers, labels |
| `xl` | 12pt | Status indicators, banners |
| `xxl` | 14pt | Empty states, dialogs |
| `hero` | 16pt | Onboarding, hero moments |

### Web Icons

Web uses a matching icon set (Lucide or equivalent) at the same size tiers, converted to pixel values.

### Icon Weight

Match icon weight to adjacent text weight. If the icon sits next to a semibold label, use a semibold symbol variant.

---

## Component Patterns

### Badge

The universal small indicator. Capsule shape, tinted background, matching text.

```
Layout:    HStack(spacing: 3) { icon + label }
Font:      9pt semibold (mini), 10pt semibold (regular)
Padding:   6pt horizontal, 3pt vertical
Shape:     Capsule
Fill:      color @ 12% opacity
Text:      Full-saturation color
```

Badges are used for: status, model, provider, language, tool type, fork indicator, issue ID.

### Card

The primary content container. Used for tool cards, session rows, code blocks.

```
Background: backgroundTertiary
Border:     surfaceBorder (1px)
Radius:     md (6pt) or lg (10pt) for larger cards
Shadow:     sm or md depending on elevation
Padding:    sm (8pt) mobile, md (12pt) desktop
```

### Button

Four variants:

| Variant | Background | Text | Border |
|---------|-----------|------|--------|
| **Primary** | accent | white | none |
| **Secondary** | surfaceElevated | textPrimary | surfaceBorder |
| **Ghost** | transparent | accent | none |
| **Danger** | feedbackNegative @ 12% | feedbackNegative | none |

Touch targets: minimum 44pt on iOS, 28pt height on desktop.

### Permission Banner

A high-urgency component that demands attention:

```
Background: statusPermission @ 12%
Border:     statusPermission @ 25%
Radius:     lg (10pt)
Icon:       exclamationmark.triangle.fill in statusPermission
Content:    Tool name (bold) + rich detail (monospaced)
```

The banner uses a left-aligned warning icon, structured tool info, and a subtle "Accept in terminal" hint.

### Session Row

The dashboard list item. Three information tiers:

1. **Primary:** Session name + status dot
2. **Secondary:** Provider badge + model badge + project name
3. **Tertiary:** Timestamp + token count

Active sessions get a colored left edge bar (3pt, status color). Hover shows `surfaceHover` background.

### Status Dot

A colored circle with optional glow. Three sizes:

- **Mini:** 6pt dot, no glow — inline indicators
- **Standard:** 8pt dot, subtle glow — list items
- **Large:** 10pt+ dot, strong glow — headers, hero states

### Composer Input

The message input area:

```
Background: backgroundTertiary
Border:     composerPrompt/Steer/Review/Shell (2pt, bottom-focused)
Radius:     ml (8pt)
Shadow:     composer (upward, subtle)
Padding:    md (12pt)
```

Border color changes to reflect input mode — this is the primary affordance for knowing what mode you're in.

### Diff View

Unified diff with line-level detail:

```
Background: backgroundCode
Line bg:    diffAddedBg / diffRemovedBg (30% opacity wash)
Edge bar:   3pt left bar in diffAddedEdge / diffRemovedEdge
Prefix:     +/- in diffAddedAccent / diffRemovedAccent (bold)
Word diff:  Inline highlight at 25% opacity
```

---

## Interaction Patterns

### Urgency Hierarchy

The dashboard sorts content by urgency. The visual design reinforces this:

1. **Permission / Question** — Bright status color, glow, positioned at top, attention count badge
2. **Working** — Calm cyan, standard brightness
3. **Reply** — Soft blue, slightly dimmer
4. **Ended** — Gray, recedes

### Progressive Disclosure

- Dashboard shows session summary → click to see full conversation
- Tool cards show name + icon → expand to see input/output
- Code diffs show file list → click to see hunks → hover to see word-level diffs
- Approval cards show tool + risk → expand to see full context

### Keyboard-First, Touch-Friendly

Desktop users should be able to navigate the entire app without a mouse:
- Arrow keys / Emacs bindings for list navigation
- `y/n/Y/N` for approval triage
- `Cmd+K` for quick switcher
- `Cmd+T` for terminal focus

Mobile users should never need to reach for the top of the screen:
- Bottom-pinned actions
- Sheet detents for progressive content
- Swipe gestures where appropriate

### Empty States

When there's no content, show:
- A single icon (hero size, 16pt)
- One line of explanatory text (textSecondary)
- One action button if applicable

No illustrations, no mascots, no multi-paragraph explanations.

---

## Accessibility

### Contrast Ratios

All text meets WCAG AA minimum contrast on our darkest backgrounds:

| Text Tier | Contrast on `backgroundPrimary` | Standard |
|-----------|-------------------------------|----------|
| Primary (0.92) | ~15:1 | Exceeds AAA |
| Secondary (0.65) | ~10:1 | Exceeds AAA |
| Tertiary (0.50) | ~7.5:1 | Exceeds AA |
| Quaternary (0.38) | ~5.5:1 | Meets AA |

Status colors are chosen to be distinguishable by people with common color vision deficiencies (protanopia, deuteranopia). Each status also has a unique icon to provide a non-color signal.

### Reduced Motion

All animations respect the system preference:
- Web: `@media (prefers-reduced-motion: reduce)` collapses all transitions
- Native: `UIAccessibility.isReduceMotionEnabled` / `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`

### Dynamic Type

Native apps support Dynamic Type scaling. The TypeScale values are base sizes — they scale proportionally with the user's preferred text size.

### VoiceOver

- All status dots have accessibility labels ("Working", "Needs Permission", etc.)
- Tool cards announce their tool type and key content
- Decorative elements use `.accessibilityHidden(true)`
- Approval cards expose keyboard actions to the accessibility API

### Focus Indicators

- Web: `2px solid accent` outline with `2px` offset on `:focus-visible`
- Native: System default focus rings, enhanced with accent color where needed

---

## Cross-Platform Rules

### Layout Modes

| Mode | Trigger | Layout |
|------|---------|--------|
| `phoneCompact` | iPhone, any orientation | Single column, bottom actions, sheets with detents |
| `pad` | iPad, any orientation | Two-pane, split views, comfortable touch targets |
| `desktop` | macOS | Full sidebar, hover states, keyboard shortcuts, compact density |

### Non-Negotiable Rules

1. Start with `phoneCompact` layout. Scale up.
2. No unguarded fixed widths in shared views.
3. Every iOS sheet needs explicit detents + drag indicator.
4. Use ONLY design tokens — no ad-hoc colors, sizes, or spacing.
5. All long text must truncate safely (`.lineLimit(1)`, `.truncationMode(.middle)`).
6. No hover-only affordances as the sole interaction path.
7. Bottom actions on iPhone use `safeAreaInset(edge: .bottom)`.

### Platform Enhancements

| Feature | macOS | iPad | iPhone |
|---------|-------|------|--------|
| Hover states | Yes | No | No |
| Keyboard shortcuts | Full | Some | Minimal |
| Sidebar | Always visible | Toggle | Sheet |
| Information density | High | Medium | Low |
| Touch targets | 28pt min | 44pt min | 44pt min |
| Pointer cursor | Custom on interactive | System | N/A |

---

## Naming Conventions

### Token Naming Pattern

```
{category}.{modifier}

Color:    accent, accentGlow, accentMuted
          status{State}: statusWorking, statusPermission
          feedback{Severity}: feedbackPositive, feedbackNegative
          text{Priority}: textPrimary, textSecondary
          background{Level}: backgroundPrimary, backgroundTertiary
          surface{State}: surfaceHover, surfaceSelected
          tool{Name}: toolRead, toolBash
          model{Name}: modelOpus, modelSonnet
          diff{Type}{Part}: diffAddedBg, diffRemovedEdge

Spacing:  xxs, xs, sm, md, lg, xl, xxl (plus sm_, md_, lg_ half-steps)

Type:     micro, caption, body, subhead, title, headline (plus chat*, thinking*)

Radius:   xs, sm, md, ml, lg, xl

Opacity:  tint, subtle, light, medium, strong, vivid

Motion:   snappy, standard, gentle, bouncy, hover, fade
```

### CSS Variable Pattern

```css
--color-{category}-{modifier}: value;
--space-{size}: value;
--type-{name}: value;
--radius-{size}: value;
--shadow-{size}: value;
--glow-{name}: value;
--transition-{speed}: value;
--font-{family}: value;
--line-height-{name}: value;
```

---

## Implementation Files

| File | Platform | Contents |
|------|----------|----------|
| `Theme.swift` | Native | All Color extensions, Spacing, TypeScale, Radius, OpacityTier, EdgeBar, SessionDisplayStatus, component views |
| `DesignTokens.swift` | Native | IconScale, LineHeight, ShadowToken, Shadow, Motion |
| `tokens.css` | Web | All CSS custom properties — colors, spacing, type, radius, shadows, transitions, z-index |
| `global.css` | Web | Base styles, scrollbar styling, selection color, focus rings, reduced motion |
| `typography.md` | Docs | Full typography reference with examples |
| `CLIENT_DESIGN_PRINCIPLES.md` | Docs | Architecture principles for the Swift client |
| `UI_CROSS_PLATFORM_GUIDELINES.md` | Docs | Platform-specific layout rules |

---

## Design Checklist

When building a new view or component, verify:

- [ ] Uses only design tokens (no magic numbers for colors, sizes, spacing, or radii)
- [ ] Text uses correct hierarchy tier (primary/secondary/tertiary)
- [ ] Status colors use the 5-state system, not ad-hoc colors
- [ ] Works in `phoneCompact` layout first
- [ ] Truncates long text safely
- [ ] Touch targets meet platform minimums (44pt iOS, 28pt macOS)
- [ ] Animations use Motion presets
- [ ] Interactive elements have hover/press states
- [ ] Accessibility labels on non-text indicators
- [ ] Supports reduced motion preference
- [ ] Dark background only — no light mode paths

---

*"A cosmic harbor for AI agent sessions — spacecraft docked at your mission control center."*
