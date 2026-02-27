use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::mpsc;

use orbitdock_protocol::ClientMessage;

use crate::persistence::PersistCommand;
use crate::state::SessionRegistry;
use crate::websocket::{send_rest_only_error, OutboundMessage};

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    let _ = conn_id;

    match msg {
        ClientMessage::CreateReviewComment {
            session_id,
            turn_id,
            file_path,
            line_start,
            line_end,
            body,
            tag,
        } => {
            let comment_id = format!(
                "rc-{}-{}",
                &session_id[..8.min(session_id.len())],
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis()
            );

            let tag_str = tag.map(|t| {
                match t {
                    orbitdock_protocol::ReviewCommentTag::Clarity => "clarity",
                    orbitdock_protocol::ReviewCommentTag::Scope => "scope",
                    orbitdock_protocol::ReviewCommentTag::Risk => "risk",
                    orbitdock_protocol::ReviewCommentTag::Nit => "nit",
                }
                .to_string()
            });

            let now = {
                let secs = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                format!("{}Z", secs)
            };

            let comment = orbitdock_protocol::ReviewComment {
                id: comment_id.clone(),
                session_id: session_id.clone(),
                turn_id: turn_id.clone(),
                file_path: file_path.clone(),
                line_start,
                line_end,
                body: body.clone(),
                tag,
                status: orbitdock_protocol::ReviewCommentStatus::Open,
                created_at: now,
                updated_at: None,
            };

            let _ = state
                .persist()
                .send(PersistCommand::ReviewCommentCreate {
                    id: comment_id,
                    session_id: session_id.clone(),
                    turn_id,
                    file_path,
                    line_start,
                    line_end,
                    body,
                    tag: tag_str,
                })
                .await;

            // Broadcast to session subscribers
            if let Some(actor) = state.get_session(&session_id) {
                actor
                    .send(crate::session_command::SessionCommand::Broadcast {
                        msg: orbitdock_protocol::ServerMessage::ReviewCommentCreated {
                            session_id,
                            comment,
                        },
                    })
                    .await;
            }
        }

        ClientMessage::UpdateReviewComment {
            comment_id,
            body,
            tag,
            status,
        } => {
            let tag_str = tag.map(|t| match t {
                orbitdock_protocol::ReviewCommentTag::Clarity => "clarity".to_string(),
                orbitdock_protocol::ReviewCommentTag::Scope => "scope".to_string(),
                orbitdock_protocol::ReviewCommentTag::Risk => "risk".to_string(),
                orbitdock_protocol::ReviewCommentTag::Nit => "nit".to_string(),
            });
            let status_str = status.map(|s| match s {
                orbitdock_protocol::ReviewCommentStatus::Open => "open".to_string(),
                orbitdock_protocol::ReviewCommentStatus::Resolved => "resolved".to_string(),
            });

            let _ = state
                .persist()
                .send(PersistCommand::ReviewCommentUpdate {
                    id: comment_id.clone(),
                    body: body.clone(),
                    tag: tag_str,
                    status: status_str,
                })
                .await;

            // TODO: broadcast ReviewCommentUpdated once we can read back the full comment
            // For now, the client can optimistically update its local state
        }

        ClientMessage::DeleteReviewComment { comment_id } => {
            let _ = state
                .persist()
                .send(PersistCommand::ReviewCommentDelete {
                    id: comment_id.clone(),
                })
                .await;

            // We don't know the session_id here, so we can't target a broadcast.
            // The client should optimistically remove the comment locally.
        }

        ClientMessage::ListReviewComments { session_id, .. } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/review-comments",
                Some(session_id),
            )
            .await;
        }

        _ => unreachable!("review_comments::handle called with non-review-comment message"),
    }
}
