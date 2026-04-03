use std::sync::Arc;

use axum::{
  body::Bytes,
  extract::{Path, Query, State},
  http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
  Json,
};
use orbitdock_protocol::{
  ControlDeckConfigUpdate, ControlDeckImageAttachmentRef, ControlDeckPreferences,
  ControlDeckSnapshot, ControlDeckSubmitTurnRequest,
};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use super::{
  errors::{bad_request, internal, not_found, service_unavailable},
  ApiErrorResponse,
};
use crate::runtime::control_deck::{
  load_control_deck_preferences, load_control_deck_snapshot as load_control_deck_snapshot_runtime,
  submit_control_deck_turn as submit_control_deck_turn_runtime,
  update_control_deck_config as update_control_deck_config_runtime,
  update_control_deck_preferences as update_control_deck_preferences_runtime,
  upload_control_deck_image_attachment as upload_control_deck_image_attachment_runtime,
  ControlDeckAttachmentUploadError, ControlDeckConfigUpdateError,
  ControlDeckPreferencesUpdateError, ControlDeckSnapshotLoadError, ControlDeckSubmitError,
};
use crate::runtime::session_registry::SessionRegistry;

#[derive(Debug, Serialize)]
pub struct ControlDeckSubmitResponse {
  pub accepted: bool,
  pub row: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
}

#[derive(Debug, Serialize)]
pub struct ControlDeckImageAttachmentResponse {
  pub attachment: ControlDeckImageAttachmentRef,
}

#[derive(Debug, Deserialize, Default)]
pub struct UploadControlDeckImageAttachmentQuery {
  #[serde(default)]
  pub display_name: Option<String>,
  #[serde(default)]
  pub pixel_width: Option<u32>,
  #[serde(default)]
  pub pixel_height: Option<u32>,
}

pub async fn get_control_deck_snapshot(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<ControlDeckSnapshot>, (StatusCode, Json<ApiErrorResponse>)> {
  load_control_deck_snapshot_runtime(&state, &session_id)
    .await
    .map(Json)
    .map_err(|error| map_snapshot_load_error(error, &session_id))
}

pub async fn update_control_deck_config(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<ControlDeckConfigUpdate>,
) -> Result<Json<ControlDeckSnapshot>, (StatusCode, Json<ApiErrorResponse>)> {
  info!(
    component = "control_deck",
    event = "config_update.http.request",
    session_id = %session_id,
    model = ?body.model,
    effort = ?body.effort,
    approval_policy = ?body.approval_policy,
    sandbox_mode = ?body.sandbox_mode,
    permission_mode = ?body.permission_mode,
    collaboration_mode = ?body.collaboration_mode,
    approvals_reviewer = ?body.approvals_reviewer,
    "Received control deck config update request"
  );

  match update_control_deck_config_runtime(&state, &session_id, body).await {
    Ok(snapshot) => {
      info!(
        component = "control_deck",
        event = "config_update.http.response",
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
        "Control deck config update applied"
      );
      Ok(Json(snapshot))
    }
    Err(error) => {
      warn!(
        component = "control_deck",
        event = "config_update.http.error",
        session_id = %session_id,
        error = ?error,
        "Control deck config update failed"
      );
      Err(map_config_update_error(error, &session_id))
    }
  }
}

pub async fn get_control_deck_preferences() -> Json<ControlDeckPreferences> {
  Json(load_control_deck_preferences())
}

pub async fn update_control_deck_preferences(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<ControlDeckPreferences>,
) -> Result<Json<ControlDeckPreferences>, (StatusCode, Json<ApiErrorResponse>)> {
  update_control_deck_preferences_runtime(&state, body)
    .await
    .map(Json)
    .map_err(map_preferences_update_error)
}

pub async fn submit_control_deck_turn(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<ControlDeckSubmitTurnRequest>,
) -> Result<(StatusCode, Json<ControlDeckSubmitResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  submit_control_deck_turn_runtime(&state, &session_id, body)
    .await
    .map(|result| {
      (
        StatusCode::ACCEPTED,
        Json(ControlDeckSubmitResponse {
          accepted: true,
          row: result.row,
        }),
      )
    })
    .map_err(|error| map_submit_error(error, &session_id))
}

pub async fn upload_control_deck_image_attachment(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Query(query): Query<UploadControlDeckImageAttachmentQuery>,
  headers: HeaderMap,
  body: Bytes,
) -> Result<Json<ControlDeckImageAttachmentResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  if body.is_empty() {
    return Err(bad_request(
      "invalid_request",
      "Provide image bytes in the request body".to_string(),
    ));
  }

  let mime_type = headers
    .get(CONTENT_TYPE)
    .and_then(|value| value.to_str().ok())
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .ok_or_else(|| {
      bad_request(
        "invalid_request",
        "Set the image MIME type in the Content-Type header".to_string(),
      )
    })?;

  upload_control_deck_image_attachment_runtime(
    &state,
    &session_id,
    body.as_ref(),
    mime_type,
    query.display_name.as_deref(),
    query.pixel_width,
    query.pixel_height,
  )
  .map(|image| {
    Json(ControlDeckImageAttachmentResponse {
      attachment: ControlDeckImageAttachmentRef {
        attachment_id: image.value,
        display_name: image.display_name,
      },
    })
  })
  .map_err(|error| map_attachment_upload_error(error, &session_id))
}

fn map_snapshot_load_error(
  error: ControlDeckSnapshotLoadError,
  session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    ControlDeckSnapshotLoadError::NotFound => {
      not_found("not_found", format!("Session {} not found", session_id))
    }
    ControlDeckSnapshotLoadError::Db(err) => internal("db_error", err),
    ControlDeckSnapshotLoadError::Runtime(err) => service_unavailable("runtime_error", err),
  }
}

fn map_preferences_update_error(
  error: ControlDeckPreferencesUpdateError,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    ControlDeckPreferencesUpdateError::Serialization(err) => internal("serialization_failed", err),
    ControlDeckPreferencesUpdateError::Persistence(err) => internal("persistence_failed", err),
  }
}

fn map_config_update_error(
  error: ControlDeckConfigUpdateError,
  session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    ControlDeckConfigUpdateError::NotFound => {
      not_found("not_found", format!("Session {} not found", session_id))
    }
    ControlDeckConfigUpdateError::InvalidConfig(message) => bad_request("invalid_request", message),
    ControlDeckConfigUpdateError::Db(message) => internal("db_error", message),
    ControlDeckConfigUpdateError::Runtime(message) => service_unavailable("runtime_error", message),
  }
}

fn map_submit_error(
  error: ControlDeckSubmitError,
  session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    ControlDeckSubmitError::InvalidRequest(message) => bad_request("invalid_request", message),
    ControlDeckSubmitError::SessionNotFound => {
      not_found("not_found", format!("Session {} not found", session_id))
    }
    ControlDeckSubmitError::ConnectorUnavailable => service_unavailable(
      "connector_unavailable",
      format!(
        "Session {} is direct but has no active connector attached",
        session_id
      ),
    ),
  }
}

fn map_attachment_upload_error(
  error: ControlDeckAttachmentUploadError,
  session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    ControlDeckAttachmentUploadError::SessionNotFound => {
      not_found("not_found", format!("Session {} not found", session_id))
    }
    ControlDeckAttachmentUploadError::Storage(err) => internal("attachment_store_failed", err),
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  use axum::body::Bytes;
  use axum::extract::{Path, Query, State};
  use axum::http::{header::CONTENT_TYPE, HeaderMap, HeaderValue, StatusCode};
  use orbitdock_protocol::Provider;

  use crate::domain::sessions::session::SessionHandle;
  use crate::support::test_support::new_test_session_registry;

  #[tokio::test]
  async fn uploads_control_deck_image_attachments_into_deck_owned_refs() {
    let _guard = crate::support::test_support::test_env_lock().lock().await;
    let state = new_test_session_registry(true);
    state.add_session(SessionHandle::new(
      "session-1".to_string(),
      Provider::Codex,
      "/repo".to_string(),
    ));

    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("image/png"));

    let Json(response) = upload_control_deck_image_attachment(
      Path("session-1".to_string()),
      State(state),
      Query(UploadControlDeckImageAttachmentQuery {
        display_name: Some("mock.png".to_string()),
        pixel_width: Some(320),
        pixel_height: Some(200),
      }),
      headers,
      Bytes::from_static(b"fake-image-bytes"),
    )
    .await
    .expect("deck attachment upload should succeed");

    assert!(response
      .attachment
      .attachment_id
      .starts_with("orbitdock-image-"));
    assert_eq!(
      response.attachment.display_name.as_deref(),
      Some("mock.png")
    );
  }

  #[tokio::test]
  async fn rejects_missing_session_for_control_deck_attachment_upload() {
    let _guard = crate::support::test_support::test_env_lock().lock().await;
    let state = new_test_session_registry(true);
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("image/png"));

    let err = upload_control_deck_image_attachment(
      Path("missing-session".to_string()),
      State(state),
      Query(UploadControlDeckImageAttachmentQuery::default()),
      headers,
      Bytes::from_static(b"fake-image-bytes"),
    )
    .await
    .expect_err("missing session should be rejected");

    assert_eq!(err.0, StatusCode::NOT_FOUND);
  }
}
