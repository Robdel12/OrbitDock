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

pub use activity_groups::{ActivityGroupKind, ActivityGroupRow};
pub use approvals::{ApprovalRow, QuestionRow};
pub use render_hints::{ConversationDisplayMode, RenderHints};
pub use rows::{
    extract_row_content_str, AssistantRow, ConversationRow, ConversationRowEntry,
    ConversationRowPage, HandoffRow, HookRow, MessageRowContent, PlanRow, SystemRow, ThinkingRow,
    ToolRow, UserRow,
};
pub use tool_display::{
    compute_diff_display, compute_expanded_output, compute_input_display, compute_tool_display,
    detect_language, ToolDiffPreview, ToolDisplay, ToolTodoItem,
};
pub use tool_payloads::{ToolInvocationPayloadContract, ToolPreview, ToolResultPayloadContract};
pub use workers::WorkerRow;
