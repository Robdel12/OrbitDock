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

pub(super) fn snapshot_kind_from_str(kind: Option<&str>) -> TokenUsageSnapshotKind {
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

#[allow(clippy::too_many_arguments)]
pub(super) fn upsert_usage_turn_snapshot(
    conn: &Connection,
    session_id: &str,
    turn_id: &str,
    turn_seq: u64,
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64,
    context_window: u64,
    snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
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

    let input_tokens_i64 = input_tokens as i64;
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
            turn_seq as i64,
            snapshot_kind_to_str(snapshot_kind),
            input_tokens as i64,
            output_tokens as i64,
            cached_tokens as i64,
            context_window as i64,
            input_delta_tokens,
            chrono_now(),
        ],
    )?;

    Ok(())
}
