use orbitdock_protocol::{ClientMessage, SessionSurface};

use crate::client::config::ClientConfig;
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
