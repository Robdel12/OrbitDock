use serde::{Deserialize, Serialize};

use crate::domain_events::approvals::{ApprovalEvent, QuestionEvent};
use crate::domain_events::tooling::{
    GroupingKey, HandoffPayload, HookPayload, PlanModePayload, ToolFamily, ToolInvocationPayload,
    ToolKind, ToolResultPayload, ToolStatus,
};
use crate::domain_events::workers::WorkerEvent;
use crate::Provider;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserMessageEvent {
    pub id: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<crate::ImageInput>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AssistantMessageEvent {
    pub id: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThinkingEvent {
    pub id: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolEvent {
    pub id: String,
    pub provider: Provider,
    pub family: ToolFamily,
    pub kind: ToolKind,
    pub status: ToolStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grouping_key: Option<GroupingKey>,
    pub invocation: ToolInvocationPayload,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<ToolResultPayload>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookEvent {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub payload: HookPayload,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HandoffEvent {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub payload: HandoffPayload,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanEvent {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub payload: PlanModePayload,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReasoningEvent {
    pub id: String,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextEvent {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SystemEvent {
    pub id: String,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event_type", rename_all = "snake_case")]
pub enum ConversationEvent {
    UserMessage(UserMessageEvent),
    AssistantMessage(AssistantMessageEvent),
    Thinking(ThinkingEvent),
    Tool(ToolEvent),
    Approval(ApprovalEvent),
    Question(QuestionEvent),
    Worker(WorkerEvent),
    Plan(PlanEvent),
    Hook(HookEvent),
    Handoff(HandoffEvent),
    Reasoning(ReasoningEvent),
    Context(ContextEvent),
    System(SystemEvent),
}
