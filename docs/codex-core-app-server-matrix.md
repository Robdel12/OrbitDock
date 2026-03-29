# Codex Core vs App Server Matrix

This doc answers a very specific question:

- what OrbitDock uses today that is not really "app-server"
- what `codex-core` still gives us that OrbitDock might actually want
- which Codex crates still make sense if app-server becomes the canonical runtime

The short version is simple.

OrbitDock currently depends on `codex-core` in meaningful ways. But most of that value is coming from our **embedded runtime architecture**, not from a large set of user-facing features that app-server cannot support.

That distinction matters.

If we move to app-server as the one real session runtime, a lot of current `codex-core` usage stops being strategic. What remains is mostly lower-level leverage: in-process embedding, direct manager access, rollout-path helpers, and internal escape hatches.

## Current Dependency Surface

OrbitDock currently pins these direct Codex dependencies in `orbitdock-server/Cargo.toml`:

- `codex-core`
- `codex-protocol`
- `codex-app-server-protocol`
- `codex-utils-absolute-path`
- `codex-arg0`
- `codex-login`

See:

- `orbitdock-server/Cargo.toml:18-25`

## What OrbitDock Uses Today

These are the major places where OrbitDock is coupled to Codex internals today:

- Embedded live runtime through `CodexThread` and `ThreadManager`
  - `orbitdock-server/crates/connector-codex/src/lib.rs`
  - `orbitdock-server/crates/connector-codex/src/config.rs`
- Direct session control via `Op::*`, `UserInput`, approvals, interrupt, skills, MCP refresh, and plugin manager access
  - `orbitdock-server/crates/connector-codex/src/session_ops.rs`
  - `orbitdock-server/crates/connector-codex/src/session.rs`
- Direct auth manager and browser login server integration
  - `orbitdock-server/crates/connector-codex/src/auth.rs`
- Raw rollout file lookup and transcript-path resolution
  - `orbitdock-server/crates/connector-codex/src/config.rs`
  - `orbitdock-server/crates/connector-codex/src/lib.rs`
  - `orbitdock-server/crates/server/src/transport/http/files.rs`
- App-server utility RPCs for config/account/rate-limit reads
  - `orbitdock-server/crates/server/src/runtime/codex_config.rs`
  - `orbitdock-server/crates/server/src/infrastructure/usage_probe.rs`

## Capability Matrix

This is the important split.

Some things are on `codex-core` today because we chose an embedded integration. Other things are genuinely lower-level and still only make sense if we want direct internal access.

| Area | OrbitDock uses today | Current dependency shape | App-server equivalent? | Keep core after app-server migration? | Recommendation |
| --- | --- | --- | --- | --- | --- |
| Live session runtime | Start/resume/fork threads, send messages, steer active turns, interrupt, stream events | `CodexThread`, `ThreadManager`, `Op::*`, `UserInput`, event mapping in `connector-codex` | Yes. `thread/start`, `thread/resume`, `thread/fork`, `turn/start`, `turn/interrupt`, streamed notifications | No for the product path | Move this to app-server. This is the biggest source of complexity today. |
| Approvals and ask-user flows | Exec approval, patch approval, permission answers, question answers | Direct `Op::*` submission plus concrete `CodexAction` plumbing | Yes. App-server exposes approval requests and client responses/server requests | No for the product path | Move to app-server and normalize responses into OrbitDock events. |
| Skills and MCP discovery | `ListSkills`, `ListMcpTools`, `RefreshMcpServers` | Direct thread ops and manager cache clearing | Yes. `skills/list` exists, app-server also owns app/tool surfaces | Probably not | Treat this as runtime capability on the app-server path. |
| Plugins | List/install/uninstall plus marketplace shaping | Mixed. Protocol types come from `codex-app-server-protocol`, but execution uses `thread_manager.plugins_manager()` | Yes. `plugin/list`, `plugin/read`, `plugin/install`, `plugin/uninstall` | No | This is a strong migration candidate. OrbitDock already thinks in app-server-shaped plugin payloads. |
| Auth and account state | Read account, login, cancel login, logout | `AuthManager`, `codex-login`, direct token refresh | Yes. `account/read`, `account/login/start`, `account/logout`, `account/updated` | No for canonical runtime | Prefer app-server auth flows. Direct auth manager access is not a strong reason to keep a whole embedded runtime. |
| Config and model discovery | Effective config, model/provider discovery, config writes | Split today. Utility APIs already use app-server; live runtime bootstrap still builds `codex_core::config::Config` directly | Yes. `config/read`, `config/value/write`, `model/list` | Probably not for product runtime | Finish the migration. This area is already partially app-server-backed. |
| Native new features | `thread/shellCommand`, `fs/watch`, remote websocket auth, newer app-server-first workflows | Not available on OrbitDock's current direct session path | Yes. These are app-server surfaces | No | This is the clearest sign that app-server should be the canonical runtime. |
| Raw rollout file lookup | Find transcript path by thread id, inspect files directly | `find_thread_path_by_id_str`, `find_codex_home` | Not really as a raw file helper. App-server gives thread APIs, not direct rollout paths | Maybe | Keep only if OrbitDock still wants file-level passive tooling. Otherwise redesign away from raw path dependence. |
| Direct plugin/auth/config managers | Call internal managers in-process | `thread_manager.plugins_manager()`, `AuthManager`, config assembly internals | Not as direct manager access | Maybe, but only for special tooling | This is lower-level leverage, not a product requirement. Keep only if we have a concrete use case. |
| Git/environment helper internals | Collect git state for event enrichment | `codex_core::git_info::collect_git_info` in event mapping | OrbitDock already has its own git resolver | No | Replace with OrbitDock-native helpers and drop this dependency reason. |
| Passive rollout parsing | Parse JSONL transcripts and recover subagent/file/tool state | `codex-protocol` types plus local rollout parser | Not a one-to-one app-server surface | Maybe | This is the best remaining argument for some lower-level Codex dependency, but it should be justified separately from the live runtime. |

## What Is Actually Core-Only Value?

If we strip away "we built the runtime around it," the remaining `codex-core` value is mostly this:

- in-process embedding without OrbitDock speaking JSON-RPC directly
- direct access to internal managers and helpers
- raw rollout/transcript file access
- a possible fallback or experimentation layer when app-server lags

That is real value. But it is **architectural value**, not a broad product-surface advantage.

If we do not plan to exploit that on purpose, it is hard to justify carrying the whole embedded runtime as a permanent first-class path.

## Crate Matrix

This is the more practical dependency decision.

| Crate | What OrbitDock uses it for today | If app-server becomes canonical | Likely recommendation |
| --- | --- | --- | --- |
| `codex-app-server-protocol` | Typed request/response payloads, especially config and plugin surfaces | Still needed | Keep |
| `codex-core` | Embedded live runtime, auth/config/plugin managers, rollout helpers, some git helpers | Most product-runtime usage should disappear | Keep during migration. Reevaluate afterward. Likely remove from the main live-session path, maybe retain only if passive/experimental tooling still needs it. |
| `codex-protocol` | Embedded event and op types, rollout parsing, model/config types | Embedded runtime usage should shrink sharply; passive tooling may still need it | Reevaluate after runtime migration. Possibly keep only for rollout/passive support, or remove if that path is redesigned. |
| `codex-login` | Direct ChatGPT login server in OrbitDock auth service | App-server auth should replace this | Candidate to remove |
| `codex-arg0` | Current direct integration bootstrapping | May still appear indirectly if OrbitDock adopts in-process app-server client | Likely remove as a direct design dependency, but verify upstream client/runtime needs first |
| `codex-utils-absolute-path` | Plugin path normalization | Replaceable locally if needed | Candidate to remove |

## Important Nuance About Binary Size

Moving to app-server does **not automatically** mean `codex-core` disappears from the binary.

Upstream now has `codex-app-server-client`, which is an in-process app-server facade. But that crate currently depends on:

- `codex-app-server`
- `codex-core`
- `codex-protocol`
- `codex-arg0`

So there are really two separate decisions:

1. Should OrbitDock make app-server the canonical runtime surface?
2. Should OrbitDock also remove most direct lower-level Codex crates from its own dependency graph?

The first answer looks like yes.

The second answer is "probably later, after the migration works and we confirm what passive tooling still needs."

## Recommendation

Use app-server as the one canonical Codex runtime for OrbitDock sessions.

Keep a narrow internal runtime boundary so OrbitDock's server stays in control of persistence, HTTP, and WebSocket behavior. But stop treating embedded `codex-core` as a co-equal long-term backend unless we can name a concrete reason it must survive.

### What to migrate first

- live session lifecycle
- turn start / interrupt / steer behavior
- approvals
- auth/account flows
- plugins
- skills / MCP listing

### What to reevaluate after that works

- passive rollout support
- raw transcript-path lookups
- direct auth manager access
- direct plugin manager access
- direct config/model assembly

### What likely becomes deleteable

- most direct `codex-core` runtime plumbing in `connector-codex`
- `codex-login`
- direct `codex-core` auth integration
- direct plugin-manager wiring
- direct `Op::*`-driven session command handling

## Bottom Line

Right now, OrbitDock is carrying a lot of `codex-core` complexity because the whole session stack is built around embedded core.

That does not mean OrbitDock needs all of that complexity in the future.

The matrix points to a pretty clear conclusion:

- app-server covers most of the product surface OrbitDock actually wants
- most remaining `codex-core` value is lower-level leverage, not must-have runtime surface
- we should keep only the lower-level pieces we can defend with a specific use case
