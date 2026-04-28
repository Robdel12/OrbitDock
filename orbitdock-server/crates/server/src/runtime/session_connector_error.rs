use tokio::sync::mpsc;

use orbitdock_connector_core::ConnectorStateEvent;

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_command_handler::dispatch_connector_event;

pub(crate) async fn emit_connector_error(
  session_id: &str,
  message: impl Into<String>,
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  dispatch_connector_event(
    session_id,
    ConnectorStateEvent::Error(message.into()),
    handle,
    persist_tx,
  )
  .await;
}
