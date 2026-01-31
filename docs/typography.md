# Typography Design System

OrbitDock's typography system prioritizes readability and clear hierarchy in the cosmic harbor theme. As a text-heavy app displaying conversations, code, and metadata, typography choices directly impact usability.

The dark space theme demands careful attention to contrast and legibility.

## Core Principles

1. **Conversation text is primary** - Body text should be comfortable to read for extended periods
2. **Code is secondary** - Slightly smaller than body text, visually distinct but not dominant
3. **Metadata is tertiary** - Timestamps, token counts, labels should recede into the background
4. **Generous spacing** - Text needs room to breathe, especially in a dark theme

---

## Type Scale

### Body Text
The foundation of the app. Used for conversation messages and markdown content.

| Element | Size | Weight | Opacity | Line Spacing |
|---------|------|--------|---------|--------------|
| Body | 15.5pt | Regular | 0.92 | Default |
| Body (user bubble) | 15.5pt | Regular | 0.95 | 3pt |

### Headings
Clear hierarchy for markdown content.

| Element | Size | Weight | Top Margin | Bottom Margin |
|---------|------|--------|------------|---------------|
| H1 | 24pt | Bold | 28pt | 14pt |
| H2 | 20pt | Semibold | 24pt | 10pt |
| H3 | 17pt | Semibold | 20pt | 8pt |

### Code
Monospaced text for code blocks, diffs, and inline code.

| Element | Size | Weight | Line Height |
|---------|------|--------|-------------|
| Code block | 12.5pt | Regular | 18pt |
| Inline code | 13pt | Regular | - |
| Line numbers | 11pt | Regular | 18pt |
| Diff prefix (+/-) | 12.5pt | Bold | - |

### Metadata
Supporting information that shouldn't compete with content.

| Element | Size | Weight | Style |
|---------|------|--------|-------|
| Timestamps | 11pt | Medium | Monospaced |
| Token counts | 10-11pt | Medium | Monospaced |
| Labels ("Claude", "You") | 12pt | Semibold | - |
| Badges/counts | 10-11pt | Medium | - |

### UI Controls
Buttons, indicators, and interactive elements.

| Element | Size | Weight |
|---------|------|--------|
| Button text | 11-12pt | Medium |
| Expand/collapse | 11-12pt | Medium |
| Status banners | 12-13pt | Semibold |

---

## Font Weights

Use weights purposefully to create hierarchy:

| Weight | Usage |
|--------|-------|
| **Bold** | H1 headings, diff indicators (+/-), chevrons |
| **Semibold** | H2/H3 headings, labels, emphasis in markdown |
| **Medium** | Metadata, buttons, secondary text |
| **Regular** | Body text, code, line numbers |

---

## Color & Opacity

### Text Colors

```swift
// Primary content (starlight)
.primary                    // Headings, important text
Color.textPrimary           // Body text (0.92 white)
.primary.opacity(0.95)      // User message bubbles

// Secondary content (distant stars)
Color.textSecondary         // Labels, less important text (0.55 white)
Color.textTertiary          // Metadata, timestamps (0.35 white)
Color.textQuaternary        // Very subtle indicators (0.20 white)

// Semantic colors
Color.modelOpus             // Cosmic purple - Opus branding
Color.modelSonnet           // Nebula blue - Sonnet branding
Color.modelHaiku            // Aqua teal - Haiku branding
Color.accent                // Orbit cyan - user message accents, links
```

### Code Colors (Syntax Highlighting)

All syntax colors are defined in `Theme.swift` and accessed via the `SyntaxColors` enum:

```swift
enum SyntaxColors {
    static let keyword  = Color.syntaxKeyword   // Nebula purple
    static let string   = Color.syntaxString    // Solar orange
    static let number   = Color.syntaxNumber    // Starchart lime
    static let comment  = Color.syntaxComment   // Distant star gray
    static let type     = Color.syntaxType      // Orbit cyan (brand!)
    static let function = Color.syntaxFunction  // Signal yellow
    static let property = Color.syntaxProperty  // Atmosphere blue
    static let text     = Color.syntaxText      // Starlight
}

// Inline code
Color.markdownInlineCode    // Warm signal orange
```

### Diff Colors

```swift
// Backgrounds (deep space tinted)
let addedBg   = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)

// Accents (for +/- symbols)
let addedAccent   = Color.statusSuccess   // Soft green confirmation
let removedAccent = Color.statusError     // Soft red warning

// Line numbers
Color.textTertiary
```

---

## Spacing

### Paragraph & List Spacing

| Element | Top | Bottom |
|---------|-----|--------|
| Paragraph | 0pt | 14pt |
| List item | 4pt | 4pt |
| Blockquote | 12pt | 12pt |
| Code block | 12pt | 12pt |
| Thematic break | 20pt | 20pt |

### Message Spacing

| Element | Value |
|---------|-------|
| Between messages | 20pt vertical padding each |
| Horizontal margins | 32pt |
| Bottom scroll padding | 32pt |
| User message max-width offset | 100pt from left |
| Assistant message max-width offset | 100pt from right |

### Component Internal Spacing

| Element | Padding |
|---------|---------|
| User message bubble | 18pt horizontal, 14pt vertical |
| Code block header | 14pt horizontal, 10pt top, 8pt bottom |
| Code block content | 10pt vertical, 14pt horizontal for code |
| Table cells | 14pt horizontal, 10pt vertical |

---

## Implementation Reference

### MarkdownUI Theme

```swift
extension MarkdownUI.Theme {
    static let orbitDock = Theme()
        .text {
            ForegroundColor(Color.textPrimary)
            FontSize(15.5)
        }
        .code {
            ForegroundColor(Color.markdownInlineCode)
            BackgroundColor(Color.white.opacity(0.07))
        }
        .link {
            ForegroundColor(Color.markdownLink)  // Orbit cyan
            UnderlineStyle(.single)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(24)
                    FontWeight(.bold)
                }
                .markdownMargin(top: 28, bottom: 14)
        }
        // ... etc
}
```

### SwiftUI Text Patterns

```swift
// Body text
Text(content)
    .font(.system(size: 15.5))
    .foregroundStyle(Color.textPrimary)

// Metadata
Text(timestamp)
    .font(.system(size: 11, weight: .medium, design: .monospaced))
    .foregroundStyle(Color.textQuaternary)

// Code
Text(code)
    .font(.system(size: 12.5, design: .monospaced))
    .foregroundStyle(Color.syntaxText)

// Labels
Text("Claude")
    .font(.system(size: 12, weight: .semibold))
    .foregroundStyle(Color.modelOpus)

// Links and interactive text
Text("View details")
    .foregroundStyle(Color.accent)  // Orbit cyan
```

---

## Guidelines

### Do

- Use the type scale consistently
- Let body text be the largest non-heading element
- Use opacity to create subtle hierarchy within the same color
- Give text generous margins and padding
- Use monospaced fonts for anything code-related

### Don't

- Make metadata larger than body text
- Use bold for body text (reserve for headings)
- Crowd text together - spacing is cheap
- Mix too many font sizes in one component
- Use pure white (.primary) for large blocks of text - soften with opacity

---

## Quick Reference

```
24pt  Bold      - H1
20pt  Semibold  - H2
17pt  Semibold  - H3
15.5pt Regular  - Body text, user messages
13pt  Regular   - Inline code
12.5pt Regular  - Code blocks, diffs
12pt  Semibold  - Labels ("Claude", "You")
11pt  Medium    - Timestamps, line numbers, metadata
10pt  Medium    - Token counts, badges
```

---

## Cosmic Theme Color Philosophy

OrbitDock uses a "deep space with nebula undertones" color palette:

| Color Role | Usage | Theme Color |
|------------|-------|-------------|
| **Brand accent** | Links, active states, interactive elements | `Color.accent` (Orbit cyan) |
| **Working status** | Active session indicators | `Color.statusWorking` (Orbit cyan) |
| **Code types** | Type annotations in syntax highlighting | `Color.syntaxType` (Orbit cyan) |

The cyan orbit ring from the app icon should appear consistently throughout the UI for brand cohesion. Use it for:
- Links and interactive text
- Active/selected states
- Working session indicators (the "in orbit" state)
- Code types and certain language badges

Reserve other colors for semantic meaning (amber for waiting, red for errors, green for success/completion).
