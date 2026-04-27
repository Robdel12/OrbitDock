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

#[cfg(test)]
#[path = "usage_tests.rs"]
mod tests;
