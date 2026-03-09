use orbitdock_protocol::{Message, Provider, TokenUsage, TokenUsageSnapshotKind};

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
    pub new_messages: Vec<Message>,
}

pub(crate) struct TranscriptSyncInputs {
    pub provider: Provider,
    pub current_usage: TokenUsage,
    pub transcript_usage: Option<TokenUsage>,
    pub transcript_messages: Vec<Message>,
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
    transcript_message_count: usize,
    existing_count: usize,
    confirmed_count: Option<usize>,
) -> TranscriptMessageSyncDecision {
    if confirmed_count.is_some_and(|count| count != existing_count) {
        return TranscriptMessageSyncDecision::SkipRuntimeCountChanged;
    }

    if transcript_message_count <= existing_count {
        return TranscriptMessageSyncDecision::SkipNoNewMessages;
    }

    TranscriptMessageSyncDecision::AppendNewMessages
}

pub(crate) fn plan_transcript_sync(input: TranscriptSyncInputs) -> TranscriptSyncPlan {
    let usage_update =
        transcript_usage_update(input.provider, &input.current_usage, input.transcript_usage);

    let message_sync_decision = classify_transcript_message_sync(
        input.transcript_messages.len(),
        input.existing_count,
        input.confirmed_count,
    );

    let new_messages = match message_sync_decision {
        TranscriptMessageSyncDecision::AppendNewMessages => {
            input.transcript_messages[input.existing_count..].to_vec()
        }
        TranscriptMessageSyncDecision::SkipNoNewMessages
        | TranscriptMessageSyncDecision::SkipRuntimeCountChanged => vec![],
    };

    TranscriptSyncPlan {
        usage_update,
        message_sync_decision,
        new_messages,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        classify_transcript_message_sync, plan_transcript_sync, transcript_usage_update,
        TranscriptMessageSyncDecision, TranscriptSyncInputs,
    };
    use orbitdock_protocol::{Message, MessageType, Provider, TokenUsage, TokenUsageSnapshotKind};

    fn usage(input: u64, output: u64, cached: u64, window: u64) -> TokenUsage {
        TokenUsage {
            input_tokens: input,
            output_tokens: output,
            cached_tokens: cached,
            context_window: window,
        }
    }

    fn message(sequence: u64, content: &str) -> Message {
        Message {
            id: format!("message-{sequence}"),
            session_id: "session-1".to_string(),
            sequence: Some(sequence),
            message_type: MessageType::Assistant,
            content: content.to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "123Z".to_string(),
            duration_ms: None,
            images: vec![],
        }
    }

    #[test]
    fn transcript_usage_update_only_emits_when_usage_changes() {
        assert!(transcript_usage_update(
            Provider::Codex,
            &usage(1, 2, 3, 4),
            Some(usage(1, 2, 3, 4)),
        )
        .is_none());

        let update = transcript_usage_update(
            Provider::Claude,
            &usage(1, 2, 3, 4),
            Some(usage(2, 2, 3, 4)),
        )
        .expect("expected usage update");
        assert_eq!(update.usage.input_tokens, 2);
        assert_eq!(update.snapshot_kind, TokenUsageSnapshotKind::MixedLegacy);
    }

    #[test]
    fn transcript_message_sync_classifies_no_new_messages() {
        assert_eq!(
            classify_transcript_message_sync(2, 2, Some(2)),
            TranscriptMessageSyncDecision::SkipNoNewMessages
        );
    }

    #[test]
    fn transcript_message_sync_classifies_runtime_count_changes() {
        assert_eq!(
            classify_transcript_message_sync(4, 2, Some(3)),
            TranscriptMessageSyncDecision::SkipRuntimeCountChanged
        );
    }

    #[test]
    fn transcript_sync_plan_appends_only_new_messages_after_confirmed_count() {
        let plan = plan_transcript_sync(TranscriptSyncInputs {
            provider: Provider::Codex,
            current_usage: usage(1, 2, 3, 4),
            transcript_usage: None,
            transcript_messages: vec![message(0, "a"), message(1, "b"), message(2, "c")],
            existing_count: 2,
            confirmed_count: Some(2),
        });

        assert_eq!(
            plan.message_sync_decision,
            TranscriptMessageSyncDecision::AppendNewMessages
        );
        assert_eq!(plan.new_messages.len(), 1);
        assert_eq!(plan.new_messages[0].sequence, Some(2));
        assert_eq!(plan.new_messages[0].content, "c");
        assert!(plan.usage_update.is_none());
    }

    #[test]
    fn transcript_sync_plan_appends_new_messages_without_a_confirmed_count() {
        let plan = plan_transcript_sync(TranscriptSyncInputs {
            provider: Provider::Claude,
            current_usage: usage(1, 2, 3, 4),
            transcript_usage: None,
            transcript_messages: vec![message(0, "a"), message(1, "b")],
            existing_count: 1,
            confirmed_count: None,
        });

        assert_eq!(
            plan.message_sync_decision,
            TranscriptMessageSyncDecision::AppendNewMessages
        );
        assert_eq!(plan.new_messages.len(), 1);
        assert_eq!(plan.new_messages[0].content, "b");
    }

    #[test]
    fn transcript_sync_plan_keeps_usage_update_when_message_append_is_skipped() {
        let plan = plan_transcript_sync(TranscriptSyncInputs {
            provider: Provider::Codex,
            current_usage: usage(1, 2, 3, 4),
            transcript_usage: Some(usage(9, 2, 3, 4)),
            transcript_messages: vec![message(0, "a"), message(1, "b")],
            existing_count: 1,
            confirmed_count: Some(2),
        });

        assert_eq!(
            plan.message_sync_decision,
            TranscriptMessageSyncDecision::SkipRuntimeCountChanged
        );
        assert!(plan.new_messages.is_empty());
        assert!(plan.usage_update.is_some());
    }
}
