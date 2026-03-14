use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
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
    SkipRuntimeCountChanged,
}

#[derive(Debug, Clone)]
pub(crate) struct TranscriptSyncPlan {
    pub usage_update: Option<TranscriptUsageUpdate>,
    pub message_sync_decision: TranscriptMessageSyncDecision,
    pub new_rows: Vec<ConversationRowEntry>,
}

pub(crate) struct TranscriptSyncInputs {
    pub provider: Provider,
    pub current_usage: TokenUsage,
    pub transcript_usage: Option<TokenUsage>,
    pub transcript_rows: Vec<ConversationRowEntry>,
    pub existing_count: usize,
    pub confirmed_count: Option<usize>,
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

pub(crate) fn classify_transcript_message_sync(
    transcript_row_count: usize,
    existing_count: usize,
    confirmed_count: Option<usize>,
) -> TranscriptMessageSyncDecision {
    if confirmed_count.is_some_and(|count| count != existing_count) {
        return TranscriptMessageSyncDecision::SkipRuntimeCountChanged;
    }

    if transcript_row_count <= existing_count {
        return TranscriptMessageSyncDecision::SkipNoNewMessages;
    }

    TranscriptMessageSyncDecision::AppendNewMessages
}

pub(crate) fn plan_transcript_sync(input: TranscriptSyncInputs) -> TranscriptSyncPlan {
    let usage_update =
        transcript_usage_update(input.provider, &input.current_usage, input.transcript_usage);

    let message_sync_decision = classify_transcript_message_sync(
        input.transcript_rows.len(),
        input.existing_count,
        input.confirmed_count,
    );

    let new_rows = match message_sync_decision {
        TranscriptMessageSyncDecision::AppendNewMessages => {
            input.transcript_rows[input.existing_count..].to_vec()
        }
        TranscriptMessageSyncDecision::SkipNoNewMessages
        | TranscriptMessageSyncDecision::SkipRuntimeCountChanged => vec![],
    };

    TranscriptSyncPlan {
        usage_update,
        message_sync_decision,
        new_rows,
    }
}
