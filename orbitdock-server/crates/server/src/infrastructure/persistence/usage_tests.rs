use super::*;
fn create_usage_ledger_test_schema(conn: &Connection) {
  conn
    .execute_batch(
      "CREATE TABLE sessions (
           id TEXT PRIMARY KEY,
           provider TEXT,
           model TEXT,
           codex_integration_mode TEXT,
           claude_integration_mode TEXT,
           started_at TEXT
         );
         CREATE TABLE usage_turns (
           session_id TEXT NOT NULL,
           turn_id TEXT NOT NULL,
           turn_seq INTEGER NOT NULL,
           provider TEXT NOT NULL DEFAULT 'claude',
           model TEXT,
           snapshot_kind TEXT NOT NULL,
           input_tokens INTEGER NOT NULL DEFAULT 0,
           output_tokens INTEGER NOT NULL DEFAULT 0,
           cached_tokens INTEGER NOT NULL DEFAULT 0,
           context_window INTEGER NOT NULL DEFAULT 0,
           input_delta_tokens INTEGER NOT NULL DEFAULT 0,
           created_at TEXT NOT NULL,
           PRIMARY KEY (session_id, turn_id)
         );
         CREATE TABLE usage_ledger_entries (
           session_id TEXT NOT NULL,
           turn_id TEXT NOT NULL,
           turn_seq INTEGER NOT NULL DEFAULT 0,
           provider TEXT NOT NULL,
           model TEXT,
           session_started_at TEXT,
           observed_at TEXT NOT NULL,
           snapshot_kind TEXT NOT NULL,
           billable_input_tokens INTEGER NOT NULL DEFAULT 0,
           billable_output_tokens INTEGER NOT NULL DEFAULT 0,
           cache_read_tokens INTEGER NOT NULL DEFAULT 0,
           cache_write_tokens INTEGER NOT NULL DEFAULT 0,
           context_input_tokens INTEGER NOT NULL DEFAULT 0,
           context_window INTEGER NOT NULL DEFAULT 0,
           estimated_cost_usd REAL NOT NULL DEFAULT 0,
           pricing_source TEXT NOT NULL DEFAULT 'orbitdock_builtin',
           pricing_version TEXT NOT NULL DEFAULT '2026-04-backbone-v1',
           pricing_model_key TEXT,
           input_cost_per_token REAL NOT NULL DEFAULT 0,
           output_cost_per_token REAL NOT NULL DEFAULT 0,
           cache_read_cost_per_token REAL NOT NULL DEFAULT 0,
           cache_write_cost_per_token REAL NOT NULL DEFAULT 0,
           PRIMARY KEY (session_id, turn_id)
         );
         CREATE TABLE usage_session_state (
           session_id TEXT PRIMARY KEY,
           provider TEXT NOT NULL,
           codex_integration_mode TEXT,
           claude_integration_mode TEXT,
           snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
           snapshot_input_tokens INTEGER NOT NULL DEFAULT 0,
           snapshot_output_tokens INTEGER NOT NULL DEFAULT 0,
           snapshot_cached_tokens INTEGER NOT NULL DEFAULT 0,
           snapshot_context_window INTEGER NOT NULL DEFAULT 0,
           lifetime_input_tokens INTEGER NOT NULL DEFAULT 0,
           lifetime_output_tokens INTEGER NOT NULL DEFAULT 0,
           lifetime_cached_tokens INTEGER NOT NULL DEFAULT 0,
           context_input_tokens INTEGER NOT NULL DEFAULT 0,
           context_cached_tokens INTEGER NOT NULL DEFAULT 0,
           context_window INTEGER NOT NULL DEFAULT 0,
           updated_at TEXT NOT NULL
         );",
    )
    .expect("create usage schema");
}

fn insert_usage_turn(
  conn: &Connection,
  turn_id: &str,
  turn_seq: u64,
  input_tokens: u64,
  output_tokens: u64,
  cached_tokens: u64,
) {
  let row = TurnSnapshotRow {
    session_id: "session-1",
    turn_id,
    turn_seq,
    provider: "codex",
    model: Some("gpt-5.4"),
    input_tokens,
    output_tokens,
    cached_tokens,
    context_window: 200_000,
    snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
  };
  upsert_usage_turn_snapshot(conn, &row).expect("upsert usage turn");
  recompute_usage_ledger_for_session(conn, "session-1").expect("recompute usage ledger");
}

#[test]
fn ledger_recompute_handles_out_of_order_lifetime_turns() {
  let conn = Connection::open_in_memory().expect("open sqlite");
  create_usage_ledger_test_schema(&conn);
  conn
    .execute(
      "INSERT INTO sessions (id, provider, model, started_at) VALUES (?1, ?2, ?3, ?4)",
      params!["session-1", "codex", "gpt-5.4", "2026-04-22T00:00:00Z"],
    )
    .expect("insert session");

  insert_usage_turn(&conn, "turn-1", 1, 100, 10, 50);
  insert_usage_turn(&conn, "turn-3", 3, 300, 30, 150);
  insert_usage_turn(&conn, "turn-2", 2, 180, 18, 90);

  let rows = conn
    .prepare(
      "SELECT turn_id, billable_input_tokens, billable_output_tokens, cache_read_tokens, pricing_source, pricing_version, pricing_model_key
         FROM usage_ledger_entries
         WHERE session_id = 'session-1'
         ORDER BY turn_seq",
    )
    .and_then(|mut stmt| {
      let rows = stmt.query_map([], |row| {
        Ok((
          row.get::<_, String>(0)?,
          row.get::<_, i64>(1)?,
          row.get::<_, i64>(2)?,
          row.get::<_, i64>(3)?,
          row.get::<_, String>(4)?,
          row.get::<_, String>(5)?,
          row.get::<_, Option<String>>(6)?,
        ))
      })?;
      rows.collect::<Result<Vec<_>, _>>()
    })
    .expect("read ledger rows");

  assert_eq!(
    rows,
    vec![
      (
        "turn-1".to_string(),
        100,
        10,
        50,
        "orbitdock_builtin".to_string(),
        "2026-04-backbone-v1".to_string(),
        Some("gpt-5".to_string()),
      ),
      (
        "turn-2".to_string(),
        80,
        8,
        40,
        "orbitdock_builtin".to_string(),
        "2026-04-backbone-v1".to_string(),
        Some("gpt-5".to_string()),
      ),
      (
        "turn-3".to_string(),
        120,
        12,
        60,
        "orbitdock_builtin".to_string(),
        "2026-04-backbone-v1".to_string(),
        Some("gpt-5".to_string()),
      ),
    ]
  );
}

#[test]
fn repair_usage_accounting_backfills_missing_ledger_rows_and_normalizes_legacy_kinds() {
  let conn = Connection::open_in_memory().expect("open sqlite");
  create_usage_ledger_test_schema(&conn);
  conn
    .execute(
      "INSERT INTO sessions (id, provider, model, started_at) VALUES (?1, ?2, ?3, ?4)",
      params![
        "session-1",
        "claude",
        "claude-sonnet-4",
        "2026-03-29T00:00:00Z"
      ],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_turns (
           session_id, turn_id, turn_seq, provider, model, snapshot_kind, input_tokens, output_tokens, cached_tokens, context_window, input_delta_tokens, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
      params![
        "session-1",
        "turn-1",
        1_i64,
        "claude",
        "claude-sonnet-4",
        "mixed_legacy",
        100_i64,
        20_i64,
        40_i64,
        200_000_i64,
        100_i64,
        "2026-03-29T00:05:00Z",
      ],
    )
    .expect("insert legacy turn");

  repair_usage_accounting(&conn).expect("repair usage accounting");

  let row = conn
    .query_row(
      "SELECT
           ule.snapshot_kind,
           ule.pricing_source,
           ule.pricing_version,
           ule.pricing_model_key,
           ule.billable_input_tokens,
           ule.billable_output_tokens,
           ule.cache_read_tokens,
           uss.snapshot_input_tokens,
           uss.snapshot_output_tokens,
           uss.snapshot_cached_tokens
         FROM usage_ledger_entries ule
         JOIN usage_session_state uss ON uss.session_id = ule.session_id
         WHERE ule.session_id = ?1 AND ule.turn_id = ?2",
      params!["session-1", "turn-1"],
      |row| {
        Ok((
          row.get::<_, String>(0)?,
          row.get::<_, String>(1)?,
          row.get::<_, String>(2)?,
          row.get::<_, Option<String>>(3)?,
          row.get::<_, i64>(4)?,
          row.get::<_, i64>(5)?,
          row.get::<_, i64>(6)?,
          row.get::<_, i64>(7)?,
          row.get::<_, i64>(8)?,
          row.get::<_, i64>(9)?,
        ))
      },
    )
    .expect("read repaired ledger row");

  assert_eq!(
    row,
    (
      "mixed".to_string(),
      "orbitdock_builtin".to_string(),
      "2026-04-backbone-v1".to_string(),
      Some("claude-sonnet-4".to_string()),
      100,
      20,
      40,
      100,
      20,
      40,
    )
  );
}

#[test]
fn repair_usage_accounting_restores_original_turn_timestamps_in_ledger() {
  let conn = Connection::open_in_memory().expect("open sqlite");
  create_usage_ledger_test_schema(&conn);
  conn
    .execute(
      "INSERT INTO sessions (id, provider, model, started_at) VALUES (?1, ?2, ?3, ?4)",
      params!["session-1", "codex", "gpt-5.4", "2026-03-29T00:00:00Z"],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_turns (
           session_id, turn_id, turn_seq, provider, model, snapshot_kind, input_tokens, output_tokens, cached_tokens, context_window, input_delta_tokens, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
      params![
        "session-1",
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "lifetime_totals",
        100_i64,
        20_i64,
        10_i64,
        200_000_i64,
        100_i64,
        "2026-03-29T00:05:00Z",
      ],
    )
    .expect("insert usage turn");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
           session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
           snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
           cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd,
           pricing_source, pricing_version, pricing_model_key, input_cost_per_token,
           output_cost_per_token, cache_read_cost_per_token, cache_write_cost_per_token
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)",
      params![
        "session-1",
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "2026-03-29T00:00:00Z",
        "2026-04-26T18:08:32Z",
        "lifetime_totals",
        100_i64,
        20_i64,
        10_i64,
        0_i64,
        100_i64,
        200_000_i64,
        0.25_f64,
        "orbitdock_builtin",
        "2026-04-backbone-v1",
        "gpt-5.4",
        0.0_f64,
        0.0_f64,
        0.0_f64,
        0.0_f64,
      ],
    )
    .expect("insert stale ledger row");

  assert!(usage_accounting_repair_needed(&conn).expect("detect repair need"));

  repair_usage_accounting(&conn).expect("repair usage accounting");

  let observed_at: String = conn
    .query_row(
      "SELECT observed_at
         FROM usage_ledger_entries
         WHERE session_id = ?1 AND turn_id = ?2",
      params!["session-1", "turn-1"],
      |row| row.get(0),
    )
    .expect("read repaired observed_at");

  assert_eq!(observed_at, "2026-03-29T00:05:00Z");
}

#[test]
fn ledger_recompute_preserves_turn_level_model_snapshots_when_session_model_changes() {
  let conn = Connection::open_in_memory().expect("open sqlite");
  create_usage_ledger_test_schema(&conn);
  conn
    .execute(
      "INSERT INTO sessions (id, provider, model, started_at) VALUES (?1, ?2, ?3, ?4)",
      params![
        "session-1",
        "claude",
        "claude-opus-4",
        "2026-04-22T00:00:00Z"
      ],
    )
    .expect("insert session");

  upsert_usage_turn_snapshot(
    &conn,
    &TurnSnapshotRow {
      session_id: "session-1",
      turn_id: "turn-1",
      turn_seq: 1,
      provider: "claude",
      model: Some("claude-sonnet-4"),
      input_tokens: 100,
      output_tokens: 20,
      cached_tokens: 10,
      context_window: 200_000,
      snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
    },
  )
  .expect("insert first turn");
  upsert_usage_turn_snapshot(
    &conn,
    &TurnSnapshotRow {
      session_id: "session-1",
      turn_id: "turn-2",
      turn_seq: 2,
      provider: "claude",
      model: Some("claude-opus-4"),
      input_tokens: 160,
      output_tokens: 40,
      cached_tokens: 20,
      context_window: 200_000,
      snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
    },
  )
  .expect("insert second turn");

  recompute_usage_ledger_for_session(&conn, "session-1").expect("recompute usage ledger");

  let rows = conn
    .prepare(
      "SELECT turn_id, model, pricing_model_key
         FROM usage_ledger_entries
         WHERE session_id = 'session-1'
         ORDER BY turn_seq",
    )
    .and_then(|mut stmt| {
      let rows = stmt.query_map([], |row| {
        Ok((
          row.get::<_, String>(0)?,
          row.get::<_, Option<String>>(1)?,
          row.get::<_, Option<String>>(2)?,
        ))
      })?;
      rows.collect::<Result<Vec<_>, _>>()
    })
    .expect("read ledger rows");

  assert_eq!(
    rows,
    vec![
      (
        "turn-1".to_string(),
        Some("claude-sonnet-4".to_string()),
        Some("claude-sonnet-4".to_string()),
      ),
      (
        "turn-2".to_string(),
        Some("claude-opus-4".to_string()),
        Some("claude-opus-4".to_string()),
      ),
    ]
  );
}

#[test]
fn context_turn_normalization_uses_deltas_for_input_and_cache() {
  let previous = TokenUsage {
    input_tokens: 100,
    output_tokens: 20,
    cached_tokens: 80,
    context_window: 200_000,
  };
  let current = TokenUsage {
    input_tokens: 160,
    output_tokens: 12,
    cached_tokens: 96,
    context_window: 200_000,
  };

  let normalized = normalize_usage_for_ledger(
    Some(&previous),
    &current,
    TokenUsageSnapshotKind::ContextTurn,
  );

  assert_eq!(normalized.billable_input_tokens, 60);
  assert_eq!(normalized.cache_read_tokens, 16);
  assert_eq!(normalized.billable_output_tokens, 12);
}

#[test]
fn lifetime_totals_normalization_uses_output_deltas() {
  let previous = TokenUsage {
    input_tokens: 1_000,
    output_tokens: 100,
    cached_tokens: 200,
    context_window: 258_400,
  };
  let current = TokenUsage {
    input_tokens: 1_250,
    output_tokens: 140,
    cached_tokens: 260,
    context_window: 258_400,
  };

  let normalized = normalize_usage_for_ledger(
    Some(&previous),
    &current,
    TokenUsageSnapshotKind::LifetimeTotals,
  );

  assert_eq!(normalized.billable_input_tokens, 250);
  assert_eq!(normalized.billable_output_tokens, 40);
  assert_eq!(normalized.cache_read_tokens, 60);
}
