use std::sync::Arc;

use orbitdock_protocol::domain_events::AgentType;
use orbitdock_protocol::Provider;

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_paths::claude_transcript_path_from_cwd;

use super::routing::{
  cleanup_claude_shadow_session, resolve_claude_hook_routing, ClaudeHookRoutingDecision,
};
use super::subagent_updates::{publish_claude_subagent_update, ClaudeSubagentUpdate};

pub(crate) async fn handle_claude_subagent_event(
  state: &Arc<SessionRegistry>,
  session_id: String,
  hook_event_name: String,
  agent_id: String,
  agent_type: Option<String>,
  agent_transcript_path: Option<String>,
) {
  match resolve_claude_hook_routing(state, &session_id).await {
    ClaudeHookRoutingDecision::ManagedDirect { owner_session_id } => {
      cleanup_claude_shadow_session(state, &session_id, "managed_direct_session").await;
      let persist_tx = state.persist().clone();

      match hook_event_name.as_str() {
        "SubagentStart" => {
          let raw_type = agent_type.as_deref().unwrap_or("unknown");
          let normalized_type = AgentType::from_str_normalized(raw_type);
          let _ = persist_tx
            .send(PersistCommand::ClaudeSubagentStart {
              id: agent_id.clone(),
              session_id: owner_session_id.clone(),
              agent_type: normalized_type.clone(),
            })
            .await;
          publish_claude_subagent_update(
            state,
            &owner_session_id,
            ClaudeSubagentUpdate::Started {
              agent_id: agent_id.clone(),
              agent_type: normalized_type.clone(),
            },
          )
          .await;
          let _ = persist_tx
            .send(PersistCommand::ClaudeSessionUpdate {
              id: owner_session_id,
              work_status: None,
              attention_reason: None,
              last_tool: None,
              last_tool_at: None,
              pending_tool_name: None,
              pending_tool_input: None,
              pending_question: None,
              source: None,
              agent_type: None,
              permission_mode: None,
              active_subagent_id: Some(Some(agent_id)),
              active_subagent_type: Some(Some(normalized_type)),
              first_prompt: None,
              compact_count_increment: false,
            })
            .await;
        }
        "SubagentStop" => {
          let subagent_id = agent_id.clone();
          let _ = persist_tx
            .send(PersistCommand::ClaudeSubagentEnd {
              id: subagent_id.clone(),
              transcript_path: agent_transcript_path,
            })
            .await;
          publish_claude_subagent_update(
            state,
            &owner_session_id,
            ClaudeSubagentUpdate::Stopped {
              agent_id: subagent_id,
            },
          )
          .await;
          let _ = persist_tx
            .send(PersistCommand::ClaudeSessionUpdate {
              id: owner_session_id,
              work_status: None,
              attention_reason: None,
              last_tool: None,
              last_tool_at: None,
              pending_tool_name: None,
              pending_tool_input: None,
              pending_question: None,
              source: None,
              agent_type: None,
              permission_mode: None,
              active_subagent_id: Some(None),
              active_subagent_type: Some(None),
              first_prompt: None,
              compact_count_increment: false,
            })
            .await;
        }
        _ => {}
      }
      return;
    }
    ClaudeHookRoutingDecision::IgnoreShadowedByDirect => {
      cleanup_claude_shadow_session(state, &session_id, "direct_owner_exists").await;
      return;
    }
    ClaudeHookRoutingDecision::IgnoreOwnershipLookupFailed => {
      return;
    }
    ClaudeHookRoutingDecision::Passive => {}
  }

  let persist_tx = state.persist().clone();

  if state.get_session(&session_id).is_none() {
    if let Some(pending_cwd) = state.peek_pending_hook_cwd(Provider::Claude, &session_id) {
      let git_info = crate::domain::git::repo::resolve_git_info(&pending_cwd).await;
      let derived_tp = claude_transcript_path_from_cwd(&pending_cwd, &session_id);
      super::session_materialization::materialize_claude_session(
        &session_id,
        &pending_cwd,
        derived_tp,
        git_info.as_ref(),
        state,
        &persist_tx,
      )
      .await;
    }
  }

  if let Some(existing) = state.get_session(&session_id) {
    if existing.snapshot().provider == Provider::Codex {
      return;
    }
  }

  match hook_event_name.as_str() {
    "SubagentStart" => {
      let raw_type = agent_type.as_deref().unwrap_or("unknown");
      let normalized_type = AgentType::from_str_normalized(raw_type);
      let _ = persist_tx
        .send(PersistCommand::ClaudeSubagentStart {
          id: agent_id.clone(),
          session_id: session_id.clone(),
          agent_type: normalized_type.clone(),
        })
        .await;
      publish_claude_subagent_update(
        state,
        &session_id,
        ClaudeSubagentUpdate::Started {
          agent_id: agent_id.clone(),
          agent_type: normalized_type.clone(),
        },
      )
      .await;
    }
    "SubagentStop" => {
      let subagent_id = agent_id.clone();
      let _ = persist_tx
        .send(PersistCommand::ClaudeSubagentEnd {
          id: subagent_id.clone(),
          transcript_path: agent_transcript_path,
        })
        .await;
      publish_claude_subagent_update(
        state,
        &session_id,
        ClaudeSubagentUpdate::Stopped {
          agent_id: subagent_id,
        },
      )
      .await;
    }
    _ => {}
  }
}
