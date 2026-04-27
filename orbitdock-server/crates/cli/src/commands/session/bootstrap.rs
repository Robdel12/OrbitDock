use orbitdock_protocol::{ClientMessage, ConversationSnapshotPage, SessionSurface};

use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::client::ws::WsClient;
use crate::error::CliError;

pub(crate) async fn ws_connect(
  config: &ClientConfig,
  output: &crate::output::Output,
) -> Option<WsClient> {
  match WsClient::connect(config).await {
    Ok(ws) => Some(ws),
    Err(e) => {
      output.print_error(&CliError::connection(e.to_string()));
      None
    }
  }
}

pub(crate) async fn fetch_session_detail_snapshot(
  config: &ClientConfig,
  session_id: &str,
) -> Result<orbitdock_protocol::SessionDetailSnapshot, CliError> {
  let rest = RestClient::new(config);
  rest
    .get::<orbitdock_protocol::SessionDetailSnapshot>(&format!("/api/sessions/{session_id}/detail"))
    .await
    .into_result()
    .map_err(|(_, err)| err)
}

pub(crate) async fn fetch_conversation_snapshot(
  config: &ClientConfig,
  session_id: &str,
  limit: usize,
) -> Result<ConversationSnapshotPage, CliError> {
  let rest = RestClient::new(config);
  rest
    .get::<ConversationSnapshotPage>(&format!(
      "/api/sessions/{session_id}/conversation?limit={limit}"
    ))
    .await
    .into_result()
    .map_err(|(_, err)| err)
}

pub(crate) async fn subscribe_session_surface(
  ws: &mut WsClient,
  session_id: &str,
  surface: SessionSurface,
  since_revision: Option<u64>,
) -> Result<(), CliError> {
  ws.send(&ClientMessage::SubscribeSessionSurface {
    session_id: session_id.to_string(),
    surface,
    since_revision,
  })
  .await
  .map_err(|error| CliError::connection(error.to_string()))
}

pub(crate) async fn bootstrap_session_subscription(
  config: &ClientConfig,
  ws: &mut WsClient,
  session_id: &str,
) -> Result<orbitdock_protocol::SessionState, CliError> {
  let snapshot = fetch_session_detail_snapshot(config, session_id).await?;
  subscribe_session_surface(
    ws,
    session_id,
    SessionSurface::Detail,
    Some(snapshot.revision),
  )
  .await?;
  Ok(snapshot.session)
}
