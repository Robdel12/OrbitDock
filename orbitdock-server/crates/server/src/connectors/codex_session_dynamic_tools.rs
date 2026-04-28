use std::sync::Arc;

use crate::domain::mission_control::executor::MissionToolResult;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_mutations::end_session;
use crate::runtime::session_registry::SessionRegistry;
use tokio::sync::mpsc;
use tracing::warn;

use super::load_mission_tool_execution_context;

#[derive(Debug, Clone)]
pub(super) enum DynamicToolPostResponseEffects {
  None,
  Mission(DynamicToolMissionPostResponseEffects),
}

#[derive(Debug, Clone)]
pub(super) struct DynamicToolMissionPostResponseEffects {
  pub blocked: bool,
  pub completed_state: Option<String>,
  pub pr_url: Option<String>,
}

#[derive(Debug, Clone)]
pub(super) struct DynamicToolExecutionResult {
  pub success: bool,
  pub output: String,
  pub post_response_effects: DynamicToolPostResponseEffects,
}

impl DynamicToolExecutionResult {
  pub(super) fn workspace(success: bool, output: String) -> Self {
    Self {
      success,
      output,
      post_response_effects: DynamicToolPostResponseEffects::None,
    }
  }

  pub(super) fn mission(result: MissionToolResult) -> Self {
    Self {
      success: result.success,
      output: result.output,
      post_response_effects: DynamicToolPostResponseEffects::Mission(
        DynamicToolMissionPostResponseEffects {
          blocked: result.blocked,
          completed_state: result.completed_state,
          pr_url: result.pr_url,
        },
      ),
    }
  }

  pub(super) fn failure_json(message: String) -> Self {
    Self::workspace(false, serde_json::json!({ "error": message }).to_string())
  }
}

pub(super) async fn apply_dynamic_tool_post_response_effects(
  session_handle: &SessionHandle,
  state: &Arc<SessionRegistry>,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  call_id: &str,
  tool_name: &str,
  output: &str,
  post_response_effects: DynamicToolPostResponseEffects,
) {
  let DynamicToolPostResponseEffects::Mission(mission_effects) = post_response_effects else {
    return;
  };

  let mission_context = match load_mission_tool_execution_context(session_handle, state).await {
    Ok(Some(context)) => context,
    Ok(None) => return,
    Err(error) => {
      warn!(
          component = "codex_connector",
          event = "codex.dynamic_tool.side_effect_context_failed",
          session_id = %session_id,
          call_id = %call_id,
          tool_name = %tool_name,
          error = %error,
          "Failed to load mission context for dynamic tool side effects"
      );
      return;
    }
  };

  if let Some(pr_url) = mission_effects.pr_url {
    let _ = persist_tx
      .send(PersistCommand::MissionIssueSetPrUrl {
        mission_id: mission_context.context.mission_id.clone(),
        issue_id: mission_context.context.issue_id.clone(),
        pr_url,
      })
      .await;
    state.publish_mission_invalidation(&mission_context.context.mission_id);
  }

  if mission_effects.blocked {
    let now = chrono::Utc::now().to_rfc3339();
    let _ = persist_tx
      .send(PersistCommand::MissionIssueUpdateState {
        mission_id: mission_context.context.mission_id.clone(),
        issue_id: mission_context.context.issue_id.clone(),
        orchestration_state: "blocked".to_string(),
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(Some(output.to_string())),
        retry_due_at: None,
        started_at: None,
        completed_at: Some(Some(now)),
      })
      .await;
    state.publish_mission_invalidation(&mission_context.context.mission_id);
  }

  if mission_effects.completed_state.is_some() {
    let now = chrono::Utc::now().to_rfc3339();
    let _ = persist_tx
      .send(PersistCommand::MissionIssueUpdateState {
        mission_id: mission_context.context.mission_id.clone(),
        issue_id: mission_context.context.issue_id.clone(),
        orchestration_state: "completed".to_string(),
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(None),
        retry_due_at: Some(None),
        started_at: None,
        completed_at: Some(Some(now)),
      })
      .await;

    end_session(state, session_id).await;
    state.publish_mission_invalidation(&mission_context.context.mission_id);
  }
}
