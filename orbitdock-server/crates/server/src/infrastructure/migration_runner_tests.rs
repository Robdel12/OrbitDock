use super::*;

#[test]
fn run_migrations_on_fresh_db() {
  let mut conn = Connection::open_in_memory().expect("open in-memory db");
  run_migrations(&mut conn).expect("migrations should succeed");
  let expected_migration_count =
    super::embedded::migrations::runner().get_migrations().len() as i64;

  let migration_count: i64 = conn
    .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
      row.get(0)
    })
    .expect("count refinery history rows");
  assert_eq!(migration_count, expected_migration_count);

  let sessions_table_exists: i64 = conn
    .query_row(
      "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(sessions_table_exists, 1);

  let old_runner_table_exists: i64 = conn
    .query_row(
      "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'schema_versions'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(old_runner_table_exists, 0);

  let mut stmt = conn
    .prepare("PRAGMA table_info(approval_history)")
    .expect("prepare pragma");
  let columns: Vec<String> = stmt
    .query_map([], |row| row.get::<_, String>(1))
    .expect("query columns")
    .filter_map(Result::ok)
    .collect();
  for expected in [
    "tool_input",
    "diff",
    "question",
    "question_prompts",
    "preview",
    "permission_suggestions",
    "permission_reason",
    "requested_permissions",
    "granted_permissions",
  ] {
    assert!(
      columns.iter().any(|column| column == expected),
      "expected approval_history to include column {expected}"
    );
  }

  let mut session_stmt = conn
    .prepare("PRAGMA table_info(sessions)")
    .expect("prepare sessions pragma");
  let session_columns: Vec<String> = session_stmt
    .query_map([], |row| row.get::<_, String>(1))
    .expect("query session columns")
    .filter_map(Result::ok)
    .collect();
  for expected in [
    "collaboration_mode",
    "personality",
    "service_tier",
    "developer_instructions",
    "last_progress_at",
    "allow_bypass_permissions",
  ] {
    assert!(
      session_columns.iter().any(|column| column == expected),
      "expected sessions to include column {expected}"
    );
  }

  let mut usage_ledger_stmt = conn
    .prepare("PRAGMA table_info(usage_ledger_entries)")
    .expect("prepare usage ledger pragma");
  let usage_ledger_columns: Vec<String> = usage_ledger_stmt
    .query_map([], |row| row.get::<_, String>(1))
    .expect("query usage ledger columns")
    .filter_map(Result::ok)
    .collect();
  for expected in [
    "pricing_source",
    "pricing_version",
    "pricing_model_key",
    "input_cost_per_token",
    "output_cost_per_token",
    "cache_read_cost_per_token",
    "cache_write_cost_per_token",
  ] {
    assert!(
      usage_ledger_columns.iter().any(|column| column == expected),
      "expected usage_ledger_entries to include column {expected}"
    );
  }

  let mut usage_turns_stmt = conn
    .prepare("PRAGMA table_info(usage_turns)")
    .expect("prepare usage turns pragma");
  let usage_turns_columns: Vec<String> = usage_turns_stmt
    .query_map([], |row| row.get::<_, String>(1))
    .expect("query usage turns columns")
    .filter_map(Result::ok)
    .collect();
  for expected in ["provider", "model"] {
    assert!(
      usage_turns_columns.iter().any(|column| column == expected),
      "expected usage_turns to include column {expected}"
    );
  }
}

#[test]
fn idempotent_migrations() {
  let mut conn = Connection::open_in_memory().expect("open in-memory db");
  run_migrations(&mut conn).expect("first run");
  run_migrations(&mut conn).expect("second run should be idempotent");
  let expected_migration_count =
    super::embedded::migrations::runner().get_migrations().len() as i64;

  let migration_count: i64 = conn
    .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
      row.get(0)
    })
    .expect("count refinery history rows");
  assert_eq!(migration_count, expected_migration_count);
}

#[test]
fn idempotent_migrations_preserve_usage_session_state_without_turns() {
  let mut conn = Connection::open_in_memory().expect("open in-memory db");
  run_migrations(&mut conn).expect("first run");

  conn
    .execute(
      "INSERT INTO sessions (
         id, provider, status, work_status, lifecycle_state, control_mode,
         codex_integration_mode, project_path, started_at, last_activity_at
       ) VALUES (
         ?1, 'codex', 'active', 'waiting', 'open', 'direct',
         'direct', '/tmp/orbitdock', '2026-04-26T10:00:00Z', '2026-04-26T10:00:00Z'
       )",
      ["session-1"],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_session_state (
         session_id, provider, codex_integration_mode, snapshot_kind,
         snapshot_input_tokens, snapshot_output_tokens, snapshot_cached_tokens,
         snapshot_context_window, lifetime_input_tokens, lifetime_output_tokens,
         lifetime_cached_tokens, context_input_tokens, context_cached_tokens,
         context_window, updated_at
       ) VALUES (
         ?1, 'codex', 'direct', 'lifetime_totals',
         10, 5, 2, 200000, 10, 5, 2, 10, 2, 200000, '2026-04-26T10:01:00Z'
       )",
      ["session-1"],
    )
    .expect("insert usage session state");

  run_migrations(&mut conn).expect("second run should be idempotent");

  let state_exists: bool = conn
    .query_row(
      "SELECT EXISTS(
         SELECT 1
         FROM usage_session_state
         WHERE session_id = 'session-1'
       )",
      [],
      |row| row.get::<_, i64>(0).map(|value| value == 1),
    )
    .expect("read usage session state");

  assert!(state_exists);
}

#[test]
fn direct_claude_owner_alias_must_be_unique() {
  let mut conn = Connection::open_in_memory().expect("open in-memory db");
  run_migrations(&mut conn).expect("migrations should succeed");

  conn
    .execute(
      "INSERT INTO sessions (
              id, provider, status, work_status, lifecycle_state, control_mode,
              claude_integration_mode, project_path, started_at, last_activity_at
           ) VALUES (
              ?1, 'claude', 'active', 'waiting', 'open', 'direct',
              'direct', '/tmp/alpha', '2026-03-26T10:00:00Z', '2026-03-26T10:00:00Z'
           )",
      ["od-direct-1"],
    )
    .expect("insert first direct Claude session");
  conn
    .execute(
      "UPDATE sessions SET claude_sdk_session_id = ?1 WHERE id = ?2",
      ["claude-sdk-1", "od-direct-1"],
    )
    .expect("assign first owner alias");

  conn
    .execute(
      "INSERT INTO sessions (
              id, provider, status, work_status, lifecycle_state, control_mode,
              claude_integration_mode, project_path, started_at, last_activity_at
           ) VALUES (
              ?1, 'claude', 'active', 'waiting', 'open', 'direct',
              'direct', '/tmp/beta', '2026-03-26T10:05:00Z', '2026-03-26T10:05:00Z'
           )",
      ["od-direct-2"],
    )
    .expect("insert second direct Claude session");

  let err = conn
    .execute(
      "UPDATE sessions SET claude_sdk_session_id = ?1 WHERE id = ?2",
      ["claude-sdk-1", "od-direct-2"],
    )
    .expect_err("duplicate direct owner alias should be rejected");

  assert!(
    err
      .to_string()
      .contains("claude direct session owner already exists"),
    "unexpected error: {err}"
  );
}

#[test]
fn backfills_last_progress_at_from_last_activity_at() {
  let conn = Connection::open_in_memory().expect("open in-memory db");
  conn
    .execute_batch(
      "CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              last_activity_at TEXT
          );
          INSERT INTO sessions (id, last_activity_at) VALUES ('session-1', '123Z');",
    )
    .expect("seed pre-migration schema");

  conn
    .execute_batch(include_str!(
      "../../../../migrations/V033__last_progress_at.sql"
    ))
    .expect("apply V033 migration");

  let last_progress_at: Option<String> = conn
    .query_row(
      "SELECT last_progress_at FROM sessions WHERE id = 'session-1'",
      [],
      |row| row.get(0),
    )
    .expect("read progress timestamp");

  assert_eq!(last_progress_at.as_deref(), Some("123Z"));
}

#[test]
fn post_v042_vacuum_runs_only_when_newly_applied_or_columns_dropped() {
  assert!(should_run_post_v042_vacuum(false, true, false));
  assert!(should_run_post_v042_vacuum(true, true, true));
  assert!(!should_run_post_v042_vacuum(true, true, false));
  assert!(!should_run_post_v042_vacuum(false, false, false));
}
