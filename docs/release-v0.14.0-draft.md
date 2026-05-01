# OrbitDock v0.14.0 Draft

Working range:

- Previous stable tag: `v0.13.0`
- Target release: `v0.14.0`
- Compare working tree: `v0.13.0..main`

Working artifacts saved locally:

- Full patch: `/tmp/orbitdock-v0.14.0-full.diff`
- Full commit log with stat output: `/tmp/orbitdock-v0.14.0-commits.txt`

Compare stats:

- `156` commits
- `953` changed files
- `106,196` insertions
- `95,949` deletions

## Draft GitHub Release Notes

## Quick start

- **App (iPhone, iPad, and Mac):** Join the TestFlight beta: https://testflight.apple.com/join/w4jThqxE
- **Server (recommended install):**
  - `curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash`
- **Standalone server assets:**
  - `orbitdock-darwin-arm64.zip`
  - `orbitdock-linux-x86_64.zip`
  - `orbitdock-linux-aarch64.zip`
- **Docs:** https://github.com/Robdel12/OrbitDock#readme

## OrbitDock v0.14.0

This release covers everything from `v0.13.0` to `v0.14.0`.

It is a major architecture and product-surface release: 156 commits across 953 files, with 106,196 insertions and 95,949 deletions. The biggest themes are a more capable Codex runtime, stronger session and transport behavior across the app, server-authoritative usage and state flows, and a deep cleanup of the server/API foundation underneath all of that.

## Highlights

### Codex runtime and tooling got much stronger

- Codex app-server support became much more first-class across the server and native app, including deeper runtime integration and better surfaced app-server state in OrbitDock.
- OrbitDock now supports newer Codex v0.122 tool surfaces more cleanly, including better handling around richer tool and conversation flows.
- Native OrbitDock picked up real app-server-backed features here too, including session capabilities, runtime controls, shell command handling, and cleaner MCP auth/status surfaces.
- Generated images now land as attachments instead of feeling like a second-class side path.

### Session flows, control surfaces, and browsing improved

- Native session transport and scene architecture were tightened so session surfaces behave more consistently across the app.
- The Control Deck picked up cleaner model and question flows, better app-server-backed runtime controls, and improved session/detail/runtime boundaries compared to `v0.13.0`.
- Dashboard and library behavior were cleaned up too, including usage refresh improvements and fixes for archive sorting and ID search.
- Conversation, dashboard, and session detail surfaces also got better native rendering for server-provided diff previews, durable bash output, and simplified fork/config state.

### Server-owned truth is much stronger

- Usage accounting moved further toward a fully server-authoritative model, with cleaner persistence, reporting, and native consumption.
- Session and runtime flows now rely more consistently on explicit server-owned state instead of mixed client/server inference.
- HTTP and WebSocket responsibilities are clearer now, which helps both correctness and future feature work.

### The server and API foundation got a serious cleanup

- OrbitDock’s Rust server and API surface were heavily reorganized so the remaining large modules act more like real authority spines instead of giant mixed-responsibility catch-alls.
- Old compatibility shims, dead protocol leaves, stale WebSocket mutation paths, orphaned rollout code, and a long tail of dead helpers were removed instead of just being shuffled around.
- Runtime startup, restore, resume, and takeover flows were tightened so the remaining ownership boundaries are much easier to reason about.

## Important release notes

- **This is a large release.**
  - If you self-host the server, treat this like a real upgrade point rather than a tiny patch. It includes broad runtime, protocol, transport, persistence, and native session-architecture cleanup.
- **Codex and session runtime behavior changed in meaningful ways.**
  - This release deepens app-server integration, tightens transport ownership, and cleans up a lot of old compatibility behavior under the hood.
- **HTTP is now the clear authoritative mutation path.**
  - WebSocket remains for replay, subscriptions, and follow-up deltas. If you have custom tooling or older assumptions that still treat WS as a write path, update those expectations.
- **Server binaries are attached.**
  - Download the macOS arm64, Linux x86_64, or Linux aarch64 zip that matches your platform.

## Full changelog

- Compare: https://github.com/Robdel12/OrbitDock/compare/v0.13.0...v0.14.0

## Deep Dive

This section is for release prep and reviewer sanity-checking, not for the final GitHub body.

### Chunk 1: Server/API refactor endgame

High-signal commits:

- `♻️ Complete the server functional refactor` `#258`
- `♻️ Strongly type connector outputs` `#259`
- `♻️ Finish native and API refactor`
- the full deletion/reorganization wave from `94ea8c58` through `4f3c08ab`

What happened:

- giant Rust server/API files were split into responsibility-aligned modules
- the entire Rust test surface was extracted out of giant production files first
- then the dead-code/dead-surface pass deleted compatibility junk instead of preserving it
- runtime authority, restore/hydration, protocol shaping, and transport ownership were all tightened in later waves

Why it matters to the release:

- this is the single biggest technical story in the range
- it makes the server safer to keep shipping on top of
- it also justifies a version bump beyond a patch release

### Chunk 2: Native session/runtime architecture

High-signal commits:

- `♻️ stabilize native session transport and scene architecture` `#260`
- `♻️ simplify native and server data flow`
- `♻️ Make session surfaces authoritative`
- `♻️ Harden native session state flow`

Hot areas by file churn:

- `OrbitDockNative/OrbitDock/Services/Server/`
- `OrbitDockNative/OrbitDock/Views/`
- `OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/`
- `OrbitDockNative/OrbitDock/Views/SessionDetail/`
- `OrbitDockNative/OrbitDock/Views/Dashboard/`

What happened:

- session/runtime ownership moved toward explicit surface owners
- native HTTP and realtime transport responsibilities were cleaned up
- control deck and session detail wiring were improved around the new server truth model
- dashboard, library, and mission control surfaces also evolved on top of that cleanup

Why it matters to the release:

- even though much of this work is architectural, it directly affects app stability, consistency, and future feature velocity
- this is the biggest app-side story in the range

### Chunk 3: Codex app-server and runtime maturity

High-signal commits:

- `✨ Make Codex app-server the first-class runtime`
- `✨ Surface app-server state in OrbitDock UI`
- `♻️ Finish Codex app-server conversation surface`
- `♻️ Deepen Codex app-server runtime integration`
- many later cleanup commits in the refactor endgame that touch Codex session/runtime/transport paths

What happened:

- Codex app-server support moved closer to the center of the product instead of feeling bolted on
- server runtime, protocol, and native UI all got tightened around that path
- native OrbitDock gained real app-server-backed features, including session capabilities sheets, runtime/controls reads, shell command flows, MCP auth/status plumbing, and cleaner control-deck refresh behavior
- dead rollout/parser leftovers were eventually deleted once the new path was clearly in charge

Why it matters to the release:

- it is one of the clearest user-facing capability improvements in the range
- it also explains a lot of the transport/runtime cleanup decisions

### Chunk 4: Usage accounting and server-owned truth

High-signal commits:

- `♻️ Make usage accounting fully server authoritative`
- `♻️ Finalize usage and runtime surfaces`
- `🐛 Restore persisted usage turn state`
- the later usage helper/persistence cleanup wave

What happened:

- usage history, summaries, and token/cost accounting moved further toward a server-owned backbone
- the native app dropped more local guesswork and drift-prone fallbacks
- persistence and reporting around usage became more explicit and durable

Why it matters to the release:

- this is one of the most important trust-building improvements in the range
- it affects both correctness and product confidence

### Chunk 5: Product polish and surrounding surfaces

High-signal commits:

- `✨ Serve generated images as attachments`
- `✨ Support Codex v0.122 tool surfaces`
- `💄 Redesign control-deck model picker`
- dashboard, library, mission control, and review follow-up fixes
- site/marketing additions for new OrbitDock pages

What happened:

- a meaningful amount of user-visible polish landed alongside the architecture work
- this range is not just “big internal refactor”; it also includes UI, workflow, and positioning improvements

Why it matters to the release:

- the notes should not read like a backend maintenance release
- there are real product-facing improvements worth calling out

## Recommended release framing

Suggested characterization:

- “major architecture and product-surface release”
- not “maintenance release”
- not “small polish release”

Suggested version:

- `v0.14.0`

Why:

- the range is too large and too structural for `v0.13.1`
- transport ownership, runtime authority, protocol cleanup, native architecture, and Codex maturity together feel like a minor-version release

## Recommended final release checklist

### Release notes

- tighten the three highlight sections after one final review pass
- verify whether you want to explicitly mention Codex app-server by name in the intro paragraph
- decide whether to call out TestFlight separately or leave the app callout in `Quick start`

### Validation

- rerun the core Rust validation suite you care about for release confidence
- rerun the macOS native build
- if iOS release confidence matters for this cut, run the iOS build/test pass you trust most
- sanity-check session create, send, resume, approvals, usage summary, dashboard, and library flows

### Tagging and publishing

- create `v0.14.0`
- build/upload server assets
- apply the final GitHub release body
- verify compare link and attached assets before publishing
