---
name: orbitdock-release-notes
description: "Standardize OrbitDock changelogs using two modes: (1) GitHub tag release notes with the stable long-form template (`Quick start`, `OrbitDock vX`, `Highlights`, `Important release notes`, `Full changelog`) and (2) TestFlight build-train changelogs based on build-marker commits like `🔖 v0.7.0-b7` to `🔖 v0.7.0-b8` that are not tags. Use when editing releases with `gh`, generating TestFlight notes, or producing platform-specific diffs (iOS/iPadOS vs macOS)."
---

# OrbitDock Release Notes

## Overview

Write and update OrbitDock release notes in a consistent, high-signal format.
Use `gh` and `git` as the source of truth before publishing edits.

## Modes

Choose one mode before gathering inputs:

- `tag-release mode`: Stable GitHub release notes for tagged versions (for example, `v0.10.0 -> v0.11.0`).
- `build-train mode`: TestFlight changelogs for emoji build markers that are commit subjects, not tags (for example, `🔖 v0.7.0-b7 -> 🔖 v0.7.0-b8`).

## Gather Inputs

### Tag-release mode

Collect these inputs:

- Target tag (for example, `v0.11.0`).
- Previous stable tag for compare link (for example, `v0.10.0`).
- Existing body and assets:
  - `gh release view <tag> --repo Robdel12/OrbitDock --json body,assets,name,tagName,url`
- Compare stats for the intro paragraph:
  - `gh api repos/Robdel12/OrbitDock/compare/<prev>...<tag> --jq '{total_commits,ahead_by,files:(.files|length),insertions:([.files[].additions]|add),deletions:([.files[].deletions]|add)}'`
- Optional deeper signal for highlight themes:
  - `gh api repos/Robdel12/OrbitDock/compare/<prev>...<tag> --jq '.commits[].commit.message'`

### Build-train mode (TestFlight)

Collect these inputs:

- Source marker and destination marker (for example, `🔖 v0.7.0-b7` and `🔖 v0.7.0-b8`).
- Resolve marker commit SHAs:
  - `BASE_SHA=$(git rev-list --all --max-count=1 --grep='^🔖 v0\\.7\\.0-b7')`
  - `HEAD_SHA=$(git rev-list --all --max-count=1 --grep='^🔖 v0\\.7\\.0-b8')`
- Confirm range stats:
  - `git diff --shortstat "$BASE_SHA..$HEAD_SHA"`
  - `git log --oneline --no-merges "$BASE_SHA..$HEAD_SHA"`
- Optional release lookup by display name (if needed):
  - `gh api repos/Robdel12/OrbitDock/releases --paginate --jq '.[] | select(.name=="🔖 v0.7.0-b8") | {name,tag_name,target_commitish,published_at,url}'`

For platform-specific slices (iOS/iPadOS vs macOS):

- Native file list in range:
  - `git diff --name-only "$BASE_SHA..$HEAD_SHA" -- OrbitDockNative/OrbitDock`
- Compile-guard signal:
  - `git diff "$BASE_SHA..$HEAD_SHA" -- OrbitDockNative/OrbitDock | rg '#if os\\((iOS|macOS)\\)|#elseif os\\((iOS|macOS)\\)'`
- UIKit/AppKit signal:
  - `git diff "$BASE_SHA..$HEAD_SHA" -- OrbitDockNative/OrbitDock | rg 'import (UIKit|AppKit)'`

## Build Release Body

### Tag-release mode

Follow [references/release-template.md](references/release-template.md).

### Build-train mode (TestFlight)

Follow [references/testflight-template.md](references/testflight-template.md).
Keep this concise and outcome-focused; TestFlight notes should be easy to skim in-app.
Output must be plain text only for TestFlight.

Rules:

- Keep section order and heading levels stable.
- Write highlights as grouped themes with 2-4 bullets each.
- Keep claims grounded in compare data and observable file/commit changes.
- Include only real attached server asset names in `Quick start`.
- Use a full compare URL in `## Full changelog`.
- For build-train notes, always include the marker range (`🔖 ... -> 🔖 ...`) and avoid tag language unless tags are truly involved.
- For platform notes, explicitly separate shared/native changes from iOS/iPadOS-only and macOS-only changes when possible.
- For TestFlight output, remove markdown syntax (no `#`, `##`, `###`, `-`, or backticks in final copy).
- For TestFlight output, remove emoji from user-facing text. If marker commits include an emoji prefix, strip it in the changelog text (for example, `🔖 v0.7.0-b8` -> `v0.7.0-b8`).

## Publish and Verify

1. Write notes to a temporary file.
2. Apply with:
   - `gh release edit <tag> --repo Robdel12/OrbitDock --notes-file <path>`
3. Verify with:
   - `gh release view <tag> --repo Robdel12/OrbitDock --json body,url`
4. Confirm the page URL and final body text in the output.

TestFlight mode:

1. Resolve marker SHAs and verify both exist.
2. Generate a copy/paste plain-text note from the template.
3. Keep a short "Platform breakdown" section when platform-specific changes are non-trivial.

## Guardrails

- Do not invent features that are not visible in commit/file history.
- Do not drop `Quick start` or `Full changelog` when targeting the v0.8.0/v0.9.0 style.
- Do not leave stale version text from prior releases.
- Prefer plain language over marketing-heavy copy.
- Keep release channel notes accurate (`stable` vs `nightly`).
- Do not assume build markers are tags; treat them as commit anchors unless verified otherwise.
- Do not claim iOS-only or macOS-only changes without file or compile-guard evidence.
- Do not include markdown formatting in final TestFlight text.
- Do not include emojis in final TestFlight text.

## References

- [references/release-template.md](references/release-template.md) for the canonical note structure.
- [references/testflight-template.md](references/testflight-template.md) for build-train changelogs.
