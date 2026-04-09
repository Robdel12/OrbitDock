use std::sync::Arc;

use orbitdock_protocol::domain_events::AgentType;
use orbitdock_protocol::{Provider, SubagentInfo, SubagentStatus};

use crate::domain::sessions::transition::Input;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_time::chrono_now;

pub enum ClaudeSubagentUpdate {
  Started {
    agent_id: String,
    agent_type: AgentType,
  },
  Stopped {
    agent_id: String,
  },
}

pub async fn publish_claude_subagent_update(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  update: ClaudeSubagentUpdate,
) {
  let Some(actor) = state.get_session(session_id) else {
    return;
  };

  let current_subagents = actor
    .retained_state()
    .await
    .map(|session| session.subagents)
    .unwrap_or_default();

  let updated_subagents = apply_claude_subagent_update(current_subagents, update);
  actor
    .send(SessionCommand::ProcessEvent {
      event: Input::SubagentsUpdated {
        subagents: updated_subagents,
      },
    })
    .await;
}

pub fn apply_claude_subagent_update(
  subagents: Vec<SubagentInfo>,
  update: ClaudeSubagentUpdate,
) -> Vec<SubagentInfo> {
  let now = chrono_now();

  match update {
    ClaudeSubagentUpdate::Started {
      agent_id,
      agent_type,
    } => {
      let mut updated = false;
      let mut next_subagents: Vec<SubagentInfo> = subagents
        .into_iter()
        .map(|mut subagent| {
          if subagent.id == agent_id {
            subagent.agent_type = agent_type.clone();
            subagent.provider = Some(Provider::Claude);
            subagent.status = SubagentStatus::Running;
            subagent.ended_at = None;
            subagent.last_activity_at = Some(now.clone());
            updated = true;
          }
          subagent
        })
        .collect();

      if !updated {
        next_subagents.push(SubagentInfo {
          id: agent_id,
          agent_type,
          started_at: now.clone(),
          ended_at: None,
          provider: Some(Provider::Claude),
          label: None,
          status: SubagentStatus::Running,
          task_summary: None,
          result_summary: None,
          error_summary: None,
          parent_subagent_id: None,
          model: None,
          last_activity_at: Some(now),
        });
      }

      next_subagents
    }
    ClaudeSubagentUpdate::Stopped { agent_id } => {
      let mut updated = false;
      let mut next_subagents: Vec<SubagentInfo> = subagents
        .into_iter()
        .map(|mut subagent| {
          if subagent.id == agent_id {
            subagent.provider = Some(Provider::Claude);
            subagent.status = SubagentStatus::Completed;
            subagent.ended_at = Some(now.clone());
            subagent.last_activity_at = Some(now.clone());
            updated = true;
          }
          subagent
        })
        .collect();

      if !updated {
        next_subagents.push(SubagentInfo {
          id: agent_id,
          agent_type: AgentType::BackgroundTask,
          started_at: now.clone(),
          ended_at: Some(now.clone()),
          provider: Some(Provider::Claude),
          label: None,
          status: SubagentStatus::Completed,
          task_summary: None,
          result_summary: None,
          error_summary: None,
          parent_subagent_id: None,
          model: None,
          last_activity_at: Some(now),
        });
      }

      next_subagents
    }
  }
}
