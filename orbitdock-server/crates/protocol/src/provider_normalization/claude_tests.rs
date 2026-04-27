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
  let event =
    normalize_sdk_control_request("set_permission_mode", ProviderEventCorrelation::default());

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
  let sdk = normalize_sdk_message("mystery", Some("nope"), ProviderEventCorrelation::default());
  let hook = normalize_hook_event("MysteryHook", ProviderEventCorrelation::default());
  let control =
    normalize_sdk_control_request("mystery_request", ProviderEventCorrelation::default());

  assert_eq!(sdk.domain, ProviderEventDomain::Unknown);
  assert_eq!(hook.action, ProviderEventAction::Unknown);
  assert_eq!(control.status, Some(ProviderEventStatus::Unknown));
  assert_eq!(sdk.payload.concept, ClaudeConcept::Unknown);
}
