use super::usage_kind::snapshot_kind_from_str;
use super::usage_writes::recompute_all_usage_ledgers;
use super::*;

pub(crate) fn rebuild_usage_session_state(conn: &Connection) -> Result<(), rusqlite::Error> {
  if !query_exists(
    conn,
    "SELECT 1
       FROM sqlite_master
       WHERE type = 'table' AND name = 'usage_session_state'",
  )? {
    return Ok(());
  }

  conn.execute("DELETE FROM usage_session_state", [])?;

  let session_ids = conn
    .prepare("SELECT DISTINCT session_id FROM usage_turns")?
    .query_map([], |row| row.get::<_, String>(0))?
    .collect::<Result<Vec<_>, _>>()?;

  for session_id in session_ids {
    let session_meta: Option<(String, Option<String>, Option<String>)> = conn
      .query_row(
        "SELECT COALESCE(provider, 'claude'), codex_integration_mode, claude_integration_mode
         FROM sessions
         WHERE id = ?1",
        params![&session_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
      )
      .optional()?;
    let Some((provider, codex_mode, claude_mode)) = session_meta else {
      continue;
    };

    let latest_turn: Option<(String, i64, i64, i64, i64)> = conn
      .query_row(
        "SELECT snapshot_kind, input_tokens, output_tokens, cached_tokens, context_window
         FROM usage_turns
         WHERE session_id = ?1
         ORDER BY turn_seq DESC, rowid DESC
         LIMIT 1",
        params![&session_id],
        |row| {
          Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
          ))
        },
      )
      .optional()?;
    let Some((
      snapshot_kind,
      snapshot_input_tokens,
      snapshot_output_tokens,
      snapshot_cached_tokens,
      snapshot_context_window,
    )) = latest_turn
    else {
      continue;
    };

    let (lifetime_input_tokens, lifetime_output_tokens, lifetime_cached_tokens): (i64, i64, i64) =
      conn.query_row(
        "SELECT
         COALESCE(SUM(billable_input_tokens), 0),
         COALESCE(SUM(billable_output_tokens), 0),
         COALESCE(SUM(cache_read_tokens), 0)
       FROM usage_ledger_entries
       WHERE session_id = ?1",
        params![&session_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
      )?;

    let snapshot_kind_enum = snapshot_kind_from_str(Some(snapshot_kind.as_str()));
    let (context_input_tokens, context_cached_tokens) = match snapshot_kind_enum {
      TokenUsageSnapshotKind::CompactionReset => (0, 0),
      _ => (snapshot_input_tokens, snapshot_cached_tokens),
    };

    conn.execute(
      "INSERT INTO usage_session_state (
         session_id,
         provider,
         codex_integration_mode,
         claude_integration_mode,
         snapshot_kind,
         snapshot_input_tokens,
         snapshot_output_tokens,
         snapshot_cached_tokens,
         snapshot_context_window,
         lifetime_input_tokens,
         lifetime_output_tokens,
         lifetime_cached_tokens,
         context_input_tokens,
         context_cached_tokens,
         context_window,
         updated_at
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
      params![
        &session_id,
        provider,
        codex_mode,
        claude_mode,
        snapshot_kind,
        snapshot_input_tokens,
        snapshot_output_tokens,
        snapshot_cached_tokens,
        snapshot_context_window,
        lifetime_input_tokens,
        lifetime_output_tokens,
        lifetime_cached_tokens,
        context_input_tokens,
        context_cached_tokens,
        snapshot_context_window,
        chrono_now(),
      ],
    )?;
  }

  Ok(())
}

pub(crate) fn usage_accounting_repair_needed(conn: &Connection) -> Result<bool, rusqlite::Error> {
  if query_exists(
    conn,
    "SELECT 1
       FROM usage_turns
       WHERE provider IS NULL
          OR trim(provider) = ''
          OR model IS NULL",
  )? {
    return Ok(true);
  }

  if query_exists(
    conn,
    "SELECT 1
       FROM usage_turns ut
       LEFT JOIN usage_ledger_entries ule
         ON ule.session_id = ut.session_id
        AND ule.turn_id = ut.turn_id
       WHERE ule.turn_id IS NULL",
  )? {
    return Ok(true);
  }

  if query_exists(
    conn,
    "SELECT 1
       FROM usage_ledger_entries
       WHERE pricing_model_key IS NULL
          OR input_cost_per_token = 0
          OR output_cost_per_token = 0",
  )? {
    return Ok(true);
  }

  if query_exists(
    conn,
    "SELECT 1
       FROM usage_turns ut
       JOIN usage_ledger_entries ule
         ON ule.session_id = ut.session_id
        AND ule.turn_id = ut.turn_id
      WHERE COALESCE(NULLIF(ule.observed_at, ''), '') != COALESCE(NULLIF(ut.created_at, ''), '')",
  )? {
    return Ok(true);
  }

  query_exists(
    conn,
    "SELECT 1
       FROM usage_turns ut
       LEFT JOIN usage_session_state uss
         ON uss.session_id = ut.session_id
       WHERE uss.session_id IS NULL",
  )
}

pub(crate) fn repair_usage_accounting_if_needed(conn: &Connection) -> Result<(), rusqlite::Error> {
  if !usage_accounting_tables_exist(conn)? {
    return Ok(());
  }

  if !usage_accounting_repair_needed(conn)? {
    return Ok(());
  }

  repair_usage_accounting(conn)
}

pub(crate) fn repair_usage_accounting(conn: &Connection) -> Result<(), rusqlite::Error> {
  if !usage_accounting_tables_exist(conn)? {
    return Ok(());
  }

  conn.execute(
    "UPDATE usage_turns
     SET provider = COALESCE(NULLIF(provider, ''), (
           SELECT COALESCE(s.provider, 'claude')
           FROM sessions s
           WHERE s.id = usage_turns.session_id
         )),
         model = COALESCE(model, (
           SELECT s.model
           FROM sessions s
           WHERE s.id = usage_turns.session_id
         ))
     WHERE provider IS NULL
       OR trim(provider) = ''
       OR model IS NULL",
    [],
  )?;

  recompute_all_usage_ledgers(conn)?;
  rebuild_usage_session_state(conn)
}

fn usage_accounting_tables_exist(conn: &Connection) -> Result<bool, rusqlite::Error> {
  if !query_exists(
    conn,
    "SELECT 1
       FROM sqlite_master
       WHERE type = 'table' AND name = 'usage_turns'",
  )? {
    return Ok(false);
  }

  query_exists(
    conn,
    "SELECT 1
       FROM sqlite_master
       WHERE type = 'table' AND name = 'usage_ledger_entries'",
  )
}

fn query_exists(conn: &Connection, sql: &str) -> Result<bool, rusqlite::Error> {
  conn.query_row(&format!("SELECT EXISTS({sql})"), [], |row| {
    row.get::<_, i64>(0).map(|value| value == 1)
  })
}
