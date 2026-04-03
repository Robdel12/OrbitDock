use super::config::{
  apply_orbitdock_external_model_defaults, apply_orbitdock_provider_defaults,
  collaboration_mode_from_name_or_mode, collaboration_mode_from_permission_mode,
  ensure_apply_patch_feature_for_custom_models, model_rejects_reasoning_summary, parse_personality,
  parse_reasoning_summary, parse_service_tier_override, reasoning_summary_for_model,
  should_disable_reasoning_summary, should_enable_apply_patch_for_custom_models,
};
use super::event_mapping::{guardian, messages, runtime_signals, streaming};
use super::runtime::StreamingMessage;
use super::timeline::{
  hook_completed_text, hook_output_text, hook_run_is_error, hook_started_text,
  realtime_text_from_handoff_request, stream_error_should_surface_to_timeline,
};
use super::workers::{build_authoritative_codex_subagent, build_inflight_codex_subagent};
use super::workers::{build_codex_subagent_for_status, build_running_codex_subagent};
use codex_core::config::Config as CoreConfig;
use codex_core::{ModelProviderInfo, WireApi};
use codex_protocol::config_types::{ModeKind, ReasoningSummary, ServiceTier};
use codex_protocol::models::{FunctionCallOutputPayload, ResponseItem};
use codex_protocol::openai_models::{ApplyPatchToolType, ReasoningEffort};
use codex_protocol::protocol::{
  AgentStatus, CodexErrorInfo, HookCompletedEvent, HookEventName, HookExecutionMode,
  HookHandlerType, HookOutputEntry, HookOutputEntryKind, HookRunStatus, HookRunSummary, HookScope,
  HookStartedEvent, RawResponseItemEvent, RealtimeHandoffRequested, RealtimeTranscriptEntry,
  StreamErrorEvent, WarningEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::domain_events::{ToolKind, ToolStatus};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

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
fn orbitdock_provider_defaults_add_openrouter_attribution_headers() {
  let mut config = config_with_provider(
    "openrouter",
    ModelProviderInfo {
      name: "OpenRouter".to_string(),
      base_url: Some("https://openrouter.ai/api/v1".to_string()),
      env_key: Some("OPENROUTER_API_KEY".to_string()),
      env_key_instructions: None,
      experimental_bearer_token: None,
      wire_api: WireApi::Responses,
      query_params: None,
      http_headers: None,
      env_http_headers: None,
      request_max_retries: None,
      stream_max_retries: None,
      stream_idle_timeout_ms: None,
      websocket_connect_timeout_ms: None,
      requires_openai_auth: false,
      supports_websockets: false,
    },
  );

  apply_orbitdock_provider_defaults(&mut config);

  let provider = config
    .model_providers
    .get("openrouter")
    .expect("provider should exist");
  let headers = provider
    .http_headers
    .as_ref()
    .expect("headers should be set");
  assert_eq!(
    headers.get("HTTP-Referer").map(String::as_str),
    Some("https://orbitdock.dev")
  );
  assert_eq!(
    headers.get("X-OpenRouter-Title").map(String::as_str),
    Some("OrbitDock")
  );
}

#[test]
fn orbitdock_provider_defaults_preserve_existing_openrouter_headers() {
  let mut config = config_with_provider(
    "openrouter",
    ModelProviderInfo {
      name: "OpenRouter".to_string(),
      base_url: Some("https://openrouter.ai/api/v1".to_string()),
      env_key: Some("OPENROUTER_API_KEY".to_string()),
      env_key_instructions: None,
      experimental_bearer_token: None,
      wire_api: WireApi::Responses,
      query_params: None,
      http_headers: Some(HashMap::from([
        (
          "HTTP-Referer".to_string(),
          "https://custom.example".to_string(),
        ),
        ("X-Title".to_string(), "Custom Title".to_string()),
      ])),
      env_http_headers: None,
      request_max_retries: None,
      stream_max_retries: None,
      stream_idle_timeout_ms: None,
      websocket_connect_timeout_ms: None,
      requires_openai_auth: false,
      supports_websockets: false,
    },
  );

  apply_orbitdock_provider_defaults(&mut config);

  let provider = config
    .model_providers
    .get("openrouter")
    .expect("provider should exist");
  let headers = provider
    .http_headers
    .as_ref()
    .expect("headers should be set");
  assert_eq!(
    headers.get("HTTP-Referer").map(String::as_str),
    Some("https://custom.example")
  );
  assert_eq!(
    headers.get("X-Title").map(String::as_str),
    Some("Custom Title")
  );
  assert!(!headers.contains_key("X-OpenRouter-Title"));
}

#[test]
fn external_model_defaults_seed_synthetic_catalog_for_non_openai_models() {
  let mut config = config_with_provider(
    "openrouter",
    ModelProviderInfo {
      name: "OpenRouter".to_string(),
      base_url: Some("https://openrouter.ai/api/v1".to_string()),
      env_key: Some("OPENROUTER_API_KEY".to_string()),
      env_key_instructions: None,
      experimental_bearer_token: None,
      wire_api: WireApi::Responses,
      query_params: None,
      http_headers: None,
      env_http_headers: None,
      request_max_retries: None,
      stream_max_retries: None,
      stream_idle_timeout_ms: None,
      websocket_connect_timeout_ms: None,
      requires_openai_auth: false,
      supports_websockets: false,
    },
  );
  config.model = Some("z-ai/glm-5v-turbo".to_string());
  config.model_catalog = None;

  apply_orbitdock_external_model_defaults(&mut config);

  let catalog = config.model_catalog.expect("catalog should be seeded");
  let model = catalog
    .models
    .iter()
    .find(|candidate| candidate.slug == "z-ai/glm-5v-turbo")
    .expect("synthetic model should exist");
  assert_eq!(
    model.apply_patch_tool_type,
    Some(ApplyPatchToolType::Function)
  );
  assert!(!model.used_fallback_model_metadata);
  assert!(model.model_messages.is_some());
  assert!(model
    .base_instructions
    .contains("Tool invocation contract:"));
  assert!(model
    .base_instructions
    .contains("Do not claim a specific provider/model identity"));
  assert!(model.base_instructions.contains("`exec_command`"));
}

#[test]
fn external_model_defaults_leave_openai_models_untouched() {
  let mut config = config_with_provider(
    "openai",
    ModelProviderInfo::create_openai_provider(Some("https://api.openai.com/v1".to_string())),
  );
  config.model = Some("gpt-5.4".to_string());
  config.model_catalog = None;

  apply_orbitdock_external_model_defaults(&mut config);

  assert!(config.model_catalog.is_none());
}

#[test]
fn external_model_defaults_merge_into_existing_catalog_model() {
  let mut config = config_with_provider(
    "ollama",
    ModelProviderInfo {
      name: "Ollama".to_string(),
      base_url: Some("http://localhost:11434/v1".to_string()),
      env_key: None,
      env_key_instructions: None,
      experimental_bearer_token: None,
      wire_api: WireApi::Responses,
      query_params: None,
      http_headers: None,
      env_http_headers: None,
      request_max_retries: None,
      stream_max_retries: None,
      stream_idle_timeout_ms: None,
      websocket_connect_timeout_ms: None,
      requires_openai_auth: false,
      supports_websockets: false,
    },
  );
  config.model = Some("seed-model".to_string());
  config.model_catalog = None;
  apply_orbitdock_external_model_defaults(&mut config);

  let mut existing_model = config
    .model_catalog
    .as_mut()
    .expect("catalog should exist")
    .models
    .pop()
    .expect("synthetic seed model should exist");
  existing_model.slug = "gemma4".to_string();
  existing_model.base_instructions = "Provider baseline instructions.".to_string();
  existing_model.apply_patch_tool_type = None;
  if let Some(messages) = existing_model.model_messages.as_mut() {
    messages.instructions_template = Some("Provider template guidance.".to_string());
    messages.instructions_variables = None;
  }

  config.model = Some("gemma4:e4b".to_string());
  config.model_catalog = Some(codex_protocol::openai_models::ModelsResponse {
    models: vec![existing_model],
  });

  apply_orbitdock_external_model_defaults(&mut config);

  let catalog = config.model_catalog.expect("catalog should exist");
  assert_eq!(catalog.models.len(), 1);
  let model = catalog.models.first().expect("model should exist");
  assert_eq!(model.slug, "gemma4");
  assert!(model
    .base_instructions
    .contains("Provider baseline instructions."));
  assert!(model
    .base_instructions
    .contains("Tool invocation contract:"));
  assert_eq!(
    model.apply_patch_tool_type,
    Some(ApplyPatchToolType::Function)
  );

  let model_messages = model
    .model_messages
    .as_ref()
    .expect("model messages should exist");
  let template = model_messages
    .instructions_template
    .as_deref()
    .expect("template should exist");
  assert!(template.contains("Provider template guidance."));
  assert!(template.contains("Tool invocation contract:"));
  assert!(template.contains("{{ personality }}"));

  let vars = model_messages
    .instructions_variables
    .as_ref()
    .expect("instruction variables should exist");
  assert_eq!(vars.personality_default.as_deref(), Some(""));
  assert!(vars.personality_friendly.is_some());
  assert!(vars.personality_pragmatic.is_some());
}

#[test]
fn custom_provider_should_enable_apply_patch_override() {
  let config = config_with_provider(
    "openrouter",
    ModelProviderInfo {
      name: "OpenRouter".to_string(),
      base_url: Some("https://openrouter.ai/api/v1".to_string()),
      env_key: Some("OPENROUTER_API_KEY".to_string()),
      env_key_instructions: None,
      experimental_bearer_token: None,
      wire_api: WireApi::Responses,
      query_params: None,
      http_headers: None,
      env_http_headers: None,
      request_max_retries: None,
      stream_max_retries: None,
      stream_idle_timeout_ms: None,
      websocket_connect_timeout_ms: None,
      requires_openai_auth: false,
      supports_websockets: false,
    },
  );
  assert!(should_enable_apply_patch_for_custom_models(&config));
}

#[test]
fn openai_provider_should_not_enable_apply_patch_override() {
  let config = config_with_provider(
    "openai",
    ModelProviderInfo::create_openai_provider(Some("https://api.openai.com/v1".to_string())),
  );
  assert!(!should_enable_apply_patch_for_custom_models(&config));
}

#[test]
fn custom_provider_force_enables_apply_patch_feature() {
  let mut config = config_with_provider(
    "openrouter",
    ModelProviderInfo {
      name: "OpenRouter".to_string(),
      base_url: Some("https://openrouter.ai/api/v1".to_string()),
      env_key: Some("OPENROUTER_API_KEY".to_string()),
      env_key_instructions: None,
      experimental_bearer_token: None,
      wire_api: WireApi::Responses,
      query_params: None,
      http_headers: None,
      env_http_headers: None,
      request_max_retries: None,
      stream_max_retries: None,
      stream_idle_timeout_ms: None,
      websocket_connect_timeout_ms: None,
      requires_openai_auth: false,
      supports_websockets: false,
    },
  );

  let _ = config
    .features
    .disable(codex_features::Feature::ApplyPatchFreeform);

  let forced = ensure_apply_patch_feature_for_custom_models(&mut config);

  assert!(forced);
  assert!(config
    .features
    .enabled(codex_features::Feature::ApplyPatchFreeform));
}

#[test]
fn openai_provider_does_not_force_enable_apply_patch_feature() {
  let mut config = config_with_provider(
    "openai",
    ModelProviderInfo::create_openai_provider(Some("https://api.openai.com/v1".to_string())),
  );

  let _ = config
    .features
    .disable(codex_features::Feature::ApplyPatchFreeform);

  let forced = ensure_apply_patch_feature_for_custom_models(&mut config);

  assert!(!forced);
  assert!(!config
    .features
    .enabled(codex_features::Feature::ApplyPatchFreeform));
}

fn config_with_provider(provider_id: &str, provider: ModelProviderInfo) -> CoreConfig {
  let mut config =
    CoreConfig::load_default_with_cli_overrides(Vec::new()).expect("default config should load");
  config.model_provider_id = provider_id.to_string();
  config.model_provider = provider.clone();
  config
    .model_providers
    .insert(provider_id.to_string(), provider);
  config
}

#[test]
fn runtime_warning_suppresses_fallback_metadata_notice() {
  let msg_counter = AtomicU64::new(0);
  let events = super::event_mapping::runtime_signals::handle_warning(
    "event-1",
    WarningEvent {
      message:
        "Model metadata for `qwen/qwen3-coder-next` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."
          .to_string(),
    },
    &msg_counter,
  );

  assert!(events.is_empty());
}

#[test]
fn runtime_warning_preserves_other_warnings() {
  let msg_counter = AtomicU64::new(0);
  let events = super::event_mapping::runtime_signals::handle_warning(
    "event-1",
    WarningEvent {
      message: "Something else happened".to_string(),
    },
    &msg_counter,
  );

  assert_eq!(events.len(), 1);
}

#[test]
fn runtime_warning_suppresses_codex_hooks_notice() {
  let msg_counter = AtomicU64::new(0);
  let events = super::event_mapping::runtime_signals::handle_warning(
    "event-1",
    WarningEvent {
      message: "Under-development features enabled: codex_hooks. Under-development features are incomplete and may behave unpredictably. To suppress this warning, set suppress...".to_string(),
    },
    &msg_counter,
  );

  assert!(events.is_empty());
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

#[tokio::test]
async fn raw_response_function_call_surfaces_read_tool_rows() {
  let raw_tool_calls = Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new()));
  let msg_counter = AtomicU64::new(0);

  let created = streaming::handle_raw_response_item(
    "event-1",
    RawResponseItemEvent {
      item: ResponseItem::FunctionCall {
        id: None,
        name: "Read".to_string(),
        namespace: None,
        arguments: r#"{"file_path":"/tmp/example.rs"}"#.to_string(),
        call_id: "call-read-1".to_string(),
      },
    },
    &msg_counter,
    &raw_tool_calls,
  )
  .await;

  assert_eq!(created.len(), 1);
  let ConnectorEvent::ConversationRowCreated(entry) = &created[0] else {
    panic!("expected tool row create event");
  };
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.id, "call-read-1");
  assert_eq!(tool.kind, ToolKind::Read);
  assert_eq!(tool.status, ToolStatus::Running);
  assert_eq!(
    tool
      .invocation
      .get("file_path")
      .and_then(|value| value.as_str()),
    Some("/tmp/example.rs")
  );

  let updated = streaming::handle_raw_response_item(
    "event-2",
    RawResponseItemEvent {
      item: ResponseItem::FunctionCallOutput {
        call_id: "call-read-1".to_string(),
        output: FunctionCallOutputPayload::from_text("file contents".to_string()),
      },
    },
    &msg_counter,
    &raw_tool_calls,
  )
  .await;

  assert_eq!(updated.len(), 1);
  let ConnectorEvent::ConversationRowUpdated { row_id, entry } = &updated[0] else {
    panic!("expected tool row update event");
  };
  assert_eq!(row_id, "call-read-1");
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.kind, ToolKind::Read);
  assert_eq!(tool.status, ToolStatus::Completed);
  assert_eq!(
    tool
      .result
      .as_ref()
      .and_then(|value| value.get("output"))
      .and_then(|value| value.as_str()),
    Some("file contents")
  );
}

#[tokio::test]
async fn raw_response_tool_search_surfaces_tool_search_rows() {
  let raw_tool_calls = Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new()));
  let msg_counter = AtomicU64::new(0);

  let created = streaming::handle_raw_response_item(
    "event-1",
    RawResponseItemEvent {
      item: ResponseItem::ToolSearchCall {
        id: None,
        call_id: Some("call-tool-search-1".to_string()),
        status: Some("in_progress".to_string()),
        execution: "lookup".to_string(),
        arguments: serde_json::json!({ "query": "search notes" }),
      },
    },
    &msg_counter,
    &raw_tool_calls,
  )
  .await;

  assert_eq!(created.len(), 1);
  let ConnectorEvent::ConversationRowCreated(entry) = &created[0] else {
    panic!("expected tool row create event");
  };
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.kind, ToolKind::ToolSearch);
  assert_eq!(tool.status, ToolStatus::Running);

  let updated = streaming::handle_raw_response_item(
    "event-2",
    RawResponseItemEvent {
      item: ResponseItem::ToolSearchOutput {
        call_id: Some("call-tool-search-1".to_string()),
        status: "completed".to_string(),
        execution: "lookup".to_string(),
        tools: vec![serde_json::json!({ "name": "search_query" })],
      },
    },
    &msg_counter,
    &raw_tool_calls,
  )
  .await;

  assert_eq!(updated.len(), 1);
  let ConnectorEvent::ConversationRowUpdated { row_id, entry } = &updated[0] else {
    panic!("expected tool row update event");
  };
  assert_eq!(row_id, "call-tool-search-1");
  let ConversationRow::Tool(tool) = &entry.row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.kind, ToolKind::ToolSearch);
  assert_eq!(tool.status, ToolStatus::Completed);
}

#[test]
fn hook_helpers_render_user_prompt_submit_label() {
  let run = HookRunSummary {
    id: "hook-3".to_string(),
    event_name: HookEventName::UserPromptSubmit,
    handler_type: HookHandlerType::Command,
    execution_mode: HookExecutionMode::Sync,
    scope: HookScope::Turn,
    source_path: PathBuf::from("/tmp/prompt-submit-hook.sh"),
    display_order: 0,
    status: HookRunStatus::Completed,
    status_message: None,
    started_at: 1,
    completed_at: Some(2),
    duration_ms: Some(12),
    entries: vec![],
  };

  assert_eq!(
    hook_started_text(&run),
    "Running prompt submit hook via prompt-submit-hook.sh"
  );
  assert_eq!(
    hook_completed_text(&run),
    "prompt submit hook completed via prompt-submit-hook.sh"
  );
}

#[test]
fn suppresses_non_error_hook_started_rows() {
  let events = runtime_signals::handle_hook_started(HookStartedEvent {
    turn_id: None,
    run: HookRunSummary {
      id: "hook-quiet-start".to_string(),
      event_name: HookEventName::UserPromptSubmit,
      handler_type: HookHandlerType::Command,
      execution_mode: HookExecutionMode::Sync,
      scope: HookScope::Turn,
      source_path: PathBuf::from("/tmp/hooks.json"),
      display_order: 0,
      status: HookRunStatus::Running,
      status_message: None,
      started_at: 1,
      completed_at: None,
      duration_ms: None,
      entries: vec![],
    },
  });

  assert!(events.is_empty());
}

#[test]
fn suppresses_non_error_hook_completed_rows() {
  let events = runtime_signals::handle_hook_completed(HookCompletedEvent {
    turn_id: None,
    run: HookRunSummary {
      id: "hook-quiet-complete".to_string(),
      event_name: HookEventName::SessionStart,
      handler_type: HookHandlerType::Command,
      execution_mode: HookExecutionMode::Sync,
      scope: HookScope::Thread,
      source_path: PathBuf::from("/tmp/hooks.json"),
      display_order: 0,
      status: HookRunStatus::Completed,
      status_message: None,
      started_at: 1,
      completed_at: Some(2),
      duration_ms: Some(1),
      entries: vec![],
    },
  });

  assert!(events.is_empty());
}

#[test]
fn surfaces_failed_hook_completed_rows() {
  let events = runtime_signals::handle_hook_completed(HookCompletedEvent {
    turn_id: None,
    run: HookRunSummary {
      id: "hook-error-complete".to_string(),
      event_name: HookEventName::SessionStart,
      handler_type: HookHandlerType::Command,
      execution_mode: HookExecutionMode::Sync,
      scope: HookScope::Thread,
      source_path: PathBuf::from("/tmp/hooks.json"),
      display_order: 0,
      status: HookRunStatus::Failed,
      status_message: Some("Broken config".to_string()),
      started_at: 1,
      completed_at: Some(2),
      duration_ms: Some(1),
      entries: vec![],
    },
  });

  assert_eq!(events.len(), 1);
  let ConnectorEvent::ConversationRowCreated(entry) = &events[0] else {
    panic!("expected hook failure row");
  };
  let ConversationRow::Hook(hook) = &entry.row else {
    panic!("expected hook row");
  };
  assert_eq!(hook.id, "hook-hook-error-complete");
  assert!(hook.title.contains("failed via hooks.json"));
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
fn build_inflight_codex_subagent_preserves_interrupted_status() {
  let subagent = build_inflight_codex_subagent(
    "worker-interrupted".to_string(),
    Some("worker".to_string()),
    Some("Curie".to_string()),
    Some("Handle an interrupted turn".to_string()),
    Some("parent-thread".to_string()),
    &AgentStatus::Interrupted,
  )
  .expect("expected inflight worker");

  assert_eq!(
    subagent.status,
    orbitdock_protocol::SubagentStatus::Interrupted
  );
  assert!(subagent.ended_at.is_none());
  assert_eq!(
    subagent.task_summary.as_deref(),
    Some("Handle an interrupted turn")
  );
}

#[tokio::test]
async fn handle_agent_message_preserves_memory_citations() {
  let events = messages::handle_agent_message(
    "evt-1",
    codex_protocol::protocol::AgentMessageEvent {
      message: "Use the saved note".to_string(),
      phase: None,
      memory_citation: Some(codex_protocol::memory_citation::MemoryCitation {
        entries: vec![codex_protocol::memory_citation::MemoryCitationEntry {
          path: "/tmp/note.md".to_string(),
          line_start: 12,
          line_end: 16,
          note: "Remember this section".to_string(),
        }],
        rollout_ids: vec!["rollout-1".to_string()],
      }),
    },
    &Arc::new(tokio::sync::Mutex::new(None::<StreamingMessage>)),
  )
  .await;

  let row = match &events[0] {
    ConnectorEvent::ConversationRowCreated(entry) => &entry.row,
    other => panic!("expected row creation event, got {other:?}"),
  };

  let message = match row {
    ConversationRow::Assistant(message) => message,
    other => panic!("expected assistant row, got {other:?}"),
  };

  let citation = message
    .memory_citation
    .as_ref()
    .expect("memory citation should be preserved");
  assert_eq!(citation.rollout_ids, vec!["rollout-1".to_string()]);
  assert_eq!(citation.entries[0].path, "/tmp/note.md");
  assert_eq!(citation.entries[0].line_start, 12);
  assert_eq!(citation.entries[0].line_end, 16);
  assert_eq!(citation.entries[0].note, "Remember this section");
}

#[test]
fn handle_guardian_assessment_creates_guardian_tool_row_while_running() {
  let events =
    guardian::handle_guardian_assessment(codex_protocol::approvals::GuardianAssessmentEvent {
      id: "guardian-1".to_string(),
      turn_id: "turn-1".to_string(),
      status: codex_protocol::approvals::GuardianAssessmentStatus::InProgress,
      action: Some(serde_json::json!({ "command": "rm -rf /tmp/cache" })),
      risk_score: Some(87),
      risk_level: Some(codex_protocol::approvals::GuardianRiskLevel::High),
      rationale: Some("Deletes a broad path".to_string()),
    });

  let row = match &events[0] {
    ConnectorEvent::ConversationRowCreated(entry) => &entry.row,
    other => panic!("expected row creation event, got {other:?}"),
  };

  let tool = match row {
    ConversationRow::Tool(tool) => tool,
    other => panic!("expected tool row, got {other:?}"),
  };

  assert_eq!(
    tool.kind,
    orbitdock_protocol::domain_events::ToolKind::GuardianAssessment
  );
  assert_eq!(
    tool.status,
    orbitdock_protocol::domain_events::ToolStatus::Running
  );
  assert_eq!(tool.grouping_key.as_deref(), Some("turn-1"));
  assert_eq!(tool.title, "Guardian review");
  assert_eq!(tool.subtitle.as_deref(), Some("high risk"));
  assert_eq!(tool.summary.as_deref(), Some("Deletes a broad path"));
}

#[test]
fn handle_guardian_assessment_updates_guardian_tool_row_when_terminal() {
  let events =
    guardian::handle_guardian_assessment(codex_protocol::approvals::GuardianAssessmentEvent {
      id: "guardian-1".to_string(),
      turn_id: "turn-1".to_string(),
      status: codex_protocol::approvals::GuardianAssessmentStatus::Denied,
      action: Some(serde_json::json!({ "command": "rm -rf /tmp/cache" })),
      risk_score: Some(87),
      risk_level: Some(codex_protocol::approvals::GuardianRiskLevel::High),
      rationale: Some("Deletes a broad path".to_string()),
    });

  let row = match &events[0] {
    ConnectorEvent::ConversationRowUpdated { row_id, entry } => {
      assert_eq!(row_id, "guardian-guardian-1");
      &entry.row
    }
    other => panic!("expected row update event, got {other:?}"),
  };

  let tool = match row {
    ConversationRow::Tool(tool) => tool,
    other => panic!("expected tool row, got {other:?}"),
  };

  assert_eq!(
    tool.kind,
    orbitdock_protocol::domain_events::ToolKind::GuardianAssessment
  );
  assert_eq!(
    tool.status,
    orbitdock_protocol::domain_events::ToolStatus::Failed
  );
  assert_eq!(tool.grouping_key.as_deref(), Some("turn-1"));
  assert_eq!(tool.title, "Guardian review");
  assert_eq!(tool.subtitle.as_deref(), Some("high risk"));
  assert_eq!(tool.summary.as_deref(), Some("Deletes a broad path"));
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

#[test]
fn build_codex_subagent_for_status_keeps_interrupted_inflight() {
  let subagent = build_codex_subagent_for_status(
    "worker-7".to_string(),
    Some("explorer".to_string()),
    Some("Noether".to_string()),
    Some("Resume after interruption".to_string()),
    Some("parent-thread".to_string()),
    &AgentStatus::Interrupted,
  );

  assert_eq!(
    subagent.status,
    orbitdock_protocol::SubagentStatus::Interrupted
  );
  assert!(subagent.ended_at.is_none());
  assert!(subagent.result_summary.is_none());
  assert!(subagent.error_summary.is_none());
}
