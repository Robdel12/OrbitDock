use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent,
};
use orbitdock_protocol::{ImageInput, Provider};

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

pub(crate) fn build_user_row_entry(
    session_id: &str,
    message_id: String,
    content: String,
    timestamp_millis: u128,
    images: Vec<ImageInput>,
) -> ConversationRowEntry {
    ConversationRowEntry {
        session_id: session_id.to_string(),
        sequence: 0,
        turn_id: None,
        row: ConversationRow::User(MessageRowContent {
            id: message_id,
            content,
            turn_id: None,
            timestamp: Some(iso_timestamp(timestamp_millis)),
            is_streaming: false,
            images,
            memory_citation: None,
        }),
    }
}
