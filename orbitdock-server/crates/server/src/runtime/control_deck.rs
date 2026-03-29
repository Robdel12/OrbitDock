use std::sync::Arc;

use orbitdock_protocol::{
  ControlDeckConfigUpdate, ControlDeckPreferences, ControlDeckSnapshot,
  ControlDeckSubmitTurnRequest, ImageInput, MentionInput, SkillInput,
};

use crate::domain::control_deck::{
  build_control_deck_snapshot, default_control_deck_preferences,
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
    Ok(session) => Ok(build_control_deck_snapshot(
      &session,
      load_control_deck_preferences(),
    )),
    Err(SessionLoadError::NotFound) => Err(ControlDeckSnapshotLoadError::NotFound),
    Err(SessionLoadError::Db(err)) => Err(ControlDeckSnapshotLoadError::Db(err)),
    Err(SessionLoadError::Runtime(err)) => Err(ControlDeckSnapshotLoadError::Runtime(err)),
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
  update_runtime_session_config(
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
  .map_err(|error| match error {
    SessionMutationError::NotFound(_) => ControlDeckConfigUpdateError::NotFound,
    SessionMutationError::InvalidCodexConfig(message) => {
      ControlDeckConfigUpdateError::InvalidConfig(message)
    }
  })?;

  load_control_deck_snapshot(state, session_id)
    .await
    .map_err(|error| match error {
      ControlDeckSnapshotLoadError::NotFound => ControlDeckConfigUpdateError::NotFound,
      ControlDeckSnapshotLoadError::Db(message) => ControlDeckConfigUpdateError::Db(message),
      ControlDeckSnapshotLoadError::Runtime(message) => {
        ControlDeckConfigUpdateError::Runtime(message)
      }
    })
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
