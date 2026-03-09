use orbitdock_protocol::{Message, SessionState};

#[derive(Debug, Clone)]
pub struct ConversationPage {
    pub messages: Vec<Message>,
    pub total_message_count: u64,
    pub has_more_before: bool,
    pub oldest_sequence: Option<u64>,
    pub newest_sequence: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct ConversationBootstrap {
    pub session: SessionState,
    pub total_message_count: u64,
    pub has_more_before: bool,
    pub oldest_sequence: Option<u64>,
    pub newest_sequence: Option<u64>,
}
