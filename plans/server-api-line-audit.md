# Server/API Line Audit

Date: 2026-04-26

Scope: read-only macro `wc -l` audit for `orbitdock-server`, with the native `Services/Server` API edge included for comparison.

## Snapshot

- `orbitdock-server` has 142,533 counted lines across 441 tracked files from `rg --files`.
- Rust source under `orbitdock-server` has 122,855 lines across 370 `.rs` files.
- Focused server/API areas have 68,140 Rust lines across 231 files.
- Native `Services/Server` has 14,588 Swift lines across 64 files.

## Post-Phase-1 Refresh

Reference commit: `94ea8c58` (`♻️ Extract Rust tests into sibling modules`)

- Rust source under `orbitdock-server/crates` now has 122,802 lines across 489 `.rs` files.
- Dedicated Rust test files now account for 128 files under `orbitdock-server/crates`.
- Production-only Rust under `orbitdock-server/crates` now has 97,663 lines across 361 non-test `.rs` files.
- Production-only Rust under `orbitdock-server/crates/server/src` now has 64,817 lines.

What changed:

- This is primarily a structure shift, not a deletion pass. Production files lost inline test tails, and those tests moved into sibling `tests.rs` or `*_tests.rs` modules.
- The post-Phase-1 hotspot list is therefore much more useful for deletion planning because it now reflects production code instead of mixed production-plus-test mass.

Top production-only reductions after Phase 1:

| File | Baseline | Post-Phase-1 | Delta |
| --- | ---: | ---: | ---: |
| `orbitdock-server/crates/connector-core/src/transition.rs` | 4412 | 2858 | -1554 |
| `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` | 1456 | 968 | -488 |
| `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` | 1301 | 813 | -488 |
| `orbitdock-server/crates/connector-codex/src/app_server.rs` | 3090 | 2635 | -455 |
| `orbitdock-server/crates/connector-claude/src/lib.rs` | 3560 | 3157 | -403 |
| `orbitdock-server/crates/protocol/src/types.rs` | 2911 | 2643 | -268 |
| `orbitdock-server/crates/server/src/transport/http/session_actions.rs` | 826 | 631 | -195 |

Current top production-only Rust files:

| Lines | File |
| ---: | --- |
| 3157 | `orbitdock-server/crates/connector-claude/src/lib.rs` |
| 2858 | `orbitdock-server/crates/connector-core/src/transition.rs` |
| 2643 | `orbitdock-server/crates/protocol/src/types.rs` |
| 2635 | `orbitdock-server/crates/connector-codex/src/app_server.rs` |
| 2198 | `orbitdock-server/crates/cli/src/commands/session.rs` |
| 1797 | `orbitdock-server/crates/connector-codex/src/rollout_parser.rs` |
| 1617 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_display.rs` |
| 1371 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 1230 | `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs` |
| 1218 | `orbitdock-server/crates/cli/src/cli.rs` |
| 1150 | `orbitdock-server/crates/cli/src/dev_console.rs` |
| 1066 | `orbitdock-server/crates/connector-codex/src/config.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 968 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 952 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 925 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 862 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 833 | `orbitdock-server/crates/server/src/infrastructure/github/client.rs` |
| 832 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 813 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 813 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` |
| 808 | `orbitdock-server/crates/server/src/runtime/session_queries.rs` |
| 788 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 787 | `orbitdock-server/crates/connector-codex/src/session.rs` |

Current top production-only server crate files:

| Lines | File |
| ---: | --- |
| 1371 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 968 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 952 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 925 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 862 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 833 | `orbitdock-server/crates/server/src/infrastructure/github/client.rs` |
| 832 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 813 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 813 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` |
| 808 | `orbitdock-server/crates/server/src/runtime/session_queries.rs` |
| 788 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 725 | `orbitdock-server/crates/server/src/admin/setup.rs` |
| 710 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 694 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 691 | `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs` |
| 686 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/startup_recovery.rs` |
| 683 | `orbitdock-server/crates/server/src/admin/install_service.rs` |
| 631 | `orbitdock-server/crates/server/src/transport/http/session_actions.rs` |

## Post-Wave-2 Refresh

Reference commits:

- `84b327c5` (`♻️ Split protocol session types`)
- `04760925` (`♻️ Split runtime session query and restore paths`)
- `9d8fb3f7` (`♻️ Split runtime session command dispatch`)
- `f1765ded` (`♻️ Split persistence session read helpers`)
- `6fb0e350` (`♻️ Split transport session action handlers`)
- `ba633b99` (`♻️ Split CLI session command surfaces`)

Current snapshot:

- `orbitdock-server` now has 592 tracked files from `rg --files`.
- Rust source under `orbitdock-server/crates` now has 120,540 lines across 521 `.rs` files.
- Production-only Rust under `orbitdock-server/crates` now has 95,869 lines across 393 non-test `.rs` files.
- Production-only Rust under `orbitdock-server/crates/server/src` now has 63,588 lines.
- Native `Services/Server` now has 14,564 Swift lines.

What changed:

- File count went up because the plan deliberately split giant roots into smaller responsibility-aligned modules.
- Production-only Rust still dropped by 1,794 lines from the Post-Phase-1 snapshot, which means this was not just file shuffling.
- The biggest wins came from collapsing god files into facades and moving the real logic into narrow sibling modules.

Selected hotspot reductions since Post-Phase-1:

| File | Post-Phase-1 | Post-Wave-2 | Delta |
| --- | ---: | ---: | ---: |
| `orbitdock-server/crates/connector-codex/src/app_server.rs` | 2635 | 504 | -2131 |
| `orbitdock-server/crates/connector-claude/src/lib.rs` | 3157 | 17 | -3140 |
| `orbitdock-server/crates/connector-core/src/transition.rs` | 2858 | 1738 | -1120 |
| `orbitdock-server/crates/protocol/src/types.rs` | 2643 | 1652 | -991 |
| `orbitdock-server/crates/cli/src/commands/session.rs` | 2198 | 160 | -2038 |
| `orbitdock-server/crates/server/src/runtime/session_queries.rs` | 808 | 18 | -790 |
| `orbitdock-server/crates/server/src/runtime/restored_sessions.rs` | 624 | 20 | -604 |
| `orbitdock-server/crates/server/src/transport/http/session_actions.rs` | 631 | 22 | -609 |
| `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs` | 489 | 326 | -163 |
| `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` | 968 | 691 | -277 |

Current top production-only Rust files:

| Lines | File |
| ---: | --- |
| 1797 | `orbitdock-server/crates/connector-codex/src/rollout_parser.rs` |
| 1738 | `orbitdock-server/crates/connector-core/src/transition.rs` |
| 1652 | `orbitdock-server/crates/protocol/src/types.rs` |
| 1622 | `orbitdock-server/crates/connector-claude/src/stdout.rs` |
| 1617 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_display.rs` |
| 1334 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 1230 | `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs` |
| 1195 | `orbitdock-server/crates/cli/src/cli.rs` |
| 1150 | `orbitdock-server/crates/cli/src/dev_console.rs` |
| 1139 | `orbitdock-server/crates/connector-codex/src/app_server/item_mapping.rs` |
| 1102 | `orbitdock-server/crates/connector-core/src/approval_preview.rs` |
| 1066 | `orbitdock-server/crates/connector-codex/src/config.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 980 | `orbitdock-server/crates/protocol/src/types/session.rs` |
| 887 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 862 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 833 | `orbitdock-server/crates/server/src/infrastructure/github/client.rs` |
| 829 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 813 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 805 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |

Current top production-only server crate files:

| Lines | File |
| ---: | --- |
| 1334 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 887 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 862 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 833 | `orbitdock-server/crates/server/src/infrastructure/github/client.rs` |
| 829 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 813 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 805 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 786 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 782 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` |
| 725 | `orbitdock-server/crates/server/src/admin/setup.rs` |
| 706 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 694 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 691 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 691 | `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs` |
| 683 | `orbitdock-server/crates/server/src/admin/install_service.rs` |
| 631 | `orbitdock-server/crates/server/src/admin/doctor.rs` |
| 621 | `orbitdock-server/crates/server/src/runtime/session_takeover.rs` |
| 599 | `orbitdock-server/crates/server/src/connectors/claude_session.rs` |

## Post-Phase-24 Reevaluation

Reference context:

- Catch-all refactor closeout: `1451ea6b` (`📝 Close out the server catch-all refactor`)
- Fresh-eyes reevaluation: current tree on `refactor/server-api-plan-execution`

Current snapshot:

- `orbitdock-server` now has 668 tracked files from `rg --files`.
- Rust source under `orbitdock-server/crates` now has 597 `.rs` files.
- Production-only Rust under `orbitdock-server/crates` now has 94,734 lines across 468 non-test `.rs` files.
- Production-only Rust under `orbitdock-server/crates/server/src` now has 63,840 lines across 332 non-test `.rs` files.
- Native `Services/Server` now has 14,571 Swift lines across 64 files.

What changed:

- Production-only Rust dropped again from the prior 95,869-line snapshot, but the more important change is qualitative: the remaining size is now concentrated in accepted spines and contract seams instead of broad accidental junk drawers.
- The fresh read is that file count is no longer the problem by itself. The remaining debt is mostly:
  - duplicate authority or recovery/materialization seams
  - protocol typing escape hatches
  - WebSocket mutation drift versus HTTP authority
  - native mirror/parity sprawl

Current top production-only Rust files:

| Lines | File |
| ---: | --- |
| 1132 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 938 | `orbitdock-server/crates/protocol/src/types/session.rs` |
| 931 | `orbitdock-server/crates/connector-core/src/transition.rs` |
| 877 | `orbitdock-server/crates/cli/src/cli/shared.rs` |
| 787 | `orbitdock-server/crates/connector-codex/src/session.rs` |
| 767 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 757 | `orbitdock-server/crates/connector-codex/src/session_ops.rs` |
| 725 | `orbitdock-server/crates/server/src/admin/setup.rs` |
| 720 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 706 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 702 | `orbitdock-server/crates/cli/src/commands/session/live.rs` |
| 699 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 683 | `orbitdock-server/crates/server/src/admin/install_service.rs` |
| 673 | `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs` |
| 668 | `orbitdock-server/crates/connector-claude/src/connector.rs` |
| 651 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 644 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 639 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 631 | `orbitdock-server/crates/server/src/admin/doctor.rs` |
| 616 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |

Current top production-only server crate files:

| Lines | File |
| ---: | --- |
| 1132 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 767 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 725 | `orbitdock-server/crates/server/src/admin/setup.rs` |
| 720 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 706 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 699 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 683 | `orbitdock-server/crates/server/src/admin/install_service.rs` |
| 651 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 644 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 639 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 631 | `orbitdock-server/crates/server/src/admin/doctor.rs` |
| 616 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 599 | `orbitdock-server/crates/server/src/connectors/claude_session.rs` |
| 590 | `orbitdock-server/crates/server/src/domain/conversation_semantics/shared.rs` |
| 589 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 581 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/daytona.rs` |
| 580 | `orbitdock-server/crates/server/src/runtime/mission_orchestrator.rs` |
| 579 | `orbitdock-server/crates/server/src/runtime/session_takeover.rs` |
| 578 | `orbitdock-server/crates/server/src/domain/mission_control/config_model.rs` |
| 574 | `orbitdock-server/crates/server/src/runtime/mission_reconciliation.rs` |

Current top native API edge files:

| Lines | File |
| ---: | --- |
| 1579 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerSessionContracts.swift` |
| 1439 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerConversationContracts.swift` |
| 1237 | `OrbitDockNative/OrbitDock/Services/Server/ServerConnection.swift` |
| 668 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerApprovalContracts.swift` |
| 667 | `OrbitDockNative/OrbitDock/Services/Server/API/SessionsClient.swift` |
| 638 | `OrbitDockNative/OrbitDock/Services/Server/ServerSessionAPI.swift` |
| 557 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpointStore.swift` |
| 555 | `OrbitDockNative/OrbitDock/Services/Server/ServerRuntimeRegistry.swift` |
| 439 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerCapabilitiesContracts.swift` |
| 432 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerTypedPayloads.swift` |

Fresh classification read:

- `leave alone`
  - The session core spine is real now: `state.rs`, `session.rs`, `session_actor.rs`, `writer.rs`, `session_accounting_writes.rs`.
  - The HTTP sessions surface is mostly in the right place.
  - The native transport split is mostly aligned with the REST bootstrap + WS follow-up contract.
- `optional polish`
  - `session_writes.rs`, `session_queries/projection.rs`, `router.rs`, `http/mod.rs`, `capabilities/runtime.rs`, `admin/setup.rs`, `admin/install_service.rs`, `protocol/types/session.rs`, and a few still-large but coherent connector/protocol modules.
- `delete or drift-fix candidates`
  - `protocol/src/provider_normalization/shared.rs` looks unused outside its own export path and should be verified for removal.
  - `server/src/runtime/session_command_persistence.rs` preserves a parallel persistence translation lane.
  - `server/src/transport/http/sessions_summary.rs` and `server/src/transport/websocket/server_info.rs` are tiny wrappers/shims worth collapsing.
  - `cli/src/commands/session/http.rs` still uses the stale fork route (`/api/sessions/{id}/fork`) while the router exposes `/api/sessions/{id}/lifecycle/fork`.
  - Native likely has two dead/duplicate areas worth verifying:
    - `ClientToServerMessage.init(from:)`
    - `ConversationClient.fetchSessionInstructions(...)`
- `redesign candidates`
  - Runtime authority seams: `session_reads/startup_recovery.rs`, `session_runtime_helpers.rs`, `session_takeover.rs`, `session_resume.rs`, `session_queries/detail.rs`, hook materialization paths.
  - Protocol typing seams: `conversation_contracts/tool_payloads.rs`, `types/approvals.rs`, `domain_events/approvals.rs`, `types/session.rs`.
  - Transport convergence seams: CLI live session mutation path plus WS mutation handlers (`messaging.rs`, `session_crud.rs`, `approvals.rs`).
  - Native parity seams: `ServerSessionContracts.swift`, `ServerConversationContracts.swift`, `ServerToClientMessage+Decoding.swift`.

Best next implementation threads after the catch-all refactor:

1. Low-risk delete and drift fixes.
2. HTTP versus WebSocket mutation convergence.
3. Runtime recovery/materialization authority convergence.
4. Protocol and native contract narrowing.

## Baseline Refactor Pressure Read

The section below is the original pre-Phase-1 hotspot read. Keep it for comparison against the refreshed production-only numbers above.

Highest pressure files by size and boundary mixing:

| Priority | File | Lines | Why it stands out |
| ---: | --- | ---: | --- |
| 1 | `orbitdock-server/crates/connector-claude/src/lib.rs` | 3560 | Claude connector create/control/event-loop/message mapping all live together. The connector constructor starts around line 748 and the event loop/message handlers run through the 2700s. |
| 2 | `orbitdock-server/crates/connector-core/src/transition.rs` | 4412 | Transition reducer, approval preview/risk rendering, shell parsing, diff preview, and tests share one file. The reducer starts around line 636; approval preview starts around line 1739; tests start around line 2857. |
| 3 | `orbitdock-server/crates/connector-codex/src/app_server.rs` | 3090 | RPC client, app-server lifecycle, notification/request mapping, tool-row mapping, usage mapping, and tests are all coupled. Mapping begins around line 642; tests start around line 2634. |
| 4 | `orbitdock-server/crates/protocol/src/types.rs` | 2911 | General protocol surface: provider config, sessions, dashboard, usage, worktrees, missions, permissions, and tests. Session summary begins around line 660; usage types around line 2041. |
| 5 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` | 1456 | Actor command handling, persistence op execution, delta broadcasting, connector event upgrades, and tests are concentrated in one path. Main handler starts around line 367. |
| 6 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` | 1301 | Query/read logic, repair/backfill, ledger recompute, helper schema, and tests live together. Tests begin around line 812. |
| 7 | `orbitdock-server/crates/server/src/transport/http/session_actions.rs` | 826 | Many unrelated session-control endpoints share request/response DTOs, image upload/read, messaging, steer, shell, compact, undo, rollback, stop, and rewind actions. Endpoint handlers start around line 249. |
| 8 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs` | 489 | Not huge, but semantically hot. Create request parsing, Codex selection normalization, provider branching, worktree handling, session creation response shaping, and tests sit together. `create_session` starts around line 133. |

## Rust Bucket Totals

| Lines | Files | Bucket |
| ---: | ---: | --- |
| 22740 | 61 | `infrastructure` |
| 17909 | 58 | `runtime` |
| 16702 | 91 | `transport` |
| 12466 | 27 | `protocol` |
| 12144 | 38 | `domain` |
| 9731 | 13 | `orbitdock-server/crates/connector-codex` |
| 9217 | 28 | `cli` |
| 6024 | 20 | `connectors` |
| 5315 | 14 | `admin` |
| 4742 | 5 | `orbitdock-server/crates/connector-core` |
| 3979 | 2 | `orbitdock-server/crates/connector-claude` |
| 1008 | 10 | `support` |
| 809 | 1 | `app` |
| 58 | 1 | `root` |
| 11 | 1 | `other` |

## Top Focused Server/API Files

| Lines | File |
| ---: | --- |
| 2911 | `orbitdock-server/crates/protocol/src/types.rs` |
| 1908 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_display.rs` |
| 1756 | `orbitdock-server/crates/server/src/infrastructure/persistence/tests.rs` |
| 1695 | `orbitdock-server/crates/protocol/src/client.rs` |
| 1525 | `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs` |
| 1456 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 1301 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` |
| 1271 | `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs` |
| 1197 | `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs` |
| 1147 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 1048 | `orbitdock-server/crates/server/src/runtime/session_mutations.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 1002 | `orbitdock-server/crates/protocol/src/server.rs` |
| 964 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 962 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 925 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 916 | `orbitdock-server/crates/server/src/runtime/session_queries.rs` |
| 843 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 838 | `orbitdock-server/crates/protocol/src/provider_normalization/codex.rs` |
| 826 | `orbitdock-server/crates/server/src/transport/http/session_actions.rs` |
| 752 | `orbitdock-server/crates/server/src/runtime/session_registry.rs` |
| 711 | `orbitdock-server/crates/server/src/runtime/session_takeover.rs` |
| 703 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 698 | `orbitdock-server/crates/server/src/runtime/mission_reconciliation.rs` |
| 688 | `orbitdock-server/crates/server/src/runtime/mission_orchestrator.rs` |
| 686 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/startup_recovery.rs` |
| 685 | `orbitdock-server/crates/server/src/transport/http/capabilities/tests.rs` |
| 683 | `orbitdock-server/crates/server/src/runtime/session_actor.rs` |
| 683 | `orbitdock-server/crates/server/src/transport/http/sessions/tests.rs` |
| 655 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/daytona.rs` |
| 643 | `orbitdock-server/crates/server/src/transport/http/server_meta/tests.rs` |
| 639 | `orbitdock-server/crates/server/src/runtime/session_resume.rs` |
| 624 | `orbitdock-server/crates/server/src/runtime/restored_sessions.rs` |
| 599 | `orbitdock-server/crates/server/src/connectors/claude_session.rs` |
| 598 | `orbitdock-server/crates/server/src/runtime/session_creation.rs` |
| 562 | `orbitdock-server/crates/protocol/src/provider_normalization/claude.rs` |
| 533 | `orbitdock-server/crates/server/src/infrastructure/persistence/commands.rs` |
| 526 | `orbitdock-server/crates/protocol/src/domain_events/tooling.rs` |
| 516 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_types.rs` |
| 511 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_tests.rs` |
| 510 | `orbitdock-server/crates/server/src/infrastructure/persistence/workspace_sync.rs` |
| 501 | `orbitdock-server/crates/server/src/transport/http/router.rs` |
| 493 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_from_persist.rs` |
| 489 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs` |
| 488 | `orbitdock-server/crates/server/src/runtime/codex_config/resolver.rs` |
| 474 | `orbitdock-server/crates/server/src/transport/http/mission_control/issue_reports.rs` |
| 469 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_writer.rs` |
| 450 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_to_persist.rs` |
| 446 | `orbitdock-server/crates/server/src/connectors/claude_hooks/handler.rs` |
| 428 | `orbitdock-server/crates/server/src/transport/websocket/connection.rs` |
| 424 | `orbitdock-server/crates/server/src/connectors/claude_hooks/status_events.rs` |
| 412 | `orbitdock-server/crates/server/src/connectors/claude_hooks/tool_events.rs` |
| 391 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/session_hydration.rs` |
| 380 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/local.rs` |
| 378 | `orbitdock-server/crates/server/src/infrastructure/persistence/approvals.rs` |
| 374 | `orbitdock-server/crates/server/src/infrastructure/persistence/connector_writes.rs` |
| 374 | `orbitdock-server/crates/server/src/transport/websocket/handlers/messaging.rs` |
| 358 | `orbitdock-server/crates/server/src/transport/http/update.rs` |
| 357 | `orbitdock-server/crates/server/src/transport/http/mission_control/tracker_keys.rs` |
| 350 | `orbitdock-server/crates/server/src/connectors/jsonl_tailer.rs` |
| 344 | `orbitdock-server/crates/server/src/transport/http/shell.rs` |
| 337 | `orbitdock-server/crates/server/src/transport/http/worktrees.rs` |
| 336 | `orbitdock-server/crates/server/src/transport/websocket/handlers/shell.rs` |
| 317 | `orbitdock-server/crates/server/src/infrastructure/persistence/mission_writes.rs` |
| 300 | `orbitdock-server/crates/server/src/transport/http/mission_control/common.rs` |
| 295 | `orbitdock-server/crates/server/src/connectors/claude_hooks/approval.rs` |
| 291 | `orbitdock-server/crates/server/src/runtime/approval_dispatch.rs` |
| 288 | `orbitdock-server/crates/server/src/transport/http/sync.rs` |
| 286 | `orbitdock-server/crates/server/src/connectors/subagent_parser.rs` |
| 286 | `orbitdock-server/crates/server/src/transport/websocket/handlers/subscribe.rs` |
| 283 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/fork.rs` |
| 281 | `orbitdock-server/crates/server/src/runtime/session_registry/ownership.rs` |
| 281 | `orbitdock-server/crates/server/src/transport/http/approvals.rs` |
| 277 | `orbitdock-server/crates/server/src/runtime/session_fork_runtime.rs` |
| 277 | `orbitdock-server/crates/server/src/transport/http/sessions/usage.rs` |
| 271 | `orbitdock-server/crates/server/src/transport/http/connector_actions.rs` |
| 270 | `orbitdock-server/crates/server/src/runtime/codex_config_types.rs` |
| 269 | `orbitdock-server/crates/server/src/transport/http/sessions/row_content.rs` |
| 264 | `orbitdock-server/crates/server/src/transport/http/mission_control/files.rs` |
| 258 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_materialization.rs` |

## Native API Edge Counts

| Lines | File |
| ---: | --- |
| 1549 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerSessionContracts.swift` |
| 1439 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerConversationContracts.swift` |
| 1255 | `OrbitDockNative/OrbitDock/Services/Server/ServerConnection.swift` |
| 695 | `OrbitDockNative/OrbitDock/Services/Server/API/SessionsClient.swift` |
| 668 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerApprovalContracts.swift` |
| 638 | `OrbitDockNative/OrbitDock/Services/Server/ServerSessionAPI.swift` |
| 557 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpointStore.swift` |
| 555 | `OrbitDockNative/OrbitDock/Services/Server/ServerRuntimeRegistry.swift` |
| 439 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerCapabilitiesContracts.swift` |
| 432 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerTypedPayloads.swift` |
| 425 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerToClientMessage+Decoding.swift` |
| 382 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerToClientMessage+Encoding.swift` |
| 282 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpointRuntime.swift` |
| 266 | `OrbitDockNative/OrbitDock/Services/Server/API/ConversationClient.swift` |
| 250 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerUsageContracts.swift` |
| 248 | `OrbitDockNative/OrbitDock/Services/Server/API/MissionsClient.swift` |
| 244 | `OrbitDockNative/OrbitDock/Services/Server/API/ApprovalsClient.swift` |
| 244 | `OrbitDockNative/OrbitDock/Services/Server/EndpointTransport.swift` |
| 229 | `OrbitDockNative/OrbitDock/Services/Server/API/ServerHTTPClient.swift` |
| 219 | `OrbitDockNative/OrbitDock/Services/Server/ServerSessionTransport.swift` |
| 179 | `OrbitDockNative/OrbitDock/Services/Server/ServerTypeAdapters.swift` |
| 170 | `OrbitDockNative/OrbitDock/Services/Server/ServerRuntime.swift` |
| 167 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ClientToServerMessage.swift` |
| 152 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerAuthContracts.swift` |
| 150 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerSharedTypes.swift` |
| 148 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerToClientEventContracts.swift` |
| 143 | `OrbitDockNative/OrbitDock/Services/Server/API/CapabilitiesClient.swift` |
| 140 | `OrbitDockNative/OrbitDock/Services/Server/ServerRoleCoordinator.swift` |
| 138 | `OrbitDockNative/OrbitDock/Services/Server/ConnectionFileLogger.swift` |
| 132 | `OrbitDockNative/OrbitDock/Services/Server/API/UsageClient.swift` |
| 116 | `OrbitDockNative/OrbitDock/Services/Server/NetworkFileLogger.swift` |
| 105 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerToClientMessageCoding.swift` |
| 104 | `OrbitDockNative/OrbitDock/Services/Server/API/SessionsSummaryClient.swift` |
| 96 | `OrbitDockNative/OrbitDock/Services/Server/API/HTTPTransportTypes.swift` |
| 88 | `OrbitDockNative/OrbitDock/Services/Server/API/ServerAPICommon.swift` |
| 87 | `OrbitDockNative/OrbitDock/Services/Server/RootSessionSnapshotLoader.swift` |
| 86 | `OrbitDockNative/OrbitDock/Services/Server/API/SessionControlsClient.swift` |
| 84 | `OrbitDockNative/OrbitDock/Services/Server/ConnectionCircuitBreaker.swift` |
| 81 | `OrbitDockNative/OrbitDock/Services/Server/CodexAccountService.swift` |
| 80 | `OrbitDockNative/OrbitDock/Services/Server/API/ServerClients.swift` |
| 79 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerUpdateContracts.swift` |
| 77 | `OrbitDockNative/OrbitDock/Services/Server/API/ServerHTTPError.swift` |
| 75 | `OrbitDockNative/OrbitDock/Services/Server/API/WorktreesClient.swift` |
| 73 | `OrbitDockNative/OrbitDock/Services/Server/API/ServerUpdateClient.swift` |
| 72 | `OrbitDockNative/OrbitDock/Services/Server/ServerSessionContext.swift` |
| 71 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerHandshakeContracts.swift` |
| 68 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpointSettings.swift` |
| 62 | `OrbitDockNative/OrbitDock/Services/Server/WorktreeService.swift` |
| 59 | `OrbitDockNative/OrbitDock/Services/Server/API/HTTPRequestBuilder.swift` |
| 58 | `OrbitDockNative/OrbitDock/Services/Server/ServerRuntimeRegistryPlanner.swift` |
| 57 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpointIdentityPlanner.swift` |
| 56 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerWorktreeContracts.swift` |
| 51 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpointSettingsClient.swift` |
| 47 | `OrbitDockNative/OrbitDock/Services/Server/API/SkillsClient.swift` |
| 32 | `OrbitDockNative/OrbitDock/Services/Server/Protocol/TerminalMessages.swift` |
| 31 | `OrbitDockNative/OrbitDock/Services/Server/ServerEndpoint.swift` |
| 27 | `OrbitDockNative/OrbitDock/Services/Server/API/FilesystemClient.swift` |
| 25 | `OrbitDockNative/OrbitDock/Services/Server/API/SessionRuntimeClient.swift` |
| 21 | `OrbitDockNative/OrbitDock/Services/Server/API/ConfigClient.swift` |
| 21 | `OrbitDockNative/OrbitDock/Services/Server/ConnectionStatus.swift` |
| 20 | `OrbitDockNative/OrbitDock/Services/Server/ServerRuntimeReadiness.swift` |
| 18 | `OrbitDockNative/OrbitDock/Services/Server/API/LibraryClient.swift` |
| 17 | `OrbitDockNative/OrbitDock/Services/Server/API/ReviewClient.swift` |
| 9 | `OrbitDockNative/OrbitDock/Services/Server/API/DashboardClient.swift` |

## All Rust Source Counts

| Lines | File |
| ---: | --- |
| 4412 | `orbitdock-server/crates/connector-core/src/transition.rs` |
| 3560 | `orbitdock-server/crates/connector-claude/src/lib.rs` |
| 3090 | `orbitdock-server/crates/connector-codex/src/app_server.rs` |
| 2911 | `orbitdock-server/crates/protocol/src/types.rs` |
| 2451 | `orbitdock-server/crates/cli/src/commands/session.rs` |
| 1908 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_display.rs` |
| 1859 | `orbitdock-server/crates/connector-codex/src/rollout_parser.rs` |
| 1756 | `orbitdock-server/crates/server/src/infrastructure/persistence/tests.rs` |
| 1695 | `orbitdock-server/crates/protocol/src/client.rs` |
| 1573 | `orbitdock-server/crates/cli/src/cli.rs` |
| 1568 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 1525 | `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs` |
| 1469 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 1456 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 1301 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` |
| 1271 | `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs` |
| 1216 | `orbitdock-server/crates/cli/src/dev_console.rs` |
| 1197 | `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs` |
| 1147 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 1127 | `orbitdock-server/crates/connector-codex/src/config.rs` |
| 1048 | `orbitdock-server/crates/server/src/runtime/session_mutations.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 1031 | `orbitdock-server/crates/server/src/infrastructure/github/client.rs` |
| 1002 | `orbitdock-server/crates/protocol/src/server.rs` |
| 964 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 962 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 925 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 916 | `orbitdock-server/crates/server/src/runtime/session_queries.rs` |
| 863 | `orbitdock-server/crates/connector-codex/src/tests.rs` |
| 843 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 841 | `orbitdock-server/crates/server/src/domain/codex_tools.rs` |
| 838 | `orbitdock-server/crates/protocol/src/provider_normalization/codex.rs` |
| 834 | `orbitdock-server/crates/connector-codex/src/session_ops.rs` |
| 826 | `orbitdock-server/crates/server/src/transport/http/session_actions.rs` |
| 811 | `orbitdock-server/crates/server/src/admin/install_service.rs` |
| 809 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 801 | `orbitdock-server/crates/server/src/admin/setup.rs` |
| 800 | `orbitdock-server/crates/server/src/domain/sessions/approval_state.rs` |
| 787 | `orbitdock-server/crates/connector-codex/src/session.rs` |
| 752 | `orbitdock-server/crates/server/src/runtime/session_registry.rs` |
| 739 | `orbitdock-server/crates/server/src/admin/doctor.rs` |
| 711 | `orbitdock-server/crates/server/src/runtime/session_takeover.rs` |
| 709 | `orbitdock-server/crates/server/src/domain/git/repo.rs` |
| 703 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 698 | `orbitdock-server/crates/server/src/runtime/mission_reconciliation.rs` |
| 688 | `orbitdock-server/crates/server/src/runtime/mission_orchestrator.rs` |
| 686 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/startup_recovery.rs` |
| 685 | `orbitdock-server/crates/server/src/transport/http/capabilities/tests.rs` |
| 683 | `orbitdock-server/crates/server/src/runtime/session_actor.rs` |
| 683 | `orbitdock-server/crates/server/src/transport/http/sessions/tests.rs` |
| 677 | `orbitdock-server/crates/server/src/domain/conversation_semantics/shared.rs` |
| 655 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/daytona.rs` |
| 643 | `orbitdock-server/crates/server/src/transport/http/server_meta/tests.rs` |
| 639 | `orbitdock-server/crates/server/src/runtime/session_resume.rs` |
| 624 | `orbitdock-server/crates/server/src/runtime/restored_sessions.rs` |
| 613 | `orbitdock-server/crates/cli/src/commands/mission.rs` |
| 599 | `orbitdock-server/crates/server/src/connectors/claude_session.rs` |
| 598 | `orbitdock-server/crates/server/src/runtime/session_creation.rs` |
| 578 | `orbitdock-server/crates/server/src/domain/mission_control/config_model.rs` |
| 562 | `orbitdock-server/crates/protocol/src/provider_normalization/claude.rs` |
| 557 | `orbitdock-server/crates/server/src/admin/install_hooks.rs` |
| 534 | `orbitdock-server/crates/server/src/domain/mission_control/config.rs` |
| 533 | `orbitdock-server/crates/server/src/infrastructure/persistence/commands.rs` |
| 528 | `orbitdock-server/crates/server/src/admin/tunnel.rs` |
| 526 | `orbitdock-server/crates/protocol/src/domain_events/tooling.rs` |
| 525 | `orbitdock-server/crates/server/src/infrastructure/daytona.rs` |
| 516 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_types.rs` |
| 511 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_tests.rs` |
| 510 | `orbitdock-server/crates/server/src/infrastructure/persistence/workspace_sync.rs` |
| 506 | `orbitdock-server/crates/server/src/admin/hook_forward.rs` |
| 502 | `orbitdock-server/crates/server/src/domain/worktrees/include_copy.rs` |
| 501 | `orbitdock-server/crates/server/src/transport/http/router.rs` |
| 496 | `orbitdock-server/crates/server/src/domain/conversation_semantics/codex.rs` |
| 493 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_from_persist.rs` |
| 489 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs` |
| 488 | `orbitdock-server/crates/server/src/runtime/codex_config/resolver.rs` |
| 479 | `orbitdock-server/crates/server/src/infrastructure/terminal.rs` |
| 474 | `orbitdock-server/crates/server/src/transport/http/mission_control/issue_reports.rs` |
| 470 | `orbitdock-server/crates/server/src/infrastructure/migration_runner.rs` |
| 469 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_writer.rs` |
| 459 | `orbitdock-server/crates/server/src/infrastructure/linear/client.rs` |
| 458 | `orbitdock-server/crates/server/src/infrastructure/usage_probe.rs` |
| 450 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_to_persist.rs` |
| 446 | `orbitdock-server/crates/server/src/connectors/claude_hooks/handler.rs` |
| 442 | `orbitdock-server/crates/server/src/infrastructure/shell.rs` |
| 437 | `orbitdock-server/crates/server/src/infrastructure/logging.rs` |
| 428 | `orbitdock-server/crates/server/src/transport/websocket/connection.rs` |
| 424 | `orbitdock-server/crates/server/src/connectors/claude_hooks/status_events.rs` |
| 423 | `orbitdock-server/crates/server/src/admin/upgrade_executor.rs` |
| 419 | `orbitdock-server/crates/connector-claude/src/session.rs` |
| 412 | `orbitdock-server/crates/server/src/connectors/claude_hooks/tool_events.rs` |
| 391 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/session_hydration.rs` |
| 384 | `orbitdock-server/crates/server/src/infrastructure/tool_pty.rs` |
| 380 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/local.rs` |
| 378 | `orbitdock-server/crates/server/src/infrastructure/persistence/approvals.rs` |
| 374 | `orbitdock-server/crates/server/src/infrastructure/persistence/connector_writes.rs` |
| 374 | `orbitdock-server/crates/server/src/transport/websocket/handlers/messaging.rs` |
| 372 | `orbitdock-server/crates/server/src/domain/mission_control/executor.rs` |
| 370 | `orbitdock-server/crates/server/src/infrastructure/github_releases/client.rs` |
| 358 | `orbitdock-server/crates/server/src/transport/http/update.rs` |
| 357 | `orbitdock-server/crates/server/src/transport/http/mission_control/tracker_keys.rs` |
| 355 | `orbitdock-server/crates/server/src/infrastructure/images.rs` |
| 354 | `orbitdock-server/crates/server/src/infrastructure/crypto.rs` |
| 352 | `orbitdock-server/crates/server/src/domain/sessions/snapshot.rs` |
| 350 | `orbitdock-server/crates/server/src/connectors/jsonl_tailer.rs` |
| 344 | `orbitdock-server/crates/server/src/transport/http/shell.rs` |
| 337 | `orbitdock-server/crates/server/src/transport/http/worktrees.rs` |
| 336 | `orbitdock-server/crates/server/src/transport/websocket/handlers/shell.rs` |
| 317 | `orbitdock-server/crates/server/src/infrastructure/persistence/mission_writes.rs` |
| 303 | `orbitdock-server/crates/cli/src/commands/review.rs` |
| 303 | `orbitdock-server/crates/server/src/infrastructure/github/models.rs` |
| 300 | `orbitdock-server/crates/server/src/transport/http/mission_control/common.rs` |
| 298 | `orbitdock-server/crates/connector-codex/src/workers.rs` |
| 296 | `orbitdock-server/crates/server/src/infrastructure/housekeeping.rs` |
| 295 | `orbitdock-server/crates/server/src/connectors/claude_hooks/approval.rs` |
| 293 | `orbitdock-server/crates/server/src/domain/sessions/conversation_state.rs` |
| 291 | `orbitdock-server/crates/server/src/runtime/approval_dispatch.rs` |
| 288 | `orbitdock-server/crates/server/src/transport/http/sync.rs` |
| 286 | `orbitdock-server/crates/server/src/connectors/subagent_parser.rs` |
| 286 | `orbitdock-server/crates/server/src/transport/websocket/handlers/subscribe.rs` |
| 284 | `orbitdock-server/crates/server/src/infrastructure/auth_tokens.rs` |
| 283 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/fork.rs` |
| 281 | `orbitdock-server/crates/cli/src/main.rs` |
| 281 | `orbitdock-server/crates/server/src/runtime/session_registry/ownership.rs` |
| 281 | `orbitdock-server/crates/server/src/transport/http/approvals.rs` |
| 278 | `orbitdock-server/crates/server/src/domain/sessions/restore.rs` |
| 277 | `orbitdock-server/crates/connector-core/src/event.rs` |
| 277 | `orbitdock-server/crates/server/src/runtime/session_fork_runtime.rs` |
| 277 | `orbitdock-server/crates/server/src/transport/http/sessions/usage.rs` |
| 276 | `orbitdock-server/crates/cli/src/commands/usage.rs` |
| 273 | `orbitdock-server/crates/server/src/domain/mission_control/skills.rs` |
| 271 | `orbitdock-server/crates/server/src/transport/http/connector_actions.rs` |
| 270 | `orbitdock-server/crates/server/src/runtime/codex_config_types.rs` |
| 269 | `orbitdock-server/crates/server/src/transport/http/sessions/row_content.rs` |
| 268 | `orbitdock-server/crates/cli/src/commands/worktree.rs` |
| 267 | `orbitdock-server/crates/server/src/infrastructure/linear/models.rs` |
| 264 | `orbitdock-server/crates/server/src/transport/http/mission_control/files.rs` |
| 258 | `orbitdock-server/crates/server/src/admin/ensure_path.rs` |
| 258 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_materialization.rs` |
| 252 | `orbitdock-server/crates/server/src/runtime/mission_dispatch.rs` |
| 247 | `orbitdock-server/crates/server/src/runtime/dashboard.rs` |
| 243 | `orbitdock-server/crates/server/src/domain/mission_control/template.rs` |
| 242 | `orbitdock-server/crates/server/src/infrastructure/persistence/messages.rs` |
| 239 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads.rs` |
| 237 | `orbitdock-server/crates/server/src/runtime/session_fork_targets.rs` |
| 237 | `orbitdock-server/crates/server/src/transport/http/mission_control/crud.rs` |
| 236 | `orbitdock-server/crates/server/src/transport/http/permissions/settings_files.rs` |
| 234 | `orbitdock-server/crates/server/src/runtime/session_direct_start.rs` |
| 231 | `orbitdock-server/crates/protocol/src/diff_merge.rs` |
| 229 | `orbitdock-server/crates/server/src/domain/sessions/transition.rs` |
| 227 | `orbitdock-server/crates/connector-codex/src/auth.rs` |
| 226 | `orbitdock-server/crates/server/src/domain/mission_control/tools.rs` |
| 225 | `orbitdock-server/crates/server/src/infrastructure/persistence/writer.rs` |
| 224 | `orbitdock-server/crates/server/src/runtime/background/git_refresh.rs` |
| 224 | `orbitdock-server/crates/server/src/transport/http/files.rs` |
| 217 | `orbitdock-server/crates/server/src/domain/sessions/dashboard_projection.rs` |
| 216 | `orbitdock-server/crates/cli/src/commands/mcp_mission_tools.rs` |
| 216 | `orbitdock-server/crates/server/src/transport/http/mission_control/orchestrator.rs` |
| 215 | `orbitdock-server/crates/server/src/transport/websocket/handlers/tool_pty.rs` |
| 214 | `orbitdock-server/crates/server/src/support/ai_naming.rs` |
| 210 | `orbitdock-server/crates/server/src/transport/websocket/handlers/terminal.rs` |
| 209 | `orbitdock-server/crates/server/src/transport/http/review_comments/handlers.rs` |
| 208 | `orbitdock-server/crates/protocol/src/provider_normalization/shared.rs` |
| 205 | `orbitdock-server/crates/server/src/support/snapshot_compaction.rs` |
| 204 | `orbitdock-server/crates/cli/src/commands/model.rs` |
| 197 | `orbitdock-server/crates/server/src/admin/status.rs` |
| 196 | `orbitdock-server/crates/server/src/domain/conversation_semantics/mod.rs` |
| 195 | `orbitdock-server/crates/connector-codex/src/policy_bridge.rs` |
| 195 | `orbitdock-server/crates/server/src/admin/pair.rs` |
| 195 | `orbitdock-server/crates/server/src/runtime/session_commands.rs` |
| 193 | `orbitdock-server/crates/server/src/transport/http/server_info/tests.rs` |
| 192 | `orbitdock-server/crates/server/src/infrastructure/persistence/subagent_writes.rs` |
| 191 | `orbitdock-server/crates/server/src/support/normalization.rs` |
| 186 | `orbitdock-server/crates/server/src/domain/worktrees/service.rs` |
| 185 | `orbitdock-server/crates/server/src/infrastructure/github_releases/types.rs` |
| 184 | `orbitdock-server/crates/server/src/transport/http/review_comments/tests.rs` |
| 183 | `orbitdock-server/crates/server/src/runtime/session_registry/connection_state.rs` |
| 182 | `orbitdock-server/crates/server/src/connectors/claude_hooks/subagent_events.rs` |
| 181 | `orbitdock-server/crates/server/src/transport/http/sessions/conversation.rs` |
| 178 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_start.rs` |
| 178 | `orbitdock-server/crates/server/src/transport/http/server_info/workspace_provider.rs` |
| 177 | `orbitdock-server/crates/cli/src/commands/mcp.rs` |
| 176 | `orbitdock-server/crates/cli/src/output/human.rs` |
| 176 | `orbitdock-server/crates/protocol/src/domain_events/approvals.rs` |
| 175 | `orbitdock-server/crates/server/src/runtime/session_registry/sessions_summary.rs` |
| 172 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/ownership_reads.rs` |
| 169 | `orbitdock-server/crates/server/src/transport/http/capabilities/mcp.rs` |
| 168 | `orbitdock-server/crates/cli/src/client/rest.rs` |
| 168 | `orbitdock-server/crates/server/src/runtime/session_mutations/plan_snapshots.rs` |
| 167 | `orbitdock-server/crates/server/src/runtime/session_broadcasts.rs` |
| 167 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/codex_config.rs` |
| 165 | `orbitdock-server/crates/cli/src/commands/codex.rs` |
| 161 | `orbitdock-server/crates/server/src/runtime/session_registry/sessions.rs` |
| 159 | `orbitdock-server/crates/server/src/domain/sessions/diff_preview.rs` |
| 159 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/resume.rs` |
| 157 | `orbitdock-server/crates/server/src/domain/instructions.rs` |
| 155 | `orbitdock-server/crates/server/src/infrastructure/metrics.rs` |
| 153 | `orbitdock-server/crates/protocol/src/lib.rs` |
| 153 | `orbitdock-server/crates/server/src/runtime/session_mutations/session_lifecycle.rs` |
| 152 | `orbitdock-server/crates/connector-codex/src/lib.rs` |
| 147 | `orbitdock-server/crates/server/src/infrastructure/persistence/subagents.rs` |
| 146 | `orbitdock-server/crates/server/src/infrastructure/persistence/startup_cleanup.rs` |
| 146 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/mutations.rs` |
| 145 | `orbitdock-server/crates/server/src/runtime/codex_config/documents.rs` |
| 145 | `orbitdock-server/crates/server/src/runtime/worktree_creation.rs` |
| 143 | `orbitdock-server/crates/cli/src/commands/fs.rs` |
| 142 | `orbitdock-server/crates/protocol/src/domain_events/conversation.rs` |
| 142 | `orbitdock-server/crates/server/src/runtime/conversation_policy.rs` |
| 141 | `orbitdock-server/crates/server/src/infrastructure/persistence/review_comments.rs` |
| 141 | `orbitdock-server/crates/server/src/transport/websocket/transport.rs` |
| 135 | `orbitdock-server/crates/cli/src/output/mod.rs` |
| 135 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_outbox.rs` |
| 135 | `orbitdock-server/crates/server/src/transport/http/capabilities/mod.rs` |
| 134 | `orbitdock-server/crates/connector-codex/src/runtime.rs` |
| 132 | `orbitdock-server/crates/server/src/infrastructure/persistence/workspaces.rs` |
| 132 | `orbitdock-server/crates/server/src/transport/http/server_info/mod.rs` |
| 130 | `orbitdock-server/crates/server/src/connectors/claude_hooks/subagent_updates.rs` |
| 130 | `orbitdock-server/crates/server/src/runtime/transcript_sync_policy.rs` |
| 130 | `orbitdock-server/crates/server/src/transport/http/mission_control/mod.rs` |
| 129 | `orbitdock-server/crates/cli/src/client/ws.rs` |
| 129 | `orbitdock-server/crates/connector-codex/src/timeline.rs` |
| 129 | `orbitdock-server/crates/server/src/infrastructure/auth.rs` |
| 129 | `orbitdock-server/crates/server/src/runtime/codex_config/catalog.rs` |
| 129 | `orbitdock-server/crates/server/src/transport/http/sessions/common.rs` |
| 128 | `orbitdock-server/crates/server/src/transport/shell_streaming.rs` |
| 127 | `orbitdock-server/crates/server/src/domain/mission_control/tracker.rs` |
| 127 | `orbitdock-server/crates/server/src/domain/sessions/facets.rs` |
| 127 | `orbitdock-server/crates/server/src/runtime/session_lifecycle_policy.rs` |
| 126 | `orbitdock-server/crates/cli/src/client/config.rs` |
| 122 | `orbitdock-server/crates/server/src/admin/init.rs` |
| 121 | `orbitdock-server/crates/server/src/transport/http/server_meta/mod.rs` |
| 120 | `orbitdock-server/crates/server/src/transport/http/mission_control/issues.rs` |
| 119 | `orbitdock-server/crates/cli/src/commands/shell.rs` |
| 115 | `orbitdock-server/crates/server/src/transport/http/codex_auth.rs` |
| 115 | `orbitdock-server/crates/server/src/transport/web_assets.rs` |
| 114 | `orbitdock-server/crates/protocol/src/grouping/planner.rs` |
| 113 | `orbitdock-server/crates/server/src/support/api_keys.rs` |
| 112 | `orbitdock-server/crates/cli/src/commands/approval.rs` |
| 111 | `orbitdock-server/crates/cli/src/commands/server.rs` |
| 111 | `orbitdock-server/crates/protocol/src/provider_normalization/mod.rs` |
| 110 | `orbitdock-server/crates/server/src/transport/http/permissions/handlers.rs` |
| 110 | `orbitdock-server/crates/server/src/transport/http/sessions/mod.rs` |
| 109 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/common.rs` |
| 108 | `orbitdock-server/crates/server/src/runtime/session_mutations/config_notices.rs` |
| 107 | `orbitdock-server/crates/server/src/infrastructure/usage_pricing.rs` |
| 106 | `orbitdock-server/crates/server/src/admin/bind_guard.rs` |
| 106 | `orbitdock-server/crates/server/src/connectors/claude_hooks/routing.rs` |
| 104 | `orbitdock-server/crates/cli/src/commands/config.rs` |
| 104 | `orbitdock-server/crates/server/src/domain/mission_control/prompt.rs` |
| 104 | `orbitdock-server/crates/server/src/infrastructure/paths.rs` |
| 103 | `orbitdock-server/crates/server/src/runtime/codex_config/rpc_client.rs` |
| 103 | `orbitdock-server/crates/server/src/runtime/session_registry/recent_projects.rs` |
| 102 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/mod.rs` |
| 102 | `orbitdock-server/crates/server/src/transport/http/capabilities/plugins.rs` |
| 102 | `orbitdock-server/crates/server/src/transport/http/mod.rs` |
| 102 | `orbitdock-server/crates/server/src/transport/http/permissions/query.rs` |
| 98 | `orbitdock-server/crates/server/src/infrastructure/persistence/worktrees.rs` |
| 97 | `orbitdock-server/crates/server/src/transport/websocket/rest_only_policy.rs` |
| 96 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_plan.rs` |
| 96 | `orbitdock-server/crates/server/src/transport/http/capabilities/common.rs` |
| 94 | `orbitdock-server/crates/server/src/transport/http/mission_control/defaults.rs` |
| 93 | `orbitdock-server/crates/server/src/runtime/session_fork_policy.rs` |
| 92 | `orbitdock-server/crates/server/src/transport/websocket/router.rs` |
| 91 | `orbitdock-server/crates/server/src/transport/websocket/handlers/approvals.rs` |
| 89 | `orbitdock-server/crates/server/src/runtime/background/update_checker.rs` |
| 86 | `orbitdock-server/crates/server/src/support/session_modes.rs` |
| 85 | `orbitdock-server/crates/server/src/runtime/message_dispatch_policy.rs` |
| 85 | `orbitdock-server/crates/server/src/runtime/session_registry/dashboard.rs` |
| 85 | `orbitdock-server/crates/server/src/transport/http/test_support.rs` |
| 84 | `orbitdock-server/crates/server/src/domain/mission_control/eligibility.rs` |
| 84 | `orbitdock-server/crates/server/src/infrastructure/persistence/review_writes.rs` |
| 82 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/takeover.rs` |
| 82 | `orbitdock-server/crates/server/src/transport/websocket/handlers/session_management.rs` |
| 81 | `orbitdock-server/crates/server/src/infrastructure/db_pool.rs` |
| 81 | `orbitdock-server/crates/server/src/runtime/session_registry/missions.rs` |
| 80 | `orbitdock-server/crates/protocol/src/conversation_contracts/activity_groups.rs` |
| 79 | `orbitdock-server/crates/protocol/src/domain_events/workers.rs` |
| 79 | `orbitdock-server/crates/server/src/transport/websocket/message_groups.rs` |
| 73 | `orbitdock-server/crates/server/src/support/session_time.rs` |
| 73 | `orbitdock-server/crates/server/src/transport/http/errors.rs` |
| 73 | `orbitdock-server/crates/server/src/transport/websocket/handlers/session_crud.rs` |
| 71 | `orbitdock-server/crates/server/src/runtime/session_registry/hooks.rs` |
| 71 | `orbitdock-server/crates/server/src/transport/http/capabilities/instructions.rs` |
| 70 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_end.rs` |
| 70 | `orbitdock-server/crates/server/src/domain/mission_control/config/parser.rs` |
| 68 | `orbitdock-server/crates/server/src/transport/http/server_info/server_state.rs` |
| 67 | `orbitdock-server/crates/server/src/support/session_paths.rs` |
| 63 | `orbitdock-server/crates/server/src/domain/mission_control/config/serializer.rs` |
| 60 | `orbitdock-server/crates/server/src/connectors/hook_handler.rs` |
| 60 | `orbitdock-server/crates/server/src/domain/sessions/session_naming.rs` |
| 60 | `orbitdock-server/crates/server/src/transport/http/capabilities/skills.rs` |
| 59 | `orbitdock-server/crates/server/src/runtime/session_state_transitions.rs` |
| 59 | `orbitdock-server/crates/server/src/transport/http/capabilities/runtime.rs` |
| 58 | `orbitdock-server/crates/cli/src/commands/mod.rs` |
| 58 | `orbitdock-server/crates/server/src/lib.rs` |
| 58 | `orbitdock-server/crates/server/src/transport/http/review_comments/mod.rs` |
| 57 | `orbitdock-server/crates/server/src/runtime/session_registry/connector_registry.rs` |
| 51 | `orbitdock-server/crates/server/src/transport/http/review_comments/support.rs` |
| 50 | `orbitdock-server/crates/server/src/runtime/session_prompt.rs` |
| 49 | `orbitdock-server/crates/server/src/domain/mission_control/retry.rs` |
| 47 | `orbitdock-server/crates/server/src/runtime/server_info.rs` |
| 46 | `orbitdock-server/crates/server/src/transport/http/sessions/review.rs` |
| 44 | `orbitdock-server/crates/cli/src/commands/health.rs` |
| 43 | `orbitdock-server/crates/server/src/transport/http/sessions/summary.rs` |
| 43 | `orbitdock-server/crates/server/src/transport/websocket/handlers/claude_hooks.rs` |
| 42 | `orbitdock-server/crates/server/src/infrastructure/persistence/worktree_writes.rs` |
| 42 | `orbitdock-server/crates/server/src/transport/websocket/handlers/config.rs` |
| 41 | `orbitdock-server/crates/server/src/support/test_support.rs` |
| 38 | `orbitdock-server/crates/server/src/connectors/claude_hooks/http.rs` |
| 38 | `orbitdock-server/crates/server/src/transport/http/server_info/openai.rs` |
| 38 | `orbitdock-server/crates/server/src/transport/http/sessions/detail.rs` |
| 37 | `orbitdock-server/crates/server/src/admin/upgrade.rs` |
| 36 | `orbitdock-server/crates/cli/src/error.rs` |
| 36 | `orbitdock-server/crates/connector-codex/src/row_mapping.rs` |
| 36 | `orbitdock-server/crates/server/src/domain/sessions/conversation.rs` |
| 35 | `orbitdock-server/crates/server/src/admin/mod.rs` |
| 35 | `orbitdock-server/crates/server/src/domain/mission_control/mod.rs` |
| 34 | `orbitdock-server/crates/protocol/src/conversation_contracts/mod.rs` |
| 34 | `orbitdock-server/crates/protocol/src/domain_events/mod.rs` |
| 34 | `orbitdock-server/crates/server/src/runtime/mod.rs` |
| 34 | `orbitdock-server/crates/server/src/transport/http/capabilities/flags.rs` |
| 34 | `orbitdock-server/crates/server/src/transport/http/permissions/mod.rs` |
| 33 | `orbitdock-server/crates/protocol/src/conversation_contracts/approvals.rs` |
| 32 | `orbitdock-server/crates/server/src/infrastructure/persistence/config.rs` |
| 32 | `orbitdock-server/crates/server/src/transport/http/server_meta/models.rs` |
| 30 | `orbitdock-server/crates/server/src/transport/websocket/test_support.rs` |
| 22 | `orbitdock-server/crates/protocol/src/conversation_contracts/render_hints.rs` |
| 22 | `orbitdock-server/crates/protocol/src/domain_events/lifecycle.rs` |
| 22 | `orbitdock-server/crates/server/src/runtime/session_registry/library.rs` |
| 22 | `orbitdock-server/crates/server/src/transport/http/permissions/snapshot.rs` |
| 22 | `orbitdock-server/crates/server/src/transport/websocket/mod.rs` |
| 21 | `orbitdock-server/crates/server/src/runtime/codex_config/preferences.rs` |
| 20 | `orbitdock-server/crates/connector-core/src/lib.rs` |
| 20 | `orbitdock-server/crates/server/src/infrastructure/mod.rs` |
| 20 | `orbitdock-server/crates/server/src/transport/http/mission_control/tests.rs` |
| 19 | `orbitdock-server/crates/connector-core/src/panic.rs` |
| 19 | `orbitdock-server/crates/protocol/src/conversation_contracts/workers.rs` |
| 19 | `orbitdock-server/crates/server/src/runtime/codex_config.rs` |
| 19 | `orbitdock-server/crates/server/src/runtime/session_subscriptions.rs` |
| 17 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/mod.rs` |
| 17 | `orbitdock-server/crates/server/src/transport/websocket/handlers/rest_only.rs` |
| 16 | `orbitdock-server/crates/server/src/connectors/claude_hooks/transcript_sync.rs` |
| 16 | `orbitdock-server/crates/server/src/infrastructure/persistence/config_writes.rs` |
| 16 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync.rs` |
| 15 | `orbitdock-server/crates/server/src/transport/http/sessions_summary.rs` |
| 14 | `orbitdock-server/crates/connector-core/src/error.rs` |
| 14 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_payloads.rs` |
| 12 | `orbitdock-server/crates/server/src/domain/mission_control/config/scaffold.rs` |
| 12 | `orbitdock-server/crates/server/src/domain/sessions/mod.rs` |
| 11 | `orbitdock-server/crates/server/build.rs` |
| 11 | `orbitdock-server/crates/server/src/transport/websocket/handlers/mod.rs` |
| 10 | `orbitdock-server/crates/protocol/src/grouping/summaries.rs` |
| 10 | `orbitdock-server/crates/server/src/support/mod.rs` |
| 9 | `orbitdock-server/crates/cli/src/lib.rs` |
| 9 | `orbitdock-server/crates/protocol/src/grouping/mod.rs` |
| 8 | `orbitdock-server/crates/protocol/src/grouping/grouping_keys.rs` |
| 8 | `orbitdock-server/crates/server/src/support/usage_errors.rs` |
| 7 | `orbitdock-server/crates/server/src/connectors/claude_hooks/mod.rs` |
| 7 | `orbitdock-server/crates/server/src/domain/mod.rs` |
| 6 | `orbitdock-server/crates/server/src/connectors/mod.rs` |
| 4 | `orbitdock-server/crates/server/src/transport/mod.rs` |
| 3 | `orbitdock-server/crates/cli/src/client/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/domain/worktrees/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/infrastructure/github_releases/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/infrastructure/github/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/infrastructure/linear/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/runtime/background/mod.rs` |
| 1 | `orbitdock-server/crates/cli/src/output/json.rs` |
| 1 | `orbitdock-server/crates/server/src/domain/git/mod.rs` |
| 1 | `orbitdock-server/crates/server/src/transport/websocket/server_info.rs` |

## All orbitdock-server File Counts

| Lines | File |
| ---: | --- |
| 13373 | `orbitdock-server/Cargo.lock` |
| 4412 | `orbitdock-server/crates/connector-core/src/transition.rs` |
| 3560 | `orbitdock-server/crates/connector-claude/src/lib.rs` |
| 3090 | `orbitdock-server/crates/connector-codex/src/app_server.rs` |
| 2911 | `orbitdock-server/crates/protocol/src/types.rs` |
| 2451 | `orbitdock-server/crates/cli/src/commands/session.rs` |
| 1908 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_display.rs` |
| 1859 | `orbitdock-server/crates/connector-codex/src/rollout_parser.rs` |
| 1756 | `orbitdock-server/crates/server/src/infrastructure/persistence/tests.rs` |
| 1695 | `orbitdock-server/crates/protocol/src/client.rs` |
| 1573 | `orbitdock-server/crates/cli/src/cli.rs` |
| 1568 | `orbitdock-server/crates/server/src/domain/sessions/session.rs` |
| 1525 | `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs` |
| 1469 | `orbitdock-server/crates/server/src/domain/sessions/state.rs` |
| 1456 | `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` |
| 1301 | `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` |
| 1298 | `orbitdock-server/docs/API.md` |
| 1271 | `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs` |
| 1216 | `orbitdock-server/crates/cli/src/dev_console.rs` |
| 1197 | `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs` |
| 1147 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs` |
| 1127 | `orbitdock-server/crates/connector-codex/src/config.rs` |
| 1048 | `orbitdock-server/crates/server/src/runtime/session_mutations.rs` |
| 1041 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` |
| 1031 | `orbitdock-server/crates/server/src/infrastructure/github/client.rs` |
| 1002 | `orbitdock-server/crates/protocol/src/server.rs` |
| 964 | `orbitdock-server/crates/server/src/connectors/codex_session.rs` |
| 962 | `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs` |
| 925 | `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` |
| 916 | `orbitdock-server/crates/server/src/runtime/session_queries.rs` |
| 863 | `orbitdock-server/crates/connector-codex/src/tests.rs` |
| 843 | `orbitdock-server/crates/server/src/runtime/message_dispatch.rs` |
| 841 | `orbitdock-server/crates/server/src/domain/codex_tools.rs` |
| 838 | `orbitdock-server/crates/protocol/src/provider_normalization/codex.rs` |
| 834 | `orbitdock-server/crates/connector-codex/src/session_ops.rs` |
| 826 | `orbitdock-server/crates/server/src/transport/http/session_actions.rs` |
| 811 | `orbitdock-server/crates/server/src/admin/install_service.rs` |
| 809 | `orbitdock-server/crates/server/src/app/mod.rs` |
| 801 | `orbitdock-server/crates/server/src/admin/setup.rs` |
| 800 | `orbitdock-server/crates/server/src/domain/sessions/approval_state.rs` |
| 787 | `orbitdock-server/crates/connector-codex/src/session.rs` |
| 774 | `orbitdock-server/docs/SPEC.md` |
| 752 | `orbitdock-server/crates/server/src/runtime/session_registry.rs` |
| 739 | `orbitdock-server/crates/server/src/admin/doctor.rs` |
| 711 | `orbitdock-server/crates/server/src/runtime/session_takeover.rs` |
| 709 | `orbitdock-server/crates/server/src/domain/git/repo.rs` |
| 703 | `orbitdock-server/crates/server/src/transport/http/server_meta/usage.rs` |
| 698 | `orbitdock-server/crates/server/src/runtime/mission_reconciliation.rs` |
| 688 | `orbitdock-server/crates/server/src/runtime/mission_orchestrator.rs` |
| 686 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/startup_recovery.rs` |
| 685 | `orbitdock-server/crates/server/src/transport/http/capabilities/tests.rs` |
| 683 | `orbitdock-server/crates/server/src/runtime/session_actor.rs` |
| 683 | `orbitdock-server/crates/server/src/transport/http/sessions/tests.rs` |
| 677 | `orbitdock-server/crates/server/src/domain/conversation_semantics/shared.rs` |
| 655 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/daytona.rs` |
| 643 | `orbitdock-server/crates/server/src/transport/http/server_meta/tests.rs` |
| 639 | `orbitdock-server/crates/server/src/runtime/session_resume.rs` |
| 624 | `orbitdock-server/crates/server/src/runtime/restored_sessions.rs` |
| 613 | `orbitdock-server/crates/cli/src/commands/mission.rs` |
| 606 | `orbitdock-server/README.md` |
| 599 | `orbitdock-server/crates/server/src/connectors/claude_session.rs` |
| 598 | `orbitdock-server/crates/server/src/runtime/session_creation.rs` |
| 578 | `orbitdock-server/crates/server/src/domain/mission_control/config_model.rs` |
| 562 | `orbitdock-server/crates/protocol/src/provider_normalization/claude.rs` |
| 557 | `orbitdock-server/crates/server/src/admin/install_hooks.rs` |
| 534 | `orbitdock-server/crates/server/src/domain/mission_control/config.rs` |
| 533 | `orbitdock-server/crates/server/src/infrastructure/persistence/commands.rs` |
| 528 | `orbitdock-server/crates/server/src/admin/tunnel.rs` |
| 526 | `orbitdock-server/crates/protocol/src/domain_events/tooling.rs` |
| 525 | `orbitdock-server/crates/server/src/infrastructure/daytona.rs` |
| 516 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_types.rs` |
| 511 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_tests.rs` |
| 511 | `orbitdock-server/docs/claude-connector-parity.md` |
| 510 | `orbitdock-server/crates/server/src/infrastructure/persistence/workspace_sync.rs` |
| 506 | `orbitdock-server/crates/server/src/admin/hook_forward.rs` |
| 502 | `orbitdock-server/crates/server/src/domain/worktrees/include_copy.rs` |
| 501 | `orbitdock-server/crates/server/src/transport/http/router.rs` |
| 496 | `orbitdock-server/crates/server/src/domain/conversation_semantics/codex.rs` |
| 495 | `orbitdock-server/docs/conversation-contracts.md` |
| 493 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_from_persist.rs` |
| 489 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs` |
| 488 | `orbitdock-server/crates/server/src/runtime/codex_config/resolver.rs` |
| 479 | `orbitdock-server/crates/server/src/infrastructure/terminal.rs` |
| 474 | `orbitdock-server/crates/server/src/transport/http/mission_control/issue_reports.rs` |
| 470 | `orbitdock-server/crates/server/src/infrastructure/migration_runner.rs` |
| 469 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_writer.rs` |
| 459 | `orbitdock-server/crates/server/src/infrastructure/linear/client.rs` |
| 458 | `orbitdock-server/crates/server/src/infrastructure/usage_probe.rs` |
| 450 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_to_persist.rs` |
| 446 | `orbitdock-server/crates/server/src/connectors/claude_hooks/handler.rs` |
| 442 | `orbitdock-server/crates/server/src/infrastructure/shell.rs` |
| 437 | `orbitdock-server/crates/server/src/infrastructure/logging.rs` |
| 428 | `orbitdock-server/crates/server/src/transport/websocket/connection.rs` |
| 424 | `orbitdock-server/crates/server/src/connectors/claude_hooks/status_events.rs` |
| 423 | `orbitdock-server/crates/server/src/admin/upgrade_executor.rs` |
| 419 | `orbitdock-server/crates/connector-claude/src/session.rs` |
| 412 | `orbitdock-server/crates/server/src/connectors/claude_hooks/tool_events.rs` |
| 399 | `orbitdock-server/install.sh` |
| 391 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/session_hydration.rs` |
| 384 | `orbitdock-server/crates/server/src/infrastructure/tool_pty.rs` |
| 380 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/local.rs` |
| 378 | `orbitdock-server/crates/server/src/infrastructure/persistence/approvals.rs` |
| 374 | `orbitdock-server/crates/server/src/infrastructure/persistence/connector_writes.rs` |
| 374 | `orbitdock-server/crates/server/src/transport/websocket/handlers/messaging.rs` |
| 372 | `orbitdock-server/crates/server/src/domain/mission_control/executor.rs` |
| 370 | `orbitdock-server/crates/server/src/infrastructure/github_releases/client.rs` |
| 363 | `orbitdock-server/docs/server-architecture.md` |
| 358 | `orbitdock-server/crates/server/src/transport/http/update.rs` |
| 357 | `orbitdock-server/crates/server/src/transport/http/mission_control/tracker_keys.rs` |
| 355 | `orbitdock-server/crates/server/src/infrastructure/images.rs` |
| 354 | `orbitdock-server/crates/server/src/infrastructure/crypto.rs` |
| 353 | `orbitdock-server/docs/package-lock.json` |
| 352 | `orbitdock-server/crates/server/src/domain/sessions/snapshot.rs` |
| 350 | `orbitdock-server/crates/server/src/connectors/jsonl_tailer.rs` |
| 344 | `orbitdock-server/crates/server/src/transport/http/shell.rs` |
| 337 | `orbitdock-server/crates/server/src/transport/http/worktrees.rs` |
| 336 | `orbitdock-server/crates/server/src/transport/websocket/handlers/shell.rs` |
| 317 | `orbitdock-server/crates/server/src/infrastructure/persistence/mission_writes.rs` |
| 303 | `orbitdock-server/crates/cli/src/commands/review.rs` |
| 303 | `orbitdock-server/crates/server/src/infrastructure/github/models.rs` |
| 300 | `orbitdock-server/crates/server/src/transport/http/mission_control/common.rs` |
| 299 | `orbitdock-server/package-release-assets.sh` |
| 298 | `orbitdock-server/crates/connector-codex/src/workers.rs` |
| 296 | `orbitdock-server/crates/server/src/infrastructure/housekeeping.rs` |
| 295 | `orbitdock-server/crates/server/src/connectors/claude_hooks/approval.rs` |
| 293 | `orbitdock-server/crates/server/src/domain/sessions/conversation_state.rs` |
| 291 | `orbitdock-server/crates/server/src/runtime/approval_dispatch.rs` |
| 288 | `orbitdock-server/crates/server/src/transport/http/sync.rs` |
| 286 | `orbitdock-server/crates/server/src/connectors/subagent_parser.rs` |
| 286 | `orbitdock-server/crates/server/src/transport/websocket/handlers/subscribe.rs` |
| 284 | `orbitdock-server/crates/server/src/infrastructure/auth_tokens.rs` |
| 283 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/fork.rs` |
| 281 | `orbitdock-server/crates/cli/src/main.rs` |
| 281 | `orbitdock-server/crates/server/src/runtime/session_registry/ownership.rs` |
| 281 | `orbitdock-server/crates/server/src/transport/http/approvals.rs` |
| 278 | `orbitdock-server/crates/server/src/domain/sessions/restore.rs` |
| 277 | `orbitdock-server/crates/connector-core/src/event.rs` |
| 277 | `orbitdock-server/crates/server/src/runtime/session_fork_runtime.rs` |
| 277 | `orbitdock-server/crates/server/src/transport/http/sessions/usage.rs` |
| 276 | `orbitdock-server/crates/cli/src/commands/usage.rs` |
| 273 | `orbitdock-server/crates/server/src/domain/mission_control/skills.rs` |
| 271 | `orbitdock-server/crates/server/src/transport/http/connector_actions.rs` |
| 270 | `orbitdock-server/crates/server/src/runtime/codex_config_types.rs` |
| 269 | `orbitdock-server/crates/server/src/transport/http/sessions/row_content.rs` |
| 268 | `orbitdock-server/crates/cli/src/commands/worktree.rs` |
| 267 | `orbitdock-server/crates/server/src/infrastructure/linear/models.rs` |
| 264 | `orbitdock-server/crates/server/src/transport/http/mission_control/files.rs` |
| 258 | `orbitdock-server/crates/server/src/admin/ensure_path.rs` |
| 258 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_materialization.rs` |
| 252 | `orbitdock-server/crates/server/src/runtime/mission_dispatch.rs` |
| 247 | `orbitdock-server/crates/server/src/runtime/dashboard.rs` |
| 243 | `orbitdock-server/crates/server/src/domain/mission_control/template.rs` |
| 242 | `orbitdock-server/crates/server/src/infrastructure/persistence/messages.rs` |
| 239 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads.rs` |
| 237 | `orbitdock-server/crates/server/src/runtime/session_fork_targets.rs` |
| 237 | `orbitdock-server/crates/server/src/transport/http/mission_control/crud.rs` |
| 236 | `orbitdock-server/crates/server/src/transport/http/permissions/settings_files.rs` |
| 234 | `orbitdock-server/crates/server/src/runtime/session_direct_start.rs` |
| 231 | `orbitdock-server/crates/protocol/src/diff_merge.rs` |
| 229 | `orbitdock-server/crates/server/src/domain/sessions/transition.rs` |
| 227 | `orbitdock-server/crates/connector-codex/src/auth.rs` |
| 226 | `orbitdock-server/crates/server/src/domain/mission_control/tools.rs` |
| 225 | `orbitdock-server/crates/server/src/infrastructure/persistence/writer.rs` |
| 224 | `orbitdock-server/crates/server/src/runtime/background/git_refresh.rs` |
| 224 | `orbitdock-server/crates/server/src/transport/http/files.rs` |
| 220 | `orbitdock-server/migrations/V001__baseline.sql` |
| 217 | `orbitdock-server/crates/server/src/domain/sessions/dashboard_projection.rs` |
| 216 | `orbitdock-server/crates/cli/src/commands/mcp_mission_tools.rs` |
| 216 | `orbitdock-server/crates/server/src/transport/http/mission_control/orchestrator.rs` |
| 215 | `orbitdock-server/crates/server/src/transport/websocket/handlers/tool_pty.rs` |
| 214 | `orbitdock-server/crates/server/src/support/ai_naming.rs` |
| 210 | `orbitdock-server/crates/server/src/transport/websocket/handlers/terminal.rs` |
| 209 | `orbitdock-server/crates/server/src/transport/http/review_comments/handlers.rs` |
| 208 | `orbitdock-server/crates/protocol/src/provider_normalization/shared.rs` |
| 205 | `orbitdock-server/crates/server/src/support/snapshot_compaction.rs` |
| 204 | `orbitdock-server/crates/cli/src/commands/model.rs` |
| 197 | `orbitdock-server/crates/server/src/admin/status.rs` |
| 196 | `orbitdock-server/crates/server/src/domain/conversation_semantics/mod.rs` |
| 195 | `orbitdock-server/crates/connector-codex/src/policy_bridge.rs` |
| 195 | `orbitdock-server/crates/server/src/admin/pair.rs` |
| 195 | `orbitdock-server/crates/server/src/runtime/session_commands.rs` |
| 193 | `orbitdock-server/crates/server/src/transport/http/server_info/tests.rs` |
| 192 | `orbitdock-server/crates/server/src/infrastructure/persistence/subagent_writes.rs` |
| 191 | `orbitdock-server/crates/server/src/support/normalization.rs` |
| 186 | `orbitdock-server/crates/server/src/domain/worktrees/service.rs` |
| 185 | `orbitdock-server/crates/server/src/infrastructure/github_releases/types.rs` |
| 184 | `orbitdock-server/crates/server/src/transport/http/review_comments/tests.rs` |
| 183 | `orbitdock-server/crates/server/src/runtime/session_registry/connection_state.rs` |
| 182 | `orbitdock-server/crates/server/src/connectors/claude_hooks/subagent_events.rs` |
| 181 | `orbitdock-server/crates/server/src/transport/http/sessions/conversation.rs` |
| 178 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_start.rs` |
| 178 | `orbitdock-server/crates/server/src/transport/http/server_info/workspace_provider.rs` |
| 177 | `orbitdock-server/crates/cli/src/commands/mcp.rs` |
| 176 | `orbitdock-server/crates/cli/src/output/human.rs` |
| 176 | `orbitdock-server/crates/protocol/src/domain_events/approvals.rs` |
| 175 | `orbitdock-server/crates/server/src/runtime/session_registry/sessions_summary.rs` |
| 172 | `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/ownership_reads.rs` |
| 169 | `orbitdock-server/crates/server/src/transport/http/capabilities/mcp.rs` |
| 168 | `orbitdock-server/crates/cli/src/client/rest.rs` |
| 168 | `orbitdock-server/crates/server/src/runtime/session_mutations/plan_snapshots.rs` |
| 167 | `orbitdock-server/crates/server/src/runtime/session_broadcasts.rs` |
| 167 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/codex_config.rs` |
| 165 | `orbitdock-server/crates/cli/src/commands/codex.rs` |
| 161 | `orbitdock-server/crates/server/src/runtime/session_registry/sessions.rs` |
| 159 | `orbitdock-server/crates/server/src/domain/sessions/diff_preview.rs` |
| 159 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/resume.rs` |
| 157 | `orbitdock-server/crates/server/src/domain/instructions.rs` |
| 155 | `orbitdock-server/crates/server/src/infrastructure/metrics.rs` |
| 153 | `orbitdock-server/crates/protocol/src/lib.rs` |
| 153 | `orbitdock-server/crates/server/src/runtime/session_mutations/session_lifecycle.rs` |
| 152 | `orbitdock-server/crates/connector-codex/src/lib.rs` |
| 147 | `orbitdock-server/crates/server/src/infrastructure/persistence/subagents.rs` |
| 146 | `orbitdock-server/crates/server/src/infrastructure/persistence/startup_cleanup.rs` |
| 146 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/mutations.rs` |
| 145 | `orbitdock-server/crates/server/src/runtime/codex_config/documents.rs` |
| 145 | `orbitdock-server/crates/server/src/runtime/worktree_creation.rs` |
| 143 | `orbitdock-server/crates/cli/src/commands/fs.rs` |
| 142 | `orbitdock-server/crates/protocol/src/domain_events/conversation.rs` |
| 142 | `orbitdock-server/crates/server/src/runtime/conversation_policy.rs` |
| 141 | `orbitdock-server/crates/server/src/infrastructure/persistence/review_comments.rs` |
| 141 | `orbitdock-server/crates/server/src/transport/websocket/transport.rs` |
| 135 | `orbitdock-server/crates/cli/src/output/mod.rs` |
| 135 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_outbox.rs` |
| 135 | `orbitdock-server/crates/server/src/transport/http/capabilities/mod.rs` |
| 134 | `orbitdock-server/crates/connector-codex/src/runtime.rs` |
| 132 | `orbitdock-server/crates/server/src/infrastructure/persistence/workspaces.rs` |
| 132 | `orbitdock-server/crates/server/src/transport/http/server_info/mod.rs` |
| 130 | `orbitdock-server/crates/server/src/connectors/claude_hooks/subagent_updates.rs` |
| 130 | `orbitdock-server/crates/server/src/runtime/transcript_sync_policy.rs` |
| 130 | `orbitdock-server/crates/server/src/transport/http/mission_control/mod.rs` |
| 129 | `orbitdock-server/crates/cli/src/client/ws.rs` |
| 129 | `orbitdock-server/crates/connector-codex/src/timeline.rs` |
| 129 | `orbitdock-server/crates/server/src/infrastructure/auth.rs` |
| 129 | `orbitdock-server/crates/server/src/runtime/codex_config/catalog.rs` |
| 129 | `orbitdock-server/crates/server/src/transport/http/sessions/common.rs` |
| 128 | `orbitdock-server/crates/server/src/transport/shell_streaming.rs` |
| 127 | `orbitdock-server/crates/server/src/domain/mission_control/tracker.rs` |
| 127 | `orbitdock-server/crates/server/src/domain/sessions/facets.rs` |
| 127 | `orbitdock-server/crates/server/src/runtime/session_lifecycle_policy.rs` |
| 126 | `orbitdock-server/crates/cli/src/client/config.rs` |
| 122 | `orbitdock-server/crates/server/src/admin/init.rs` |
| 121 | `orbitdock-server/crates/server/src/transport/http/server_meta/mod.rs` |
| 120 | `orbitdock-server/Cargo.toml` |
| 120 | `orbitdock-server/crates/server/src/transport/http/mission_control/issues.rs` |
| 119 | `orbitdock-server/crates/cli/src/commands/shell.rs` |
| 115 | `orbitdock-server/crates/server/src/transport/http/codex_auth.rs` |
| 115 | `orbitdock-server/crates/server/src/transport/web_assets.rs` |
| 114 | `orbitdock-server/crates/protocol/src/grouping/planner.rs` |
| 113 | `orbitdock-server/crates/server/src/support/api_keys.rs` |
| 112 | `orbitdock-server/crates/cli/src/commands/approval.rs` |
| 111 | `orbitdock-server/crates/cli/src/commands/server.rs` |
| 111 | `orbitdock-server/crates/protocol/src/provider_normalization/mod.rs` |
| 110 | `orbitdock-server/crates/server/src/transport/http/permissions/handlers.rs` |
| 110 | `orbitdock-server/crates/server/src/transport/http/sessions/mod.rs` |
| 109 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/common.rs` |
| 108 | `orbitdock-server/crates/server/src/runtime/session_mutations/config_notices.rs` |
| 107 | `orbitdock-server/crates/server/src/infrastructure/usage_pricing.rs` |
| 106 | `orbitdock-server/crates/server/src/admin/bind_guard.rs` |
| 106 | `orbitdock-server/crates/server/src/connectors/claude_hooks/routing.rs` |
| 104 | `orbitdock-server/crates/cli/src/commands/config.rs` |
| 104 | `orbitdock-server/crates/server/src/domain/mission_control/prompt.rs` |
| 104 | `orbitdock-server/crates/server/src/infrastructure/paths.rs` |
| 103 | `orbitdock-server/crates/server/src/runtime/codex_config/rpc_client.rs` |
| 103 | `orbitdock-server/crates/server/src/runtime/session_registry/recent_projects.rs` |
| 102 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/mod.rs` |
| 102 | `orbitdock-server/crates/server/src/transport/http/capabilities/plugins.rs` |
| 102 | `orbitdock-server/crates/server/src/transport/http/mod.rs` |
| 102 | `orbitdock-server/crates/server/src/transport/http/permissions/query.rs` |
| 98 | `orbitdock-server/crates/server/src/infrastructure/persistence/worktrees.rs` |
| 97 | `orbitdock-server/crates/server/src/transport/websocket/rest_only_policy.rs` |
| 96 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync_plan.rs` |
| 96 | `orbitdock-server/crates/server/src/transport/http/capabilities/common.rs` |
| 94 | `orbitdock-server/crates/server/src/transport/http/mission_control/defaults.rs` |
| 93 | `orbitdock-server/crates/server/src/runtime/session_fork_policy.rs` |
| 92 | `orbitdock-server/crates/server/src/transport/websocket/router.rs` |
| 91 | `orbitdock-server/crates/server/src/transport/websocket/handlers/approvals.rs` |
| 89 | `orbitdock-server/crates/server/src/runtime/background/update_checker.rs` |
| 86 | `orbitdock-server/crates/server/src/support/session_modes.rs` |
| 85 | `orbitdock-server/crates/server/src/runtime/message_dispatch_policy.rs` |
| 85 | `orbitdock-server/crates/server/src/runtime/session_registry/dashboard.rs` |
| 85 | `orbitdock-server/crates/server/src/transport/http/test_support.rs` |
| 84 | `orbitdock-server/crates/server/src/domain/mission_control/eligibility.rs` |
| 84 | `orbitdock-server/crates/server/src/infrastructure/persistence/review_writes.rs` |
| 82 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/takeover.rs` |
| 82 | `orbitdock-server/crates/server/src/transport/websocket/handlers/session_management.rs` |
| 81 | `orbitdock-server/crates/server/src/infrastructure/db_pool.rs` |
| 81 | `orbitdock-server/crates/server/src/runtime/session_registry/missions.rs` |
| 80 | `orbitdock-server/crates/protocol/src/conversation_contracts/activity_groups.rs` |
| 79 | `orbitdock-server/crates/protocol/src/domain_events/workers.rs` |
| 79 | `orbitdock-server/crates/server/src/transport/websocket/message_groups.rs` |
| 73 | `orbitdock-server/crates/server/src/support/session_time.rs` |
| 73 | `orbitdock-server/crates/server/src/transport/http/errors.rs` |
| 73 | `orbitdock-server/crates/server/src/transport/websocket/handlers/session_crud.rs` |
| 71 | `orbitdock-server/crates/server/src/runtime/session_registry/hooks.rs` |
| 71 | `orbitdock-server/crates/server/src/transport/http/capabilities/instructions.rs` |
| 70 | `orbitdock-server/crates/server/src/connectors/claude_hooks/session_end.rs` |
| 70 | `orbitdock-server/crates/server/src/domain/mission_control/config/parser.rs` |
| 68 | `orbitdock-server/crates/server/src/transport/http/server_info/server_state.rs` |
| 67 | `orbitdock-server/crates/server/src/support/session_paths.rs` |
| 63 | `orbitdock-server/crates/server/src/domain/mission_control/config/serializer.rs` |
| 60 | `orbitdock-server/crates/server/src/connectors/hook_handler.rs` |
| 60 | `orbitdock-server/crates/server/src/domain/sessions/session_naming.rs` |
| 60 | `orbitdock-server/crates/server/src/transport/http/capabilities/skills.rs` |
| 60 | `orbitdock-server/migrations/V007__usage_tracking.sql` |
| 59 | `orbitdock-server/crates/server/src/runtime/session_state_transitions.rs` |
| 59 | `orbitdock-server/crates/server/src/transport/http/capabilities/runtime.rs` |
| 59 | `orbitdock-server/migrations/V040__unique_claude_direct_owner.sql` |
| 58 | `orbitdock-server/crates/cli/src/commands/mod.rs` |
| 58 | `orbitdock-server/crates/server/Cargo.toml` |
| 58 | `orbitdock-server/crates/server/src/lib.rs` |
| 58 | `orbitdock-server/crates/server/src/transport/http/review_comments/mod.rs` |
| 57 | `orbitdock-server/crates/server/src/runtime/session_registry/connector_registry.rs` |
| 51 | `orbitdock-server/crates/server/src/transport/http/review_comments/support.rs` |
| 50 | `orbitdock-server/crates/server/src/runtime/session_prompt.rs` |
| 49 | `orbitdock-server/crates/server/src/domain/mission_control/retry.rs` |
| 47 | `orbitdock-server/crates/server/src/runtime/server_info.rs` |
| 46 | `orbitdock-server/crates/server/src/transport/http/sessions/review.rs` |
| 44 | `orbitdock-server/crates/cli/src/commands/health.rs` |
| 43 | `orbitdock-server/crates/server/src/transport/http/sessions/summary.rs` |
| 43 | `orbitdock-server/crates/server/src/transport/websocket/handlers/claude_hooks.rs` |
| 42 | `orbitdock-server/crates/server/src/infrastructure/persistence/worktree_writes.rs` |
| 42 | `orbitdock-server/crates/server/src/transport/websocket/handlers/config.rs` |
| 41 | `orbitdock-server/crates/connector-codex/prompts/external_model_instructions.md` |
| 41 | `orbitdock-server/crates/server/src/support/test_support.rs` |
| 41 | `orbitdock-server/docker/linux-release.Dockerfile` |
| 41 | `orbitdock-server/migrations/V025__mission_control.sql` |
| 38 | `orbitdock-server/crates/server/src/connectors/claude_hooks/http.rs` |
| 38 | `orbitdock-server/crates/server/src/transport/http/server_info/openai.rs` |
| 38 | `orbitdock-server/crates/server/src/transport/http/sessions/detail.rs` |
| 37 | `orbitdock-server/crates/server/src/admin/upgrade.rs` |
| 37 | `orbitdock-server/migrations/V039__block_claude_direct_shadow_sessions.sql` |
| 36 | `orbitdock-server/crates/cli/src/error.rs` |
| 36 | `orbitdock-server/crates/connector-codex/src/row_mapping.rs` |
| 36 | `orbitdock-server/crates/server/src/domain/sessions/conversation.rs` |
| 35 | `orbitdock-server/crates/cli/Cargo.toml` |
| 35 | `orbitdock-server/crates/connector-codex/Cargo.toml` |
| 35 | `orbitdock-server/crates/server/src/admin/mod.rs` |
| 35 | `orbitdock-server/crates/server/src/domain/mission_control/mod.rs` |
| 34 | `orbitdock-server/crates/protocol/src/conversation_contracts/mod.rs` |
| 34 | `orbitdock-server/crates/protocol/src/domain_events/mod.rs` |
| 34 | `orbitdock-server/crates/server/src/runtime/mod.rs` |
| 34 | `orbitdock-server/crates/server/src/transport/http/capabilities/flags.rs` |
| 34 | `orbitdock-server/crates/server/src/transport/http/permissions/mod.rs` |
| 33 | `orbitdock-server/crates/protocol/src/conversation_contracts/approvals.rs` |
| 33 | `orbitdock-server/migrations/V038__workspace_sync.sql` |
| 32 | `orbitdock-server/crates/server/src/infrastructure/persistence/config.rs` |
| 32 | `orbitdock-server/crates/server/src/transport/http/server_meta/models.rs` |
| 30 | `orbitdock-server/crates/server/src/transport/websocket/test_support.rs` |
| 28 | `orbitdock-server/migrations/V045__database_performance.sql` |
| 28 | `orbitdock-server/migrations/V048__usage_accounting_backbone.sql` |
| 26 | `orbitdock-server/migrations/V010__worktree_support.sql` |
| 26 | `orbitdock-server/migrations/V043__usage_ledger.sql` |
| 22 | `orbitdock-server/crates/protocol/src/conversation_contracts/render_hints.rs` |
| 22 | `orbitdock-server/crates/protocol/src/domain_events/lifecycle.rs` |
| 22 | `orbitdock-server/crates/server/src/runtime/session_registry/library.rs` |
| 22 | `orbitdock-server/crates/server/src/transport/http/permissions/snapshot.rs` |
| 22 | `orbitdock-server/crates/server/src/transport/websocket/mod.rs` |
| 22 | `orbitdock-server/migrations/V042__drop_legacy_message_columns.sql` |
| 21 | `orbitdock-server/crates/server/src/runtime/codex_config/preferences.rs` |
| 21 | `orbitdock-server/migrations/V046__immutable_provider_session_ids.sql` |
| 20 | `orbitdock-server/crates/connector-core/src/lib.rs` |
| 20 | `orbitdock-server/crates/server/src/infrastructure/mod.rs` |
| 20 | `orbitdock-server/crates/server/src/transport/http/mission_control/tests.rs` |
| 20 | `orbitdock-server/migrations/V049__usage_turn_model_snapshot.sql` |
| 19 | `orbitdock-server/build-universal.sh` |
| 19 | `orbitdock-server/crates/connector-core/src/panic.rs` |
| 19 | `orbitdock-server/crates/protocol/src/conversation_contracts/workers.rs` |
| 19 | `orbitdock-server/crates/server/src/runtime/codex_config.rs` |
| 19 | `orbitdock-server/crates/server/src/runtime/session_subscriptions.rs` |
| 18 | `orbitdock-server/crates/connector-claude/Cargo.toml` |
| 17 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/mod.rs` |
| 17 | `orbitdock-server/crates/server/src/transport/websocket/handlers/rest_only.rs` |
| 16 | `orbitdock-server/crates/server/src/connectors/claude_hooks/transcript_sync.rs` |
| 16 | `orbitdock-server/crates/server/src/infrastructure/persistence/config_writes.rs` |
| 16 | `orbitdock-server/crates/server/src/infrastructure/persistence/sync.rs` |
| 16 | `orbitdock-server/docs/package.json` |
| 15 | `orbitdock-server/crates/server/src/transport/http/sessions_summary.rs` |
| 14 | `orbitdock-server/crates/connector-core/Cargo.toml` |
| 14 | `orbitdock-server/crates/connector-core/src/error.rs` |
| 14 | `orbitdock-server/crates/protocol/src/conversation_contracts/tool_payloads.rs` |
| 14 | `orbitdock-server/migrations/V011__auth_tokens.sql` |
| 13 | `orbitdock-server/crates/protocol/Cargo.toml` |
| 12 | `orbitdock-server/crates/server/src/domain/mission_control/config/scaffold.rs` |
| 12 | `orbitdock-server/crates/server/src/domain/sessions/mod.rs` |
| 12 | `orbitdock-server/migrations/V023__rollout_checkpoints.sql` |
| 11 | `orbitdock-server/crates/server/build.rs` |
| 11 | `orbitdock-server/crates/server/src/transport/websocket/handlers/mod.rs` |
| 11 | `orbitdock-server/migrations/V012__unread_tracking.sql` |
| 10 | `orbitdock-server/crates/protocol/src/grouping/summaries.rs` |
| 10 | `orbitdock-server/crates/server/src/support/mod.rs` |
| 10 | `orbitdock-server/migrations/V024__approval_elicitation_network.sql` |
| 10 | `orbitdock-server/migrations/V044__sync_outbox.sql` |
| 9 | `orbitdock-server/crates/cli/src/lib.rs` |
| 9 | `orbitdock-server/crates/protocol/src/grouping/mod.rs` |
| 9 | `orbitdock-server/migrations/V019__subagent_metadata.sql` |
| 9 | `orbitdock-server/migrations/V029__fix_message_sequences.sql` |
| 9 | `orbitdock-server/migrations/V037__session_control_mode.sql` |
| 8 | `orbitdock-server/crates/protocol/src/grouping/grouping_keys.rs` |
| 8 | `orbitdock-server/crates/server/src/support/usage_errors.rs` |
| 8 | `orbitdock-server/migrations/V036__session_lifecycle_state.sql` |
| 7 | `orbitdock-server/crates/server/src/connectors/claude_hooks/mod.rs` |
| 7 | `orbitdock-server/crates/server/src/domain/mod.rs` |
| 7 | `orbitdock-server/migrations/V047__rename_mixed_usage_snapshot.sql` |
| 6 | `orbitdock-server/crates/server/src/connectors/mod.rs` |
| 6 | `orbitdock-server/migrations/V004__claude_models.sql` |
| 6 | `orbitdock-server/migrations/V006__claude_models.sql` |
| 6 | `orbitdock-server/migrations/V021__codex_control_plane.sql` |
| 6 | `orbitdock-server/migrations/V022__conversation_row_data.sql` |
| 6 | `orbitdock-server/migrations/V033__last_progress_at.sql` |
| 5 | `orbitdock-server/migrations/V003__config_table.sql` |
| 5 | `orbitdock-server/migrations/V027__mission_name.sql` |
| 4 | `orbitdock-server/crates/server/src/transport/mod.rs` |
| 4 | `orbitdock-server/migrations/V005__pending_approval_id.sql` |
| 4 | `orbitdock-server/migrations/V034__mission_tracker_credentials.sql` |
| 3 | `orbitdock-server/crates/cli/src/client/mod.rs` |
| 3 | `orbitdock-server/migrations/V009__message_error_column.sql` |
| 3 | `orbitdock-server/migrations/V020__approval_history_request_permissions.sql` |
| 3 | `orbitdock-server/migrations/V028__mission_file_path.sql` |
| 3 | `orbitdock-server/migrations/V031__codex_config_mode_profile_provider.sql` |
| 2 | `orbitdock-server/crates/server/src/domain/worktrees/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/infrastructure/github_releases/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/infrastructure/github/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/infrastructure/linear/mod.rs` |
| 2 | `orbitdock-server/crates/server/src/runtime/background/mod.rs` |
| 2 | `orbitdock-server/migrations/V026__mission_issue_url.sql` |
| 2 | `orbitdock-server/migrations/V030__codex_config_source_and_overrides.sql` |
| 2 | `orbitdock-server/migrations/V035__turn_status.sql` |
| 1 | `orbitdock-server/crates/cli/src/output/json.rs` |
| 1 | `orbitdock-server/crates/server/src/domain/git/mod.rs` |
| 1 | `orbitdock-server/crates/server/src/transport/websocket/server_info.rs` |
| 1 | `orbitdock-server/migrations/V002__message_images.sql` |
| 1 | `orbitdock-server/migrations/V008__approval_version.sql` |
| 1 | `orbitdock-server/migrations/V013__approval_history_payload.sql` |
| 1 | `orbitdock-server/migrations/V014__approval_history_diff.sql` |
| 1 | `orbitdock-server/migrations/V015__approval_history_question.sql` |
| 1 | `orbitdock-server/migrations/V016__approval_history_question_prompts.sql` |
| 1 | `orbitdock-server/migrations/V017__approval_history_preview.sql` |
| 1 | `orbitdock-server/migrations/V018__approval_history_permission_suggestions.sql` |
| 1 | `orbitdock-server/migrations/V032__mission_issue_pr_url.sql` |
| 1 | `orbitdock-server/migrations/V041__drop_rollout_checkpoints.sql` |
| 1 | `orbitdock-server/rustfmt.toml` |

## Suggested First Refactor Threads

1. Split `connector-claude/src/lib.rs` by responsibility first. Suggested modules: process/control transport, event loop state, assistant/user/system message mapping, tool rendering, approval/control request mapping, image input conversion, and tests by behavior. This matches the known concern and has the cleanest payoff.
2. Split `connector-core/src/transition.rs` second, but carefully. Keep the transition reducer central; move approval preview/risk/shell parsing/diff-preview helpers into dedicated modules so the reducer remains easy to audit.
3. Split `connector-codex/src/app_server.rs` around protocol client vs notification/request mapping vs tool row mapping. This should reduce risk when app-server protocol changes.
4. Split `protocol/src/types.rs` into domain-aligned protocol modules once the connector files stop importing it as one giant surface.
5. For HTTP, prioritize semantic splits over line-count splits: `session_actions.rs` and `session_lifecycle/create.rs` should become thin transport mappers over runtime/domain request types.
