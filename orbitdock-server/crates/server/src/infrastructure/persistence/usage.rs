use super::*;
use crate::infrastructure::usage_pricing::{estimate_cost_usd, pricing_snapshot};

pub(super) fn snapshot_kind_to_str(kind: TokenUsageSnapshotKind) -> &'static str {
  match kind {
    TokenUsageSnapshotKind::Unknown => "unknown",
    TokenUsageSnapshotKind::ContextTurn => "context_turn",
    TokenUsageSnapshotKind::LifetimeTotals => "lifetime_totals",
    TokenUsageSnapshotKind::Mixed => "mixed",
    TokenUsageSnapshotKind::CompactionReset => "compaction_reset",
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct NormalizedUsageLedgerEntry {
  pub billable_input_tokens: u64,
  pub billable_output_tokens: u64,
  pub cache_read_tokens: u64,
  pub cache_write_tokens: u64,
  pub context_input_tokens: u64,
  pub context_window: u64,
}

pub(crate) fn normalize_usage_for_ledger(
  previous: Option<&TokenUsage>,
  current: &TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> NormalizedUsageLedgerEntry {
  let prev_input = previous.map(|usage| usage.input_tokens).unwrap_or(0);
  let prev_output = previous.map(|usage| usage.output_tokens).unwrap_or(0);
  let prev_cached = previous.map(|usage| usage.cached_tokens).unwrap_or(0);

  match snapshot_kind {
    TokenUsageSnapshotKind::ContextTurn => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens.saturating_sub(prev_input),
      billable_output_tokens: current.output_tokens,
      cache_read_tokens: current.cached_tokens.saturating_sub(prev_cached),
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens,
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::LifetimeTotals => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens.saturating_sub(prev_input),
      billable_output_tokens: current.output_tokens.saturating_sub(prev_output),
      cache_read_tokens: current.cached_tokens.saturating_sub(prev_cached),
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens,
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::Mixed => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens,
      billable_output_tokens: current.output_tokens,
      cache_read_tokens: current.cached_tokens,
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens.saturating_add(current.cached_tokens),
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::CompactionReset => NormalizedUsageLedgerEntry {
      billable_input_tokens: 0,
      billable_output_tokens: current.output_tokens.saturating_sub(prev_output),
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      context_input_tokens: 0,
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::Unknown => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens,
      billable_output_tokens: current.output_tokens,
      cache_read_tokens: current.cached_tokens,
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens,
      context_window: current.context_window,
    },
  }
}

pub(crate) fn snapshot_kind_from_str(kind: Option<&str>) -> TokenUsageSnapshotKind {
  match kind {
    Some("context_turn") => TokenUsageSnapshotKind::ContextTurn,
    Some("lifetime_totals") => TokenUsageSnapshotKind::LifetimeTotals,
    Some("mixed") => TokenUsageSnapshotKind::Mixed,
    Some("mixed_legacy") => TokenUsageSnapshotKind::Mixed,
    Some("compaction_reset") => TokenUsageSnapshotKind::CompactionReset,
    _ => TokenUsageSnapshotKind::Unknown,
  }
}

pub(super) fn persist_usage_event(
  conn: &Connection,
  session_id: &str,
  usage: &TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "INSERT INTO usage_events (
            session_id,
            observed_at,
            snapshot_kind,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    params![
      session_id,
      chrono_now(),
      snapshot_kind_to_str(snapshot_kind),
      usage.input_tokens as i64,
      usage.output_tokens as i64,
      usage.cached_tokens as i64,
      usage.context_window as i64,
    ],
  )?;
  Ok(())
}

pub(super) fn upsert_usage_session_state(
  conn: &Connection,
  session_id: &str,
  usage: &TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
  let session_meta: Option<(String, Option<String>, Option<String>)> = conn
    .query_row(
      "SELECT COALESCE(provider, 'claude'), codex_integration_mode, claude_integration_mode
             FROM sessions
             WHERE id = ?1",
      params![session_id],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .optional()?;
  let (provider, codex_mode, claude_mode) =
    session_meta.unwrap_or(("claude".to_string(), None, None));

  let existing: Option<(i64, i64, i64, i64, i64, i64)> = conn
    .query_row(
      "SELECT
                lifetime_input_tokens,
                lifetime_output_tokens,
                lifetime_cached_tokens,
                context_input_tokens,
                context_cached_tokens,
                context_window
             FROM usage_session_state
             WHERE session_id = ?1",
      params![session_id],
      |row| {
        Ok((
          row.get(0)?,
          row.get(1)?,
          row.get(2)?,
          row.get(3)?,
          row.get(4)?,
          row.get(5)?,
        ))
      },
    )
    .optional()?;

  let usage_input = usage.input_tokens as i64;
  let usage_output = usage.output_tokens as i64;
  let usage_cached = usage.cached_tokens as i64;
  let usage_window = usage.context_window as i64;

  let (
    mut lifetime_input,
    mut lifetime_output,
    mut lifetime_cached,
    mut context_input,
    mut context_cached,
    mut context_window,
  ) = if let Some(values) = existing {
    values
  } else {
    (
      usage_input,
      usage_output,
      usage_cached,
      usage_input,
      usage_cached,
      usage_window,
    )
  };

  match snapshot_kind {
    TokenUsageSnapshotKind::Unknown => {}
    TokenUsageSnapshotKind::ContextTurn => {
      context_input = usage_input;
      context_cached = usage_cached;
      context_window = usage_window;
    }
    TokenUsageSnapshotKind::LifetimeTotals => {
      lifetime_input = usage_input;
      lifetime_output = usage_output;
      lifetime_cached = usage_cached;
      context_input = usage_input;
      context_cached = usage_cached;
      context_window = usage_window;
    }
    TokenUsageSnapshotKind::Mixed => {
      // Context values are per-call (for context fill display).
      context_input = usage_input;
      context_cached = usage_cached;
      context_window = usage_window;
      // Input and cached are per-call — accumulate into lifetime totals.
      // Output is already accumulated in the transition layer.
      lifetime_input += usage_input;
      lifetime_output = usage_output;
      lifetime_cached += usage_cached;
    }
    TokenUsageSnapshotKind::CompactionReset => {
      // Context resets (compaction clears context), but lifetime totals persist.
      context_input = 0;
      context_cached = 0;
      context_window = usage_window;
      lifetime_input = lifetime_input.max(usage_input);
      lifetime_output = lifetime_output.max(usage_output);
      lifetime_cached = lifetime_cached.max(usage_cached);
    }
  }

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
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        ON CONFLICT(session_id) DO UPDATE SET
            provider = excluded.provider,
            codex_integration_mode = excluded.codex_integration_mode,
            claude_integration_mode = excluded.claude_integration_mode,
            snapshot_kind = excluded.snapshot_kind,
            snapshot_input_tokens = excluded.snapshot_input_tokens,
            snapshot_output_tokens = excluded.snapshot_output_tokens,
            snapshot_cached_tokens = excluded.snapshot_cached_tokens,
            snapshot_context_window = excluded.snapshot_context_window,
            lifetime_input_tokens = excluded.lifetime_input_tokens,
            lifetime_output_tokens = excluded.lifetime_output_tokens,
            lifetime_cached_tokens = excluded.lifetime_cached_tokens,
            context_input_tokens = excluded.context_input_tokens,
            context_cached_tokens = excluded.context_cached_tokens,
            context_window = excluded.context_window,
            updated_at = excluded.updated_at",
    params![
      session_id,
      provider,
      codex_mode,
      claude_mode,
      snapshot_kind_to_str(snapshot_kind),
      usage_input,
      usage_output,
      usage_cached,
      usage_window,
      lifetime_input,
      lifetime_output,
      lifetime_cached,
      context_input,
      context_cached,
      context_window,
      chrono_now(),
    ],
  )?;

  Ok(())
}

pub(super) struct TurnSnapshotRow<'a> {
  pub session_id: &'a str,
  pub turn_id: &'a str,
  pub turn_seq: u64,
  pub provider: &'a str,
  pub model: Option<&'a str>,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub context_window: u64,
  pub snapshot_kind: TokenUsageSnapshotKind,
}

pub(super) fn upsert_usage_turn_snapshot(
  conn: &Connection,
  row: &TurnSnapshotRow<'_>,
) -> Result<(), rusqlite::Error> {
  let TurnSnapshotRow {
    session_id,
    turn_id,
    turn_seq,
    provider,
    model,
    input_tokens,
    output_tokens,
    cached_tokens,
    context_window,
    snapshot_kind,
  } = row;

  let previous_input: i64 = conn
    .query_row(
      "SELECT input_tokens
             FROM usage_turns
             WHERE session_id = ?1 AND turn_seq < ?2
             ORDER BY turn_seq DESC, rowid DESC
             LIMIT 1",
      params![session_id, *turn_seq as i64],
      |row| row.get(0),
    )
    .optional()?
    .unwrap_or(0);

  let input_tokens_i64 = *input_tokens as i64;
  let input_delta_tokens = (input_tokens_i64 - previous_input).max(0);

  conn.execute(
    "INSERT INTO usage_turns (
            session_id,
            turn_id,
            turn_seq,
            provider,
            model,
            snapshot_kind,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            input_delta_tokens,
            created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
        ON CONFLICT(session_id, turn_id) DO UPDATE SET
            turn_seq = excluded.turn_seq,
            provider = excluded.provider,
            model = excluded.model,
            snapshot_kind = excluded.snapshot_kind,
            input_tokens = excluded.input_tokens,
            output_tokens = excluded.output_tokens,
            cached_tokens = excluded.cached_tokens,
            context_window = excluded.context_window,
            input_delta_tokens = excluded.input_delta_tokens,
            created_at = excluded.created_at",
    params![
      session_id,
      turn_id,
      *turn_seq as i64,
      provider,
      model,
      snapshot_kind_to_str(*snapshot_kind),
      *input_tokens as i64,
      *output_tokens as i64,
      *cached_tokens as i64,
      *context_window as i64,
      input_delta_tokens,
      chrono_now(),
    ],
  )?;

  Ok(())
}

#[derive(Debug)]
struct StoredTurnUsageSnapshot {
  turn_id: String,
  turn_seq: u64,
  provider: String,
  model: Option<String>,
  created_at: String,
  usage: TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
}

pub(super) fn recompute_usage_ledger_for_session(
  conn: &Connection,
  session_id: &str,
) -> Result<(), rusqlite::Error> {
  let session_started_at: Option<String> = conn.query_row(
    "SELECT started_at
       FROM sessions
       WHERE id = ?1",
    params![session_id],
    |row| row.get(0),
  )?;

  let turns = conn
    .prepare(
      "SELECT turn_id, turn_seq, provider, model, created_at, input_tokens, output_tokens, cached_tokens, context_window, snapshot_kind
       FROM usage_turns
       WHERE session_id = ?1
       ORDER BY turn_seq ASC, rowid ASC",
    )?
    .query_map(params![session_id], |row| {
      let snapshot_kind: String = row.get(9)?;
      Ok(StoredTurnUsageSnapshot {
        turn_id: row.get(0)?,
        turn_seq: row.get::<_, i64>(1)?.max(0) as u64,
        provider: row.get(2)?,
        model: row.get(3)?,
        created_at: row.get(4)?,
        usage: TokenUsage {
          input_tokens: row.get::<_, i64>(5)?.max(0) as u64,
          output_tokens: row.get::<_, i64>(6)?.max(0) as u64,
          cached_tokens: row.get::<_, i64>(7)?.max(0) as u64,
          context_window: row.get::<_, i64>(8)?.max(0) as u64,
        },
        snapshot_kind: snapshot_kind_from_str(Some(snapshot_kind.as_str())),
      })
    })?
    .collect::<Result<Vec<_>, _>>()?;

  conn.execute(
    "DELETE FROM usage_ledger_entries
     WHERE session_id = ?1
       AND NOT EXISTS (
         SELECT 1
         FROM usage_turns ut
         WHERE ut.session_id = usage_ledger_entries.session_id
           AND ut.turn_id = usage_ledger_entries.turn_id
       )",
    params![session_id],
  )?;

  let mut previous_usage: Option<TokenUsage> = None;
  for turn in turns {
    let normalized =
      normalize_usage_for_ledger(previous_usage.as_ref(), &turn.usage, turn.snapshot_kind);
    let provider_enum = turn
      .provider
      .parse()
      .unwrap_or(orbitdock_protocol::Provider::Claude);
    let pricing = pricing_snapshot(provider_enum, turn.model.as_deref());
    let estimated_cost_usd = estimate_cost_usd(
      &pricing,
      normalized.billable_input_tokens,
      normalized.billable_output_tokens,
      normalized.cache_read_tokens,
      normalized.cache_write_tokens,
    );

    conn.execute(
      "INSERT INTO usage_ledger_entries (
        session_id,
        turn_id,
        turn_seq,
        provider,
        model,
        session_started_at,
        observed_at,
        snapshot_kind,
        billable_input_tokens,
        billable_output_tokens,
        cache_read_tokens,
        cache_write_tokens,
        context_input_tokens,
        context_window,
        estimated_cost_usd,
        pricing_source,
        pricing_version,
        pricing_model_key,
        input_cost_per_token,
        output_cost_per_token,
        cache_read_cost_per_token,
        cache_write_cost_per_token
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
      ON CONFLICT(session_id, turn_id) DO UPDATE SET
        turn_seq = excluded.turn_seq,
        provider = excluded.provider,
        model = excluded.model,
        session_started_at = excluded.session_started_at,
        observed_at = excluded.observed_at,
        snapshot_kind = excluded.snapshot_kind,
        billable_input_tokens = excluded.billable_input_tokens,
        billable_output_tokens = excluded.billable_output_tokens,
        cache_read_tokens = excluded.cache_read_tokens,
        cache_write_tokens = excluded.cache_write_tokens,
        context_input_tokens = excluded.context_input_tokens,
        context_window = excluded.context_window,
        estimated_cost_usd = excluded.estimated_cost_usd,
        pricing_source = excluded.pricing_source,
        pricing_version = excluded.pricing_version,
        pricing_model_key = excluded.pricing_model_key,
        input_cost_per_token = excluded.input_cost_per_token,
        output_cost_per_token = excluded.output_cost_per_token,
        cache_read_cost_per_token = excluded.cache_read_cost_per_token,
        cache_write_cost_per_token = excluded.cache_write_cost_per_token",
      params![
        session_id,
        &turn.turn_id,
        turn.turn_seq as i64,
        &turn.provider,
        &turn.model,
        &session_started_at,
        &turn.created_at,
        snapshot_kind_to_str(turn.snapshot_kind),
        normalized.billable_input_tokens as i64,
        normalized.billable_output_tokens as i64,
        normalized.cache_read_tokens as i64,
        normalized.cache_write_tokens as i64,
        normalized.context_input_tokens as i64,
        normalized.context_window as i64,
        estimated_cost_usd,
        pricing.source,
        pricing.version,
        &pricing.model_key,
        pricing.input_cost_per_token,
        pricing.output_cost_per_token,
        pricing.cache_read_cost_per_token,
        pricing.cache_write_cost_per_token,
      ],
    )?;
    previous_usage = Some(turn.usage);
  }

  Ok(())
}

pub(crate) fn recompute_all_usage_ledgers(conn: &Connection) -> Result<(), rusqlite::Error> {
  let session_ids = conn
    .prepare("SELECT DISTINCT session_id FROM usage_turns")?
    .query_map([], |row| row.get::<_, String>(0))?
    .collect::<Result<Vec<_>, _>>()?;

  for session_id in session_ids {
    recompute_usage_ledger_for_session(conn, &session_id)?;
  }

  Ok(())
}

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

fn usage_accounting_repair_needed(conn: &Connection) -> Result<bool, rusqlite::Error> {
  if query_exists(
    conn,
    "SELECT 1
       FROM usage_turns
       WHERE snapshot_kind = 'mixed_legacy'",
  )? {
    return Ok(true);
  }

  if query_exists(
    conn,
    "SELECT 1
       FROM usage_ledger_entries
       WHERE snapshot_kind = 'mixed_legacy'",
  )? {
    return Ok(true);
  }

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
     SET snapshot_kind = 'mixed'
     WHERE snapshot_kind = 'mixed_legacy'",
    [],
  )?;
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
  conn.execute(
    "UPDATE usage_ledger_entries
     SET snapshot_kind = 'mixed'
     WHERE snapshot_kind = 'mixed_legacy'",
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

#[cfg(test)]
mod tests {
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
}
