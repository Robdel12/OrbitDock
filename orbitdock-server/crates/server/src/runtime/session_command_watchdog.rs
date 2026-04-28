use std::time::Duration;

use orbitdock_connector_core::ConnectorStateEvent;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

pub(crate) fn is_turn_ending(event: &ConnectorStateEvent) -> bool {
  matches!(
    event,
    ConnectorStateEvent::TurnAborted { .. }
      | ConnectorStateEvent::TurnCompleted
      | ConnectorStateEvent::SessionEnded { .. }
  )
}

/// Spawn an interrupt watchdog that sends a synthetic `TurnAborted` after
/// 10 seconds if no turn-ending event arrives.
pub(crate) fn spawn_interrupt_watchdog(
  tx: mpsc::Sender<ConnectorStateEvent>,
  session_id: String,
  component: &'static str,
) -> JoinHandle<()> {
  tokio::spawn(async move {
    tokio::time::sleep(Duration::from_secs(10)).await;
    warn!(
        component = component,
        event = format_args!("{component}.interrupt.watchdog_fired"),
        session_id = %session_id,
        "Interrupt watchdog fired — forcing TurnAborted"
    );
    let _ = tx
      .send(ConnectorStateEvent::TurnAborted {
        reason: "interrupt_timeout".to_string(),
      })
      .await;
  })
}

pub(crate) fn abort_interrupt_watchdog(watchdog: &mut Option<JoinHandle<()>>) {
  if let Some(handle) = watchdog.take() {
    handle.abort();
  }
}

pub(crate) fn restart_interrupt_watchdog(
  watchdog: &mut Option<JoinHandle<()>>,
  tx: mpsc::Sender<ConnectorStateEvent>,
  session_id: &str,
  component: &'static str,
) {
  abort_interrupt_watchdog(watchdog);
  *watchdog = Some(spawn_interrupt_watchdog(
    tx,
    session_id.to_string(),
    component,
  ));
}
