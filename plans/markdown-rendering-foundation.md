# Markdown Rendering Foundation

A comprehensive plan to refactor and re-architect the markdown rendering pipeline in OrbitDock. This is a full audit of every problem, every consumer, every duplication — and a phased plan to fix it all.

---

## Current State — Full Audit

### Architecture Overview

There are **two completely independent markdown rendering pipelines** that parse the same AST separately, duplicate inline walking logic, use different style tokens, and drift on spacing/colors:

| Pipeline | Entry Point | Output | Used By |
|----------|------------|--------|---------|
| **Native** | `MarkdownAttributedStringRenderer.parse()` → `[MarkdownBlock]` → `NativeMarkdownContentView` | NSAttributedString in NSTextView/UITextView | Conversation timeline (macOS + iOS) |
| **SwiftUI** | `Document(parsing:)` → `MarkdownDocumentView` → per-block SwiftUI views | SwiftUI `Text` + `AttributedString` | WorkStreamEntry, TaskCard, UserBashCard |

### Consumer Inventory

Every callsite of the markdown system, exhaustively:

**Native Pipeline Consumers** (primary path — conversation timeline):
| Callsite | What it does |
|----------|-------------|
| `NativeRichMessageCellView.configure()` (:319) | Parses message content into `[MarkdownBlock]`, renders via `NativeMarkdownContentView` |
| `NativeRichMessageCellView.requiredHeight()` (:918) | Parses again for height calculation (cached — same key hits) |
| `UIKitRichMessageCell.configure()` (:206) | iOS mirror — identical pattern |
| `UIKitRichMessageCell.requiredHeight()` (:780) | iOS mirror — identical pattern |
| `ExpandedToolCellView` (:1070) | Uses `NativeSyntaxHighlighter.highlightLine()` for tool output code lines |
| `UIKitExpandedToolCell` (:643) | iOS mirror — uses `NativeSyntaxHighlighter.highlightLine()` |
| `NativeCodeBlockView.rebuildCodeContent()` (:335) | Uses `NativeSyntaxHighlighter.highlightLine()` for code block lines |

**SwiftUI Pipeline Consumers** (secondary — tool cards, work stream, streaming):
| Callsite | What it does |
|----------|-------------|
| `WorkStreamEntry` (:573, :755) | `MarkdownContentView(content:)` for message previews |
| `WorkStreamEntry` (:775, :829, :915, :973) | `StreamingMarkdownView(content:)` for live streaming + thinking |
| `TaskCard` (:244) | `MarkdownView(content: output)` for task agent output |
| `UserBashCard` (:170) | `ThinkingMarkdownView(content:)` for bash context preview |
| `CodeBlockView` in `MarkdownView.swift` (:820) | `SyntaxHighlighter.highlightLine()` for SwiftUI code blocks |

**Syntax Highlighter Consumers** (used outside markdown too):
| Callsite | What it does |
|----------|-------------|
| `EditCard` (:611) | `SyntaxHighlighter.highlightLine()` for diff line display |
| `ReadCard` (:112) | `SyntaxHighlighter.highlightLine()` for file content preview |
| `DiffHunkView` (:265) | `SyntaxHighlighter.highlightLine()` for code review inline diff |
| `CodeReviewFeedbackCard` (:430) | `SyntaxHighlighter.highlightLine()` for feedback code snippets |

**Cache Lifecycle**:
| Callsite | What it does |
|----------|-------------|
| `OrbitDockApp.swift` (:38-39) | iOS memory pressure: clears `MarkdownAttributedStringRenderer.clearCache()` + `NativeSyntaxHighlighter.clearCache()` |
| No macOS equivalent | macOS has no memory pressure handler for markdown caches |

---

### Problem 1: Dual Style Systems

Two enums for the same concept:
- `ContentStyle` (native, in `MarkdownAttributedStringRenderer.swift`) — `.standard` / `.thinking`
- `MarkdownStyle` (SwiftUI, in `MarkdownView.swift`) — `.standard` / `.thinking`
- `StreamingMarkdownView.Style` (SwiftUI, in `MarkdownView.swift`) — `.standard` / `.thinking` (a third copy!)

Three enums. Same two cases. Three files.

### Problem 2: Hardcoded Color Literals (10 Locations)

Theme.swift already defines `Color.markdownInlineCode`, `Color.markdownLink`, `Color.markdownBlockquote` — but **nobody uses them**. Instead, raw RGB literals are scattered:

**Inline code tan** (`0.95, 0.68, 0.45`):
- `MarkdownAttributedStringRenderer.swift:229-230` — `PlatformColor.calibrated(red: 0.95, green: 0.68, blue: 0.45, ...)`
- `MarkdownView.swift:439-443` — `Color(red: 0.95, green: 0.68, blue: 0.45)`
- `MarkdownView.swift:540-543` — `Color(red: 0.95, green: 0.68, blue: 0.45)` (attributedString path)

**Thinking inline code tan** (`0.85, 0.6, 0.4`):
- `MarkdownView.swift:439` — `Color(red: 0.85, green: 0.6, blue: 0.4)`
- `MarkdownView.swift:540` — `Color(red: 0.85, green: 0.6, blue: 0.4)` (attributedString path)
- `MarkdownAttributedStringRenderer.swift:229` — `PlatformColor.calibrated(red: 0.95, green: 0.68, blue: 0.45, alpha: 0.7)` (different approach — same base color with lower alpha, not a different hue!)

**Link blue** (`0.5, 0.72, 0.95`):
- `MarkdownAttributedStringRenderer.swift:239` — `PlatformColor.calibrated(red: 0.5, green: 0.72, blue: 0.95, ...)`
- `MarkdownView.swift:450-454` — `Color(red: 0.5, green: 0.72, blue: 0.95)`
- `MarkdownView.swift:459` — `Color(red: 0.5, green: 0.72, blue: 0.95)` (image alt text)
- `MarkdownView.swift:553-556` — `Color(red: 0.5, green: 0.72, blue: 0.95)` (attributedString path)
- `NativeMarkdownContentView.swift:276` — `PlatformColor.calibrated(red: 0.5, green: 0.72, blue: 0.95, ...)` (link text attributes)
- `NativeMarkdownContentView.swift:294` — same (iOS link text attributes)

**The irony**: Theme.swift defines `Color.markdownInlineCode = Color(red: 0.95, green: 0.7, blue: 0.45)` — note the green is `0.7` vs the actual hardcoded `0.68`. **The theme token doesn't even match the code.** And `Color.markdownLink = accent` (cyan) which is `(0.35, 0.78, 0.95)` — completely different from the hardcoded blue `(0.5, 0.72, 0.95)`. The theme tokens exist but are wrong and unused.

### Problem 3: Thinking Mode Style Drift

The two renderers use different values for thinking mode:

| Property | Native (`MarkdownAttributedStringRenderer`) | SwiftUI (`MarkdownView`) |
|----------|----------------------------------------------|--------------------------|
| Body font size | 13pt (hardcoded `thinkingBodySize`) | `TypeScale.code` = 12pt |
| Inline code size | 11.5pt (hardcoded `thinkingCodeSize`) | `TypeScale.caption` = 10pt |
| H1 size | 18pt | `TypeScale.subhead` = 13pt |
| H2 size | 15pt | `TypeScale.body` = 11pt |
| H3 size | 13pt | `TypeScale.code` = 12pt |
| Line spacing | 5.5pt (paragraph style attribute) | `lineSpacing(2)` (SwiftUI modifier) |
| Paragraph spacing | 10pt (paragraph style attribute) | `.padding(.bottom, 6)` (view padding) |
| H1 top margin | 16pt | 10pt |
| H1 bottom margin | 7pt | 5pt |
| H1 kerning | 0 | 0 |
| H2 kerning | 0 | 0 |
| H3 kerning | 0 | 0.5 (!) |
| Blockquote bar | `Color.textTertiary.opacity(0.5)`, 2pt | `Color.textTertiary.opacity(0.5)`, 2pt |
| Blockquote text | `Color.textSecondary.opacity(0.8)` | `Color.textSecondary.opacity(0.8)` |

These are user-visible differences. Content rendered in WorkStreamEntry (SwiftUI) looks different from the same content in the conversation timeline (native).

### Problem 4: SyntaxHighlighter — 550 Lines of Dead Duplication

`SyntaxHighlighter.swift` is 1108 lines. It contains 11 languages, each implemented twice:

| Language | Line-based function | Full-code function | Keyword list duplicated? |
|----------|--------------------|--------------------|--------------------------|
| Swift | `highlightSwiftLine()` :109 | `highlightSwift()` :560 | Yes — identical 53 keywords + 15 types |
| JavaScript/TS | `highlightJavaScriptLine()` :190 | `highlightJavaScript()` :648 | Yes — identical 28 keywords + 12 types |
| Python | `highlightPythonLine()` :256 | `highlightPython()` :714 | Yes — identical 31 keywords + 12 types |
| Go | `highlightGoLine()` :306 | `highlightGo()` :764 | Yes — identical 24 keywords + 18 types |
| Rust | `highlightRustLine()` :369 | `highlightRust()` :827 | Yes — identical 33 keywords + 21 types |
| HTML/XML | `highlightHTMLLine()` :445 | `highlightHTML()` :903 | Yes (pattern-only) |
| CSS | `highlightCSSLine()` :452 | `highlightCSS()` :910 | Yes (pattern-only) |
| JSON | `highlightJSONLine()` :459 | `highlightJSON()` :917 | Yes (pattern-only) |
| Bash | `highlightBashLine()` :466 | `highlightBash()` :924 | Yes — identical 18 keywords |
| YAML | `highlightYAMLLine()` :497 | `highlightYAML()` :955 | Yes (pattern-only) |
| SQL | `highlightSQLLine()` :510 | `highlightSQL()` :968 | Yes — identical 24 keywords |

The full-code `highlight()` function (line 71) is only called from... the full-code `highlight()` entry point, which is never called from the SwiftUI CodeBlockView (it uses `highlightLine()` per line). **The entire full-code path is dead code.**

Wait — let me verify. The SwiftUI `CodeBlockView` at `:820` calls `SyntaxHighlighter.highlightLine()`. The native `NativeCodeBlockView` calls `NativeSyntaxHighlighter.highlightLine()` which calls `SyntaxHighlighter.highlightLine()`. Nobody calls `SyntaxHighlighter.highlight()` (the full-code entry point). **It's completely dead.**

### Problem 5: NativeSyntaxHighlighter — Backwards Conversion Layer

The highlighting pipeline for native code blocks is:

```
SyntaxHighlighter.highlightLine(line, language:)
  → AttributedString (SwiftUI type, with Color foreground runs)
    → NativeSyntaxHighlighter.convertToNSAttributedString()
      → Iterates AttributedString.runs
      → Extracts foregroundColor from each run
      → Builds NSMutableAttributedString with PlatformColor(color)
        → NSAttributedString (AppKit/UIKit type)
```

This is a 87-line file that exists solely to undo the type system. The highlighter should produce `NSAttributedString` directly (it's the primary consumer) and have a thin adapter for the 4 SwiftUI callsites.

The conversion is also lossy — `PlatformColor(color)` initializer from SwiftUI `Color` to NSColor/UIColor can lose color space precision in some edge cases.

### Problem 6: `#if os()` Explosion in Native Views

Platform branching count per file:
- `NativeCodeBlockView.swift`: **18** `#if os()` blocks
- `NativeMarkdownContentView.swift`: **9** `#if os()` blocks
- `NativeRichMessageCellView.swift`: **2** `#if os()` blocks (macOS-only via top-level guard)

`NativeCodeBlockView.swift` has the worst platform-branching density in the codebase. Almost every setup step and action handler is duplicated for macOS/iOS because `NSTextField` vs `UILabel`, `NSButton` vs `UIButton`, `NSScrollView` vs `UIScrollView` have different APIs. A `PlatformTextField`, `PlatformButton`, `PlatformScrollView` abstraction (or at minimum, factory methods) would cut this dramatically.

### Problem 7: List Rendering — Hand-Rolled Re-Parser

`parseListContinuation()` (lines 467-515) deserializes the already-parsed AST back to raw markdown (`paragraph.format()`), splits by newlines, and re-detects list markers with hand-rolled string scanning. This is fragile because:

1. `paragraph.format()` re-serializes the AST, which may not produce identical whitespace to the input
2. The marker detection (`- `, `* `, `+ `, `1.`, `1)`) doesn't handle all CommonMark continuation cases
3. It only fires when `split.count > 1` — single-paragraph list items bypass it entirely
4. The `foundMarker` guard means it returns `nil` if no nested markers are found, falling back to inline rendering — so paragraphs with continuation lines but no nested markers get different treatment

What it's trying to solve is real — `swift-markdown` sometimes models continuation paragraphs within a single `ListItem.Paragraph` rather than separate child blocks. But the fix should be upstream (walking the AST more carefully), not a re-parser.

### Problem 8: Mutable Static State (`activeStyle`)

`MarkdownAttributedStringRenderer.activeStyle` is a `private static var` set at the top of `parse()` and read by `Fonts` and `Colors` nested enums during AST walking. This works because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes everything `@MainActor`, but:

1. It's implicit context — the `Fonts.body` and `Colors.text` computed properties have no parameter indicating which style they're resolving
2. If `parse()` is ever called reentrantly (unlikely but possible if a property observer triggers a re-render mid-parse), the style would be wrong
3. It prevents ever moving parsing off the main thread for performance

### Problem 9: Cache Design Issues

**Three separate caches**, two of which cache the same content:

| Cache | Location | Max Size (macOS/iOS) | Key | Value |
|-------|----------|---------------------|-----|-------|
| Parse cache | `MarkdownAttributedStringRenderer` | 500 / 160 | `(markdown, style)` | `[MarkdownBlock]` |
| SwiftUI highlight cache | `SyntaxHighlighter` | 4,000 / 4,000 | `"lang:line"` | `AttributedString` |
| Native highlight cache | `NativeSyntaxHighlighter` | 4,000 / 1,500 | `"lang:line"` | `NSAttributedString` |

The two highlight caches store the **same content in different types**. A line highlighted by `SyntaxHighlighter` gets cached as `AttributedString`, then converted and cached again as `NSAttributedString` in `NativeSyntaxHighlighter`. Double memory for the same data.

All three use nuclear eviction: `removeAll(keepingCapacity: true)` when full. This means scrolling through a long conversation with >500 unique paragraphs causes the parse cache to clear entirely, re-parsing everything on the next scroll pass. Same for code blocks with >4000 unique lines.

**No macOS memory pressure handler** — iOS clears caches on `didReceiveMemoryWarningNotification`, but macOS has no equivalent. Long macOS sessions accumulate cache entries indefinitely until the nuclear eviction threshold.

### Problem 10: SwiftUI `MarkdownView` Link Handling Split

`MarkdownParagraphView` (MarkdownView.swift:213-231) checks `paragraph.children.contains { $0 is Markdown.Link }`:
- **If links present**: renders via `attributedString()` path → SwiftUI `AttributedString` with `.link` attribute → tappable
- **If no links**: renders via `inlineText()` path → SwiftUI `Text` concatenation → not tappable, no bare URL detection

This means:
1. Bare URLs in the SwiftUI path are never auto-linked (the native path auto-detects them via `NSDataDetector`)
2. The same paragraph renders through completely different code paths depending on whether it contains a link
3. The `attributedString()` path duplicates all the inline walking logic from `inlineText()` — bold/italic/code/strikethrough all reimplemented

The `MarkdownListItemView` (MarkdownView.swift:313-343) has the **same conditional split** duplicated for list item paragraphs.

### Problem 11: Language Normalization Duplicated

Two implementations of language alias mapping:

1. `MarkdownAttributedStringRenderer.normalizeLanguage()` (:138-150) — used by native parser
2. `CodeBlockView.normalizedLanguage` (:713-728) — used by SwiftUI code blocks

Both map `js` → `javascript`, `ts` → `typescript`, `sh` → `bash`, etc. Same mappings, two locations. If you add a new alias to one, you'll forget the other.

### Problem 12: Language Color Mapping Diverged

Two implementations with **different color systems**:

| Language | `NativeCodeBlockView.languageColor()` | `CodeBlockView.languageColor()` |
|----------|--------------------------------------|--------------------------------|
| Swift | `Color.langSwift` (themed) | `.orange` (system) |
| JavaScript | `Color.langJavaScript` (themed) | `.yellow` (system) |
| Python | `Color.langPython` (themed) | `.blue` (system) |
| Ruby | `Color.langRuby` (themed) | `.red` (system) |
| Go | `Color.langGo` (themed) | `.cyan` (system) |
| Rust | `Color.langRust` (themed) | `.orange` (system) |
| Bash | `Color.langBash` (themed) | `.green` (system) |
| JSON | `Color.langJSON` (themed) | `.purple` (system) |
| HTML | `Color.langHTML` (themed) | `.red` (system) |
| CSS | `Color.langCSS` (themed) | `.blue` (system) |
| SQL | `Color.langSQL` (themed) | `.cyan` (system) |
| Default | `Color.textTertiary` (themed) | `.secondary` (system) |

The native renderer uses the carefully defined theme colors. The SwiftUI renderer uses raw system colors. These look visibly different. The CLAUDE.md explicitly says "Don't use system colors (.blue, .green, .purple, .orange)" — the SwiftUI `CodeBlockView` violates this.

### Problem 13: Code Block Style Tokens Not From Theme

Both `NativeCodeBlockView` and `CodeBlockView` (SwiftUI) hardcode code block styling:
- Background: `Color(red: 0.06, green: 0.06, blue: 0.07)` — defined inline, not from `Color.backgroundCode`
- Border: `Color.white.opacity(0.06)` — not from any theme token
- Line number color: `.white.opacity(0.35)` — not from `Color.textQuaternary`
- Line number background: `.white.opacity(0.02)` — not from any token

Theme.swift defines `Color.backgroundCode = Color(red: 0.03, green: 0.035, blue: 0.055)` but nobody uses it — the actual code blocks use a different, slightly brighter shade.

### Problem 14: Blockquote Styling Inconsistent

Native blockquote bar:
- `NativeMarkdownContentView.blockquoteBarColor = PlatformColor(Color.accentMuted).withAlphaComponent(0.9)`

SwiftUI blockquote bar:
- Standard: `Color.accentMuted.opacity(0.9)` — matches!
- Thinking: `Color.textTertiary.opacity(0.5)` — matches!

But native blockquote text uses `Fonts.blockquoteBody` which is `PlatformFont.systemFont(ofSize: TypeScale.reading).withItalic()` at 14pt, while SwiftUI uses `TypeScale.reading` (14pt standard) / `TypeScale.code` (12pt thinking). The font sizes happen to match here, but through different code paths that could diverge.

### Problem 15: Test Coverage Gaps

5 tests in `MarkdownParsingTests.swift`. Missing coverage for:

**Inline elements**:
- Bold, italic, bold-italic nesting (`***text***`)
- Inline code font/color/background
- Strikethrough
- Bare URL auto-detection via NSDataDetector
- Explicit markdown links with URL attribute
- Image alt-text rendering
- Inline HTML rendering

**Block elements**:
- Heading levels 1-3 with correct font sizes, kerning, margins
- Blockquote with accent bar and italic text
- Code block height calculation
- Code block expand/collapse thresholds
- Thematic break rendering

**Style variants**:
- Thinking mode: all font sizes, colors, spacing differences
- Content style consistency between standard/thinking

**Edge cases**:
- Empty content → empty blocks array
- Content with only whitespace
- Deeply nested lists (3+ levels)
- Code blocks inside list items
- Tables with mismatched column counts
- Very long single paragraphs
- Mixed heading levels
- Consecutive code blocks
- Markdown with HTML blocks interspersed

**System behavior**:
- Parse cache: hit/miss/eviction behavior
- SyntaxHighlighter cache: line-level caching
- Height calculation accuracy (parsed blocks height vs actually rendered height)
- Language normalization (all aliases)

---

## Plan — The Fix

### Phase 1: Unified Style System

**Goal:** Single source of truth for all markdown typography and color tokens. Eliminate all hardcoded color literals and mutable static state.

**Files touched:** `MarkdownTheme.swift` (new), `MarkdownAttributedStringRenderer.swift`, `MarkdownView.swift`, `NativeMarkdownContentView.swift`, `NativeCodeBlockView.swift`, `Theme.swift`

1. **Create `Markdown/MarkdownTheme.swift`** — a struct that owns all typography and color values:
   ```swift
   struct MarkdownTheme: Sendable {
     // Text
     let bodyFont: PlatformFont
     let bodyBoldFont: PlatformFont
     let bodyItalicFont: PlatformFont
     let bodyBoldItalicFont: PlatformFont
     let inlineCodeFont: PlatformFont
     let blockquoteFont: PlatformFont

     let textColor: PlatformColor
     let inlineCodeColor: PlatformColor
     let inlineCodeBgColor: PlatformColor
     let linkColor: PlatformColor
     let blockquoteBarColor: PlatformColor
     let blockquoteTextColor: PlatformColor

     // Spacing
     let lineSpacing: CGFloat
     let paragraphSpacing: CGFloat
     let listSpacingBefore: CGFloat
     let listSpacing: CGFloat

     // Headings (per level 1-3)
     let headings: [HeadingStyle]  // index 0 = H1, 1 = H2, 2 = H3

     struct HeadingStyle: Sendable {
       let font: PlatformFont
       let color: PlatformColor
       let topMargin: CGFloat
       let bottomMargin: CGFloat
       let kerning: CGFloat
     }

     // SwiftUI accessors (computed)
     var bodySwiftUIFont: Font { ... }
     var textSwiftUIColor: Color { ... }
     // etc.

     static let standard = MarkdownTheme(...)
     static let thinking = MarkdownTheme(...)
   }
   ```
2. **Fix Theme.swift markdown tokens** — `Color.markdownInlineCode` currently has wrong green channel (`0.7` vs actual `0.68`). `Color.markdownLink` uses `accent` (cyan `0.35, 0.78, 0.95`) but the actual hardcoded link color is `(0.5, 0.72, 0.95)`. Either update the theme tokens to match the actual values, or decide the canonical colors and update everything.
3. **Pass `MarkdownTheme` explicitly** to `MarkdownAttributedStringRenderer.parse()` as a parameter instead of using `activeStyle` static var. Delete `activeStyle`, `ContentStyle`, `MarkdownStyle`, and `StreamingMarkdownView.Style`.
4. **Delete all hardcoded RGB literals** from `MarkdownView.swift` and `NativeMarkdownContentView.swift`. Replace with theme token references.
5. **Add thinking-mode theme token for inline code** — currently the native renderer uses `alpha: 0.7` on the same tan, while SwiftUI uses a completely different hue (`0.85, 0.6, 0.4`). Decide on one approach.

### Phase 2: Syntax Highlighting Consolidation

**Goal:** One set of language definitions. One highlighting engine. One cache. Delete ~600 lines.

**Files touched:** `SyntaxHighlighter.swift`, `NativeSyntaxHighlighter.swift` (delete), `LanguageDefinition.swift` (new), `NativeCodeBlockView.swift`, `CodeBlockView` in `MarkdownView.swift`, `OrbitDockApp.swift`

1. **Extract language definitions** into a data-driven `LanguageDefinition` struct:
   ```swift
   struct LanguageDefinition {
     let keywords: [String]
     let types: [String]
     let stringPattern: String
     let commentPattern: String
     let numberPattern: String
     let specialPatterns: [(pattern: String, tokenType: SyntaxTokenType)]

     /// Normalized name (e.g., "javascript" not "js")
     let canonicalName: String
     /// All aliases (e.g., ["js", "jsx"])
     let aliases: [String]
     /// Badge dot color
     let badgeColor: Color
   }
   ```
   This consolidates: keyword lists, normalization aliases, and badge colors into one place per language.

2. **Delete all 11 full-code highlighter functions** (`highlightSwift()`, `highlightJavaScript()`, etc.) and the dead `highlight()` entry point. ~550 lines removed.

3. **Refactor `SyntaxHighlighter` to produce `NSAttributedString` as primary output** — the native path (conversation timeline) is the primary consumer. Add a thin `toSwiftUIAttributedString()` adapter for the 4 SwiftUI callsites (EditCard, ReadCard, DiffHunkView, CodeReviewFeedbackCard).

4. **Delete `NativeSyntaxHighlighter.swift`** entirely. Move its cache into `SyntaxHighlighter` (now producing `NSAttributedString` directly). Update `OrbitDockApp.swift` memory pressure handler.

5. **Consolidate language normalization** — one `LanguageDefinition.resolve(_ alias: String) -> LanguageDefinition?` lookup, used by both pipelines and the badge color mapping.

6. **Fix `CodeBlockView` language colors** — replace raw system colors (`.orange`, `.yellow`, `.blue`) with `languageDefinition.badgeColor` which uses the themed `Color.langSwift`, etc.

### Phase 3: Consolidate Rendering Pipelines

**Goal:** SwiftUI path consumes `[MarkdownBlock]` from the same parser. Delete 200+ lines of duplicate AST walking.

**Files touched:** `MarkdownView.swift` (major rewrite), `MarkdownAttributedStringRenderer.swift` (minor)

1. **Rewrite `MarkdownView.swift`** to consume `[MarkdownBlock]` instead of walking the `Document` AST independently:
   ```swift
   struct MarkdownContentView: View {
     let content: String
     var theme: MarkdownTheme = .standard

     var body: some View {
       let blocks = MarkdownAttributedStringRenderer.parse(content, theme: theme)
       VStack(alignment: .leading, spacing: 0) {
         ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
           MarkdownBlockView(block: block, theme: theme)
         }
       }
     }
   }
   ```
2. **Delete the duplicate inline walkers**: `inlineText()`, `inlineSegment()`, `attributedString()`, `inlineAttributedString()` — all 200+ lines. The `.text(NSAttributedString)` blocks render via `Text(AttributedString(nsAttributedString))` in SwiftUI.
3. **Delete `MarkdownDocumentView`** and its `blockView(for:)` dispatcher.
4. **Unify code blocks** — the SwiftUI `CodeBlockView` should use the same `LanguageDefinition` data and theme tokens. It can remain a pure SwiftUI view (wrapping in NSViewRepresentable would be overkill for the ~5 callsites that use it), but it shares all configuration with the native `NativeCodeBlockView`.
5. **Unify table rendering** — `MarkdownTableView` (SwiftUI) should use theme tokens instead of raw `.white.opacity()` values.
6. **Fix link handling** — with the unified block model, every `.text(NSAttributedString)` block already has bare URLs auto-detected (via `NSDataDetector` in the native parser). The SwiftUI path gets this for free. Delete the `hasLinks` conditional split in `MarkdownParagraphView`.

### Phase 4: Fix List Rendering

**Goal:** Remove the hand-rolled re-parser. Properly walk the AST for all list item content types.

**Files touched:** `MarkdownAttributedStringRenderer.swift`

1. **Delete `parseListContinuation()`** and `ListContinuationLine` enum (~80 lines).
2. **Audit `swift-markdown` AST output** for common Claude list patterns — capture actual AST structures for:
   - Simple bullet list
   - Nested bullets (2-3 levels deep)
   - Ordered list within unordered
   - Code block inside list item
   - Continuation paragraph (soft-wrapped long content)
   - Task list with checkboxes
3. **Fix `renderListItem()`** to handle all child block types:
   - `BlockQuote` inside list items (currently falls to plaintext)
   - Multiple `Paragraph` children (continuation paragraphs) — render with proper indent
   - `ThematicBreak` inside list items
   - Nested `Table` inside list items
4. **Add regression tests** for each pattern above.

### Phase 5: Reduce Platform Branching

**Goal:** Reduce the 18 `#if os()` blocks in `NativeCodeBlockView` through platform abstraction.

**Files touched:** `NativeCodeBlockView.swift`, potentially `PlatformTypes.swift` or similar

1. **Create factory methods** for platform-specific view setup:
   ```swift
   // Instead of 18 #if os() blocks for NSTextField vs UILabel:
   private func makeLabel(_ text: String, font: PlatformFont, color: PlatformColor) -> PlatformView
   private func makeButton(title: String, action: Selector) -> PlatformView
   ```
2. **Consolidate button action patterns** — `NSButton(target:action:)` vs `UIButton.addTarget(_:action:for:)` into a shared protocol or helper.
3. **Target: reduce from 18 to ~4-6 `#if os()` blocks** (setup, scroll view, clipboard, layout-specific).

### Phase 6: Improve Caching

**Goal:** Smarter eviction, unified caches, macOS memory handling.

**Files touched:** `MarkdownAttributedStringRenderer.swift`, `SyntaxHighlighter.swift`, `OrbitDockApp.swift`

1. **Replace nuclear eviction** with partial eviction — when at capacity, remove the oldest 25% of entries. Use an `OrderedDictionary` (from swift-collections) or a simple array-backed LRU:
   ```swift
   struct LRUCache<Key: Hashable, Value> {
     private var storage: [Key: (value: Value, accessOrder: Int)] = [:]
     private var accessCounter = 0
     let maxSize: Int

     mutating func get(_ key: Key) -> Value? { ... }
     mutating func set(_ key: Key, _ value: Value) { ... }
   }
   ```
2. **Merge highlight caches** — after Phase 2, there's only one `SyntaxHighlighter` cache producing `NSAttributedString` directly. One cache, one eviction path.
3. **Add macOS memory pressure handling** — use `DispatchSource.makeMemoryPressureSource()` to clear caches on macOS, matching the existing iOS behavior.
4. **Add cache statistics logging** (debug builds) — hit rate, eviction count, cache size. Write to timeline log for performance tuning.

### Phase 7: Expand Test Coverage

**Goal:** Comprehensive tests for the parsing and rendering layer.

**Files touched:** `MarkdownParsingTests.swift` (major expansion)

Tests organized by category:

**Inline Elements:**
- `testBoldRendering` — verify font weight
- `testItalicRendering` — verify italic trait
- `testBoldItalicNesting` — `***text***` gets bold+italic
- `testInlineCodeStyling` — verify font (monospaced), color (theme token), background color
- `testStrikethroughAttribute` — verify `.strikethroughStyle` attribute
- `testExplicitLinkWithURL` — verify `.link` attribute with correct URL
- `testBareURLAutoDetection` — verify NSDataDetector finds and linkifies bare URLs
- `testImageAltTextRendering` — verify alt text displayed, linked to source
- `testInlineHTMLRenderedAsPlainText` — verify HTML tags rendered as text

**Block Elements:**
- `testHeadingLevels` — H1/H2/H3 font sizes, weights, kerning per level
- `testHeadingSpacing` — top/bottom margins per level
- `testBlockquoteStyles` — italic font, accent color, paragraph style
- `testCodeBlockParsing` — language extraction, trailing newline trimming
- `testCodeBlockHeight` — deterministic height for known line counts
- `testCodeBlockCollapseThreshold` — 15+ lines triggers collapse
- `testTableHeaderAndRowExtraction` — column/row parsing
- `testTablePadding` — cells padded to header count
- `testThematicBreakBlock` — produces `.thematicBreak`

**Lists:**
- `testOrderedListNumbering` — start index, sequential numbering
- `testUnorderedListBullets` — bullet character
- `testTaskListCheckboxes` — checked/unchecked markers
- `testNestedListIndentation` — headIndent increases per level
- `testCodeBlockInsideListItem` — fenced code in list items
- `testMultipleParagraphsInListItem` — continuation paragraphs

**Style Variants:**
- `testThinkingModeFontSizes` — verify all font sizes are smaller than standard
- `testThinkingModeColors` — verify muted text color, reduced opacity
- `testThinkingModeSpacing` — verify tighter line/paragraph spacing
- `testStandardVsThinkingConsistency` — same content parsed with both, verify structural equivalence (same block types)

**Language Handling:**
- `testLanguageNormalization` — all aliases map to canonical names
- `testLanguageBadgeColors` — each language has a themed badge color
- `testUnknownLanguageFallback` — unknown languages get generic highlighting

**Caching:**
- `testParseCacheHit` — same content+style returns cached result (reference equality)
- `testParseCacheMissOnDifferentStyle` — same content, different style → cache miss
- `testParseCacheEviction` — verify cache doesn't grow unbounded
- `testHighlightCacheHit` — same line+language returns cached result

**Height Calculation:**
- `testTextBlockHeight` — measured height matches NSLayoutManager
- `testCodeBlockHeightCollapsed` — 8 visible lines + header + expand button
- `testCodeBlockHeightExpanded` — all lines + header
- `testMixedBlocksHeight` — text + code + table produces correct total

---

## File Impact Summary

| File | Action | Lines Changed (est.) |
|------|--------|---------------------|
| **New: `Markdown/MarkdownTheme.swift`** | Unified typography + color tokens | +150 |
| **New: `Markdown/LanguageDefinition.swift`** | Data-driven language definitions + normalization + badge colors | +200 |
| `MarkdownAttributedStringRenderer.swift` | Accept `MarkdownTheme`, delete `activeStyle`/`ContentStyle`/`Fonts`/`Colors` nested enums | ~-100, +50 |
| `MarkdownView.swift` | Major rewrite: consume `[MarkdownBlock]`, delete duplicate walkers | ~-400, +80 |
| `SyntaxHighlighter.swift` | Delete 550 lines of full-code duplicates, refactor to `NSAttributedString` output | ~-600, +30 |
| `NativeSyntaxHighlighter.swift` | **Delete entirely** | -87 |
| `NativeCodeBlockView.swift` | Use `LanguageDefinition`, reduce `#if os()` blocks | ~-60, +40 |
| `NativeMarkdownContentView.swift` | Use theme tokens for link colors | ~-10, +5 |
| `NativeRichMessageCellView.swift` | Pass theme to parse calls | ~5 |
| `UIKitRichMessageCell.swift` | Pass theme to parse calls | ~5 |
| `Theme.swift` | Fix `markdownInlineCode`/`markdownLink` values, possibly remove if all tokens move to `MarkdownTheme` | ~5 |
| `OrbitDockApp.swift` | Update cache clearing calls, add macOS memory pressure | ~10 |
| `MarkdownParsingTests.swift` | Major expansion | +400 |

**Net effect:** ~-700 lines removed, ~+975 lines added. But the added lines are mostly tests (+400), a well-structured theme (+150), and language definitions (+200). Actual rendering code decreases by ~700 lines.

---

## Execution Order & Dependencies

```
Phase 1 (Style System) ─────┐
                              ├── Phase 3 (Pipeline Consolidation) ── Phase 4 (Lists)
Phase 2 (Syntax Highlight) ──┘

Phase 5 (Platform Branching) ── independent, anytime
Phase 6 (Caching) ── after Phase 2 (merged caches)
Phase 7 (Tests) ── after each phase, incrementally
```

Recommended order: **1 → 2 → 3 → 4 → 5 → 6**, with Phase 7 tests added at the end of each phase.

Each phase is self-contained and shippable. No phase leaves the app in a broken state.

---

## Non-Goals

- **Tree-sitter / TextMate grammars** — regex is fine for 11 languages. This plan is about architecture, not adding an engine.
- **Markdown editing** — read-only renderer for AI conversation output.
- **LaTeX / math rendering** — not needed for coding agent output.
- **Image rendering in markdown** — images are handled at the message level (`NativeRichMessageCellView`), not the markdown level.
- **Replacing `swift-markdown`** — the Apple library is solid. The problems are in our code, not the parser.
- **Server-side rendering** — markdown is always rendered client-side in Swift.

---

## Success Criteria

After all phases:
1. **One color change = one file edit** — any markdown color/font tweak only requires updating `MarkdownTheme`
2. **Zero hardcoded RGB in rendering code** — all colors come from theme tokens
3. **Content looks identical** across SwiftUI and native renderers (same spacing, colors, fonts)
4. **`SyntaxHighlighter.swift` < 600 lines** (down from 1108)
5. **`NativeSyntaxHighlighter.swift` deleted**
6. **`MarkdownView.swift` < 400 lines** (down from 941)
7. **40+ markdown parsing tests** (up from 5)
8. **No `#if os()` in `NativeCodeBlockView` setup** (down from 18)
9. **One language definition = one data struct** — adding a new language is adding one static constant
