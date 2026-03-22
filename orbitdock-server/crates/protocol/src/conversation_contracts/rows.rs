use serde::{Deserialize, Serialize};

use crate::conversation_contracts::activity_groups::{ActivityGroupRow, ActivityGroupRowSummary};
use crate::conversation_contracts::approvals::{ApprovalRow, QuestionRow};
use crate::conversation_contracts::render_hints::RenderHints;
use crate::conversation_contracts::tool_display::{
    compute_tool_display, ToolDisplay, ToolDisplayInput,
};
use crate::conversation_contracts::tool_payloads::{
    ToolInvocationPayloadContract, ToolPreview, ToolResultPayloadContract,
};
use crate::conversation_contracts::workers::WorkerRow;
use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};
use crate::{ImageInput, Provider};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCitation {
    pub entries: Vec<MemoryCitationEntry>,
    pub rollout_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCitationEntry {
    pub path: String,
    pub line_start: u32,
    pub line_end: u32,
    pub note: String,
}

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_citation: Option<MemoryCitation>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextRowKind {
    AgentInstructions,
    Environment,
    Skill,
    Reminder,
    Personality,
    UserInstructions,
    Generic,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextRow {
    pub id: String,
    pub kind: ContextRowKind,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell: Option<String>,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeRowKind {
    TurnAborted,
    LocalCommandCaveat,
    Generic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeRowSeverity {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NoticeRow {
    pub id: String,
    pub kind: NoticeRowKind,
    pub severity: NoticeRowSeverity,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShellCommandRowKind {
    UserShellCommand,
    SlashCommand,
    Bash,
    LocalCommandOutput,
    ShellContext,
    Generic,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShellCommandRow {
    pub id: String,
    pub kind: ShellCommandRowKind,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default)]
    pub render_hints: RenderHints,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskRowKind {
    BackgroundCommand,
    Generic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskRowStatus {
    Pending,
    Running,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskRow {
    pub id: String,
    pub kind: TaskRowKind,
    pub status: TaskRowStatus,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_text: Option<String>,
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
            ConversationRow::Context(row) => &row.id,
            ConversationRow::Notice(row) => &row.id,
            ConversationRow::ShellCommand(row) => &row.id,
            ConversationRow::Task(row) => &row.id,
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
    Context(ContextRow),
    Notice(NoticeRow),
    ShellCommand(ShellCommandRow),
    Task(TaskRow),
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

// ---------------------------------------------------------------------------
// Wire-safe summary types — no raw tool payloads, guaranteed tool_display
// ---------------------------------------------------------------------------

/// Wire-safe tool row for WS events and HTTP timeline responses.
/// Carries all display metadata but never raw invocation/result payloads.
/// `tool_display` is required — the server always computes it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolRowSummary {
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
    #[serde(default)]
    pub render_hints: RenderHints,
    /// Always present on wire — server computes eagerly.
    pub tool_display: ToolDisplay,
}

impl ToolRow {
    pub fn to_summary(&self) -> ToolRowSummary {
        let display = self.tool_display.clone().unwrap_or_else(|| {
            let result_str = self.result.as_ref().and_then(|v| v.as_str());
            compute_tool_display(ToolDisplayInput {
                kind: self.kind,
                family: self.family,
                status: self.status,
                title: &self.title,
                subtitle: self.subtitle.as_deref(),
                summary: self.summary.as_deref(),
                duration_ms: self.duration_ms,
                invocation_input: Some(&self.invocation),
                result_output: result_str,
            })
        });
        ToolRowSummary {
            id: self.id.clone(),
            provider: self.provider,
            family: self.family,
            kind: self.kind,
            status: self.status,
            title: self.title.clone(),
            subtitle: self.subtitle.clone(),
            summary: self.summary.clone(),
            preview: self.preview.clone(),
            started_at: self.started_at.clone(),
            ended_at: self.ended_at.clone(),
            duration_ms: self.duration_ms,
            grouping_key: self.grouping_key.clone(),
            render_hints: self.render_hints.clone(),
            tool_display: display,
        }
    }
}

/// Wire-safe row enum — Tool and ActivityGroup variants use summary types.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "row_type", rename_all = "snake_case")]
pub enum ConversationRowSummary {
    User(UserRow),
    Assistant(AssistantRow),
    Thinking(ThinkingRow),
    Context(ContextRow),
    Notice(NoticeRow),
    ShellCommand(ShellCommandRow),
    Task(TaskRow),
    Tool(ToolRowSummary),
    ActivityGroup(ActivityGroupRowSummary),
    Question(QuestionRow),
    Approval(ApprovalRow),
    Worker(WorkerRow),
    Plan(PlanRow),
    Hook(HookRow),
    Handoff(HandoffRow),
    System(SystemRow),
}

impl ConversationRow {
    /// Convert to wire-safe summary.
    pub fn to_summary(&self) -> ConversationRowSummary {
        match self {
            ConversationRow::User(r) => ConversationRowSummary::User(r.clone()),
            ConversationRow::Assistant(r) => ConversationRowSummary::Assistant(r.clone()),
            ConversationRow::Thinking(r) => ConversationRowSummary::Thinking(r.clone()),
            ConversationRow::System(r) => ConversationRowSummary::System(r.clone()),
            ConversationRow::Context(r) => ConversationRowSummary::Context(r.clone()),
            ConversationRow::Notice(r) => ConversationRowSummary::Notice(r.clone()),
            ConversationRow::ShellCommand(r) => ConversationRowSummary::ShellCommand(r.clone()),
            ConversationRow::Task(r) => ConversationRowSummary::Task(r.clone()),
            ConversationRow::Tool(r) => ConversationRowSummary::Tool(r.to_summary()),
            ConversationRow::ActivityGroup(r) => {
                ConversationRowSummary::ActivityGroup(r.to_summary())
            }
            ConversationRow::Question(r) => ConversationRowSummary::Question(r.clone()),
            ConversationRow::Approval(r) => ConversationRowSummary::Approval(r.clone()),
            ConversationRow::Worker(r) => ConversationRowSummary::Worker(r.clone()),
            ConversationRow::Plan(r) => ConversationRowSummary::Plan(r.clone()),
            ConversationRow::Hook(r) => ConversationRowSummary::Hook(r.clone()),
            ConversationRow::Handoff(r) => ConversationRowSummary::Handoff(r.clone()),
        }
    }
}

/// Wire-safe entry wrapper.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowEntrySummary {
    pub session_id: String,
    pub sequence: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    pub row: ConversationRowSummary,
}

impl RowEntrySummary {
    pub fn id(&self) -> &str {
        match &self.row {
            ConversationRowSummary::User(row)
            | ConversationRowSummary::Assistant(row)
            | ConversationRowSummary::Thinking(row)
            | ConversationRowSummary::System(row) => &row.id,
            ConversationRowSummary::Context(row) => &row.id,
            ConversationRowSummary::Notice(row) => &row.id,
            ConversationRowSummary::ShellCommand(row) => &row.id,
            ConversationRowSummary::Task(row) => &row.id,
            ConversationRowSummary::Plan(row) => &row.id,
            ConversationRowSummary::Hook(row) => &row.id,
            ConversationRowSummary::Handoff(row) => &row.id,
            ConversationRowSummary::Tool(row) => &row.id,
            ConversationRowSummary::ActivityGroup(row) => &row.id,
            ConversationRowSummary::Question(row) => &row.id,
            ConversationRowSummary::Approval(row) => &row.id,
            ConversationRowSummary::Worker(row) => &row.id,
        }
    }
}

impl ConversationRowEntry {
    /// Convert to wire-safe summary.
    pub fn to_summary(&self) -> RowEntrySummary {
        RowEntrySummary {
            session_id: self.session_id.clone(),
            sequence: self.sequence,
            turn_id: self.turn_id.clone(),
            row: self.row.to_summary(),
        }
    }
}

/// Wire-safe page using summary entries.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowPageSummary {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<RowEntrySummary>,
    pub total_row_count: u64,
    pub has_more_before: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub newest_sequence: Option<u64>,
}

/// Extract a human-readable content string from a conversation row.
pub fn extract_row_content_str(row: &ConversationRow) -> String {
    match row {
        ConversationRow::User(m)
        | ConversationRow::Assistant(m)
        | ConversationRow::Thinking(m)
        | ConversationRow::System(m) => m.content.clone(),
        ConversationRow::Context(c) => c.summary.clone().unwrap_or_else(|| c.title.clone()),
        ConversationRow::Notice(n) => n.summary.clone().unwrap_or_else(|| n.title.clone()),
        ConversationRow::ShellCommand(s) => s
            .summary
            .clone()
            .or_else(|| s.command.clone())
            .unwrap_or_else(|| s.title.clone()),
        ConversationRow::Task(t) => t.summary.clone().unwrap_or_else(|| t.title.clone()),
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

/// Extract a human-readable content string from a summary row.
pub fn extract_row_content_str_summary(row: &ConversationRowSummary) -> String {
    match row {
        ConversationRowSummary::User(m)
        | ConversationRowSummary::Assistant(m)
        | ConversationRowSummary::Thinking(m)
        | ConversationRowSummary::System(m) => m.content.clone(),
        ConversationRowSummary::Context(c) => c.summary.clone().unwrap_or_else(|| c.title.clone()),
        ConversationRowSummary::Notice(n) => n.summary.clone().unwrap_or_else(|| n.title.clone()),
        ConversationRowSummary::ShellCommand(s) => s
            .summary
            .clone()
            .or_else(|| s.command.clone())
            .unwrap_or_else(|| s.title.clone()),
        ConversationRowSummary::Task(t) => t.summary.clone().unwrap_or_else(|| t.title.clone()),
        ConversationRowSummary::Tool(t) => t.title.clone(),
        ConversationRowSummary::Plan(p) => p.title.clone(),
        ConversationRowSummary::Hook(h) => h.title.clone(),
        ConversationRowSummary::Handoff(h) => h.title.clone(),
        ConversationRowSummary::Worker(w) => w.title.clone(),
        ConversationRowSummary::Approval(a) => a.id.clone(),
        ConversationRowSummary::Question(q) => q.id.clone(),
        ConversationRowSummary::ActivityGroup(g) => g.title.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::{ConversationRow, ConversationRowEntry, MessageRowContent, ToolRow};
    use crate::conversation_contracts::render_hints::RenderHints;
    use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};
    use crate::{ImageInput, Provider};

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
                memory_citation: None,
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

    #[test]
    fn flat_invocation_passes_through_unchanged() {
        // Current format: flat JSON, correct kind — should not be affected
        let row = ToolRow {
            id: "toolu_abc".into(),
            provider: Provider::Claude,
            family: ToolFamily::Shell,
            kind: ToolKind::Bash,
            status: ToolStatus::Completed,
            title: "Bash".into(),
            subtitle: None,
            summary: None,
            preview: None,
            started_at: None,
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: serde_json::json!({"command": "ls -la"}),
            result: Some(serde_json::json!({"output": "file1\nfile2"})),
            render_hints: RenderHints::default(),
            tool_display: None,
        };

        let summary = row.to_summary();
        assert_eq!(summary.kind, ToolKind::Bash);
        assert_eq!(summary.family, ToolFamily::Shell);
        assert_eq!(summary.tool_display.tool_type, "bash");
    }
}
