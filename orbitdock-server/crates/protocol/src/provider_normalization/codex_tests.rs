use super::{
  normalize_protocol_event, normalize_response_item, CodexConcept, CodexSourceKind,
  CodexThreadOperation,
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
