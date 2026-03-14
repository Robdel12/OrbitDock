//! Claude-specific normalization over the shared provider event skeleton.

use serde::{Deserialize, Serialize};

use crate::provider_normalization::{
    NormalizedProviderEvent, ProviderEventAction, ProviderEventCorrelation, ProviderEventDomain,
    ProviderEventSource, ProviderEventStatus,
};
use crate::Provider;

/// Claude-specific payload carried inside a normalized provider event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClaudeNormalizedPayload {
    pub source_kind: ClaudeSourceKind,
    pub concept: ClaudeConcept,
    pub raw_event_name: String,
}

/// Claude raw source kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeSourceKind {
    Hook,
    SdkMessage,
    SdkControlRequest,
}

/// Claude runtime/tool concept distilled from raw SDK or hook terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeConcept {
    SessionLifecycle,
    ConversationMessage,
    PartialAssistantStream,
    ToolCall,
    Permission,
    PlanMode,
    Compaction,
    HookExecution,
    Task,
    Subagent,
    RateLimit,
    Auth,
    FilePersistence,
    Elicitation,
    PromptSuggestion,
    Unknown,
}

pub type ClaudeNormalizedEvent = NormalizedProviderEvent<ClaudeNormalizedPayload>;

/// Normalize a Claude SDK message type/subtype pair.
pub fn normalize_sdk_message(
    message_type: &str,
    subtype: Option<&str>,
    correlation: ProviderEventCorrelation,
) -> ClaudeNormalizedEvent {
    let message_type = message_type.trim();
    let subtype = subtype.map(str::trim).filter(|value| !value.is_empty());
    let raw_event_name = subtype
        .map(|value| format!("{message_type}:{value}"))
        .unwrap_or_else(|| message_type.to_string());

    let (domain, action, status, concept) = match (message_type, subtype) {
        ("assistant", _) => (
            ProviderEventDomain::Message,
            ProviderEventAction::Completed,
            None,
            ClaudeConcept::ConversationMessage,
        ),
        ("user", _) => (
            ProviderEventDomain::Message,
            ProviderEventAction::Emitted,
            None,
            ClaudeConcept::ConversationMessage,
        ),
        ("stream_event", _) => (
            ProviderEventDomain::Message,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::PartialAssistantStream,
        ),
        ("tool_progress", _) => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::ToolCall,
        ),
        ("tool_use_summary", _) => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            ClaudeConcept::ToolCall,
        ),
        ("result", Some("success")) => (
            ProviderEventDomain::Session,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            ClaudeConcept::SessionLifecycle,
        ),
        (
            "result",
            Some(
                "error_during_execution"
                | "error_max_turns"
                | "error_max_budget_usd"
                | "error_max_structured_output_retries",
            ),
        ) => (
            ProviderEventDomain::Session,
            ProviderEventAction::Failed,
            Some(ProviderEventStatus::Failed),
            ClaudeConcept::SessionLifecycle,
        ),
        ("system", Some("init")) => (
            ProviderEventDomain::Session,
            ProviderEventAction::Started,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        ("system", Some("status")) => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        ("system", Some("compact_boundary")) => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Compacted),
            ClaudeConcept::Compaction,
        ),
        ("system", Some("hook_started")) => (
            ProviderEventDomain::Hook,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::HookExecution,
        ),
        ("system", Some("hook_progress")) => (
            ProviderEventDomain::Hook,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::HookExecution,
        ),
        ("system", Some("hook_response")) => (
            ProviderEventDomain::Hook,
            ProviderEventAction::Responded,
            None,
            ClaudeConcept::HookExecution,
        ),
        ("system", Some("task_started")) => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::Subagent,
        ),
        ("system", Some("task_progress")) => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Updated,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::Subagent,
        ),
        ("system", Some("task_notification")) => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Completed,
            None,
            ClaudeConcept::Subagent,
        ),
        ("system", Some("files_persisted")) => (
            ProviderEventDomain::Files,
            ProviderEventAction::Persisted,
            None,
            ClaudeConcept::FilePersistence,
        ),
        ("system", Some("elicitation_complete")) => (
            ProviderEventDomain::Elicitation,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            ClaudeConcept::Elicitation,
        ),
        ("system", Some("local_command_output")) => (
            ProviderEventDomain::Message,
            ProviderEventAction::Emitted,
            None,
            ClaudeConcept::ConversationMessage,
        ),
        ("auth_status", _) => (
            ProviderEventDomain::Auth,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::Auth,
        ),
        ("rate_limit_event", _) => (
            ProviderEventDomain::RateLimit,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::RateLimit,
        ),
        ("prompt_suggestion", _) => (
            ProviderEventDomain::Prompt,
            ProviderEventAction::Suggested,
            None,
            ClaudeConcept::PromptSuggestion,
        ),
        _ => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Unknown,
            Some(ProviderEventStatus::Unknown),
            ClaudeConcept::Unknown,
        ),
    };

    ClaudeNormalizedEvent {
        provider: Provider::Claude,
        source: ProviderEventSource::SdkMessage,
        domain,
        action,
        status,
        correlation: correlation.into_some(),
        payload: ClaudeNormalizedPayload {
            source_kind: ClaudeSourceKind::SdkMessage,
            concept,
            raw_event_name,
        },
    }
}

/// Normalize a Claude SDK control request subtype.
pub fn normalize_sdk_control_request(
    subtype: &str,
    correlation: ProviderEventCorrelation,
) -> ClaudeNormalizedEvent {
    let subtype = subtype.trim();
    let (domain, action, status, concept) = match subtype {
        "can_use_tool" => (
            ProviderEventDomain::Permission,
            ProviderEventAction::Requested,
            None,
            ClaudeConcept::Permission,
        ),
        "set_permission_mode" => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::PlanMode,
        ),
        "stop_task" => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Requested,
            None,
            ClaudeConcept::Subagent,
        ),
        "elicitation" => (
            ProviderEventDomain::Elicitation,
            ProviderEventAction::Requested,
            None,
            ClaudeConcept::Elicitation,
        ),
        _ => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Unknown,
            Some(ProviderEventStatus::Unknown),
            ClaudeConcept::Unknown,
        ),
    };

    ClaudeNormalizedEvent {
        provider: Provider::Claude,
        source: ProviderEventSource::SdkControlRequest,
        domain,
        action,
        status,
        correlation: correlation.into_some(),
        payload: ClaudeNormalizedPayload {
            source_kind: ClaudeSourceKind::SdkControlRequest,
            concept,
            raw_event_name: subtype.to_string(),
        },
    }
}

/// Normalize a Claude hook event name.
pub fn normalize_hook_event(
    hook_event_name: &str,
    correlation: ProviderEventCorrelation,
) -> ClaudeNormalizedEvent {
    let hook_event_name = hook_event_name.trim();
    let (domain, action, status, concept) = match hook_event_name {
        "SessionStart" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Started,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        "SessionEnd" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Completed,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        "UserPromptSubmit" => (
            ProviderEventDomain::Message,
            ProviderEventAction::Emitted,
            None,
            ClaudeConcept::ConversationMessage,
        ),
        "PreToolUse" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::ToolCall,
        ),
        "PostToolUse" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            ClaudeConcept::ToolCall,
        ),
        "PostToolUseFailure" => (
            ProviderEventDomain::Tool,
            ProviderEventAction::Failed,
            Some(ProviderEventStatus::Failed),
            ClaudeConcept::ToolCall,
        ),
        "PermissionRequest" => (
            ProviderEventDomain::Permission,
            ProviderEventAction::Requested,
            None,
            ClaudeConcept::Permission,
        ),
        "PreCompact" => (
            ProviderEventDomain::Plan,
            ProviderEventAction::Requested,
            None,
            ClaudeConcept::Compaction,
        ),
        "SubagentStart" => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Started,
            Some(ProviderEventStatus::InProgress),
            ClaudeConcept::Subagent,
        ),
        "SubagentStop" | "TaskCompleted" => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Completed,
            Some(ProviderEventStatus::Success),
            ClaudeConcept::Subagent,
        ),
        "TeammateIdle" => (
            ProviderEventDomain::Subagent,
            ProviderEventAction::Changed,
            Some(ProviderEventStatus::Idle),
            ClaudeConcept::Subagent,
        ),
        "Notification" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Emitted,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        "Stop" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        "Elicitation" => (
            ProviderEventDomain::Elicitation,
            ProviderEventAction::Requested,
            None,
            ClaudeConcept::Elicitation,
        ),
        "ElicitationResult" => (
            ProviderEventDomain::Elicitation,
            ProviderEventAction::Responded,
            None,
            ClaudeConcept::Elicitation,
        ),
        "Setup" | "InstructionsLoaded" | "ConfigChange" => (
            ProviderEventDomain::Session,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::SessionLifecycle,
        ),
        "WorktreeCreate" | "WorktreeRemove" => (
            ProviderEventDomain::Task,
            ProviderEventAction::Changed,
            None,
            ClaudeConcept::Task,
        ),
        _ => (
            ProviderEventDomain::Unknown,
            ProviderEventAction::Unknown,
            Some(ProviderEventStatus::Unknown),
            ClaudeConcept::Unknown,
        ),
    };

    ClaudeNormalizedEvent {
        provider: Provider::Claude,
        source: ProviderEventSource::Hook,
        domain,
        action,
        status,
        correlation: correlation.into_some(),
        payload: ClaudeNormalizedPayload {
            source_kind: ClaudeSourceKind::Hook,
            concept,
            raw_event_name: hook_event_name.to_string(),
        },
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
        normalize_hook_event, normalize_sdk_control_request, normalize_sdk_message, ClaudeConcept,
    };
    use crate::provider_normalization::{
        ProviderEventAction, ProviderEventCorrelation, ProviderEventDomain, ProviderEventSource,
        ProviderEventStatus,
    };
    use crate::Provider;

    #[test]
    fn sdk_tool_progress_maps_to_tool_update() {
        let event = normalize_sdk_message(
            "tool_progress",
            None,
            ProviderEventCorrelation {
                tool_use_id: Some("tool-1".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.provider, Provider::Claude);
        assert_eq!(event.source, ProviderEventSource::SdkMessage);
        assert_eq!(event.domain, ProviderEventDomain::Tool);
        assert_eq!(event.action, ProviderEventAction::Updated);
        assert_eq!(event.status, Some(ProviderEventStatus::InProgress));
        assert_eq!(event.payload.concept, ClaudeConcept::ToolCall);
        assert_eq!(
            event
                .correlation
                .as_ref()
                .and_then(|value| value.tool_use_id.as_deref()),
            Some("tool-1")
        );
    }

    #[test]
    fn sdk_permission_control_maps_to_permission_request() {
        let event = normalize_sdk_control_request(
            "can_use_tool",
            ProviderEventCorrelation {
                tool_use_id: Some("tool-2".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.source, ProviderEventSource::SdkControlRequest);
        assert_eq!(event.domain, ProviderEventDomain::Permission);
        assert_eq!(event.action, ProviderEventAction::Requested);
        assert_eq!(event.payload.concept, ClaudeConcept::Permission);
    }

    #[test]
    fn sdk_set_permission_mode_maps_to_plan_mode_change() {
        let event = normalize_sdk_control_request(
            "set_permission_mode",
            ProviderEventCorrelation::default(),
        );

        assert_eq!(event.domain, ProviderEventDomain::Plan);
        assert_eq!(event.action, ProviderEventAction::Changed);
        assert_eq!(event.payload.concept, ClaudeConcept::PlanMode);
        assert_eq!(event.correlation, None);
    }

    #[test]
    fn hook_tool_failure_maps_to_failed_tool_event() {
        let event = normalize_hook_event(
            "PostToolUseFailure",
            ProviderEventCorrelation {
                tool_use_id: Some("tool-3".into()),
                ..Default::default()
            },
        );

        assert_eq!(event.source, ProviderEventSource::Hook);
        assert_eq!(event.domain, ProviderEventDomain::Tool);
        assert_eq!(event.action, ProviderEventAction::Failed);
        assert_eq!(event.status, Some(ProviderEventStatus::Failed));
        assert_eq!(event.payload.concept, ClaudeConcept::ToolCall);
    }

    #[test]
    fn hook_subagent_events_map_to_subagent_domain() {
        let started = normalize_hook_event("SubagentStart", ProviderEventCorrelation::default());
        let stopped = normalize_hook_event("SubagentStop", ProviderEventCorrelation::default());
        let idle = normalize_hook_event("TeammateIdle", ProviderEventCorrelation::default());

        assert_eq!(started.domain, ProviderEventDomain::Subagent);
        assert_eq!(started.action, ProviderEventAction::Started);
        assert_eq!(stopped.domain, ProviderEventDomain::Subagent);
        assert_eq!(stopped.action, ProviderEventAction::Completed);
        assert_eq!(idle.status, Some(ProviderEventStatus::Idle));
    }

    #[test]
    fn sdk_rate_limit_event_maps_to_rate_limit_domain() {
        let event = normalize_sdk_message(
            "rate_limit_event",
            None,
            ProviderEventCorrelation::default(),
        );

        assert_eq!(event.domain, ProviderEventDomain::RateLimit);
        assert_eq!(event.action, ProviderEventAction::Changed);
        assert_eq!(event.payload.concept, ClaudeConcept::RateLimit);
    }

    #[test]
    fn sdk_result_error_maps_to_failed_session_event() {
        let event = normalize_sdk_message(
            "result",
            Some("error_during_execution"),
            ProviderEventCorrelation::default(),
        );

        assert_eq!(event.domain, ProviderEventDomain::Session);
        assert_eq!(event.action, ProviderEventAction::Failed);
        assert_eq!(event.status, Some(ProviderEventStatus::Failed));
    }

    #[test]
    fn unknown_values_fall_back_cleanly() {
        let sdk =
            normalize_sdk_message("mystery", Some("nope"), ProviderEventCorrelation::default());
        let hook = normalize_hook_event("MysteryHook", ProviderEventCorrelation::default());
        let control =
            normalize_sdk_control_request("mystery_request", ProviderEventCorrelation::default());

        assert_eq!(sdk.domain, ProviderEventDomain::Unknown);
        assert_eq!(hook.action, ProviderEventAction::Unknown);
        assert_eq!(control.status, Some(ProviderEventStatus::Unknown));
        assert_eq!(sdk.payload.concept, ClaudeConcept::Unknown);
    }
}
