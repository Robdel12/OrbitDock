use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{load_session_by_id, RestoredSession};
use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexConfigMode, CodexConfigSource, CodexSessionOverrides, Provider,
  SessionSummary,
};

use super::hydration::hydrate_restored_rows_if_missing;
use super::parsing::parse_provider;
use super::state::restored_session_to_handle;

pub(crate) struct PreparedResumeSession {
  pub provider: Provider,
  pub project_path: String,
  pub transcript_path: Option<String>,
  pub model: Option<String>,
  pub codex_thread_id: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub sandbox_policy_details: Option<orbitdock_protocol::CodexSandboxPolicy>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub codex_config_mode: Option<CodexConfigMode>,
  pub codex_config_profile: Option<String>,
  pub codex_model_provider: Option<String>,
  pub codex_config_source: Option<CodexConfigSource>,
  pub codex_config_overrides: Option<CodexSessionOverrides>,
  pub claude_sdk_session_id: Option<String>,
  pub row_count: usize,
  pub transcript_loaded: bool,
  pub summary: SessionSummary,
  pub handle: SessionHandle,
  pub allow_bypass_permissions: bool,
}

pub(crate) fn prepare_restored_session_for_direct_resume(
  restored: RestoredSession,
  transcript_loaded: bool,
) -> PreparedResumeSession {
  let provider = parse_provider(&restored.provider);
  let project_path = restored.project_path.clone();
  let transcript_path = restored.transcript_path.clone();
  let model = restored.model.clone();
  let codex_thread_id = restored.codex_thread_id.clone();
  let approval_policy = restored.approval_policy.clone();
  let sandbox_mode = restored.sandbox_mode.clone();
  let sandbox_policy_details = restored
    .codex_config_overrides
    .as_ref()
    .and_then(|overrides| overrides.sandbox_policy_details.clone())
    .or_else(|| {
      restored
        .sandbox_mode
        .as_deref()
        .and_then(orbitdock_protocol::CodexSandboxPolicy::from_storage_text)
    });
  let collaboration_mode = restored.collaboration_mode.clone();
  let multi_agent = restored.multi_agent;
  let personality = restored.personality.clone();
  let service_tier = restored.service_tier.clone();
  let developer_instructions = restored.developer_instructions.clone();
  let codex_config_mode = restored.codex_config_mode;
  let codex_config_profile = restored.codex_config_profile.clone();
  let codex_model_provider = restored.codex_model_provider.clone();
  let codex_config_source = restored.codex_config_source;
  let codex_config_overrides = restored.codex_config_overrides.clone();
  let claude_sdk_session_id = restored.claude_sdk_session_id.clone();
  let allow_bypass_permissions = restored.allow_bypass_permissions;
  let row_count = restored.rows.len();

  let mut handle = restored_session_to_handle(
    restored,
    orbitdock_protocol::SessionStatus::Active,
    orbitdock_protocol::WorkStatus::Waiting,
  );
  match provider {
    Provider::Claude => handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct)),
    Provider::Codex => {
      handle.set_codex_integration_mode(Some(orbitdock_protocol::CodexIntegrationMode::Direct))
    }
  }
  let summary = handle.summary();

  PreparedResumeSession {
    provider,
    project_path,
    transcript_path,
    model,
    codex_thread_id,
    approval_policy,
    sandbox_mode,
    sandbox_policy_details,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides,
    claude_sdk_session_id,
    row_count,
    transcript_loaded,
    summary,
    handle,
    allow_bypass_permissions,
  }
}

pub(crate) async fn load_prepared_resume_session(
  session_id: &str,
) -> Result<Option<PreparedResumeSession>, anyhow::Error> {
  let Some(mut restored) = load_session_by_id(session_id).await? else {
    return Ok(None);
  };

  let initial_row_count = restored.rows.len();
  hydrate_restored_rows_if_missing(&mut restored, session_id).await;
  let transcript_loaded = initial_row_count == 0 && !restored.rows.is_empty();

  Ok(Some(prepare_restored_session_for_direct_resume(
    restored,
    transcript_loaded,
  )))
}
