//! Codex-specific normalization over the shared provider event skeleton.

use serde::{Deserialize, Serialize};

use crate::provider_normalization::{
    NormalizedProviderEvent, ProviderEventAction, ProviderEventCorrelation, ProviderEventDomain,
    ProviderEventSource, ProviderEventStatus,
};
use crate::Provider;

/// Codex-specific payload carried inside a normalized provider event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexNormalizedPayload {
    pub source_kind: CodexSourceKind,
    pub concept: CodexConcept,
    pub raw_event_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_operation: Option<CodexThreadOperation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
}

/// Codex raw source kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexSourceKind {
    ProtocolEvent,
    ResponseItem,
    RolloutEvent,
}

/// Codex runtime/tool/thread concept distilled from raw protocol or rollout terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexConcept {
    SessionLifecycle,
    ThreadLifecycle,
    ConversationMessage,
    Reasoning,
    ToolCall,
    Permission,
    Collaboration,
    Plan,
    ContextManagement,
    TokenUsage,
    HookExecution,
    Capability,
    Realtime,
    Error,
    Unknown,
}

/// Coarse thread-centric action preserved from raw Codex names when available.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexThreadOperation {
    Rename,
    Rollback,
    Compaction,
    Spawn,
    Interact,
    Wait,
    Close,
    Resume,
    Handoff,
    End,
}

pub type CodexNormalizedEvent = NormalizedProviderEvent<CodexNormalizedPayload>;

/// Normalize a Codex protocol event name from the live event stream.
pub fn normalize_protocol_event(
    event_name: &str,
    correlation: ProviderEventCorrelation,
) -> CodexNormalizedEvent {
    let raw_event_name = event_name.trim();
    let normalized = normalized_name(raw_event_name);

    let (domain, action, status, concept, thread_operation, tool_name) = match normalized.as_str() {
        "turnstarted" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            CodexConcept::SessionLifecycle,
            None,
            None,
        ),
        "turncomplete" | "turncompleted" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            CodexConcept::SessionLifecycle,
            None,
            None,
        ),
        "turnaborted" | "shutdowncomplete" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Failed,
            Some(ProviderEventStatus::Failed),
            CodexConcept::SessionLifecycle,
            Some(CodexThreadOperation::End),
            None,
        ),
        "sessionconfigured" | "modelreroute" | "undostarted" | "undocompleted" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::SessionLifecycle,
            None,
            None,
        ),
        "usermessage" | "agentmessage" | "warning" | "backgroundevent" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Emitted,
            None,
            CodexConcept::ConversationMessage,
            None,
            None,
        ),
        "agentmessagedelta" | "agentmessagecontentdelta" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            CodexConcept::ConversationMessage,
            None,
            None,
        ),
        "agentreasoning" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Emitted,
            None,
            CodexConcept::Reasoning,
            None,
            None,
        ),
        "agentreasoningdelta"
        | "reasoningcontentdelta"
        | "reasoningrawcontentdelta"
        | "agentreasoningrawcontent"
        | "agentreasoningrawcontentdelta"
        | "agentreasoningsectionbreak" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            CodexConcept::Reasoning,
            None,
            None,
        ),
        "execcommandbegin" | "execcommandoutputdelta" | "execcommandend" => (
            ProviderEventDomain::Tool,
            tool_action_for_name(normalized.as_str()),
            tool_status_for_name(normalized.as_str()),
            CodexConcept::ToolCall,
            None,
            Some("exec_command".to_string()),
        ),
        "patchapplybegin" | "patchapplyend" => (
            ProviderEventDomain::Tool,
            tool_action_for_name(normalized.as_str()),
            tool_status_for_name(normalized.as_str()),
            CodexConcept::ToolCall,
            None,
            Some("apply_patch".to_string()),
        ),
        "mcptoolcallbegin" | "mcptoolcallend" => (
            ProviderEventDomain::Tool,
            tool_action_for_name(normalized.as_str()),
            tool_status_for_name(normalized.as_str()),
            CodexConcept::ToolCall,
            None,
            Some("mcp_tool".to_string()),
        ),
        "websearchbegin" | "websearchend" => (
            ProviderEventDomain::Tool,
            tool_action_for_name(normalized.as_str()),
            tool_status_for_name(normalized.as_str()),
            CodexConcept::ToolCall,
            None,
            Some("web_search".to_string()),
        ),
        "viewimagetoolcall" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            CodexConcept::ToolCall,
            None,
            Some("view_image".to_string()),
        ),
        "dynamictoolcallrequest" | "dynamictoolcallresponse" => (
            ProviderEventDomain::Tool,
            tool_action_for_name(normalized.as_str()),
            tool_status_for_name(normalized.as_str()),
            CodexConcept::ToolCall,
            None,
            Some("dynamic_tool".to_string()),
        ),
        "terminalinteraction" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            CodexConcept::ToolCall,
            None,
            Some("exec_command".to_string()),
        ),
        "execapprovalrequest" | "applypatchapprovalrequest" | "requestpermissions" => (
            ProviderEventDomain::Permission,
            ProviderEventAction::Requested,
            None,
            CodexConcept::Permission,
            None,
            approval_tool_name(normalized.as_str()),
        ),
        "requestuserinput" | "elicitationrequest" => (
            ProviderEventDomain::Elicitation,
            ProviderEventAction::Requested,
            None,
            CodexConcept::Permission,
            None,
            Some("ask_user_question".to_string()),
        ),
        "tokencount" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::TokenUsage,
            None,
            None,
        ),
        "planupdate" | "plandelta" | "enteredreviewmode" | "exitedreviewmode" => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Changed,
            None,
            CodexConcept::Plan,
            None,
            plan_tool_name(normalized.as_str()),
        ),
        "contextcompacted" => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Compacted),
            CodexConcept::ContextManagement,
            Some(CodexThreadOperation::Compaction),
            Some("compact_context".to_string()),
        ),
        "hookstarted" | "hookcompleted" => (
            ProviderEventDomain::Hook,
            hook_action_for_name(normalized.as_str()),
            hook_status_for_name(normalized.as_str()),
            CodexConcept::HookExecution,
            None,
            Some("hook".to_string()),
        ),
        "threadnameupdated" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::ThreadLifecycle,
            Some(CodexThreadOperation::Rename),
            None,
        ),
        "threadrolledback" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::ThreadLifecycle,
            Some(CodexThreadOperation::Rollback),
            None,
        ),
        "collabagentspawnbegin" | "collabagentspawnend" => (
            ProviderEventDomain::Subagent,
            collab_action_for_name(normalized.as_str()),
            collab_status_for_name(normalized.as_str()),
            CodexConcept::Collaboration,
            Some(CodexThreadOperation::Spawn),
            Some("task".to_string()),
        ),
        "collabagentinteractionbegin" | "collabagentinteractionend" => (
            ProviderEventDomain::Subagent,
            collab_action_for_name(normalized.as_str()),
            collab_status_for_name(normalized.as_str()),
            CodexConcept::Collaboration,
            Some(CodexThreadOperation::Interact),
            Some("task".to_string()),
        ),
        "collabwaitingbegin" | "collabwaitingend" => (
            ProviderEventDomain::Subagent,
            collab_action_for_name(normalized.as_str()),
            collab_status_for_name(normalized.as_str()),
            CodexConcept::Collaboration,
            Some(CodexThreadOperation::Wait),
            Some("task".to_string()),
        ),
        "collabclosebegin" | "collabcloseend" => (
            ProviderEventDomain::Subagent,
            collab_action_for_name(normalized.as_str()),
            collab_status_for_name(normalized.as_str()),
            CodexConcept::Collaboration,
            Some(CodexThreadOperation::Close),
            Some("task".to_string()),
        ),
        "collabresumebegin" | "collabresumeend" => (
            ProviderEventDomain::Subagent,
            collab_action_for_name(normalized.as_str()),
            collab_status_for_name(normalized.as_str()),
            CodexConcept::Collaboration,
            Some(CodexThreadOperation::Resume),
            Some("task".to_string()),
        ),
        "realtimeconversationstarted"
        | "realtimeconversationrealtime"
        | "realtimeconversationclosed" => (
            ProviderEventDomain::Session,
            realtime_action_for_name(normalized.as_str()),
            realtime_status_for_name(normalized.as_str()),
            CodexConcept::Realtime,
            Some(CodexThreadOperation::Handoff),
            Some("handoff".to_string()),
        ),
        "rawresponseitem"
        | "deprecationnotice"
        | "skillsupdateavailable"
        | "mcpstartupupdate"
        | "mcpstartupcomplete"
        | "mcplisttoolsresponse"
        | "listskillsresponse"
        | "listremoteskillsresponse"
        | "remoteskilldownloaded"
        | "listcustompromptsresponse"
        | "gethistoryentryresponse" => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Changed,
            None,
            CodexConcept::Capability,
            None,
            None,
        ),
        "streamerror" | "error" => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Failed,
            Some(ProviderEventStatus::Failed),
            CodexConcept::Error,
            None,
            None,
        ),
        _ => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Unknown,
            Some(ProviderEventStatus::Unknown),
            CodexConcept::Unknown,
            None,
            infer_tool_name(raw_event_name),
        ),
    };

    normalized_event(
        ProviderEventSource::SdkMessage,
        raw_event_name,
        domain,
        action,
        status,
        concept,
        thread_operation,
        tool_name,
        correlation,
    )
}

/// Normalize a raw Codex response item kind.
pub fn normalize_response_item(
    item_kind: &str,
    correlation: ProviderEventCorrelation,
) -> CodexNormalizedEvent {
    let raw_event_name = item_kind.trim();
    let normalized = normalized_name(raw_event_name);

    let (domain, action, status, concept, tool_name) = match normalized.as_str() {
        "message" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Completed,
            None,
            CodexConcept::ConversationMessage,
            None,
        ),
        "functioncall" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            CodexConcept::ToolCall,
            Some("function_call".to_string()),
        ),
        "functioncalloutput" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            CodexConcept::ToolCall,
            Some("function_call".to_string()),
        ),
        "reasoning" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Completed,
            None,
            CodexConcept::Reasoning,
            None,
        ),
        _ => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Unknown,
            Some(ProviderEventStatus::Unknown),
            CodexConcept::Unknown,
            None,
        ),
    };

    normalized_event(
        ProviderEventSource::ResponseItem,
        raw_event_name,
        domain,
        action,
        status,
        concept,
        None,
        tool_name,
        correlation,
    )
}

/// Normalize a rollout-parser event name from passive Codex watching.
pub fn normalize_rollout_event(
    event_name: &str,
    correlation: ProviderEventCorrelation,
) -> CodexNormalizedEvent {
    let raw_event_name = event_name.trim();
    let normalized = normalized_name(raw_event_name);

    let (domain, action, status, concept, thread_operation, tool_name) = match normalized.as_str() {
        "sessionmeta" | "turncontext" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Started,
            None,
            CodexConcept::SessionLifecycle,
            None,
            None,
        ),
        "workstatechange" | "clearpending" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::SessionLifecycle,
            None,
            None,
        ),
        "usermessage" | "appendchatmessage" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Emitted,
            None,
            CodexConcept::ConversationMessage,
            None,
            None,
        ),
        "shellcommandbegin" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            CodexConcept::ToolCall,
            None,
            Some("exec_command".to_string()),
        ),
        "shellcommandend" | "toolcompleted" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            CodexConcept::ToolCall,
            None,
            Some("exec_command".to_string()),
        ),
        "tokencount" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::TokenUsage,
            None,
            None,
        ),
        "threadnameupdated" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            CodexConcept::ThreadLifecycle,
            Some(CodexThreadOperation::Rename),
            None,
        ),
        "planupdated" => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Changed,
            None,
            CodexConcept::Plan,
            None,
            Some("update_plan".to_string()),
        ),
        "diffupdated" => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Changed,
            None,
            CodexConcept::ContextManagement,
            None,
            Some("diff".to_string()),
        ),
        "sessionended" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            CodexConcept::ThreadLifecycle,
            Some(CodexThreadOperation::End),
            None,
        ),
        "subagentsupdated" => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Changed,
            None,
            CodexConcept::Collaboration,
            Some(CodexThreadOperation::Interact),
            Some("task".to_string()),
        ),
        _ => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Unknown,
            Some(ProviderEventStatus::Unknown),
            CodexConcept::Unknown,
            None,
            None,
        ),
    };

    normalized_event(
        ProviderEventSource::Hook,
        raw_event_name,
        domain,
        action,
        status,
        concept,
        thread_operation,
        tool_name,
        correlation,
    )
}

#[allow(clippy::too_many_arguments)]
fn normalized_event(
    source: ProviderEventSource,
    raw_event_name: &str,
    domain: ProviderEventDomain,
    action: ProviderEventAction,
    status: Option<ProviderEventStatus>,
    concept: CodexConcept,
    thread_operation: Option<CodexThreadOperation>,
    tool_name: Option<String>,
    correlation: ProviderEventCorrelation,
) -> CodexNormalizedEvent {
    CodexNormalizedEvent {
        provider: Provider::Codex,
        source,
        domain,
        action,
        status,
        correlation: correlation.into_some(),
        payload: CodexNormalizedPayload {
            source_kind: source_kind_for_source(source),
            concept,
            raw_event_name: raw_event_name.to_string(),
            thread_operation,
            tool_name,
        },
    }
}

fn source_kind_for_source(source: ProviderEventSource) -> CodexSourceKind {
    match source {
        ProviderEventSource::SdkMessage => CodexSourceKind::ProtocolEvent,
        ProviderEventSource::SdkControlRequest => CodexSourceKind::ProtocolEvent,
        ProviderEventSource::Hook => CodexSourceKind::RolloutEvent,
        ProviderEventSource::Rollout => CodexSourceKind::RolloutEvent,
        ProviderEventSource::ResponseItem => CodexSourceKind::ResponseItem,
    }
}

fn normalized_name(value: &str) -> String {
    value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect()
}

fn infer_tool_name(raw_event_name: &str) -> Option<String> {
    let normalized = normalized_name(raw_event_name);
    if normalized.contains("mcp") {
        return Some("mcp_tool".to_string());
    }
    if normalized.contains("exec") || normalized.contains("shell") || normalized.contains("bash") {
        return Some("exec_command".to_string());
    }
    if normalized.contains("patch") || normalized.contains("edit") {
        return Some("apply_patch".to_string());
    }
    if normalized.contains("plan") {
        return Some("update_plan".to_string());
    }
    if normalized.contains("hook") {
        return Some("hook".to_string());
    }
    if normalized.contains("task") || normalized.contains("collab") {
        return Some("task".to_string());
    }
    None
}

fn tool_action_for_name(normalized: &str) -> ProviderEventAction {
    if normalized.ends_with("begin") || normalized.ends_with("request") {
        ProviderEventAction::Started
    } else if normalized.ends_with("delta") || normalized == "terminalinteraction" {
        ProviderEventAction::Updated
    } else if normalized.ends_with("end") || normalized.ends_with("response") {
        ProviderEventAction::Completed
    } else {
        ProviderEventAction::Changed
    }
}

fn tool_status_for_name(normalized: &str) -> Option<ProviderEventStatus> {
    if normalized.ends_with("begin")
        || normalized.ends_with("delta")
        || normalized.ends_with("request")
    {
        Some(ProviderEventStatus::InProgress)
    } else if normalized.ends_with("end") || normalized.ends_with("response") {
        Some(ProviderEventStatus::Success)
    } else {
        None
    }
}

fn approval_tool_name(normalized: &str) -> Option<String> {
    match normalized {
        "execapprovalrequest" => Some("exec_command".to_string()),
        "applypatchapprovalrequest" => Some("apply_patch".to_string()),
        "requestpermissions" => Some("request_permissions".to_string()),
        _ => None,
    }
}

fn plan_tool_name(normalized: &str) -> Option<String> {
    match normalized {
        "planupdate" | "plandelta" => Some("update_plan".to_string()),
        "enteredreviewmode" | "exitedreviewmode" => Some("review_mode".to_string()),
        _ => None,
    }
}

fn hook_action_for_name(normalized: &str) -> ProviderEventAction {
    match normalized {
        "hookstarted" => ProviderEventAction::Started,
        "hookcompleted" => ProviderEventAction::Completed,
        _ => ProviderEventAction::Changed,
    }
}

fn hook_status_for_name(normalized: &str) -> Option<ProviderEventStatus> {
    match normalized {
        "hookstarted" => Some(ProviderEventStatus::InProgress),
        "hookcompleted" => Some(ProviderEventStatus::Success),
        _ => None,
    }
}

fn collab_action_for_name(normalized: &str) -> ProviderEventAction {
    if normalized.ends_with("begin") {
        ProviderEventAction::Started
    } else if normalized.ends_with("end") {
        ProviderEventAction::Completed
    } else {
        ProviderEventAction::Changed
    }
}

fn collab_status_for_name(normalized: &str) -> Option<ProviderEventStatus> {
    if normalized.ends_with("begin") {
        Some(ProviderEventStatus::InProgress)
    } else if normalized.ends_with("end") {
        Some(ProviderEventStatus::Success)
    } else {
        None
    }
}

fn realtime_action_for_name(normalized: &str) -> ProviderEventAction {
    match normalized {
        "realtimeconversationstarted" => ProviderEventAction::Started,
        "realtimeconversationclosed" => ProviderEventAction::Completed,
        _ => ProviderEventAction::Changed,
    }
}

fn realtime_status_for_name(normalized: &str) -> Option<ProviderEventStatus> {
    match normalized {
        "realtimeconversationstarted" => Some(ProviderEventStatus::InProgress),
        "realtimeconversationclosed" => Some(ProviderEventStatus::Success),
        _ => None,
    }
}

trait CorrelationExt {
    fn into_some(self) -> Option<Self>
    where
        Self: Sized;
}

impl CorrelationExt for ProviderEventCorrelation {
    fn into_some(self) -> Option<Self> {
        if self == ProviderEventCorrelation::default() {
            None
        } else {
            Some(self)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        normalize_protocol_event, normalize_response_item, normalize_rollout_event, CodexConcept,
        CodexSourceKind, CodexThreadOperation,
    };
    use crate::provider_normalization::{
        ProviderEventAction, ProviderEventCorrelation, ProviderEventDomain, ProviderEventSource,
        ProviderEventStatus,
    };
    use crate::Provider;

    #[test]
    fn protocol_exec_begin_maps_to_started_tool_event() {
        let event = normalize_protocol_event(
            "ExecCommandBegin",
            ProviderEventCorrelation {
                session_id: Some("session-1".into()),
                tool_use_id: Some("call-1".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.provider, Provider::Codex);
        assert_eq!(event.source, ProviderEventSource::SdkMessage);
        assert_eq!(event.domain, ProviderEventDomain::Tool);
        assert_eq!(event.action, ProviderEventAction::Started);
        assert_eq!(event.status, Some(ProviderEventStatus::InProgress));
        assert_eq!(event.payload.source_kind, CodexSourceKind::ProtocolEvent);
        assert_eq!(event.payload.concept, CodexConcept::ToolCall);
        assert_eq!(event.payload.tool_name.as_deref(), Some("exec_command"));
    }

    #[test]
    fn protocol_thread_rename_preserves_thread_operation() {
        let event = normalize_protocol_event(
            "ThreadNameUpdated",
            ProviderEventCorrelation {
                session_id: Some("session-2".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.domain, ProviderEventDomain::Session);
        assert_eq!(event.action, ProviderEventAction::Changed);
        assert_eq!(event.payload.concept, CodexConcept::ThreadLifecycle);
        assert_eq!(
            event.payload.thread_operation,
            Some(CodexThreadOperation::Rename)
        );
    }

    #[test]
    fn protocol_collab_wait_maps_to_subagent_domain() {
        let event = normalize_protocol_event(
            "CollabWaitingBegin",
            ProviderEventCorrelation {
                agent_id: Some("thread-child".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.domain, ProviderEventDomain::Subagent);
        assert_eq!(event.action, ProviderEventAction::Started);
        assert_eq!(event.status, Some(ProviderEventStatus::InProgress));
        assert_eq!(event.payload.concept, CodexConcept::Collaboration);
        assert_eq!(
            event.payload.thread_operation,
            Some(CodexThreadOperation::Wait)
        );
        assert_eq!(event.payload.tool_name.as_deref(), Some("task"));
    }

    #[test]
    fn response_item_function_call_maps_to_started_tool() {
        let event = normalize_response_item(
            "function_call",
            ProviderEventCorrelation {
                tool_use_id: Some("call-2".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.source, ProviderEventSource::ResponseItem);
        assert_eq!(event.domain, ProviderEventDomain::Tool);
        assert_eq!(event.action, ProviderEventAction::Started);
        assert_eq!(event.status, Some(ProviderEventStatus::InProgress));
        assert_eq!(event.payload.tool_name.as_deref(), Some("function_call"));
    }

    #[test]
    fn rollout_session_end_maps_to_completed_thread_lifecycle() {
        let event = normalize_rollout_event(
            "SessionEnded",
            ProviderEventCorrelation {
                session_id: Some("session-3".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.source, ProviderEventSource::Hook);
        assert_eq!(event.domain, ProviderEventDomain::Session);
        assert_eq!(event.action, ProviderEventAction::Completed);
        assert_eq!(event.status, Some(ProviderEventStatus::Success));
        assert_eq!(event.payload.concept, CodexConcept::ThreadLifecycle);
        assert_eq!(
            event.payload.thread_operation,
            Some(CodexThreadOperation::End)
        );
    }
}
