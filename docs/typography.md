# Typography Design System

Command Center's typography system prioritizes readability and clear hierarchy. As a text-heavy app displaying conversations, code, and metadata, typography choices directly impact usability.

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
// Primary content
.primary                    // Headings, important text
.primary.opacity(0.92)      // Body text (slightly softer)
.primary.opacity(0.95)      // User message bubbles

// Secondary content
.secondary                  // Labels, less important text
.tertiary                   // Metadata, timestamps, buttons
.quaternary                 // Very subtle indicators

// Semantic colors
Color.modelOpus             // Claude branding
Color.accentColor           // User message accents
```

### Code Colors (Syntax Highlighting)

```swift
enum SyntaxColors {
    static let keyword  = Color(red: 0.78, green: 0.46, blue: 0.82)  // Purple
    static let string   = Color(red: 0.81, green: 0.54, blue: 0.40)  // Orange
    static let number   = Color(red: 0.71, green: 0.81, blue: 0.54)  // Green
    static let comment  = Color(red: 0.42, green: 0.47, blue: 0.42)  // Gray-green
    static let type     = Color(red: 0.31, green: 0.73, blue: 0.78)  // Cyan
    static let function = Color(red: 0.87, green: 0.87, blue: 0.67)  // Yellow
    static let property = Color(red: 0.61, green: 0.78, blue: 0.92)  // Light blue
    static let text     = Color(red: 0.85, green: 0.85, blue: 0.85)  // Light gray
}

// Inline code
Color(red: 0.95, green: 0.65, blue: 0.45)  // Warm orange
```

### Diff Colors

```swift
// Backgrounds
let addedBg   = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)

// Accents (for +/- symbols)
let addedAccent   = Color(red: 0.4, green: 0.95, blue: 0.5)
let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

// Line numbers
.white.opacity(0.32)
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
    static let commandCenter = Theme()
        .text {
            ForegroundColor(.primary.opacity(0.92))
            FontSize(15.5)
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
    .foregroundStyle(.primary.opacity(0.92))

// Metadata
Text(timestamp)
    .font(.system(size: 11, weight: .medium, design: .monospaced))
    .foregroundStyle(.quaternary)

// Code
Text(code)
    .font(.system(size: 12.5, design: .monospaced))

// Labels
Text("Claude")
    .font(.system(size: 12, weight: .semibold))
    .foregroundStyle(Color.modelOpus)
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
