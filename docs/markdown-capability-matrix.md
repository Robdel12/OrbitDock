# Markdown Capability Matrix

This doc is the Phase 0 baseline for markdown migration work.

The goal is simple: before we refactor rendering, we need clear evidence of what system markdown parsing gives us out of the box and what still needs app-level handling.

## Scope

- Parser APIs evaluated:
  - `AttributedString(markdown:)`
  - `NSAttributedString(markdown:)`
- Environment:
  - macOS local test runs in OrbitDock workspace
  - Swift test harness (`MarkdownParsingTests`)

## Summary

System markdown parsing is good enough to be our parser source of truth for most semantics.

It handles links, bare URLs, code blocks, and table structure (via presentation intents).

Two important caveats remain:

1. Task list markers are emitted as literal text (`[x]`, `[ ]`) and still need app styling if we want checkbox UI.
2. Parser output is semantic, not final app typography. We still need theme/style application and deterministic layout for timeline rendering.

## Capability Matrix

| Capability | Status | Notes |
|---|---|---|
| Explicit links (`[label](url)`) | Supported | Emits `.link` attributes. |
| Bare URL auto-linking | Supported | Bare `https://...` gets link attribute. |
| Headings | Supported | Exposed as presentation intents. |
| Ordered/unordered lists | Supported | List structure is represented in intents. |
| Task list checkboxes | Partial | Text includes `[x]` / `[ ]`; no checkbox UI intent. |
| Fenced code blocks | Supported | `codeBlock` presentation intent includes language. |
| Tables | Supported | Table cell/row/header intents are emitted. |
| Block quotes | Supported | Represented in presentation intents. |
| Thematic breaks | Supported | Represented structurally in markdown parse output. |
| App typography/styling | Not automatic | Must be applied via OrbitDock theme tokens. |
| Deterministic timeline sizing | Not automatic | Must remain in native rendering path. |

## Migration Guidance

- Treat system markdown parser output as semantic source of truth.
- Keep timeline-native measurement/rendering for deterministic heights and smooth scrolling.
- Stop maintaining duplicate inline AST walkers in separate native and SwiftUI paths.
- Add fixture-driven parser tests first, then replace renderer layers incrementally.

## Test Coverage Source

The executable baseline for this matrix lives in:

- `OrbitDock/OrbitDockTests/MarkdownParsingTests.swift`

Key Phase 0 tests:

- `systemMarkdownLinksBareAndExplicitURLs`
- `systemMarkdownEmitsTableAndCodeBlockPresentationIntents`
- `systemMarkdownTaskListMarkersAreLiteralText`
