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

### Updated Direction (Feb 26, 2026)

We are keeping the timeline-native rendering shell for performance, and removing the custom markdown semantics/rendering logic that keeps drifting.

- **Use Apple markdown parsing as source of truth** for markdown semantics and inline attributes.
- **Keep a thin native timeline renderer** for deterministic height measurement, recycling, and streaming updates.
- **Eliminate duplicate markdown engines** across native + SwiftUI surfaces.

This gives us the best of both worlds:
- we stop writing our own markdown engine
- we keep the 60 FPS timeline behavior this app depends on

### Phase 0: Parser Capability Spike

**Goal:** Validate parser behavior against real OrbitDock transcript content before migration.

**Files touched:** `docs/markdown-capability-matrix.md` (new), `MarkdownParsingTests.swift`

1. Build a fixture set from real transcripts: long lists, nested lists, task checkboxes, tables, code fences, inline links, bare URLs, block quotes, mixed heading levels.
2. Capture parser output from the APIs we can rely on in production (`AttributedString(markdown:)` / `NSAttributedString(markdown:)`) and document edge-case behavior.
3. Record a support matrix:
   - Supported directly by system parsing
   - Needs light post-processing
   - Needs explicit fallback rendering
4. Define ship criteria for migration (no regressions on links, lists, code blocks, and tables).

### Phase 1: Introduce a Single Markdown Adapter

**Goal:** Replace ad-hoc AST walkers with one shared adapter layer.

**Files touched:** `MarkdownAttributedStringRenderer.swift` (rewrite), new `MarkdownSystemParser.swift`, `MarkdownView.swift`

1. Add `MarkdownSystemParser` as the only markdown parsing entry point.
2. Parse once and emit a shared `MarkdownIR`:
   - `text(NSAttributedString)` for prose/list/heading/blockquote content
   - `codeBlock(language, code)`
   - `table(headers, rows)`
   - `thematicBreak`
3. Delete custom inline walkers and style branching currently duplicated across native and SwiftUI paths.
4. Keep style tokens centralized (`MarkdownTheme` or equivalent) so typography stays consistent.

### Phase 2: Thin Native Renderer for Conversation Timeline

**Goal:** Preserve deterministic timeline behavior while removing markdown semantic ownership from native views.

**Files touched:** `NativeMarkdownContentView.swift`, `NativeRichMessageCellView.swift`, `UIKitRichMessageCell.swift`

1. Keep `NativeMarkdownContentView.requiredHeight(...)` and TextKit measurement as-is for deterministic row sizing.
2. Render from shared `MarkdownIR` only; no markdown parsing logic inside timeline views.
3. Keep code blocks/tables as dedicated native blocks where interaction and layout need explicit control.
4. Ensure prepend anchor + height cache behavior remains unchanged in `ConversationCollectionView`.

### Phase 3: Move SwiftUI Surfaces to the Same IR

**Goal:** Eliminate the second markdown engine entirely.

**Files touched:** `MarkdownView.swift`, `WorkStreamEntry.swift`, `TaskCard.swift`, `UserBashCard.swift`

1. Replace `Document(parsing:)` + custom block walkers in `MarkdownView.swift` with shared `MarkdownIR` rendering.
2. Keep `StreamingMarkdownView` behavior, but feed it through the shared parser output path.
3. Remove the link/no-link split logic and custom inline rendering branches.
4. Reuse the same code block and table components/configuration used by native where possible.

### Phase 4: Syntax Highlighting + Code Block Consolidation

**Goal:** Keep one syntax highlighter path and one language definition source.

**Files touched:** `SyntaxHighlighter.swift`, `NativeSyntaxHighlighter.swift` (delete), `NativeCodeBlockView.swift`, `MarkdownView.swift`

1. Consolidate language normalization and badge colors in one data model.
2. Remove dead duplicate highlight functions and duplicate caches.
3. Make one output type primary (`NSAttributedString`) with adapters for SwiftUI callsites.
4. Ensure code block styling tokens come from theme values, not inline color literals.

### Phase 5: Caching, Reliability, and Test Coverage

**Goal:** Make markdown behavior stable under long sessions and rapid streaming updates.

**Files touched:** `MarkdownParsingTests.swift`, `OrbitDockApp.swift`, parser/highlighter cache files

1. Replace full cache nukes with bounded eviction (LRU or partial eviction).
2. Add macOS memory pressure handling to clear markdown/syntax caches safely.
3. Expand tests with fixture-driven cases:
   - Links + bare URL detection
   - Nested lists + task lists
   - Tables with uneven rows
   - Code fence language mapping
   - Deterministic text/row height expectations
4. Add regression tests ensuring native and SwiftUI paths render equivalent structure from the same `MarkdownIR`.

---

## File Impact Summary (Updated)

| File | Action |
|------|--------|
| **New: `docs/markdown-capability-matrix.md`** | Parser feature matrix + migration guardrails |
| **New: `MarkdownSystemParser.swift`** | Single parsing adapter and IR builder |
| `MarkdownAttributedStringRenderer.swift` | Convert to thin adapter over system parsing (or replace entirely) |
| `MarkdownView.swift` | Remove custom AST walkers; render shared IR |
| `NativeMarkdownContentView.swift` | Render-only responsibilities, no parsing semantics |
| `NativeSyntaxHighlighter.swift` | Delete |
| `SyntaxHighlighter.swift` | Single highlighter path + unified cache |
| `MarkdownParsingTests.swift` | Fixture-driven parser and rendering regression tests |

---

## Execution Order & Dependencies (Updated)

```
Phase 0 (Capability Spike)
  -> Phase 1 (Single Parser Adapter)
    -> Phase 2 (Native Timeline Integration)
    -> Phase 3 (SwiftUI Integration)
      -> Phase 4 (Syntax/CodeBlock Consolidation)
        -> Phase 5 (Caching + Tests)
```

Recommended order: **0 → 1 → 2 → 3 → 4 → 5**.

Each phase remains shippable. Phase 0 is mandatory before broad migration.

---

## Non-Goals (Updated)

- Building a full custom markdown engine.
- Replacing native timeline virtualization with SwiftUI hosting.
- Markdown editing support.
- LaTeX/math rendering.
- Server-side markdown rendering.

---

## Success Criteria (Updated)

After all phases:
1. **One parser entry point** for all markdown content.
2. **Zero custom inline markdown walkers** in app code.
3. **One shared markdown IR** consumed by native timeline and SwiftUI surfaces.
4. **Conversation timeline keeps deterministic height + anchor behavior** under streaming/prepend updates.
5. **`NativeSyntaxHighlighter.swift` is deleted** and highlight caching is unified.
6. **No raw system colors in markdown rendering** (`.blue`, `.green`, etc.).
7. **Fixture-driven markdown tests cover real transcript edge cases** and prevent regressions.
