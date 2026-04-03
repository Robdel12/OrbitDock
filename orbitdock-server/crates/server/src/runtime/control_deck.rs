use std::sync::Arc;

use orbitdock_connector_codex::discover_models_for_context;
use orbitdock_protocol::{
  ControlDeckConfigUpdate, ControlDeckPickerOption, ControlDeckPreferences, ControlDeckSnapshot,
  ControlDeckSubmitTurnRequest, ImageInput, MentionInput, SkillInput,
};
use tracing::{debug, info, warn};

use crate::domain::control_deck::{
  build_control_deck_snapshot, control_deck_effort_options, default_control_deck_preferences,
  validate_control_deck_submit_request, ControlDeckSubmitValidationError,
  CONTROL_DECK_PREFERENCES_CONFIG_KEY,
};
use crate::infrastructure::images::store_uploaded_attachment;
use crate::infrastructure::persistence::{load_config_value, PersistCommand};
use crate::runtime::message_dispatch::{
  dispatch_send_message, DispatchMessageError, DispatchSendMessage,
};
use crate::runtime::session_mutations::{
  update_session_config as update_runtime_session_config, SessionConfigUpdate, SessionMutationError,
};
use crate::runtime::session_queries::{load_full_session_state, SessionLoadError};
use crate::runtime::session_registry::SessionRegistry;

#[derive(Debug)]
pub(crate) enum ControlDeckSnapshotLoadError {
  NotFound,
  Db(String),
  Runtime(String),
}

#[derive(Debug)]
pub(crate) enum ControlDeckPreferencesUpdateError {
  Serialization(String),
  Persistence(String),
}

#[derive(Debug)]
pub(crate) enum ControlDeckConfigUpdateError {
  NotFound,
  InvalidConfig(String),
  Db(String),
  Runtime(String),
}

#[derive(Debug)]
pub(crate) enum ControlDeckSubmitError {
  InvalidRequest(String),
  SessionNotFound,
  ConnectorUnavailable,
}

#[derive(Debug)]
pub(crate) enum ControlDeckAttachmentUploadError {
  SessionNotFound,
  Storage(String),
}

#[derive(Debug, Clone)]
pub(crate) struct ControlDeckSubmitResult {
  pub row: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
}

#[derive(Debug, Clone)]
struct ControlDeckDispatchRequest {
  session_id: String,
  content: String,
  model: Option<String>,
  effort: Option<String>,
  skills: Vec<SkillInput>,
  images: Vec<ImageInput>,
  mentions: Vec<MentionInput>,
  message_id: String,
}

pub(crate) fn load_control_deck_preferences() -> ControlDeckPreferences {
  load_config_value(CONTROL_DECK_PREFERENCES_CONFIG_KEY)
    .and_then(|raw| serde_json::from_str::<ControlDeckPreferences>(&raw).ok())
    .unwrap_or_else(default_control_deck_preferences)
}

pub(crate) async fn load_control_deck_snapshot(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<ControlDeckSnapshot, ControlDeckSnapshotLoadError> {
  match load_full_session_state(state, session_id, false).await {
    Ok(session) => {
      let effort_options = resolve_control_deck_effort_options(session_id, &session).await;
      let snapshot =
        build_control_deck_snapshot(&session, load_control_deck_preferences(), effort_options);
      debug!(
        component = "control_deck",
        event = "snapshot.loaded",
        session_id = %session_id,
        revision = snapshot.revision,
        provider = ?snapshot.state.provider,
        model = ?snapshot.state.config.model,
        effort = ?snapshot.state.config.effort,
        effort_options = snapshot.capabilities.effort_options.len(),
        "Loaded control deck snapshot"
      );
      Ok(snapshot)
    }
    Err(SessionLoadError::NotFound) => Err(ControlDeckSnapshotLoadError::NotFound),
    Err(SessionLoadError::Db(err)) => Err(ControlDeckSnapshotLoadError::Db(err)),
    Err(SessionLoadError::Runtime(err)) => Err(ControlDeckSnapshotLoadError::Runtime(err)),
  }
}

async fn resolve_control_deck_effort_options(
  session_id: &str,
  session: &orbitdock_protocol::SessionState,
) -> Vec<ControlDeckPickerOption> {
  if session.provider != orbitdock_protocol::Provider::Codex {
    let options = control_deck_effort_options(session.provider, None);
    let values = effort_option_values(&options);
    debug!(
      component = "control_deck",
      event = "effort_options.resolved.non_codex",
      session_id = %session_id,
      provider = ?session.provider,
      effort_options = ?values,
      "Resolved control deck effort options for non-Codex session"
    );
    return options;
  }

  let cwd = session
    .current_cwd
    .as_deref()
    .unwrap_or(session.project_path.as_str());
  let model_provider = session.codex_model_provider.as_deref();
  let discovered = discover_models_for_context(Some(cwd), model_provider)
    .await
    .ok();
  let active_model = session.model.as_deref().map(|value| value.trim());

  let codex_model_efforts = discovered
    .as_ref()
    .and_then(|models| {
      let active_model = active_model?;
      models.iter().find(|option| {
        option.model.eq_ignore_ascii_case(active_model)
          || option.id.eq_ignore_ascii_case(active_model)
      })
    })
    .map(|option| option.supported_reasoning_efforts.as_slice());

  let options = control_deck_effort_options(session.provider, codex_model_efforts);
  let values = effort_option_values(&options);
  info!(
    component = "control_deck",
    event = "effort_options.resolved.codex",
    session_id = %session_id,
    model_provider = ?model_provider,
    active_model = ?active_model,
    discovered_models = discovered.as_ref().map(|models| models.len()).unwrap_or(0),
    effort_options = ?values,
    "Resolved control deck effort options for Codex session"
  );
  options
}

fn effort_option_values(options: &[ControlDeckPickerOption]) -> Vec<&str> {
  options
    .iter()
    .map(|option| option.value.as_str())
    .collect::<Vec<_>>()
}

fn map_session_mutation_error(error: SessionMutationError) -> ControlDeckConfigUpdateError {
  match error {
    SessionMutationError::NotFound(_) => ControlDeckConfigUpdateError::NotFound,
    SessionMutationError::InvalidCodexConfig(message) => {
      ControlDeckConfigUpdateError::InvalidConfig(message)
    }
  }
}

fn map_snapshot_load_error(error: ControlDeckSnapshotLoadError) -> ControlDeckConfigUpdateError {
  match error {
    ControlDeckSnapshotLoadError::NotFound => ControlDeckConfigUpdateError::NotFound,
    ControlDeckSnapshotLoadError::Db(message) => ControlDeckConfigUpdateError::Db(message),
    ControlDeckSnapshotLoadError::Runtime(message) => {
      ControlDeckConfigUpdateError::Runtime(message)
    }
  }
}

pub(crate) async fn update_control_deck_preferences(
  state: &Arc<SessionRegistry>,
  preferences: ControlDeckPreferences,
) -> Result<ControlDeckPreferences, ControlDeckPreferencesUpdateError> {
  let serialized = serde_json::to_string(&preferences)
    .map_err(|error| ControlDeckPreferencesUpdateError::Serialization(error.to_string()))?;

  state
    .persist()
    .send(PersistCommand::SetConfig {
      key: CONTROL_DECK_PREFERENCES_CONFIG_KEY.to_string(),
      value: serialized,
    })
    .await
    .map_err(|error| ControlDeckPreferencesUpdateError::Persistence(error.to_string()))?;

  Ok(preferences)
}

pub(crate) async fn update_control_deck_config(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  update: ControlDeckConfigUpdate,
) -> Result<ControlDeckSnapshot, ControlDeckConfigUpdateError> {
  info!(
    component = "control_deck",
    event = "config_update.runtime.request",
    session_id = %session_id,
    update = ?update,
    "Applying control deck config update"
  );

  if let Err(error) = update_runtime_session_config(
    state,
    session_id,
    SessionConfigUpdate {
      approval_policy: update.approval_policy.map(Some),
      approval_policy_details: update.approval_policy_details.map(Some),
      sandbox_mode: update.sandbox_mode.map(Some),
      approvals_reviewer: update.approvals_reviewer.map(Some),
      permission_mode: update.permission_mode.map(Some),
      collaboration_mode: update.collaboration_mode.map(Some),
      model: update.model.map(Some),
      effort: update.effort.map(Some),
      ..Default::default()
    },
  )
  .await
  {
    warn!(
      component = "control_deck",
      event = "config_update.runtime.apply_failed",
      session_id = %session_id,
      error = ?error,
      "Failed to apply control deck config update"
    );
    return Err(map_session_mutation_error(error));
  }

  info!(
    component = "control_deck",
    event = "config_update.runtime.applied",
    session_id = %session_id,
    "Applied control deck config update; reloading snapshot"
  );

  match load_control_deck_snapshot(state, session_id).await {
    Ok(snapshot) => {
      info!(
        component = "control_deck",
        event = "config_update.runtime.response",
        session_id = %session_id,
        revision = snapshot.revision,
        model = ?snapshot.state.config.model,
        effort = ?snapshot.state.config.effort,
        approval_policy = ?snapshot.state.config.approval_policy,
        sandbox_mode = ?snapshot.state.config.sandbox_mode,
        permission_mode = ?snapshot.state.config.permission_mode,
        collaboration_mode = ?snapshot.state.config.collaboration_mode,
        approvals_reviewer = ?snapshot.state.config.approvals_reviewer,
        effort_options = snapshot.capabilities.effort_options.len(),
        "Returning updated control deck snapshot"
      );
      Ok(snapshot)
    }
    Err(error) => {
      warn!(
        component = "control_deck",
        event = "config_update.runtime.snapshot_failed",
        session_id = %session_id,
        error = ?error,
        "Control deck config update applied but snapshot reload failed"
      );
      Err(map_snapshot_load_error(error))
    }
  }
}

pub(crate) async fn submit_control_deck_turn(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  request: ControlDeckSubmitTurnRequest,
) -> Result<ControlDeckSubmitResult, ControlDeckSubmitError> {
  let plan = validate_control_deck_submit_request(request).map_err(
    |error: ControlDeckSubmitValidationError| {
      ControlDeckSubmitError::InvalidRequest(error.message().to_string())
    },
  )?;

  let user_row = dispatch_control_deck_turn(
    state,
    ControlDeckDispatchRequest {
      session_id: session_id.to_string(),
      content: plan.text,
      model: plan.model,
      effort: plan.effort,
      skills: plan.skills,
      images: plan.images,
      mentions: plan.mentions,
      message_id: format!("control-deck-http-{}", orbitdock_protocol::new_id()),
    },
  )
  .await
  .map_err(map_dispatch_error)?;

  Ok(ControlDeckSubmitResult { row: user_row })
}

async fn dispatch_control_deck_turn(
  state: &Arc<SessionRegistry>,
  request: ControlDeckDispatchRequest,
) -> Result<orbitdock_protocol::conversation_contracts::ConversationRowEntry, DispatchMessageError>
{
  dispatch_send_message(
    state,
    DispatchSendMessage {
      session_id: request.session_id,
      content: request.content,
      model: request.model,
      effort: request.effort,
      skills: request.skills,
      images: request.images,
      mentions: request.mentions,
      message_id: request.message_id,
    },
  )
  .await
}

pub(crate) fn upload_control_deck_image_attachment(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  bytes: &[u8],
  mime_type: &str,
  display_name: Option<&str>,
  pixel_width: Option<u32>,
  pixel_height: Option<u32>,
) -> Result<ImageInput, ControlDeckAttachmentUploadError> {
  if state.get_session(session_id).is_none() {
    return Err(ControlDeckAttachmentUploadError::SessionNotFound);
  }

  store_uploaded_attachment(
    session_id,
    bytes,
    mime_type,
    display_name,
    pixel_width,
    pixel_height,
  )
  .map_err(ControlDeckAttachmentUploadError::Storage)
}

fn map_dispatch_error(error: DispatchMessageError) -> ControlDeckSubmitError {
  match error {
    DispatchMessageError::SessionNotFound => ControlDeckSubmitError::SessionNotFound,
    DispatchMessageError::ConnectorUnavailable => ControlDeckSubmitError::ConnectorUnavailable,
  }
}
