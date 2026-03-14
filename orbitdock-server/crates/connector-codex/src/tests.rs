use super::config::{
    collaboration_mode_from_name_or_mode, collaboration_mode_from_permission_mode,
    model_rejects_reasoning_summary, parse_personality, parse_reasoning_summary,
    parse_service_tier_override, reasoning_summary_for_model, should_disable_reasoning_summary,
};
use super::timeline::{
    hook_completed_text, hook_output_text, hook_run_is_error, hook_started_text,
    realtime_text_from_handoff_request, stream_error_should_surface_to_timeline,
};
use super::workers::{build_authoritative_codex_subagent, build_inflight_codex_subagent};
use super::workers::{build_codex_subagent_for_status, build_running_codex_subagent};
use codex_protocol::config_types::{ModeKind, ReasoningSummary, ServiceTier};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{
    AgentStatus, CodexErrorInfo, HookEventName, HookExecutionMode, HookHandlerType,
    HookOutputEntry, HookOutputEntryKind, HookRunStatus, HookRunSummary, HookScope,
    RealtimeHandoffRequested, RealtimeTranscriptEntry, StreamErrorEvent,
};
use std::path::PathBuf;

#[test]
fn collaboration_mode_maps_plan() {
    let result = collaboration_mode_from_permission_mode(
        Some("plan"),
        "openai/gpt-5.3-codex".to_string(),
        Some(ReasoningEffort::High),
    )
    .expect("expected mode");
    assert_eq!(result.mode, ModeKind::Plan);
    assert_eq!(result.settings.model, "openai/gpt-5.3-codex");
    assert_eq!(
        result.settings.reasoning_effort,
        Some(ReasoningEffort::High)
    );
}

#[test]
fn collaboration_mode_maps_default_case_insensitive() {
    let result = collaboration_mode_from_permission_mode(
        Some("Default"),
        "openai/gpt-5.3-codex".to_string(),
        None,
    )
    .expect("expected mode");
    assert_eq!(result.mode, ModeKind::Default);
}

#[test]
fn collaboration_mode_ignores_unknown_modes() {
    let result =
        collaboration_mode_from_permission_mode(Some("acceptEdits"), "model".to_string(), None);
    assert!(result.is_none());
}

#[test]
fn collaboration_mode_preserves_explicit_developer_instructions() {
    let result = collaboration_mode_from_name_or_mode(
        Vec::new(),
        "plan",
        "openai/gpt-5.3-codex".to_string(),
        Some(ReasoningEffort::High),
        Some("Keep updates crisp."),
    )
    .expect("expected mode");

    assert_eq!(result.mode, ModeKind::Plan);
    assert_eq!(
        result.settings.developer_instructions.as_deref(),
        Some("Keep updates crisp.")
    );
}

#[test]
fn collaboration_mode_from_name_or_mode_supports_default_mode() {
    let result = collaboration_mode_from_name_or_mode(
        Vec::new(),
        "default",
        "openai/gpt-5.3-codex".to_string(),
        None,
        None,
    )
    .expect("expected mode");

    assert_eq!(result.mode, ModeKind::Default);
}

#[test]
fn collaboration_mode_from_name_or_mode_supports_default_instructions() {
    let result = collaboration_mode_from_name_or_mode(
        Vec::new(),
        "default",
        "openai/gpt-5.3-codex".to_string(),
        Some(ReasoningEffort::Medium),
        Some("Always explain the tradeoffs."),
    )
    .expect("expected synthesized mode");

    assert_eq!(result.mode, ModeKind::Default);
    assert_eq!(
        result.settings.developer_instructions.as_deref(),
        Some("Always explain the tradeoffs.")
    );
    assert_eq!(
        result.settings.reasoning_effort,
        Some(ReasoningEffort::Medium)
    );
}

#[test]
fn parse_personality_maps_known_values() {
    assert_eq!(
        parse_personality(Some("friendly")),
        Some(codex_protocol::config_types::Personality::Friendly)
    );
    assert_eq!(
        parse_personality(Some("Pragmatic")),
        Some(codex_protocol::config_types::Personality::Pragmatic)
    );
    assert_eq!(
        parse_personality(Some("none")),
        Some(codex_protocol::config_types::Personality::None)
    );
    assert_eq!(parse_personality(Some("unknown")), None);
}

#[test]
fn parse_service_tier_override_supports_set_and_clear() {
    assert_eq!(
        parse_service_tier_override(Some("fast")),
        Some(Some(ServiceTier::Fast))
    );
    assert_eq!(
        parse_service_tier_override(Some("flex")),
        Some(Some(ServiceTier::Flex))
    );
    assert_eq!(parse_service_tier_override(Some("none")), Some(None));
    assert_eq!(parse_service_tier_override(Some("bogus")), None);
}

#[test]
fn realtime_handoff_text_prefers_messages() {
    let handoff = RealtimeHandoffRequested {
        handoff_id: "handoff-1".to_string(),
        item_id: "item-1".to_string(),
        input_transcript: "fallback".to_string(),
        active_transcript: vec![
            RealtimeTranscriptEntry {
                role: "user".to_string(),
                text: "delegate now".to_string(),
            },
            RealtimeTranscriptEntry {
                role: "assistant".to_string(),
                text: "working on it".to_string(),
            },
        ],
    };

    assert_eq!(
        realtime_text_from_handoff_request(&handoff),
        Some("user: delegate now\nassistant: working on it".to_string())
    );
}

#[test]
fn realtime_handoff_text_falls_back_to_input_transcript() {
    let handoff = RealtimeHandoffRequested {
        handoff_id: "handoff-1".to_string(),
        item_id: "item-1".to_string(),
        input_transcript: "delegate now".to_string(),
        active_transcript: vec![],
    };

    assert_eq!(
        realtime_text_from_handoff_request(&handoff),
        Some("delegate now".to_string())
    );
}

#[test]
fn hook_helpers_emit_readable_timeline_text() {
    let run = HookRunSummary {
        id: "hook-1".to_string(),
        event_name: HookEventName::Stop,
        handler_type: HookHandlerType::Command,
        execution_mode: HookExecutionMode::Sync,
        scope: HookScope::Turn,
        source_path: PathBuf::from("/tmp/stop-hook.sh"),
        display_order: 0,
        status: HookRunStatus::Completed,
        status_message: Some("Cleared temporary state".to_string()),
        started_at: 1,
        completed_at: Some(2),
        duration_ms: Some(88),
        entries: vec![HookOutputEntry {
            kind: HookOutputEntryKind::Feedback,
            text: "Removed stale files".to_string(),
        }],
    };

    assert_eq!(
        hook_started_text(&run),
        "Running stop hook via stop-hook.sh"
    );
    assert_eq!(
        hook_completed_text(&run),
        "stop hook completed via stop-hook.sh: Cleared temporary state"
    );
    assert_eq!(
        hook_output_text(&run).as_deref(),
        Some("Cleared temporary state\nRemoved stale files")
    );
    assert!(!hook_run_is_error(run.status));
}

#[test]
fn hook_helpers_flag_failed_runs_as_errors() {
    let run = HookRunSummary {
        id: "hook-2".to_string(),
        event_name: HookEventName::SessionStart,
        handler_type: HookHandlerType::Agent,
        execution_mode: HookExecutionMode::Async,
        scope: HookScope::Thread,
        source_path: PathBuf::from("/tmp/session-start.prompt"),
        display_order: 1,
        status: HookRunStatus::Failed,
        status_message: None,
        started_at: 1,
        completed_at: Some(2),
        duration_ms: Some(25),
        entries: vec![HookOutputEntry {
            kind: HookOutputEntryKind::Error,
            text: "Prompt validation failed".to_string(),
        }],
    };

    assert_eq!(
        hook_completed_text(&run),
        "session start hook failed via session-start.prompt"
    );
    assert_eq!(
        hook_output_text(&run).as_deref(),
        Some("Prompt validation failed")
    );
    assert!(hook_run_is_error(run.status));
}

#[test]
fn model_rejects_reasoning_summary_for_spark() {
    assert!(model_rejects_reasoning_summary(Some("gpt-5.3-codex-spark")));
}

#[test]
fn model_rejects_reasoning_summary_for_prefixed_spark() {
    assert!(model_rejects_reasoning_summary(Some(
        "openai/gpt-5.3-codex-spark"
    )));
}

#[test]
fn model_allows_reasoning_summary_for_non_spark() {
    assert!(!model_rejects_reasoning_summary(Some("gpt-5.3-codex")));
    assert!(!model_rejects_reasoning_summary(None));
}

#[test]
fn should_disable_reasoning_summary_when_model_does_not_support_it() {
    assert!(should_disable_reasoning_summary(
        Some("gpt-5.3-codex"),
        false
    ));
}

#[test]
fn should_disable_reasoning_summary_for_known_spark_mismatch() {
    assert!(should_disable_reasoning_summary(
        Some("gpt-5.3-codex-spark"),
        true
    ));
}

#[test]
fn should_keep_reasoning_summary_for_supported_non_spark_models() {
    assert!(!should_disable_reasoning_summary(
        Some("gpt-5.3-codex"),
        true
    ));
}

#[test]
fn parse_reasoning_summary_maps_expected_values() {
    assert_eq!(
        parse_reasoning_summary("auto"),
        Some(ReasoningSummary::Auto)
    );
    assert_eq!(
        parse_reasoning_summary("concise"),
        Some(ReasoningSummary::Concise)
    );
    assert_eq!(
        parse_reasoning_summary("detailed"),
        Some(ReasoningSummary::Detailed)
    );
    assert_eq!(
        parse_reasoning_summary("none"),
        Some(ReasoningSummary::None)
    );
    assert_eq!(parse_reasoning_summary("invalid"), None);
}

#[test]
fn reasoning_summary_for_model_forces_none_for_spark() {
    assert_eq!(
        reasoning_summary_for_model(Some("gpt-5.3-codex-spark"), ReasoningSummary::Detailed),
        ReasoningSummary::None
    );
}

#[test]
fn reasoning_summary_for_model_keeps_preferred_for_non_spark() {
    assert_eq!(
        reasoning_summary_for_model(Some("gpt-5.3-codex"), ReasoningSummary::Concise),
        ReasoningSummary::Concise
    );
}

#[test]
fn retryable_response_stream_disconnects_do_not_surface_to_timeline() {
    let event = StreamErrorEvent {
        message: "Reconnecting... 2/5".to_string(),
        codex_error_info: Some(CodexErrorInfo::ResponseStreamDisconnected {
            http_status_code: None,
        }),
        additional_details: Some(
            "stream disconnected before completion: WebSocket protocol error".to_string(),
        ),
    };

    assert!(!stream_error_should_surface_to_timeline(&event));
}

#[test]
fn non_retryable_stream_errors_still_surface_to_timeline() {
    let event = StreamErrorEvent {
        message: "stream failed".to_string(),
        codex_error_info: Some(CodexErrorInfo::Other),
        additional_details: None,
    };

    assert!(stream_error_should_surface_to_timeline(&event));
}

#[test]
fn build_authoritative_codex_subagent_maps_completed_status_and_metadata() {
    let subagent = build_authoritative_codex_subagent(
        "worker-1".to_string(),
        Some("explorer".to_string()),
        Some("Repo Scout".to_string()),
        Some("Map the repository".to_string()),
        Some("parent-thread".to_string()),
        &AgentStatus::Completed(Some("Found the main modules".to_string())),
    );

    assert_eq!(subagent.id, "worker-1");
    assert_eq!(subagent.agent_type, "explorer");
    assert_eq!(subagent.label.as_deref(), Some("Repo Scout"));
    assert_eq!(subagent.task_summary.as_deref(), Some("Map the repository"));
    assert_eq!(
        subagent.parent_subagent_id.as_deref(),
        Some("parent-thread")
    );
    assert_eq!(
        subagent.status,
        orbitdock_protocol::SubagentStatus::Completed
    );
    assert_eq!(
        subagent.result_summary.as_deref(),
        Some("Found the main modules")
    );
    assert!(subagent.ended_at.is_some());
}

#[test]
fn build_authoritative_codex_subagent_maps_error_status() {
    let subagent = build_authoritative_codex_subagent(
        "worker-2".to_string(),
        None,
        None,
        None,
        None,
        &AgentStatus::Errored("sandbox denied".to_string()),
    );

    assert_eq!(subagent.agent_type, "agent");
    assert_eq!(subagent.label.as_deref(), Some("worker-2"));
    assert_eq!(subagent.status, orbitdock_protocol::SubagentStatus::Failed);
    assert_eq!(subagent.error_summary.as_deref(), Some("sandbox denied"));
    assert!(subagent.ended_at.is_some());
}

#[test]
fn build_inflight_codex_subagent_maps_running_status_only() {
    let subagent = build_inflight_codex_subagent(
        "worker-3".to_string(),
        Some("worker".to_string()),
        Some("Mill".to_string()),
        Some("Read AGENTS.md".to_string()),
        Some("parent-thread".to_string()),
        &AgentStatus::Running,
    )
    .expect("expected inflight worker");

    assert_eq!(subagent.id, "worker-3");
    assert_eq!(subagent.status, orbitdock_protocol::SubagentStatus::Running);
    assert_eq!(subagent.result_summary, None);
    assert_eq!(subagent.error_summary, None);
    assert_eq!(subagent.task_summary.as_deref(), Some("Read AGENTS.md"));
    assert!(subagent.ended_at.is_none());
}

#[test]
fn build_inflight_codex_subagent_drops_terminal_statuses() {
    let completed = build_inflight_codex_subagent(
        "worker-4".to_string(),
        None,
        None,
        None,
        None,
        &AgentStatus::Completed(Some("done".to_string())),
    );
    let errored = build_inflight_codex_subagent(
        "worker-4".to_string(),
        None,
        None,
        None,
        None,
        &AgentStatus::Errored("boom".to_string()),
    );
    let shutdown = build_inflight_codex_subagent(
        "worker-4".to_string(),
        None,
        None,
        None,
        None,
        &AgentStatus::Shutdown,
    );
    let not_found = build_inflight_codex_subagent(
        "worker-4".to_string(),
        None,
        None,
        None,
        None,
        &AgentStatus::NotFound,
    );

    assert!(completed.is_none());
    assert!(errored.is_none());
    assert!(shutdown.is_none());
    assert!(not_found.is_none());
}

#[test]
fn build_running_codex_subagent_marks_worker_running() {
    let subagent = build_running_codex_subagent(
        "worker-5".to_string(),
        Some("worker".to_string()),
        Some("Beauvoir".to_string()),
        Some("Confirm the current working directory".to_string()),
        Some("parent-thread".to_string()),
    );

    assert_eq!(subagent.status, orbitdock_protocol::SubagentStatus::Running);
    assert_eq!(subagent.label.as_deref(), Some("Beauvoir"));
    assert_eq!(
        subagent.task_summary.as_deref(),
        Some("Confirm the current working directory")
    );
}

#[test]
fn build_codex_subagent_for_status_preserves_terminal_updates() {
    let subagent = build_codex_subagent_for_status(
        "worker-6".to_string(),
        Some("explorer".to_string()),
        Some("Cicero".to_string()),
        Some("Inspect the worker lifecycle".to_string()),
        Some("parent-thread".to_string()),
        &AgentStatus::Completed(Some("Finished cleanly".to_string())),
    );

    assert_eq!(
        subagent.status,
        orbitdock_protocol::SubagentStatus::Completed
    );
    assert_eq!(subagent.result_summary.as_deref(), Some("Finished cleanly"));
    assert!(subagent.ended_at.is_some());
}
