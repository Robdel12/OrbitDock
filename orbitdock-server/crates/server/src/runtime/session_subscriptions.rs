use tokio::sync::{broadcast, oneshot};

use orbitdock_protocol::{ServerMessage, SessionState};

use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::{SessionCommand, SubscribeResult};
use crate::runtime::session_subscription_queries::hydrate_runtime_subscribe_snapshot;
use crate::support::session_modes::{
    needs_lazy_connector, should_reactivate_passive_codex_session,
};
use crate::support::session_time::parse_unix_z;

pub(crate) struct SessionSubscribeInputs<'a> {
    pub provider: orbitdock_protocol::Provider,
    pub status: orbitdock_protocol::SessionStatus,
    pub codex_integration_mode: Option<orbitdock_protocol::CodexIntegrationMode>,
    pub claude_integration_mode: Option<orbitdock_protocol::ClaudeIntegrationMode>,
    pub transcript_path: Option<&'a str>,
    pub transcript_modified_at_secs: Option<u64>,
    pub last_activity_at: Option<&'a str>,
    pub has_codex_connector: bool,
    pub has_claude_connector: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SessionSubscribePlan {
    pub reactivate_passive: bool,
    pub start_lazy_connector: bool,
}

pub(crate) enum PreparedSubscribeResult {
    Snapshot {
        state: SessionState,
        rx: broadcast::Receiver<ServerMessage>,
    },
    Replay {
        events: Vec<String>,
        rx: broadcast::Receiver<ServerMessage>,
    },
}

pub(crate) fn plan_session_subscribe(inputs: SessionSubscribeInputs<'_>) -> SessionSubscribePlan {
    let reactivate_passive = should_reactivate_passive_codex_session(
        inputs.provider,
        inputs.status,
        inputs.codex_integration_mode,
        inputs.transcript_path.is_some(),
        inputs.transcript_modified_at_secs,
        parse_unix_z(inputs.last_activity_at),
    );
    let start_lazy_connector = needs_lazy_connector(
        inputs.provider,
        inputs.status,
        inputs.codex_integration_mode,
        inputs.claude_integration_mode,
        inputs.has_codex_connector,
        inputs.has_claude_connector,
    );

    SessionSubscribePlan {
        reactivate_passive,
        start_lazy_connector,
    }
}

pub(crate) async fn request_subscribe(
    actor: &SessionActorHandle,
    since_revision: Option<u64>,
) -> Result<SubscribeResult, String> {
    let (sub_tx, sub_rx) = oneshot::channel();
    actor
        .send(SessionCommand::Subscribe {
            since_revision,
            reply: sub_tx,
        })
        .await;

    sub_rx.await.map_err(|error| error.to_string())
}

pub(crate) async fn prepare_subscribe_result(
    actor: &SessionActorHandle,
    session_id: &str,
    result: SubscribeResult,
) -> PreparedSubscribeResult {
    match result {
        SubscribeResult::Replay { events, rx } => PreparedSubscribeResult::Replay { events, rx },
        SubscribeResult::Snapshot { state, rx } => PreparedSubscribeResult::Snapshot {
            state: hydrate_runtime_subscribe_snapshot(actor, *state, session_id).await,
            rx,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{plan_session_subscribe, SessionSubscribeInputs};
    use orbitdock_protocol::{
        ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus,
    };

    #[test]
    fn subscribe_plan_prefers_reactivation_for_passive_codex_with_new_transcript_activity() {
        let plan = plan_session_subscribe(SessionSubscribeInputs {
            provider: Provider::Codex,
            status: SessionStatus::Ended,
            codex_integration_mode: Some(CodexIntegrationMode::Passive),
            claude_integration_mode: None,
            transcript_path: Some("/tmp/rollout.jsonl"),
            transcript_modified_at_secs: Some(200),
            last_activity_at: Some("100Z"),
            has_codex_connector: false,
            has_claude_connector: false,
        });

        assert!(plan.reactivate_passive);
        assert!(!plan.start_lazy_connector);
    }

    #[test]
    fn subscribe_plan_requests_lazy_connector_for_active_direct_claude_without_runtime() {
        let plan = plan_session_subscribe(SessionSubscribeInputs {
            provider: Provider::Claude,
            status: SessionStatus::Active,
            codex_integration_mode: None,
            claude_integration_mode: Some(ClaudeIntegrationMode::Direct),
            transcript_path: None,
            transcript_modified_at_secs: None,
            last_activity_at: None,
            has_codex_connector: false,
            has_claude_connector: false,
        });

        assert!(!plan.reactivate_passive);
        assert!(plan.start_lazy_connector);
    }

    #[test]
    fn subscribe_plan_stays_plain_for_active_sessions_with_live_connector() {
        let plan = plan_session_subscribe(SessionSubscribeInputs {
            provider: Provider::Codex,
            status: SessionStatus::Active,
            codex_integration_mode: Some(CodexIntegrationMode::Direct),
            claude_integration_mode: None,
            transcript_path: Some("/tmp/rollout.jsonl"),
            transcript_modified_at_secs: Some(200),
            last_activity_at: Some("100Z"),
            has_codex_connector: true,
            has_claude_connector: false,
        });

        assert!(!plan.reactivate_passive);
        assert!(!plan.start_lazy_connector);
    }
}
