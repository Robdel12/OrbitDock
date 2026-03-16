use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};
use orbitdock_protocol::{Provider, TokenUsage, TokenUsageSnapshotKind};

#[derive(Debug, Clone)]
pub(crate) struct TranscriptUsageUpdate {
    pub usage: TokenUsage,
    pub snapshot_kind: TokenUsageSnapshotKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TranscriptMessageSyncDecision {
    AppendNewMessages,
    SkipNoNewMessages,
    /// Our newest known row isn't in the transcript — replace all rows.
    ForceResync,
}

#[derive(Debug, Clone)]
pub(crate) struct TranscriptSyncPlan {
    pub usage_update: Option<TranscriptUsageUpdate>,
    pub message_sync_decision: TranscriptMessageSyncDecision,
    pub new_rows: Vec<ConversationRowEntry>,
    /// Existing tool rows that received results from later transcript entries.
    /// These need RowUpsert to update the DB with the result data.
    pub updated_rows: Vec<ConversationRowEntry>,
}

pub(crate) struct TranscriptSyncInputs {
    pub provider: Provider,
    pub current_usage: TokenUsage,
    pub transcript_usage: Option<TokenUsage>,
    pub transcript_rows: Vec<ConversationRowEntry>,
    /// ID of the newest row we've already synced (None = no rows yet).
    pub newest_known_id: Option<String>,
}

pub(crate) fn transcript_usage_update(
    provider: Provider,
    current_usage: &TokenUsage,
    transcript_usage: Option<TokenUsage>,
) -> Option<TranscriptUsageUpdate> {
    let usage = transcript_usage?;
    if usage.input_tokens == current_usage.input_tokens
        && usage.output_tokens == current_usage.output_tokens
        && usage.cached_tokens == current_usage.cached_tokens
        && usage.context_window == current_usage.context_window
    {
        return None;
    }

    let snapshot_kind = match provider {
        Provider::Codex => TokenUsageSnapshotKind::ContextTurn,
        Provider::Claude => TokenUsageSnapshotKind::MixedLegacy,
    };

    Some(TranscriptUsageUpdate {
        usage,
        snapshot_kind,
    })
}

/// Classify whether a transcript sync should append, skip, or force-resync.
///
/// Uses ID-based comparison instead of count-based — immune to inflated
/// `total_row_count` from upserts or duplicate `add_row` calls.
pub(crate) fn classify_transcript_message_sync(
    transcript_rows: &[ConversationRowEntry],
    newest_known_id: Option<&str>,
) -> (TranscriptMessageSyncDecision, usize) {
    if transcript_rows.is_empty() {
        return (TranscriptMessageSyncDecision::SkipNoNewMessages, 0);
    }

    match newest_known_id {
        None => {
            // No rows synced yet — everything is new
            (TranscriptMessageSyncDecision::AppendNewMessages, 0)
        }
        Some(known_id) => {
            match transcript_rows.iter().rposition(|r| r.id() == known_id) {
                Some(pos) if pos == transcript_rows.len() - 1 => {
                    // Up to date — newest known row is the last transcript row
                    (TranscriptMessageSyncDecision::SkipNoNewMessages, 0)
                }
                Some(pos) => {
                    // New rows after our known position
                    (TranscriptMessageSyncDecision::AppendNewMessages, pos + 1)
                }
                None => {
                    // Our known row isn't in the transcript — full resync
                    (TranscriptMessageSyncDecision::ForceResync, 0)
                }
            }
        }
    }
}

pub(crate) fn plan_transcript_sync(input: TranscriptSyncInputs) -> TranscriptSyncPlan {
    let usage_update =
        transcript_usage_update(input.provider, &input.current_usage, input.transcript_usage);

    let (message_sync_decision, split_at) =
        classify_transcript_message_sync(&input.transcript_rows, input.newest_known_id.as_deref());

    let (new_rows, updated_rows) = match message_sync_decision {
        TranscriptMessageSyncDecision::AppendNewMessages => {
            let new = input.transcript_rows[split_at..].to_vec();
            // Find existing tool rows that got results attached by the transcript
            // parser (tool_result entries matched back to earlier tool_use rows).
            let updated: Vec<ConversationRowEntry> = input.transcript_rows[..split_at]
                .iter()
                .filter(
                    |entry| matches!(&entry.row, ConversationRow::Tool(t) if t.result.is_some()),
                )
                .cloned()
                .collect();
            (new, updated)
        }
        TranscriptMessageSyncDecision::ForceResync => {
            // Full resync — treat all rows as new (replace_rows will be called)
            (input.transcript_rows, vec![])
        }
        TranscriptMessageSyncDecision::SkipNoNewMessages => (vec![], vec![]),
    };

    TranscriptSyncPlan {
        usage_update,
        message_sync_decision,
        new_rows,
        updated_rows,
    }
}
