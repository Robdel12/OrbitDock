use serde::{Deserialize, Serialize};

use crate::conversation_contracts::activity_groups::ActivityGroupRow;
use crate::conversation_contracts::approvals::{ApprovalRow, QuestionRow};
use crate::conversation_contracts::render_hints::RenderHints;
use crate::conversation_contracts::tool_display::ToolDisplay;
use crate::conversation_contracts::tool_payloads::{
    ToolInvocationPayloadContract, ToolPreview, ToolResultPayloadContract,
};
use crate::conversation_contracts::workers::WorkerRow;
use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};
use crate::{ImageInput, Provider};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageRowContent {
    pub id: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    /// True while the row is actively receiving streaming deltas.
    #[serde(default)]
    pub is_streaming: bool,
    /// Image attachments on user messages.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<ImageInput>,
}

pub type UserRow = MessageRowContent;
pub type AssistantRow = MessageRowContent;
pub type ThinkingRow = MessageRowContent;
pub type SystemRow = MessageRowContent;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookRow {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub payload: crate::domain_events::HookPayload,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HandoffRow {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub payload: crate::domain_events::HandoffPayload,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanRow {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub payload: crate::domain_events::PlanModePayload,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationRowEntry {
    pub session_id: String,
    pub sequence: u64,
    /// Turn this row belongs to — lifted so all row types carry it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    pub row: ConversationRow,
}

impl ConversationRowEntry {
    pub fn id(&self) -> &str {
        match &self.row {
            ConversationRow::User(row)
            | ConversationRow::Assistant(row)
            | ConversationRow::Thinking(row)
            | ConversationRow::System(row) => &row.id,
            ConversationRow::Plan(row) => &row.id,
            ConversationRow::Hook(row) => &row.id,
            ConversationRow::Handoff(row) => &row.id,
            ConversationRow::Tool(row) => &row.id,
            ConversationRow::ActivityGroup(row) => &row.id,
            ConversationRow::Question(row) => &row.id,
            ConversationRow::Approval(row) => &row.id,
            ConversationRow::Worker(row) => &row.id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationRowPage {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<ConversationRowEntry>,
    pub total_row_count: u64,
    pub has_more_before: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub newest_sequence: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolRow {
    pub id: String,
    pub provider: Provider,
    pub family: ToolFamily,
    pub kind: ToolKind,
    pub status: ToolStatus,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<ToolPreview>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grouping_key: Option<String>,
    pub invocation: ToolInvocationPayloadContract,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<ToolResultPayloadContract>,
    #[serde(default)]
    pub render_hints: RenderHints,
    /// Server-computed display metadata — the client renders this directly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_display: Option<ToolDisplay>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "row_type", rename_all = "snake_case")]
pub enum ConversationRow {
    User(UserRow),
    Assistant(AssistantRow),
    Thinking(ThinkingRow),
    Tool(ToolRow),
    ActivityGroup(ActivityGroupRow),
    Question(QuestionRow),
    Approval(ApprovalRow),
    Worker(WorkerRow),
    Plan(PlanRow),
    Hook(HookRow),
    Handoff(HandoffRow),
    System(SystemRow),
}

/// Extract a human-readable content string from a conversation row.
pub fn extract_row_content_str(row: &ConversationRow) -> String {
    match row {
        ConversationRow::User(m)
        | ConversationRow::Assistant(m)
        | ConversationRow::Thinking(m)
        | ConversationRow::System(m) => m.content.clone(),
        ConversationRow::Tool(t) => t.title.clone(),
        ConversationRow::Plan(p) => p.title.clone(),
        ConversationRow::Hook(h) => h.title.clone(),
        ConversationRow::Handoff(h) => h.title.clone(),
        ConversationRow::Worker(w) => w.title.clone(),
        ConversationRow::Approval(a) => a.id.clone(),
        ConversationRow::Question(q) => q.id.clone(),
        ConversationRow::ActivityGroup(g) => g.title.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::{ConversationRow, ConversationRowEntry, MessageRowContent};
    use crate::ImageInput;

    #[test]
    fn message_row_content_round_trips_streaming_images_and_turn_id() {
        let entry = ConversationRowEntry {
            session_id: "sess-1".to_string(),
            sequence: 7,
            turn_id: Some("turn-42".to_string()),
            row: ConversationRow::Assistant(MessageRowContent {
                id: "row-1".to_string(),
                content: "Streaming reply".to_string(),
                turn_id: Some("turn-42".to_string()),
                timestamp: Some("2026-03-13T12:00:00Z".to_string()),
                is_streaming: true,
                images: vec![ImageInput {
                    input_type: "attachment".to_string(),
                    value: "att-1".to_string(),
                    mime_type: Some("image/png".to_string()),
                    byte_count: None,
                    display_name: None,
                    pixel_width: None,
                    pixel_height: None,
                }],
            }),
        };

        let json = serde_json::to_value(&entry).expect("serialize conversation row");
        assert_eq!(
            json.get("turn_id").and_then(|value| value.as_str()),
            Some("turn-42")
        );
        assert_eq!(
            json.get("row")
                .and_then(|row| row.get("is_streaming"))
                .and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            json.get("row")
                .and_then(|row| row.get("images"))
                .and_then(|value| value.as_array())
                .map(Vec::len),
            Some(1)
        );

        let decoded: ConversationRowEntry =
            serde_json::from_value(json).expect("deserialize conversation row");
        assert_eq!(decoded, entry);
    }
}
