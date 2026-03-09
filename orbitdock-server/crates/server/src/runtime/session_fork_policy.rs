use orbitdock_protocol::{Message, MessageType};

#[derive(Debug, Clone)]
pub(crate) struct ForkConfigInputs {
    pub requested_model: Option<String>,
    pub requested_approval_policy: Option<String>,
    pub requested_sandbox_mode: Option<String>,
    pub requested_cwd: Option<String>,
    pub source_cwd: Option<String>,
    pub source_model: Option<String>,
    pub source_approval_policy: Option<String>,
    pub source_sandbox_mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForkConfigPlan {
    pub effective_cwd: Option<String>,
    pub effective_model: Option<String>,
    pub effective_approval_policy: Option<String>,
    pub effective_sandbox_mode: Option<String>,
}

pub(crate) fn plan_fork_config(input: ForkConfigInputs) -> ForkConfigPlan {
    ForkConfigPlan {
        effective_cwd: input.requested_cwd.or(input.source_cwd),
        effective_model: input.requested_model.or(input.source_model),
        effective_approval_policy: input
            .requested_approval_policy
            .or(input.source_approval_policy),
        effective_sandbox_mode: input.requested_sandbox_mode.or(input.source_sandbox_mode),
    }
}

pub(crate) fn truncate_messages_before_nth_user_message(
    messages: &[Message],
    nth_user_message: Option<u32>,
) -> Vec<Message> {
    let Some(nth_user_message) = nth_user_message else {
        return messages.to_vec();
    };

    let mut user_count = 0usize;
    let mut cut_idx: Option<usize> = None;

    for (idx, msg) in messages.iter().enumerate() {
        if msg.message_type == MessageType::User {
            if user_count == nth_user_message as usize {
                cut_idx = Some(idx);
                break;
            }
            user_count += 1;
        }
    }

    match cut_idx {
        Some(idx) => messages[..idx].to_vec(),
        None => Vec::new(),
    }
}

pub(crate) fn remap_messages_for_fork(
    messages: Vec<Message>,
    new_session_id: &str,
) -> Vec<Message> {
    let new_session_id = new_session_id.to_string();

    messages
        .into_iter()
        .filter(|msg| !msg.is_in_progress)
        .enumerate()
        .map(|(idx, mut msg)| {
            msg.id = format!("{new_session_id}:fork:{idx}");
            msg.session_id = new_session_id.clone();
            msg.is_in_progress = false;
            msg
        })
        .collect()
}

pub(crate) fn select_fork_messages(
    source_messages: Vec<Message>,
    rollout_messages: Vec<Message>,
) -> Vec<Message> {
    if source_messages.len() >= rollout_messages.len() {
        source_messages
    } else {
        rollout_messages
    }
}

#[cfg(test)]
mod tests {
    use super::{
        plan_fork_config, remap_messages_for_fork, select_fork_messages,
        truncate_messages_before_nth_user_message, ForkConfigInputs,
    };
    use orbitdock_protocol::{Message, MessageType};

    fn mk_msg(id: &str, message_type: MessageType, content: &str) -> Message {
        Message {
            id: id.to_string(),
            session_id: "source".to_string(),
            sequence: None,
            message_type,
            content: content.to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        }
    }

    #[test]
    fn fork_plan_prefers_requested_values_and_falls_back_to_source() {
        let plan = plan_fork_config(ForkConfigInputs {
            requested_model: Some("gpt-5".into()),
            requested_approval_policy: None,
            requested_sandbox_mode: Some("danger-full-access".into()),
            requested_cwd: None,
            source_cwd: Some("/repo".into()),
            source_model: Some("old-model".into()),
            source_approval_policy: Some("on-request".into()),
            source_sandbox_mode: Some("workspace-write".into()),
        });

        assert_eq!(plan.effective_cwd.as_deref(), Some("/repo"));
        assert_eq!(plan.effective_model.as_deref(), Some("gpt-5"));
        assert_eq!(
            plan.effective_approval_policy.as_deref(),
            Some("on-request")
        );
        assert_eq!(
            plan.effective_sandbox_mode.as_deref(),
            Some("danger-full-access")
        );
    }

    #[test]
    fn truncate_messages_before_nth_user_message_respects_user_boundaries() {
        let messages = vec![
            mk_msg("m1", MessageType::User, "u1"),
            mk_msg("m2", MessageType::Assistant, "a1"),
            mk_msg("m3", MessageType::User, "u2"),
            mk_msg("m4", MessageType::Assistant, "a2"),
        ];

        let full = truncate_messages_before_nth_user_message(&messages, None);
        assert_eq!(full.len(), 4);

        let before_first_user = truncate_messages_before_nth_user_message(&messages, Some(0));
        assert_eq!(before_first_user.len(), 0);

        let before_second_user = truncate_messages_before_nth_user_message(&messages, Some(1));
        assert_eq!(before_second_user.len(), 2);

        let out_of_range = truncate_messages_before_nth_user_message(&messages, Some(8));
        assert_eq!(out_of_range.len(), 0);
    }

    #[test]
    fn remap_messages_for_fork_reassigns_identity_and_clears_in_progress() {
        let mut in_progress = mk_msg("m2", MessageType::Assistant, "working");
        in_progress.is_in_progress = true;
        let mapped = remap_messages_for_fork(
            vec![
                mk_msg("m1", MessageType::User, "keep"),
                in_progress,
                mk_msg("m3", MessageType::Assistant, "done"),
            ],
            "od-new",
        );

        assert_eq!(mapped.len(), 2);
        assert_eq!(mapped[0].id, "od-new:fork:0");
        assert_eq!(mapped[0].session_id, "od-new");
        assert!(!mapped[0].is_in_progress);
        assert_eq!(mapped[1].id, "od-new:fork:1");
    }

    #[test]
    fn select_fork_messages_prefers_longer_source_history() {
        let source_messages = vec![
            mk_msg("m1", MessageType::User, "u1"),
            mk_msg("m2", MessageType::Assistant, "a1"),
        ];
        let rollout_messages = vec![mk_msg("m3", MessageType::User, "u1")];

        let selected = select_fork_messages(source_messages.clone(), rollout_messages);
        assert_eq!(selected.len(), source_messages.len());
    }
}
