# Markdown Selection — Scoping Recommendation

Investigation for [#61](https://github.com/Robdel12/OrbitDock/issues/61).

## Confirmed Root Cause

SwiftUI `.textSelection(.enabled)` works by creating selection regions that span contiguous `Text` views within the same container. When a non-Text view sits between two Text views, selection cannot cross the boundary — the user must start a new selection on the other side.

`MarkdownBlockView` applies `.textSelection(.enabled)` at the outer VStack level (line 31), which correctly propagates to all child `Text` views. The problem is that several block types introduce non-Text structural views that break the selection chain:

| Block type | Breaking view | Why it breaks |
|-----------|--------------|---------------|
| Code block | `SwiftUICodeBlockView` — contains `HStack`, `ScrollView`, `Button`, background shapes | Entire code block is a non-Text island |
| Blockquote | `HStack` wrapper with `RoundedRectangle` bar + Text | The bar shape breaks the text flow |
| Table | `Grid` with `GridRow`, background fills, divider shapes | Each cell is an isolated Text |
| List | `HStack` per row with marker `Text` + content `Text` | Marker/content split + vertical nesting |
| Thematic break | `HStack` with `Circle` shapes | Pure shapes, no text at all |

Plain `.text` and `.heading` blocks render as bare `Text` views and *do* participate in contiguous selection — so a message that is only paragraphs and headings actually selects fine. The fragmentation appears as soon as a code block, list, table, or blockquote sits between paragraphs.

Secondary contributor: `MarkdownContentView` renders the streaming tail as a separate `Text(verbatim:)` after the block VStack (line 66–71), so selection also cannot span from the rendered blocks into the streaming tail while content is still arriving.

## Approaches Evaluated

### Approach 1: Native read-only text view (`NSTextView` / `UITextView`)

Replace `MarkdownBlockView` with a platform text view that renders the entire message as a single `NSAttributedString` / `NSTextStorage` document.

**How it works:**
- Build an `NSAttributedString` from the parsed `[MarkdownBlock]` array (or directly from the raw markdown via a markdown→attributed-string pipeline).
- Wrap in `NSViewRepresentable` (macOS) / `UIViewRepresentable` (iOS).
- Configure as read-only, non-editable, with selection enabled.
- For code blocks: use monospaced font runs with background color attributes. For tables: use `NSTextTab` or paragraph-level tab stops (limited fidelity) or fall back to a text representation.

**Tradeoffs:**

| Dimension | Assessment |
|-----------|-----------|
| Selection | Full contiguous selection across the entire message. Cmd+A selects all. |
| Code blocks | Lose the current header (language badge, line count, copy button), expand/collapse, horizontal scroll, and line numbers. These would need to be re-implemented as text attachments or overlaid views, which is complex. |
| Tables | `NSAttributedString` has no native table layout. Would need either plain-text table fallback (pipe-delimited) or `NSTextTable` (AppKit-only, no UIKit equivalent). |
| Syntax highlighting | Already produces `NSAttributedString` via `SyntaxHighlighter.highlightNativeLine()`. Could be composed directly into the document. |
| Streaming | Appending to `NSTextStorage` is efficient, but requires careful cursor/selection preservation during updates. SwiftUI's declarative re-render model does not apply — would need imperative diffing. |
| Height measurement | `NSTextView` needs explicit width to compute intrinsic height. Inside a `LazyVStack` this requires a two-pass layout (measure available width → set text view width → read height). The old codebase had this (`MarkdownContentRepresentable`) and removed it for complexity reasons. |
| Performance | `NSTextView` has good text layout performance but `NSViewRepresentable` bridge overhead in a `LazyVStack` can cause stutters during fast scrolling. Each message becomes an AppKit/UIKit view embedded in SwiftUI, doubling the layout cost. |
| Cross-platform | Requires two separate implementations (macOS: `NSTextView`, iOS: `UITextView`) with different APIs for attributed strings, text attachments, and table handling. |
| Existing code | Reverts the architectural direction stated in `MarkdownContentView` header ("No availableWidth, no height measurement, no NSViewRepresentable"). Large rework. |

**Verdict:** Delivers the best selection UX but at very high implementation cost. Loses rich block rendering (code block chrome, table Grid, interactive expand/collapse) that would need to be rebuilt. The height measurement and representable bridge complexity is exactly what the current codebase moved away from.

### Approach 2: Hybrid path — keep SwiftUI renderer + add copy affordance

Keep the current `MarkdownBlockView` renderer as-is. Add an explicit "Copy message" button (and optional keyboard shortcut on macOS) that copies the full raw markdown to the clipboard.

**How it works:**
- Add a "Copy" button in the message row header area (next to the "Assistant" / "You" label) or as a hover-revealed action.
- On tap: copy the raw `content: String` to the pasteboard.
- Optionally add `Cmd+C` handling when a message is focused/hovered on macOS.

**Tradeoffs:**

| Dimension | Assessment |
|-----------|-----------|
| Selection | Does NOT improve drag-to-select. Users still cannot select across block boundaries. But full content is available via one click. |
| Code blocks | Already have a per-block "Copy" button. This adds message-level copy. |
| Streaming | No interaction — the button copies whatever content exists at click time. |
| Height/layout | Zero impact. |
| Performance | Zero impact. |
| Cross-platform | Trivial — one SwiftUI button, shared code. |
| Implementation cost | Very small (< 1 day). |

**Verdict:** Cheapest option, immediately shippable. Addresses the "I want to grab the whole response" need but does NOT fix the underlying selection UX. Good as a quick win shipped alongside a deeper fix.

### Approach 3: Unified `Text` concatenation (SwiftUI-native)

Restructure `MarkdownBlockView` so that *all* block content composes into a single `Text` value using SwiftUI's `Text` concatenation (`+` operator) and `AttributedString`. Non-text blocks (code, tables) would be rendered as styled attributed string runs rather than separate views.

**How it works:**
- Build one `AttributedString` that represents the full message.
- Headings: font/weight attributes on the run.
- Code blocks: monospaced font + background color attribute (renders as colored text, no background rectangle). Line numbers as leading text runs.
- Blockquotes: indented text with left-border simulated via a vertical bar character or no bar at all (italic + indented).
- Tables: pipe-delimited plain text with monospaced alignment.
- Lists: bullet/number characters + indented text.
- Render as `Text(attributedString).textSelection(.enabled)`.

**Tradeoffs:**

| Dimension | Assessment |
|-----------|-----------|
| Selection | Full contiguous selection across the entire message — one Text view. |
| Code blocks | Loses: background color fill, rounded border, header bar (language/copy/line-count), horizontal scroll for long lines, expand/collapse, line number gutter. Would need to accept a much simpler presentation (just monospaced colored text). |
| Tables | Loses Grid layout with alternating row colors, column alignment, borders. Falls back to monospaced pipe-delimited text. |
| Blockquotes | Loses the colored bar. Would need to simulate with indentation + italic/color. |
| Lists | Works well — bullet characters + indentation via paragraph style or leading spaces. |
| Syntax highlighting | Works — `SyntaxHighlighter` already produces `AttributedString`. Can be inlined. |
| Streaming | Simple append to the attributed string. |
| Height/layout | Simplified — single `Text` view auto-sizes. No measurement needed. |
| Performance | Single `Text` with large `AttributedString` can hit SwiftUI layout limits for very long messages. The existing collapse at 50 lines / 8K chars mitigates this. |
| Cross-platform | Fully shared — one implementation. |

**Verdict:** Achieves selection parity with the native text view approach while staying in pure SwiftUI. But the visual fidelity loss on code blocks and tables is significant — the current rendering is a major UX feature, not just cosmetic. This approach trades visual quality for selection quality.

## Recommendation

**Ship in two phases:**

### Phase 1: Copy affordance (hybrid path) — ship now

Add a "Copy message" action to `MessageRowView` for assistant and user messages. This immediately unblocks the most common need (grabbing a full response) with near-zero risk.

- Add a hover-revealed (macOS) / long-press (iOS) copy button to the message header area.
- Copy the raw `content` string to the system pasteboard.
- Can be shipped independently in a small PR.

### Phase 2: Read-only `NSTextView` / `UITextView` for message bodies — ship next

Replace `MarkdownBlockView` with a native text view *for the non-interactive text runs only*, while keeping `SwiftUICodeBlockView` and table `Grid` as embedded subviews.

The key insight is that the approach doesn't have to be all-or-nothing:

1. Convert paragraph (`.text`), heading, blockquote, and list blocks into a single `NSAttributedString` with styled runs.
2. When a code block or table appears in the block list, **end the current text view**, render the code block / table as the existing SwiftUI view, then **start a new text view** for subsequent text blocks.
3. This gives contiguous selection across all text-heavy blocks (which is most of the message), while preserving the rich interactive rendering for code blocks and tables.

**Implementation sketch:**
- New `MarkdownTextView` (NSViewRepresentable / UIViewRepresentable) that takes an `NSAttributedString` and renders read-only.
- `MarkdownBlockView` splits its `[MarkdownBlock]` into segments: `[.textRun(NSAttributedString), .codeBlock(...), .textRun(NSAttributedString), ...]`.
- Text runs render via `MarkdownTextView`. Code blocks and tables render as today.
- Selection spans the entire text run, which can be multiple paragraphs, headings, lists, and blockquotes.

**Why this is better than full NSTextView:**
- Preserves the rich code block and table UX.
- Each text run is relatively short (until the next code block), so height measurement is cheap.
- Streaming: only the final text run needs to be updated.
- Code block expand/collapse, copy button, syntax highlighting, horizontal scroll — all preserved.

**Why this is better than unified Text concatenation:**
- No visual fidelity loss on any block type.
- Native text view selection is more reliable than SwiftUI Text selection.
- Supports Cmd+A within a run, standard text cursor behavior, accessibility.

## File Touchpoints

| File | Change |
|------|--------|
| `Cells/MessageRowView.swift` | Phase 1: add copy button to assistant/user message views |
| `Markdown/MarkdownBlockView.swift` | Phase 2: split blocks into text-run segments, alternate between `MarkdownTextView` and existing SwiftUI block views |
| `Markdown/MarkdownContentView.swift` | Phase 2: pass available width for text view height measurement |
| New: `Markdown/MarkdownTextView.swift` | Phase 2: `NSViewRepresentable` / `UIViewRepresentable` wrapper for read-only attributed string display |
| New: `Markdown/MarkdownAttributedStringBuilder.swift` | Phase 2: converts text/heading/list/blockquote blocks into a single `NSAttributedString` |
| `Markdown/MarkdownStreamingProjection.swift` | Phase 2: minor — streaming tail feeds into the final text run instead of a separate SwiftUI Text |
| `TimelineScrollView.swift` | Phase 2: may need width geometry reader if text view needs explicit available width |

## Biggest Risks

1. **Height measurement regression** — `NSTextView` inside `LazyVStack` requires knowing available width before computing height. The old codebase had this and removed it. Needs careful implementation to avoid layout loops or blank-then-populating flicker.

2. **Streaming performance** — updating `NSTextStorage` on every token append while preserving selection state. Need to batch updates (the existing `streamingBucket` coarsening in `TimelineScrollView` helps).

3. **Cross-platform divergence** — `NSTextView` (macOS) and `UITextView` (iOS) have different APIs for attributed strings, link handling, and text attachments. Two implementations to maintain.

4. **Selection across text runs** — selection still won't span from one text run across a code block into the next text run. This is a fundamental limitation of having separate views. The mitigation is that most messages have few code blocks, so text runs are large.

## Platform Recommendation

**macOS first.** The selection UX is most painful on macOS where users expect precise drag-to-select. iOS users are more accustomed to tap-to-select and copy-menu workflows, and the copy button (Phase 1) covers the iOS need well.

Phase 2 can be macOS-only initially. iOS can follow if demand warrants, or stay on the current SwiftUI renderer with the copy affordance.
