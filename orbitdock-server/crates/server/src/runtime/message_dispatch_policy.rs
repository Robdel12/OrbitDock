use orbitdock_protocol::{ImageInput, Message, MessageType, Provider};

use crate::domain::sessions::session_naming::name_from_first_prompt;
use crate::support::normalization::{normalize_model_override, normalize_non_empty};
use crate::support::session_time::iso_timestamp;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SendMessagePlan {
    pub first_prompt: Option<String>,
    pub action_model: Option<String>,
    pub session_effort_update: Option<String>,
    pub connector_effort: Option<String>,
}

pub(crate) fn plan_send_message(
    provider: Provider,
    content: &str,
    model: Option<String>,
    effort: Option<String>,
) -> SendMessagePlan {
    let first_prompt = name_from_first_prompt(content);
    let action_model = normalize_model_override(model);
    let normalized_effort = normalize_non_empty(effort);
    let (session_effort_update, connector_effort) = if provider == Provider::Claude {
        (None, None)
    } else {
        (normalized_effort.clone(), normalized_effort)
    };

    SendMessagePlan {
        first_prompt,
        action_model,
        session_effort_update,
        connector_effort,
    }
}

pub(crate) fn build_session_message(
    session_id: &str,
    message_id: String,
    message_type: MessageType,
    content: String,
    timestamp_millis: u128,
    images: Vec<ImageInput>,
) -> Message {
    Message {
        id: message_id,
        session_id: session_id.to_string(),
        sequence: None,
        message_type,
        content,
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_timestamp(timestamp_millis),
        duration_ms: None,
        images,
    }
}

#[cfg(test)]
mod tests {
    use super::{build_session_message, plan_send_message};
    use orbitdock_protocol::{MessageType, Provider};

    #[test]
    fn send_message_plan_keeps_codex_model_and_effort_updates() {
        let plan = plan_send_message(
            Provider::Codex,
            "Ship this patch",
            Some("gpt-5.3-codex".into()),
            Some("high".into()),
        );

        assert_eq!(plan.first_prompt.as_deref(), Some("Ship this patch"));
        assert_eq!(plan.action_model.as_deref(), Some("gpt-5.3-codex"));
        assert_eq!(plan.session_effort_update.as_deref(), Some("high"));
        assert_eq!(plan.connector_effort.as_deref(), Some("high"));
    }

    #[test]
    fn send_message_plan_ignores_effort_for_claude_sessions() {
        let plan = plan_send_message(
            Provider::Claude,
            "Need help",
            Some("claude-opus".into()),
            Some("high".into()),
        );

        assert_eq!(plan.action_model.as_deref(), Some("claude-opus"));
        assert_eq!(plan.session_effort_update, None);
        assert_eq!(plan.connector_effort, None);
    }

    #[test]
    fn build_session_message_preserves_user_visible_fields() {
        let message = build_session_message(
            "session-1",
            "message-1".into(),
            MessageType::Steer,
            "Adjust the plan".into(),
            123,
            vec![],
        );

        assert_eq!(message.session_id, "session-1");
        assert_eq!(message.id, "message-1");
        assert_eq!(message.message_type, MessageType::Steer);
        assert_eq!(message.content, "Adjust the plan");
    }
}
