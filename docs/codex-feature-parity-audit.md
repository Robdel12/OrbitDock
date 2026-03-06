# Codex Feature Parity Audit

This doc tracks how OrbitDock's **Codex direct sessions** compare to upstream `openai-codex` at tag `rust-v0.111.0`.

The goal is straightforward: build a fully featured Codex app experience in OrbitDock across macOS, iOS, the OrbitDock server, and the Codex connector.

## Why This Exists

OrbitDock already does a meaningful amount of Codex integration work.

The missing pieces are mostly not "can Codex do this at all?" They are:

- whether OrbitDock exposes the full upstream control plane
- whether the OrbitDock protocol carries enough data
- whether the UI gives users access to the same features upstream clients get
- whether session and turn configuration can be changed with the same fidelity as upstream

That distinction matters.

Because OrbitDock embeds `codex-core`, a lot of built-in tool capability likely already exists in the runtime. The bigger parity gap is in **configuration, orchestration, approvals, metadata, and UI exposure**.

## Scope

This audit focuses on **Codex direct sessions** in OrbitDock:

- OrbitDock server
- `connector-codex`
- OrbitDock app protocol
- macOS and iOS UI surfaces

Parity target:

- `../openai-codex` tag `rust-v0.111.0`
- especially `codex-rs/app-server`

## Sources Reviewed

Upstream Codex:

- `codex-rs/app-server/README.md`
- `codex-rs/app-server/src/codex_message_processor.rs`
- `codex-rs/app-server/src/models.rs`
- `codex-rs/app-server/src/config_api.rs`
- `codex-rs/core/config.schema.json`
- `codex-rs/core/src/tools/spec.rs`
- `codex-rs/core/src/features.rs`
- `codex-rs/core/src/models_manager/collaboration_mode_presets.rs`

OrbitDock:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/session.rs`
- `orbitdock-server/crates/connector-codex/src/auth.rs`
- `orbitdock-server/crates/server/src/ws_handlers/session_crud.rs`
- `orbitdock-server/crates/server/src/ws_handlers/messaging.rs`
- `orbitdock-server/crates/protocol/src/client.rs`
- `orbitdock-server/crates/protocol/src/server.rs`
- `orbitdock-server/crates/protocol/src/types.rs`
- `OrbitDock/OrbitDock/Views/Codex/NewCodexSessionSheet.swift`
- `OrbitDock/OrbitDock/Views/Codex/DirectSessionComposer.swift`
- `OrbitDock/OrbitDock/Views/Codex/CodexCollaborationModePicker.swift`
- `OrbitDock/OrbitDock/Views/Codex/SkillsTab.swift`
- `OrbitDock/OrbitDock/Views/Codex/McpServersTab.swift`
- `OrbitDock/OrbitDock/Services/Server/ServerAppState.swift`
- `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift`
- `OrbitDock/OrbitDock/Services/Server/ServerProtocol.swift`

## Status Legend

| Status | Meaning |
| --- | --- |
| Done | OrbitDock appears to support the upstream capability end to end. |
| Partial | Some support exists, but important fields, workflows, or UI are missing. |
| Missing | I could not find support in the OrbitDock server or UI. |
| Runtime-only | Codex likely supports this internally through `codex-core`, but OrbitDock does not expose or configure it clearly yet. |

## Big Picture

### What OrbitDock Already Has

OrbitDock is not starting from zero.

These direct-session capabilities already exist in some form:

- create, resume, and fork Codex sessions
- send messages to a direct session
- interrupt an in-flight turn
- steer a turn
- basic approvals for exec and patch flows
- thread rename, compact, rollback, and undo-style operations
- ChatGPT-managed auth flow
- model listing
- rate limit updates
- local skill listing
- MCP server status and refresh
- timeline rendering for many streamed Codex events

### The Main Gap

The biggest gap is not low-level tool execution.

The main gap is that OrbitDock currently exposes a **thin custom subset** of what upstream `app-server` supports. To get to full-feature parity, OrbitDock needs to grow into a proper Codex host app:

- broader session config
- broader per-turn config
- richer model and feature metadata
- full config APIs
- richer MCP auth and management
- remote skills
- apps and plugins
- realtime controls
- dynamic collaboration modes
- fuller approval decisions
- UI to manage all of the above

## Recommended Work Order

Use this order if the goal is to make the parity work usable as it lands.

1. Expand the **server and protocol surface** first.
2. Expose the new session and per-turn controls in the **new session sheet** and **composer**.
3. Add **auth, MCP, skills, and config** management UIs.
4. Add **apps, plugins, and realtime** once the foundational protocol is in place.
5. Fill in lower-priority parity like thread archive flows, feedback upload, and external config import.

## Execution Board

This is the actionable checklist. It is intentionally opinionated about sequencing.

### Phase 0: Foundation and Inventory

- [ ] Confirm the parity target stays pinned to upstream `rust-v0.111.0` until this audit is worked through.
- [ ] Add a lightweight rule for updating this doc whenever OrbitDock adds a Codex capability.
- [ ] Decide whether OrbitDock should mirror upstream names exactly in the app protocol or translate them into OrbitDock-specific types.
- [ ] Decide which advanced Codex settings belong in the default UI and which should live behind an "Advanced" section.

### Phase 1: Server and Protocol Parity

- [ ] Expand Codex session creation to honor `system_prompt`, `append_system_prompt`, `allowed_tools`, `disallowed_tools`, and collaboration-mode style settings.
- [ ] Add a richer Codex session config model that can carry personality, web search mode, profile/provider selection, service tier, and other upstream config values.
- [ ] Expand per-turn message sending to support `cwd`, sandbox policy, network access, personality, summary mode, and output schema.
- [ ] Add `config/read`, `config/value/write`, `config/batchWrite`, and `configRequirements/read` to the OrbitDock protocol.
- [ ] Expand model metadata in the OrbitDock protocol to include capability flags and defaults from upstream.
- [ ] Replace hardcoded collaboration modes with a server-driven `collaborationMode/list` style response.
- [ ] Expand approval flows so OrbitDock can represent the richer decisions upstream Codex can request.
- [ ] Add server endpoints and events for remote skills, apps, plugins, realtime, and MCP auth management if they are not already present.

### Phase 2: Core UI Parity

- [ ] Expand the new Codex session UI to include personality, collaboration mode, effort, prompt/instructions, auth mode, and advanced config.
- [ ] Expand the direct-session composer so a turn can override model, effort, cwd, sandbox policy, network access, personality, summary mode, and output schema.
- [ ] Add richer approval UI for command, patch, and question requests when Codex exposes additional decisions.
- [ ] Surface full model metadata so the UI can explain why a model is or is not available.
- [ ] Add a proper advanced settings surface for Codex session defaults and effective config inspection.

### Phase 3: Integration Surfaces

- [ ] Finish remote skills support in app state and UI.
- [ ] Add MCP auth, auth reset, enable/disable, reload, and status details to the UI.
- [ ] Add apps/connectors browsing and invocation.
- [ ] Add plugin discovery and install flows where upstream supports them.
- [ ] Add richer account management for API key and other auth modes alongside ChatGPT-managed login.

### Phase 4: Advanced Parity

- [ ] Add realtime conversation controls.
- [ ] Add dedicated review flows if OrbitDock wants to expose review as a first-class action.
- [ ] Add thread archive, unarchive, metadata update, and loaded-thread management.
- [ ] Add feedback upload and any product-facing support flows that depend on it.
- [ ] Add external agent config detect/import if that fits OrbitDock's product direction.

## Parity Matrix

### Session Lifecycle and Configuration

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Thread create | `thread/start` with broad config support | Partial | Session creation works for Codex direct sessions. | Current Codex path appears to honor only a narrow subset of fields. | Expand create request handling and connector config mapping. | P0 |
| Session config fields | Model, approval, sandbox, prompts, tools, collaboration settings, config overrides | Partial | Model, approval policy, and sandbox mode are wired. | `system_prompt`, appended prompt, tool allow/deny, and other Codex-specific fields are not carried through meaningfully. | Add a richer Codex create payload and connector config builder. | P0 |
| Resume | `thread/resume` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Fork | `thread/fork` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Read without resume | `thread/read` | Partial | OrbitDock can resume and manage session state. | I did not verify a clean read-only thread inspection surface equivalent to upstream. | Decide if OrbitDock needs it as a first-class operation. | P2 |
| List threads | `thread/list` | Partial | OrbitDock has session browsing and persistence. | Upstream thread log semantics and archive state are broader. | Audit list behavior against app-server expectations. | P2 |
| Loaded threads | `thread/loaded/list` | Missing | No clear OrbitDock equivalent found. | Missing management view into in-memory loaded sessions. | Add a server API if needed for debugging and power-user tooling. | P2 |
| Archive | `thread/archive` | Missing | Not found. | Missing archive lifecycle. | Add archive and restore flows if thread lifecycle parity matters. | P2 |
| Unarchive | `thread/unarchive` | Missing | Not found. | Missing archive lifecycle. | Add archive and restore flows if thread lifecycle parity matters. | P2 |
| Unsubscribe | Thread subscription management | Missing | Not found as a clear app-server equivalent. | OrbitDock session streaming appears more implicit. | Decide if explicit subscription management is needed. | P3 |
| Metadata update | `thread/metadata/update` | Missing | Rename exists. | General metadata update support not found. | Add a broader metadata mutation API if useful. | P2 |
| Rename | `thread/name/set` style support | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Compact | `thread/compact/start` | Partial | Compact exists. | Need to confirm parity of options and event model with upstream. | Audit details and close any gaps later. | P2 |
| Rollback | `thread/rollback` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Background terminal cleanup | `backgroundTerminals/clean` | Missing | Not found. | Missing parity for background terminal management. | Add if OrbitDock exposes background terminals in direct sessions. | P3 |

### Turn Execution and Per-Turn Overrides

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Turn start | `turn/start` | Partial | OrbitDock can send messages and start work. | Current send path is narrower than upstream turn config. | Expand the message request model. | P0 |
| Input items | Text, images, local images, mentions | Partial | Text, images, mentions, and skills are supported. | Need to verify exact parity for all upstream input item forms and future item types. | Align request payload structure with upstream. | P1 |
| Model override | Per-turn model override | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Effort override | Per-turn reasoning effort | Done | Supported. | None called out in this audit. | Keep. | P2 |
| CWD override | Per-turn `cwd` | Missing | Not found in the send-message surface. | Missing turn-level working directory override. | Add to protocol, connector, and composer UI. | P0 |
| Approval override | Per-turn approval policy | Missing | Session-level autonomy exists. | Missing turn-level approval override. | Add to send-message and advanced turn controls. | P1 |
| Sandbox override | Per-turn sandbox policy | Missing | Session-level sandbox mode exists. | Missing turn-level sandbox override. | Add to send-message and advanced turn controls. | P0 |
| Network access | Per-turn network setting | Missing | Workspace-write behavior appears hardcoded in places. | Missing explicit network policy control. | Add network access as part of sandbox policy. | P0 |
| Summary mode | Per-turn summary setting | Missing | Not found. | Missing parity for summary override. | Add once protocol shape is expanded. | P1 |
| Personality | Per-turn personality | Missing | Not found. | Missing a user-visible and protocol-level personality surface. | Add support end to end. | P0 |
| Output schema | Per-turn `outputSchema` | Missing | `final_output_json_schema` appears unset. | Missing structured-output parity. | Add protocol, connector mapping, and UI affordance. | P1 |
| Steer turn | `turn/steer` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Interrupt turn | `turn/interrupt` | Done | Supported. | None called out in this audit. | Keep. | P2 |

### Approvals and Requests

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Command approvals | Command exec approval requests | Partial | Basic approval and denial flows exist. | Decision space appears simplified compared with upstream. | Carry richer decision metadata through the protocol. | P0 |
| Patch approvals | File change approval requests | Partial | Basic patch approval flow exists. | Need parity for all upstream request shapes and decision types. | Align with upstream approval contracts. | P0 |
| Question requests | `requestUserInput` style flows | Partial | Connector already handles some question-style approvals and elicitations. | UI and protocol may still flatten these too aggressively. | Treat request-user-input as a first-class interaction type. | P1 |
| MCP elicitation | MCP server user input requests | Partial | Some support exists in the connector. | Limited user-facing management in the app. | Surface in the UI as an actionable prompt flow. | P1 |
| Rule amendments | Session or persistent approval amendments | Partial | Some session-wide approval behavior exists. | Richer upstream rule and decision semantics are not fully represented. | Expand approval models and UI. | P1 |

### Models, Collaboration Modes, and Feature Metadata

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Model list | `model/list` | Partial | OrbitDock lists models. | Current model metadata is thinner than upstream. | Expand protocol types and UI usage. | P0 |
| Model metadata | Hidden state, upgrade info, defaults, modalities, personality support | Missing | Only a reduced model shape is exposed. | Missing data prevents a richer model picker and capability-aware UI. | Expand server protocol and picker UI. | P0 |
| Collaboration modes | `collaborationMode/list` | Partial | OrbitDock exposes two hardcoded modes. | Missing server-driven dynamic mode list. | Make collaboration modes fully data-driven. | P0 |
| Experimental features | `experimentalFeature/list` | Missing | Not found. | Missing visibility into feature flags and gated behavior. | Add if OrbitDock wants feature parity and debugging parity. | P2 |
| Feature flags | `codex-core` feature registry | Runtime-only | Many runtime features may already exist under the hood. | OrbitDock does not expose them as a coherent product surface. | Audit which feature flags should become UI or config options. | P1 |

### Authentication and Account Management

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Account read | `account/read` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| ChatGPT login | `account/login/start` with `chatgpt` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| API key login | `account/login/start` with `apiKey` | Missing | Not found in OrbitDock auth flows. | Missing auth parity for API-key-backed Codex use. | Add server and UI support. | P0 |
| External token auth | `chatgptAuthTokens` experimental flow | Missing | Not found. | Missing parity for host-supplied token auth. | Add only if OrbitDock needs this integration style. | P2 |
| Login cancel | `account/login/cancel` | Partial | Cancel exists for the ChatGPT flow. | Need parity across all auth flows once more auth types exist. | Generalize cancel handling. | P2 |
| Logout | `account/logout` | Done | Supported. | None called out in this audit. | Keep. | P2 |
| Account updated | `account/updated` | Partial | Some account state updates exist. | Need to verify all auth-mode transitions and capability updates are surfaced. | Audit once auth modes expand. | P2 |
| Rate limits | `account/rateLimits/read` and updates | Done | Supported. | None called out in this audit. | Keep. | P2 |

### Config API and Effective Settings

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Effective config read | `config/read` | Missing | Not found. | Missing way to inspect effective Codex config. | Add to server and settings UI. | P0 |
| Single config write | `config/value/write` | Missing | Not found. | Missing granular config mutation. | Add API and mutation UX. | P1 |
| Batch config write | `config/batchWrite` | Missing | Not found. | Missing efficient settings update path. | Add after single-key write support. | P1 |
| Config requirements | `configRequirements/read` | Missing | Not found. | Missing way to explain what config is required or unsupported. | Add to support advanced settings UI. | P1 |
| Config schema coverage | Profiles, providers, permissions, web search, memories, apps, plugins, notify, projects, features | Missing | OrbitDock only appears to expose a narrow subset. | Large parity gap against upstream config schema. | Build a typed OrbitDock view of Codex config. | P0 |

### Skills

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Local skills list | `skills/list` | Partial | OrbitDock shows enabled local skills. | Need to verify parity for full metadata and multi-cwd support. | Audit after remote skills work lands. | P2 |
| Remote skills list | `skills/remote/list` | Partial | Client transport methods appear to exist. | App state and UI wiring appear incomplete. | Finish event handling and UI. | P1 |
| Remote skill export/download | `skills/remote/export` | Partial | Some download plumbing exists. | No full user-facing workflow found. | Add browse, inspect, download, and enable UX. | P1 |
| Skills changed events | `skills/changed` | Partial | Some local skills refresh behavior exists. | Need parity for change propagation. | Audit after skill management UI expands. | P2 |
| Skills config write | `skills/config/write` | Missing | Not found. | Missing direct skill config editing. | Add once remote and local skill management is coherent. | P2 |
| Extra roots per cwd | `perCwdExtraUserRoots` style support | Missing | Not found. | Missing finer-grained skill scoping. | Add only if needed by advanced users. | P3 |

### MCP Servers and Tools

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| MCP status list | `mcpServerStatus/list` style visibility | Partial | OrbitDock shows server status and tool counts. | Good start, but not a full management surface. | Keep and expand. | P1 |
| MCP reload | `config/mcpServer/reload` | Partial | Refresh exists in the UI. | Need to verify full parity with upstream reload semantics. | Audit and align. | P2 |
| OAuth login | `mcpServer/oauth/login` | Missing | Client methods exist, but I did not find UI wiring. | Missing visible auth workflow. | Add UI and state handling. | P1 |
| OAuth completion | `mcpServer/oauthLogin/completed` | Missing | Not found end to end. | Missing visible completion flow. | Add event handling and success/failure UX. | P1 |
| Clear auth | MCP auth reset/clear | Missing | Client methods exist, but not surfaced. | Missing auth reset controls. | Add UI and state handling. | P1 |
| Enable/disable | Toggle MCP servers | Missing | Not found in the UI. | Missing management controls. | Add server action and UI affordance if upstream supports it. | P1 |
| Tool listing | MCP tools/resources/templates | Partial | OrbitDock can inspect tools and resources. | More management and discoverability work is still needed. | Expand MCP detail views. | P2 |
| Elicitation prompts | MCP user input requests | Partial | Connector support exists. | Needs stronger UI and workflow handling. | Surface as interactive prompts. | P1 |

### Apps, Plugins, and External Integrations

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| App list | `app/list` | Missing | Not found in OrbitDock UI or protocol. | Missing app connector discovery. | Add server API and browse UI. | P1 |
| App updates | `app/list/updated` | Missing | Not found. | Missing live app inventory updates. | Add after app listing exists. | P2 |
| App mentions | `app://...` mention support | Partial | OrbitDock supports mentions generally. | No clear app-specific discovery or insertion flow. | Add app picker and mention insertion UX. | P1 |
| Plugin install | `plugin/install` | Missing | Not found. | Missing plugin parity. | Add if OrbitDock wants full host-app scope. | P1 |
| External agent config detect | `externalAgentConfig/detect` | Missing | Not found. | Missing import helpers for external setups. | Add if product direction supports it. | P3 |
| External agent config import | `externalAgentConfig/import` | Missing | Not found. | Missing import helpers for external setups. | Add if product direction supports it. | P3 |

### Realtime, Review, and Secondary Workflows

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Realtime session start | `thread/realtime/start` | Missing | Connector appears to translate some realtime events. | No clear user-facing control surface to start realtime conversations. | Add protocol and UI support. | P1 |
| Realtime audio append | `appendAudio` | Missing | Not found. | Missing voice/audio parity. | Add only if OrbitDock wants true realtime/voice support. | P2 |
| Realtime text append | `appendText` | Missing | Not found. | Missing interactive realtime text feed control. | Add if realtime lands. | P2 |
| Realtime stop | `stop` | Missing | Not found. | Missing lifecycle control. | Add if realtime lands. | P2 |
| Review start | `review/start` | Partial | Some review-style events are already handled. | No obvious first-class review workflow in the UI. | Decide whether review should be a dedicated product feature. | P2 |
| Feedback upload | `feedback/upload` | Missing | Not found. | Missing parity for support/report flows. | Add if useful for debugging or issue reporting. | P3 |

### Built-In Tools and Runtime Features

| Area | Upstream capability | OrbitDock status | What OrbitDock has today | Gap | Recommended action | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Core built-in tools | Shell, read/write, apply patch, grep, list dir, request user input, JS REPL, web search, images, artifacts, agent tools, MCP resources | Runtime-only | OrbitDock likely inherits many of these through `codex-core`. | OrbitDock does not expose them as a clear capability matrix or settings surface. | Audit and document which tools are available in direct sessions today. | P1 |
| Tool allow/deny config | Restrict or permit tools | Partial | User-facing create flow carries tool fields in some places, but Codex path does not appear to honor them fully. | Missing reliable config-to-runtime mapping. | Fix server-side create and config mutation handling. | P0 |
| Dynamic tool invocation visibility | `item/tool/call` and related item flows | Partial | Timeline already shows many work items. | Need to ensure dynamic tools are represented clearly and approved correctly. | Audit once tool config support expands. | P2 |
| Web search config | Upstream config and feature support | Missing | Not found as a user-facing setting. | Missing ability to enable, disable, or explain web search behavior. | Add to config model and advanced settings. | P1 |
| Personality support | Feature-gated upstream capability | Missing | Not exposed today. | Missing a meaningful user-facing behavior control. | Add to session defaults and per-turn overrides. | P0 |
| Memory/config-backed tools | Memories and related config | Missing | Not found. | Missing parity for memory-aware behavior if OrbitDock wants it. | Decide product stance, then implement if desired. | P2 |

### UI Surface Audit

This is the product-level summary of what users can and cannot do today.

| UI surface | Current state | Main gap | Priority |
| --- | --- | --- | --- |
| New Codex Session Sheet | Good basic entry point for path, model, autonomy, endpoint, and worktree. | Missing advanced Codex session settings. | P0 |
| Direct Session Composer | Good for sending messages, attaching files, and using current direct-session affordances. | Missing per-turn override controls and richer action surfaces. | P0 |
| Collaboration Mode Picker | Present, but hardcoded. | Needs server-driven dynamic mode list. | P0 |
| Skills Tab | Local-skill support exists. | Missing remote skills and richer management. | P1 |
| MCP Tab | Status and refresh exist. | Missing auth and control flows. | P1 |
| Account/Auth UI | ChatGPT auth is present. | Missing API key and broader auth parity. | P0 |
| Advanced Settings | Limited Codex-specific visibility. | Missing effective config inspection and editing. | P0 |

## What "Full Feature Parity" Actually Means

OrbitDock does not need to copy every upstream UI choice.

But if the goal is feature parity, OrbitDock should support these outcomes:

- a user can start a Codex session with the same meaningful config choices upstream supports
- a user can override important settings on a single turn without changing the whole session
- a user can authenticate however upstream Codex allows
- a user can manage MCP servers, auth, tools, and prompts inside OrbitDock
- a user can browse and install skills and apps that Codex can use
- a user can understand model capabilities and limitations from the UI
- a user can review, approve, and interrupt work with the same fidelity upstream exposes
- OrbitDock can inspect and mutate effective Codex config without hidden state

If those outcomes are true, OrbitDock will feel like a real Codex host app rather than a partial shell around the runtime.

## Suggested Milestones

These milestones are a practical way to start checking items off.

### Milestone 1: Config and Protocol Parity

Ship the server and protocol changes that make advanced Codex settings possible.

Success looks like this:

- session creation supports prompts, tool allow/deny, collaboration mode, and richer config overrides
- turn start supports cwd, sandbox/network, personality, summary, and output schema
- effective config and config writes are available through the OrbitDock protocol
- model metadata is rich enough for a capability-aware picker

### Milestone 2: Session and Turn UI Parity

Ship the user-facing controls for the new protocol.

Success looks like this:

- new session sheet exposes advanced Codex setup
- composer exposes per-turn advanced controls
- approvals can represent richer decisions cleanly
- collaboration modes are dynamic

### Milestone 3: Integration Parity

Ship the surrounding ecosystem pieces.

Success looks like this:

- remote skills are browseable and installable
- MCP auth and management work fully
- apps/connectors are discoverable and usable
- API-key auth exists alongside ChatGPT auth

### Milestone 4: Advanced Workflow Parity

Ship the edges that make OrbitDock feel complete.

Success looks like this:

- realtime session controls exist
- review is first class if OrbitDock wants it
- archive and metadata flows exist
- advanced config and diagnostics are easy to inspect

## Recommended First Sprint

If I were starting implementation tomorrow, I would begin here:

1. Expand the Codex create payload and connector config builder.
2. Expand the per-turn send-message payload.
3. Add protocol types for richer models, collaboration modes, and config reads.
4. Update the new session sheet and composer to use the new surfaces.
5. Finish remote skills and MCP auth UI once the protocol work is stable.

That order gets OrbitDock from "partial shell" to "credible Codex app" fastest.

## Open Questions

These are worth deciding early because they affect the shape of the implementation.

- Should OrbitDock expose the full upstream config vocabulary, or curate it into a smaller OrbitDock opinionated model?
- Should advanced Codex settings live in the session sheet, a separate settings panel, or both?
- Should per-turn overrides be inline in the composer or tucked behind an advanced popover?
- Should apps and plugins be first-class product features, or implementation details surfaced only when discovered?
- Should API-key auth be treated as a primary path for OrbitDock, or secondary to ChatGPT-managed auth?
- Does OrbitDock want full realtime and voice parity, or just text-first direct-session parity?

## Definition of Done for This Audit

This doc will have done its job when:

- every row above has an owner or a conscious "not planned" decision
- completed rows are updated in place instead of tracked somewhere else
- new upstream Codex surface area gets added here before implementation starts
- the doc stays short enough to scan, but concrete enough to build from
