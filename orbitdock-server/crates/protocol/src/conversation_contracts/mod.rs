//! Typed API conversation contracts for native clients.
//!
//! These are the server-authored rows the Swift client should consume directly,
//! without provider-specific parsing in the UI layer.

pub mod activity_groups;
pub mod approvals;
pub mod render_hints;
pub mod rows;
pub mod tool_display;
pub mod tool_payloads;
pub mod workers;

pub use activity_groups::{ActivityGroupKind, ActivityGroupRow, ActivityGroupRowSummary};
pub use approvals::{ApprovalRow, QuestionRow};
pub use render_hints::{ConversationDisplayMode, RenderHints};
pub use rows::{
    extract_row_content_str, extract_row_content_str_summary, AssistantRow, ContextRow,
    ContextRowKind, ConversationRow, ConversationRowEntry, ConversationRowPage,
    ConversationRowSummary, HandoffRow, HookRow, MemoryCitation, MemoryCitationEntry,
    MessageRowContent, NoticeRow, NoticeRowKind, NoticeRowSeverity, PlanRow, RowEntrySummary,
    RowPageSummary, ShellCommandRow, ShellCommandRowKind, SystemRow, TaskRow, TaskRowKind,
    TaskRowStatus, ThinkingRow, ToolRow, ToolRowSummary, UserRow,
};
pub use tool_display::{
    classify_tool_name, compute_diff_display, compute_expanded_output, compute_input_display,
    compute_tool_display, detect_language, extract_start_line, DiffLine, DiffLineKind,
    ToolDiffPreview, ToolDisplay, ToolTodoItem,
};
pub use tool_payloads::{ToolInvocationPayloadContract, ToolPreview, ToolResultPayloadContract};
pub use workers::WorkerRow;
