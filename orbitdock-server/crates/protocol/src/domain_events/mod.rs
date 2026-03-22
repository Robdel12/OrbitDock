//! Provider-neutral domain events for OrbitDock conversations.
//!
//! These types sit between provider normalization and the API conversation
//! contracts. They should express OrbitDock's semantic understanding of the
//! conversation without leaking renderer concerns.

pub mod approvals;
pub mod conversation;
pub mod lifecycle;
pub mod tooling;
pub mod workers;

pub use approvals::{
    ApprovalChoice, ApprovalEvent, ApprovalPreview, ApprovalRequestKind, ApprovalRequestPayload,
    PermissionDescriptor, PermissionRequestPayload, PermissionScope, PermissionSuggestion,
    QuestionEvent, QuestionOption, QuestionPrompt, QuestionResponseValue,
};
pub use conversation::{
    AssistantMessageEvent, ContextEvent, ConversationEvent, HandoffEvent, HookEvent, PlanEvent,
    ReasoningEvent, SystemEvent, ThinkingEvent, ToolEvent, UserMessageEvent,
};
pub use lifecycle::{SessionLifecycleEvent, SessionLifecycleKind};
pub use tooling::{
    CommandExecutionPayload, ConfigPayload, ContextCompactionPayload, FileChangePayload,
    FileReadPayload, GenericInvocationPayload, GenericResultPayload, GroupingKey,
    GuardianAssessmentPayload, HandoffPayload, HookOutputEntry, HookPayload,
    ImageGenerationPayload, ImageViewPayload, McpToolPayload, PlanModePayload, PlanStepPayload,
    PlanStepStatus, QuestionToolPayload, SearchInvocationPayload, SearchResultPayload,
    TodoItemPayload, TodoPayload, ToolFamily, ToolInvocationPayload, ToolKind, ToolPreviewPayload,
    ToolResultPayload, ToolStatus, WebFetchPayload, WebSearchPayload, WorkerInvocationPayload,
    WorkerResultPayload,
};
pub use workers::{
    WorkerEvent, WorkerLifecycleKind, WorkerOperationKind, WorkerPeerRef, WorkerStateSnapshot,
};
