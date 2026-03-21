# Database And Persistence

Use this doc when you're changing schema, persistence flow, or server-owned state.

The short version: the Rust server is the only SQLite writer, and conversation row persistence must stay on the single-writer path.

## Core Rules

- only `orbitdock` reads from and writes to SQLite directly
- the Swift app and CLI go through REST and WebSocket
- keep schema changes additive when you reasonably can
- do not create side paths for conversation row writes

## Data Flow

```text
Claude hooks -> HTTP POST /api/hook -> Rust server -> SQLite
                                        | REST
                                        | WebSocket
                                        v
                                   Swift app
```

## Adding A Migration

1. Create `migrations/VNNN__description.sql`
2. Write the SQL change
3. Update the Rust persistence code if reads or writes change
4. Update restore and startup hydration when needed
5. Update protocol types if the new field needs to reach clients
6. Run the relevant `make rust-*` checks

OrbitDock uses `refinery`. Migration files are embedded at compile time and run on server startup.

## Important Tables

| Table | Purpose |
|---|---|
| `sessions` | Session tracking, approval queue head, approval version, repo metadata |
| `messages` | Conversation rows per session |
| `subagents` | Spawned task agents |
| `turn_diffs` | Per-turn git diff snapshots and token usage |
| `approval_history` | Approval requests and decisions |
| `review_comments` | Review annotations |
| `worktrees` | Git worktree lifecycle tracking |
| `missions` | Mission Control configuration |
| `mission_issues` | Per-issue orchestration state |
| `config` | Key-value settings, including encrypted secrets |
| `refinery_schema_history` | Active migration history |

## Single-Writer Rule For Conversation Rows

All conversation row writes must go through one of the server's sequence-owning paths.

Allowed paths:

1. Session command handlers that assign sequence numbers before persistence and broadcast
2. The transition state machine, which produces persistence effects after sequence assignment

What not to do:

- do not create `PersistCommand::RowAppend` or `RowUpsert` directly from a callsite that also uses the session actor
- do not persist rows before the actor or transition layer has assigned the correct sequence

That race is how you end up with wrong sequence numbers in SQLite.

## Approval Versioning

Approval state is versioned with a monotonic `approval_version`.

- increment on enqueue, decide, clear, or in-place update
- include the version in approval-related messages
- let clients reject stale approval updates

This is what keeps older events from stomping newer approval state on the client.

## Config Encryption

Sensitive values in the `config` table are encrypted at rest with AES-256-GCM.

Key resolution order:

1. `ORBITDOCK_ENCRYPTION_KEY`
2. `<data_dir>/encryption.key`
3. auto-generated key on first setup

If the key is lost, encrypted values cannot be recovered.

## Key Files

- `orbitdock-server/crates/server/src/infrastructure/persistence/`
- `orbitdock-server/crates/server/src/infrastructure/migration_runner.rs`
- `orbitdock-server/crates/server/src/infrastructure/paths.rs`
- `orbitdock-server/crates/server/src/infrastructure/crypto.rs`
- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs`
- `orbitdock-server/crates/server/src/connectors/`
- `migrations/`

## Related Docs

- [data-flow.md](data-flow.md)
- [client-networking.md](client-networking.md)
- [local-development.md](local-development.md)
