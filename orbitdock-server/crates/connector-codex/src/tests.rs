use super::config::{
  apply_orbitdock_embedded_runtime_defaults, apply_orbitdock_external_model_defaults,
  apply_orbitdock_provider_defaults, ensure_apply_patch_feature_for_custom_models,
  model_rejects_reasoning_summary, parse_personality, parse_reasoning_summary,
  parse_service_tier_override, reasoning_summary_for_model, should_disable_reasoning_summary,
  should_enable_apply_patch_for_custom_models,
};
use super::timeline::{
  hook_completed_text, hook_output_text, hook_run_is_error, hook_started_text,
  realtime_text_from_handoff_request, stream_error_should_surface_to_timeline,
};
use super::workers::{build_authoritative_codex_subagent, build_inflight_codex_subagent};
use super::workers::{build_codex_subagent_for_status, build_running_codex_subagent};
use super::CodexConnector;
use codex_core::config::Config as CoreConfig;
use codex_models_manager::{ModelProviderInfo, WireApi};
use codex_protocol::config_types::{ReasoningSummary, ServiceTier};
use codex_protocol::openai_models::ApplyPatchToolType;
use codex_protocol::protocol::{
  AgentStatus, CodexErrorInfo, HookEventName, HookExecutionMode, HookHandlerType, HookOutputEntry,
  HookOutputEntryKind, HookRunStatus, HookRunSummary, HookScope, HookSource,
  RealtimeHandoffRequested, RealtimeTranscriptEntry, StreamErrorEvent,
};
use codex_utils_absolute_path::AbsolutePathBuf;
use orbitdock_connector_core::{
  ConnectorOutput, ConnectorRuntimeDirective, ConnectorTransportEffect,
};
use orbitdock_protocol::domain_events::AgentType;
use std::collections::HashMap;

fn absolute_test_path(path: &str) -> AbsolutePathBuf {
  AbsolutePathBuf::from_absolute_path(path).expect("absolute test path")
}

#[test]
fn embedded_codex_runtime_paths_use_current_orbitdock_executable() {
  let current_exe = CodexConnector::embedded_codex_self_exe().expect("current executable");
  let runtime_paths =
    CodexConnector::embedded_codex_runtime_paths().expect("embedded runtime paths");

  assert_eq!(
    runtime_paths.codex_self_exe.as_path(),
    current_exe.as_path()
  );
}

#[tokio::test]
async fn embedded_environment_exposes_runtime_paths_for_sandboxed_filesystem() {
  let manager = CodexConnector::embedded_environment_manager().expect("environment manager");
  let environment = manager
    .current()
    .await
    .expect("current environment")
    .expect("local environment");

  assert!(environment.local_runtime_paths().is_some());
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
      auth: None,
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
      auth: None,
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
fn embedded_runtime_defaults_disable_codex_app_connectors() {
  let mut config = config_with_provider(
    "openai",
    ModelProviderInfo::create_openai_provider(Some("https://api.openai.com/v1".to_string())),
  );
  let _ = config.features.enable(codex_features::Feature::Apps);

  apply_orbitdock_embedded_runtime_defaults(&mut config, false);

  assert!(!config.features.enabled(codex_features::Feature::Apps));
}

#[test]
fn embedded_runtime_defaults_preserve_explicit_app_connector_opt_in() {
  let mut config = config_with_provider(
    "openai",
    ModelProviderInfo::create_openai_provider(Some("https://api.openai.com/v1".to_string())),
  );
  let _ = config.features.enable(codex_features::Feature::Apps);

  apply_orbitdock_embedded_runtime_defaults(&mut config, true);

  assert!(config.features.enabled(codex_features::Feature::Apps));
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
      auth: None,
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
      auth: None,
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
      auth: None,
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
      auth: None,
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
fn codex_output_classifies_pty_events_as_transport_only() {
  let created = ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyCreated {
    tool_id: "tool-pty-1".to_string(),
  });
  match &created {
    ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyCreated { tool_id }) => {
      assert_eq!(tool_id, "tool-pty-1");
    }
    other => panic!("expected transport PTY create output, got {other:?}"),
  }

  let output = ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyOutput {
    tool_id: "tool-pty-1".to_string(),
    bytes: b"hello".to_vec(),
  });
  match &output {
    ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyOutput { tool_id, bytes }) => {
      assert_eq!(tool_id, "tool-pty-1");
      assert_eq!(bytes, b"hello");
    }
    other => panic!("expected transport PTY output, got {other:?}"),
  }

  let runtime = ConnectorOutput::Runtime(ConnectorRuntimeDirective::DynamicToolCallRequested {
    call_id: "call-1".to_string(),
    tool_name: "file_read".to_string(),
    arguments: serde_json::json!({"path":"README.md"}),
  });
  match &runtime {
    ConnectorOutput::Runtime(ConnectorRuntimeDirective::DynamicToolCallRequested {
      call_id,
      tool_name,
      arguments,
    }) => {
      assert_eq!(call_id, "call-1");
      assert_eq!(tool_name, "file_read");
      assert_eq!(arguments["path"], "README.md");
    }
    other => panic!("expected runtime directive output, got {other:?}"),
  }
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
  let mut config = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .expect("tokio runtime should build")
    .block_on(CoreConfig::load_default_with_cli_overrides(Vec::new()))
    .expect("default config should load");
  config.model_provider_id = provider_id.to_string();
  config.model_provider = provider.clone();
  config
    .model_providers
    .insert(provider_id.to_string(), provider);
  config
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
    source_path: absolute_test_path("/tmp/stop-hook.sh"),
    source: HookSource::Unknown,
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
fn hook_helpers_render_user_prompt_submit_label() {
  let run = HookRunSummary {
    id: "hook-3".to_string(),
    event_name: HookEventName::UserPromptSubmit,
    handler_type: HookHandlerType::Command,
    execution_mode: HookExecutionMode::Sync,
    scope: HookScope::Turn,
    source_path: absolute_test_path("/tmp/prompt-submit-hook.sh"),
    source: HookSource::Unknown,
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
fn hook_helpers_flag_failed_runs_as_errors() {
  let run = HookRunSummary {
    id: "hook-2".to_string(),
    event_name: HookEventName::SessionStart,
    handler_type: HookHandlerType::Agent,
    execution_mode: HookExecutionMode::Async,
    scope: HookScope::Thread,
    source_path: absolute_test_path("/tmp/session-start.prompt"),
    source: HookSource::Unknown,
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
  assert_eq!(subagent.agent_type, AgentType::Explore);
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

  assert_eq!(subagent.agent_type, AgentType::BackgroundTask);
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
