use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

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
use crate::runtime::restored_sessions::{load_prepared_resume_session, PreparedResumeSession};
use crate::runtime::session_mutations::{
  update_session_config as update_runtime_session_config, SessionConfigUpdate, SessionMutationError,
};
use crate::runtime::session_queries::{load_full_session_state, SessionLoadError};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_resume::{
  launch_resumed_session, ResumeSessionError, ResumeSessionLaunch,
};

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
  match load_full_session_state(state, session_id, false, false).await {
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
        pending_approval = snapshot.pending_approval.is_some(),
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
    "Applied control deck config update; awaiting persistence flush"
  );

  // The config update is persisted asynchronously through the batched writer.
  // Send a Flush barrier and await its ack so the DB has the updated values
  // before we reload the snapshot.
  let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
  let _ = state
    .persist()
    .send(PersistCommand::Flush { ack: ack_tx })
    .await;
  let _ = ack_rx.await;

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

  let dispatch_request = ControlDeckDispatchRequest {
    session_id: session_id.to_string(),
    content: plan.text,
    model: plan.model,
    effort: plan.effort,
    skills: plan.skills,
    images: plan.images,
    mentions: plan.mentions,
    message_id: format!("control-deck-http-{}", orbitdock_protocol::new_id()),
  };

  let result = dispatch_control_deck_turn(state, dispatch_request.clone()).await;

  let user_row = match result {
    Ok(row) => row,
    Err(DispatchMessageError::ConnectorUnavailable) => {
      info!(
        component = "control_deck",
        event = "submit.auto_resume",
        session_id = %session_id,
        "No connector available — attempting auto-resume before retry"
      );
      auto_resume_session(state, session_id).await?;
      dispatch_control_deck_turn(state, dispatch_request)
        .await
        .map_err(map_dispatch_error)?
    }
    Err(other) => return Err(map_dispatch_error(other)),
  };

  Ok(ControlDeckSubmitResult { row: user_row })
}

/// Attempt to transparently resume a session whose connector has died.
/// Clears the stale in-memory actor, reloads from the database, and
/// relaunches the connector. Returns an error only if the session cannot
/// be resumed at all.
async fn auto_resume_session(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), ControlDeckSubmitError> {
  auto_resume_session_with(
    state,
    session_id,
    |id| {
      let id = id.to_string();
      async move { load_prepared_resume_session(&id).await }
    },
    |state, id, prepared| {
      let state = state.clone();
      let id = id.to_string();
      async move { launch_resumed_session(&state, &id, prepared).await }
    },
  )
  .await
}

async fn auto_resume_session_with<LoadPrepared, LoadFuture, LaunchResume, LaunchFuture>(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  load_prepared: LoadPrepared,
  launch_resume: LaunchResume,
) -> Result<(), ControlDeckSubmitError>
where
  LoadPrepared: Fn(&str) -> LoadFuture,
  LoadFuture: Future<Output = Result<Option<PreparedResumeSession>, anyhow::Error>>,
  LaunchResume: Fn(&Arc<SessionRegistry>, &str, PreparedResumeSession) -> LaunchFuture,
  LaunchFuture: Future<Output = Result<ResumeSessionLaunch, ResumeSessionError>>,
{
  // Serialize auto-resume attempts per session. Without this, concurrent submits can
  // launch duplicate runtimes and split subsequent message routing.
  let resume_lock = state.auto_resume_lock(session_id);
  let _guard = resume_lock.lock().await;

  // Another in-flight submit may have already reattached the connector while this call
  // waited on the lock. If so, treat auto-resume as complete.
  if state.has_active_connector_action_tx(session_id) {
    info!(
      component = "control_deck",
      event = "submit.auto_resume.already_restored",
      session_id = %session_id,
      "Auto-resume skipped because a connector is already active"
    );
    return Ok(());
  }

  let prepared = load_prepared(session_id)
    .await
    .map_err(|e| {
      warn!(
        component = "control_deck",
        event = "submit.auto_resume.load_failed",
        session_id = %session_id,
        error = %e,
        "Auto-resume failed: could not load session from database"
      );
      ControlDeckSubmitError::ConnectorUnavailable
    })?
    .ok_or_else(|| {
      warn!(
        component = "control_deck",
        event = "submit.auto_resume.not_found",
        session_id = %session_id,
        "Auto-resume failed: session not found in database"
      );
      ControlDeckSubmitError::SessionNotFound
    })?;

  let launch = launch_resume(state, session_id, prepared)
    .await
    .map_err(|e| {
      warn!(
        component = "control_deck",
        event = "submit.auto_resume.launch_failed",
        session_id = %session_id,
        error = %e.message(),
        "Auto-resume failed: connector launch error"
      );
      ControlDeckSubmitError::ConnectorUnavailable
    })?;

  // Wait for the connector to be ready (runtime startup has a 15s timeout
  // internally; we add 1s buffer).
  if let Some(startup_ready) = launch.startup_ready {
    let _ = tokio::time::timeout(Duration::from_secs(16), startup_ready).await;
  }

  info!(
    component = "control_deck",
    event = "submit.auto_resume.success",
    session_id = %session_id,
    "Auto-resume succeeded — retrying dispatch"
  );

  Ok(())
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

#[cfg(test)]
mod tests {
  use super::{auto_resume_session_with, ControlDeckSubmitError};
  use crate::domain::sessions::session::SessionHandle;
  use crate::runtime::restored_sessions::PreparedResumeSession;
  use crate::runtime::session_registry::SessionRegistry;
  use crate::runtime::session_resume::ResumeSessionLaunch;
  use crate::support::test_support::ensure_server_test_data_dir;
  use orbitdock_protocol::Provider;
  use std::sync::atomic::{AtomicUsize, Ordering};
  use std::sync::Arc;
  use tokio::sync::{mpsc, oneshot};
  use tokio::time::{sleep, Duration};

  fn test_prepared_resume_session(session_id: &str) -> PreparedResumeSession {
    let handle = SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/orbitdock-auto-resume".to_string(),
    );
    let summary = handle.summary();
    PreparedResumeSession {
      provider: Provider::Codex,
      project_path: "/tmp/orbitdock-auto-resume".to_string(),
      transcript_path: None,
      model: None,
      codex_thread_id: None,
      approval_policy: None,
      sandbox_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides: None,
      claude_sdk_session_id: None,
      row_count: 0,
      transcript_loaded: false,
      summary,
      handle,
      allow_bypass_permissions: false,
    }
  }

  #[tokio::test]
  async fn auto_resume_load_failure_keeps_existing_session_actor() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let state = Arc::new(SessionRegistry::new(persist_tx));
    let session_id = "auto-resume-load-failure";
    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/orbitdock-auto-resume".to_string(),
    ));

    let result = auto_resume_session_with(
      &state,
      session_id,
      |_id| async move { Err(anyhow::anyhow!("transient sqlite read failure")) },
      |_state, _sid, _prepared| async move {
        panic!("launch should not execute when loading prepared resume fails")
      },
    )
    .await;

    assert!(matches!(
      result,
      Err(ControlDeckSubmitError::ConnectorUnavailable)
    ));
    assert!(state.get_session(session_id).is_some());
  }

  #[tokio::test]
  async fn auto_resume_serializes_concurrent_attempts_and_launches_once() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let state = Arc::new(SessionRegistry::new(persist_tx));
    let session_id = "auto-resume-race";
    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/orbitdock-auto-resume".to_string(),
    ));

    let load_count = Arc::new(AtomicUsize::new(0));
    let launch_count = Arc::new(AtomicUsize::new(0));
    let load_count_assert = load_count.clone();

    let run_attempt = |state: Arc<SessionRegistry>,
                       load_count: Arc<AtomicUsize>,
                       launch_count: Arc<AtomicUsize>| async move {
      auto_resume_session_with(
        &state,
        session_id,
        move |id| {
          let load_count = load_count.clone();
          let id = id.to_string();
          async move {
            load_count.fetch_add(1, Ordering::SeqCst);
            Ok(Some(test_prepared_resume_session(&id)))
          }
        },
        move |state, sid, prepared| {
          let launch_count = launch_count.clone();
          let state = state.clone();
          let sid = sid.to_string();
          async move {
            launch_count.fetch_add(1, Ordering::SeqCst);
            // Simulate connector startup work so concurrent callers would race
            // into a duplicate launch without the per-session gate.
            sleep(Duration::from_millis(50)).await;
            let (tx, _rx) = mpsc::channel(1);
            state.set_codex_action_tx(&sid, tx);
            let (ready_tx, ready_rx) = oneshot::channel();
            let _ = ready_tx.send(());
            Ok(ResumeSessionLaunch {
              summary: prepared.summary,
              startup_ready: Some(ready_rx),
            })
          }
        },
      )
      .await
    };

    let first = tokio::spawn(run_attempt(
      state.clone(),
      load_count.clone(),
      launch_count.clone(),
    ));
    let second = tokio::spawn(run_attempt(state, load_count, launch_count.clone()));

    let (first_result, second_result) = tokio::join!(first, second);
    assert!(first_result.expect("first task join").is_ok());
    assert!(second_result.expect("second task join").is_ok());
    assert_eq!(load_count_assert.load(Ordering::SeqCst), 1);
    assert_eq!(launch_count.load(Ordering::SeqCst), 1);
  }
}
