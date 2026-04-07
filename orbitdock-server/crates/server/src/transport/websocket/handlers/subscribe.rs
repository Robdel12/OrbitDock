use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::warn;

use orbitdock_protocol::{ClientMessage, ServerMessage, SessionSurface};

use crate::runtime::session_commands::SubscribeResult;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_subscriptions::request_subscribe;
use crate::transport::websocket::connection::ConnectionSubscriptions;
use crate::transport::websocket::{
  send_json, send_replay_or_resync_fallback, spawn_broadcast_forwarder,
  spawn_filtered_broadcast_forwarder, OutboundMessage,
};

async fn send_http_resync_required(
  client_tx: &mpsc::Sender<OutboundMessage>,
  code: &str,
  message: String,
  session_id: Option<String>,
) {
  send_json(
    client_tx,
    ServerMessage::Error {
      code: code.to_string(),
      message,
      session_id,
    },
  )
  .await;
}

pub(crate) async fn handle(
  msg: ClientMessage,
  client_tx: &mpsc::Sender<OutboundMessage>,
  registry: &Arc<SessionRegistry>,
  subscriptions: &mut ConnectionSubscriptions,
  _conn_id: u64,
) {
  match msg {
    ClientMessage::SubscribeDashboard { since_revision } => {
      let current_revision = registry.current_dashboard_revision();
      let should_send_snapshot = since_revision.is_none_or(|revision| revision < current_revision);

      if should_send_snapshot {
        send_json(
          client_tx,
          ServerMessage::DashboardInvalidated {
            revision: current_revision,
          },
        )
        .await;
      }

      let rx = registry.subscribe_list();
      let handle = spawn_filtered_broadcast_forwarder(rx, client_tx.clone(), None, |msg| {
        matches!(
          msg,
          ServerMessage::DashboardInvalidated { .. }
            | ServerMessage::DashboardConversationUpdated { .. }
            | ServerMessage::DashboardItemRemoved { .. }
        )
      });
      subscriptions.replace_dashboard_forwarder(handle);
    }

    ClientMessage::UnsubscribeDashboard => {
      subscriptions.remove_dashboard_forwarder();
    }

    ClientMessage::SubscribeMissions { since_revision } => {
      let current_revision = registry.current_missions_revision();
      let should_send_snapshot = since_revision.is_none_or(|revision| revision < current_revision);

      if should_send_snapshot {
        send_json(
          client_tx,
          ServerMessage::MissionsInvalidated {
            revision: current_revision,
          },
        )
        .await;
      }

      let rx = registry.subscribe_list();
      let handle = spawn_filtered_broadcast_forwarder(rx, client_tx.clone(), None, |msg| {
        matches!(
          msg,
          ServerMessage::MissionDelta { .. }
            | ServerMessage::MissionHeartbeat { .. }
            | ServerMessage::MissionsInvalidated { .. }
        )
      });
      subscriptions.replace_missions_forwarder(handle);
    }

    ClientMessage::SubscribeSessionSurface {
      session_id,
      surface,
      since_revision,
    } => {
      let Some(actor) = registry.get_session(&session_id) else {
        send_json(
          client_tx,
          ServerMessage::Error {
            code: "not_found".into(),
            message: format!("Session {} not found", session_id),
            session_id: Some(session_id),
          },
        )
        .await;
        return;
      };

      match request_subscribe(&actor, since_revision).await {
        Ok(SubscribeResult::ResyncRequired { rx }) => {
          let handle = spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.clone()));
          let message = match surface {
                        SessionSurface::Detail => format!(
                            "Detail revision is missing or stale for session {}; refetch GET /api/sessions/{}/detail",
                            session_id, session_id
                        ),
                        SessionSurface::Composer => format!(
                            "Composer revision is missing or stale for session {}; refetch GET /api/sessions/{}/composer",
                            session_id, session_id
                        ),
                        SessionSurface::Conversation => format!(
                            "Conversation revision is missing or stale for session {}; refetch GET /api/sessions/{}/conversation",
                            session_id, session_id
                        ),
                    };
          let code = match surface {
            SessionSurface::Detail => "session_detail_resync_required",
            SessionSurface::Composer => "session_composer_resync_required",
            SessionSurface::Conversation => "conversation_resync_required",
          };
          send_http_resync_required(client_tx, code, message, Some(session_id.clone())).await;

          subscriptions.replace_session_surface_forwarder(session_id, surface, handle);
        }
        Ok(SubscribeResult::Replay { events, rx }) => {
          let handle = spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.clone()));
          subscriptions.replace_session_surface_forwarder(session_id.clone(), surface, handle);
          send_replay_or_resync_fallback(client_tx, &session_id, events, _conn_id).await;
        }
        Err(error) => {
          warn!(
              component = "websocket",
              event = "ws.subscribe.surface_request_failed",
              session_id = %session_id,
              error = %error,
              "Failed to subscribe to session surface"
          );
        }
      }
    }

    ClientMessage::UnsubscribeSessionSurface {
      session_id,
      surface,
    } => {
      subscriptions.remove_session_surface_forwarder(&session_id, surface);
    }
    _ => {}
  }
}
