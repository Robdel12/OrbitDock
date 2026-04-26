use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::warn;

use orbitdock_protocol::{ClientMessage, ServerMessage, SessionSurface};

use crate::runtime::session_commands::SubscribeResult;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_subscriptions::request_subscribe;
use crate::transport::websocket::connection::ConnectionSubscriptions;
use crate::transport::websocket::{
  send_json, send_replay_or_resync_fallback, spawn_filtered_broadcast_forwarder, OutboundMessage,
};

fn surface_message_matches(msg: &ServerMessage, surface: SessionSurface) -> bool {
  match surface {
    SessionSurface::Conversation => matches!(
      msg,
      ServerMessage::ConversationRowsChanged { .. }
        | ServerMessage::SessionSurfaceInvalidated {
          surface: SessionSurface::Conversation,
          ..
        }
    ),
    SessionSurface::Detail => matches!(
      msg,
      ServerMessage::SessionSurfaceInvalidated {
        surface: SessionSurface::Detail,
        ..
      }
    ),
    SessionSurface::Composer => matches!(
      msg,
      ServerMessage::SessionSurfaceInvalidated {
        surface: SessionSurface::Composer,
        ..
      }
    ),
    SessionSurface::Review => matches!(
      msg,
      ServerMessage::SessionSurfaceInvalidated {
        surface: SessionSurface::Review,
        ..
      }
    ),
    SessionSurface::Capabilities => matches!(
      msg,
      ServerMessage::SkillsUpdateAvailable { .. }
        | ServerMessage::McpStartupUpdate { .. }
        | ServerMessage::McpStartupComplete { .. }
        | ServerMessage::ClaudeCapabilities { .. }
        | ServerMessage::SessionSurfaceInvalidated {
          surface: SessionSurface::Capabilities,
          ..
        }
    ),
  }
}

fn surface_invalidation_message(
  session_id: &str,
  surface: SessionSurface,
  revision: u64,
) -> ServerMessage {
  ServerMessage::SessionSurfaceInvalidated {
    session_id: session_id.to_string(),
    surface,
    revision,
  }
}

fn filter_replay_events_for_surface(events: Vec<String>, surface: SessionSurface) -> Vec<String> {
  events
    .into_iter()
    .filter(|json| {
      serde_json::from_str::<ServerMessage>(json)
        .map(|message| surface_message_matches(&message, surface))
        .unwrap_or(false)
    })
    .collect()
}

pub(crate) async fn handle(
  msg: ClientMessage,
  client_tx: &mpsc::Sender<OutboundMessage>,
  registry: &Arc<SessionRegistry>,
  subscriptions: &mut ConnectionSubscriptions,
  _conn_id: u64,
) {
  match msg {
    ClientMessage::SubscribeSessionsSummary { since_revision } => {
      let current_revision = registry.current_sessions_summary_revision();
      let should_send_snapshot = since_revision.is_none_or(|revision| revision < current_revision);

      if should_send_snapshot {
        send_json(
          client_tx,
          ServerMessage::SessionsSummaryInvalidated {
            revision: current_revision,
          },
        )
        .await;
      }

      let rx = registry.subscribe_list();
      let handle = spawn_filtered_broadcast_forwarder(rx, client_tx.clone(), None, |msg| {
        matches!(msg, ServerMessage::SessionsSummaryInvalidated { .. })
      });
      subscriptions.replace_sessions_summary_forwarder(handle);
    }

    ClientMessage::UnsubscribeSessionsSummary => {
      subscriptions.remove_sessions_summary_forwarder();
    }

    ClientMessage::SubscribeActiveSessions { since_revision } => {
      let current_revision = registry.current_dashboard_revision();
      let should_send_snapshot = since_revision.is_none_or(|revision| revision < current_revision);

      if should_send_snapshot {
        send_json(
          client_tx,
          ServerMessage::ActiveSessionsInvalidated {
            revision: current_revision,
          },
        )
        .await;
      }

      let rx = registry.subscribe_list();
      let handle = spawn_filtered_broadcast_forwarder(rx, client_tx.clone(), None, |msg| {
        matches!(msg, ServerMessage::ActiveSessionsInvalidated { .. })
      });
      subscriptions.replace_dashboard_forwarder(handle);
    }

    ClientMessage::UnsubscribeActiveSessions => {
      subscriptions.remove_dashboard_forwarder();
    }

    ClientMessage::SubscribeArchivedSessions { since_revision } => {
      let current_revision = registry.current_library_revision();
      let should_send_snapshot = since_revision.is_none_or(|revision| revision < current_revision);

      if should_send_snapshot {
        send_json(
          client_tx,
          ServerMessage::ArchivedSessionsInvalidated {
            revision: current_revision,
          },
        )
        .await;
      }

      let rx = registry.subscribe_list();
      let handle = spawn_filtered_broadcast_forwarder(rx, client_tx.clone(), None, |msg| {
        matches!(msg, ServerMessage::ArchivedSessionsInvalidated { .. })
      });
      subscriptions.replace_library_forwarder(handle);
    }

    ClientMessage::UnsubscribeArchivedSessions => {
      subscriptions.remove_library_forwarder();
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
        matches!(msg, ServerMessage::MissionsInvalidated { .. })
      });
      subscriptions.replace_missions_forwarder(handle);
    }

    ClientMessage::UnsubscribeMissions => {
      subscriptions.remove_missions_forwarder();
    }

    ClientMessage::SubscribeMission { mission_id } => {
      let rx = registry.subscribe_list();
      let mission_id_for_filter = mission_id.clone();
      let handle = spawn_filtered_broadcast_forwarder(rx, client_tx.clone(), None, move |msg| {
        matches!(
          msg,
          ServerMessage::MissionHeartbeat { mission_id, .. } if mission_id == &mission_id_for_filter
        ) || matches!(
          msg,
          ServerMessage::MissionInvalidated { mission_id, .. } if mission_id == &mission_id_for_filter
        )
      });
      subscriptions.replace_mission_forwarder(mission_id, handle);
    }

    ClientMessage::UnsubscribeMission { mission_id } => {
      subscriptions.remove_mission_forwarder(&mission_id);
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
          let revision = actor.snapshot().revision;
          let handle = spawn_filtered_broadcast_forwarder(
            rx,
            client_tx.clone(),
            Some(session_id.clone()),
            move |msg| surface_message_matches(msg, surface),
          );
          send_json(
            client_tx,
            surface_invalidation_message(&session_id, surface, revision),
          )
          .await;

          subscriptions.replace_session_surface_forwarder(session_id, surface, handle);
        }
        Ok(SubscribeResult::Replay { events, rx }) => {
          let revision = actor.snapshot().revision;
          let handle = spawn_filtered_broadcast_forwarder(
            rx,
            client_tx.clone(),
            Some(session_id.clone()),
            move |msg| surface_message_matches(msg, surface),
          );
          subscriptions.replace_session_surface_forwarder(session_id.clone(), surface, handle);
          if surface == SessionSurface::Conversation {
            let replay = filter_replay_events_for_surface(events, surface);
            send_replay_or_resync_fallback(client_tx, &session_id, replay, _conn_id).await;
          } else if since_revision.is_none() || !events.is_empty() {
            send_json(
              client_tx,
              surface_invalidation_message(&session_id, surface, revision),
            )
            .await;
          }
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
