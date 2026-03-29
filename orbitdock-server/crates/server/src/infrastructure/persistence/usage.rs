use super::*;

pub(super) fn snapshot_kind_to_str(kind: TokenUsageSnapshotKind) -> &'static str {
  match kind {
    TokenUsageSnapshotKind::Unknown => "unknown",
    TokenUsageSnapshotKind::ContextTurn => "context_turn",
    TokenUsageSnapshotKind::LifetimeTotals => "lifetime_totals",
    TokenUsageSnapshotKind::MixedLegacy => "mixed_legacy",
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
    TokenUsageSnapshotKind::MixedLegacy => NormalizedUsageLedgerEntry {
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
    Some("mixed_legacy") => TokenUsageSnapshotKind::MixedLegacy,
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
    TokenUsageSnapshotKind::MixedLegacy => {
      context_input = usage_input;
      context_cached = usage_cached;
      context_window = usage_window;
      lifetime_output = lifetime_output.max(usage_output);
    }
    TokenUsageSnapshotKind::CompactionReset => {
      context_input = 0;
      context_cached = 0;
      context_window = usage_window;
      lifetime_output = lifetime_output.max(usage_output);
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
             WHERE session_id = ?1 AND turn_id != ?2
             ORDER BY turn_seq DESC, rowid DESC
             LIMIT 1",
      params![session_id, turn_id],
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
            snapshot_kind,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            input_delta_tokens,
            created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(session_id, turn_id) DO UPDATE SET
            turn_seq = excluded.turn_seq,
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

pub(super) fn upsert_usage_ledger_entry(
  conn: &Connection,
  row: &TurnSnapshotRow<'_>,
) -> Result<(), rusqlite::Error> {
  let TurnSnapshotRow {
    session_id,
    turn_id,
    turn_seq,
    input_tokens,
    output_tokens,
    cached_tokens,
    context_window,
    snapshot_kind,
  } = row;

  let current = TokenUsage {
    input_tokens: *input_tokens,
    output_tokens: *output_tokens,
    cached_tokens: *cached_tokens,
    context_window: *context_window,
  };

  let previous = conn
    .query_row(
      "SELECT input_tokens, output_tokens, cached_tokens, context_window
       FROM usage_turns
       WHERE session_id = ?1 AND turn_id != ?2
       ORDER BY turn_seq DESC, rowid DESC
       LIMIT 1",
      params![session_id, turn_id],
      |row| {
        Ok(TokenUsage {
          input_tokens: row.get::<_, i64>(0)?.max(0) as u64,
          output_tokens: row.get::<_, i64>(1)?.max(0) as u64,
          cached_tokens: row.get::<_, i64>(2)?.max(0) as u64,
          context_window: row.get::<_, i64>(3)?.max(0) as u64,
        })
      },
    )
    .optional()?;

  let normalized = normalize_usage_for_ledger(previous.as_ref(), &current, *snapshot_kind);
  let (provider, model, session_started_at): (String, Option<String>, Option<String>) = conn
    .query_row(
      "SELECT COALESCE(provider, 'claude'), model, started_at
       FROM sessions
       WHERE id = ?1",
      params![session_id],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;

  let estimated_cost_usd = estimate_cost_usd(
    provider.as_str(),
    model.as_deref(),
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
        estimated_cost_usd
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
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
        estimated_cost_usd = excluded.estimated_cost_usd",
    params![
      session_id,
      turn_id,
      *turn_seq as i64,
      provider,
      model,
      session_started_at,
      chrono_now(),
      snapshot_kind_to_str(*snapshot_kind),
      normalized.billable_input_tokens as i64,
      normalized.billable_output_tokens as i64,
      normalized.cache_read_tokens as i64,
      normalized.cache_write_tokens as i64,
      normalized.context_input_tokens as i64,
      normalized.context_window as i64,
      estimated_cost_usd,
    ],
  )?;

  Ok(())
}

pub(crate) fn estimate_cost_usd(
  provider: &str,
  model: Option<&str>,
  input_tokens: u64,
  output_tokens: u64,
  cache_read_tokens: u64,
  cache_write_tokens: u64,
) -> f64 {
  let pricing = estimate_model_pricing(provider, model);
  input_tokens as f64 * pricing.input_per_token
    + output_tokens as f64 * pricing.output_per_token
    + cache_read_tokens as f64 * pricing.cache_read_per_token
    + cache_write_tokens as f64 * pricing.cache_write_per_token
}

struct Pricing {
  input_per_token: f64,
  output_per_token: f64,
  cache_read_per_token: f64,
  cache_write_per_token: f64,
}

fn estimate_model_pricing(provider: &str, model: Option<&str>) -> Pricing {
  let normalized = model.unwrap_or_default().to_ascii_lowercase();

  if normalized.contains("opus") {
    return Pricing {
      input_per_token: 15.0 / 1_000_000.0,
      output_per_token: 75.0 / 1_000_000.0,
      cache_read_per_token: 1.875 / 1_000_000.0,
      cache_write_per_token: 18.75 / 1_000_000.0,
    };
  }
  if normalized.contains("sonnet") {
    return Pricing {
      input_per_token: 3.0 / 1_000_000.0,
      output_per_token: 15.0 / 1_000_000.0,
      cache_read_per_token: 0.30 / 1_000_000.0,
      cache_write_per_token: 3.75 / 1_000_000.0,
    };
  }
  if normalized.contains("haiku") {
    return Pricing {
      input_per_token: 0.8 / 1_000_000.0,
      output_per_token: 4.0 / 1_000_000.0,
      cache_read_per_token: 0.08 / 1_000_000.0,
      cache_write_per_token: 1.0 / 1_000_000.0,
    };
  }
  if normalized.contains("gpt-5") || provider.eq_ignore_ascii_case("codex") {
    return Pricing {
      input_per_token: 2.0 / 1_000_000.0,
      output_per_token: 10.0 / 1_000_000.0,
      cache_read_per_token: 0.0,
      cache_write_per_token: 0.0,
    };
  }

  Pricing {
    input_per_token: 3.0 / 1_000_000.0,
    output_per_token: 15.0 / 1_000_000.0,
    cache_read_per_token: 0.30 / 1_000_000.0,
    cache_write_per_token: 3.75 / 1_000_000.0,
  }
}

#[cfg(test)]
mod tests {
  use super::*;

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
