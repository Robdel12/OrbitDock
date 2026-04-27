//! HTTP hook handler for Claude Code hooks.
//!
//! Replaces the Swift CLI — hooks now POST JSON directly to the Rust server.
//! The 5 Claude hook message types are handled here, grouped behind the
//! Claude hook transport module instead of the WebSocket transport layer.
//!
//! **Deferred session creation:** `ClaudeSessionStart` no longer creates a DB row
//! or broadcasts `SessionCreated`. Instead it caches metadata in memory. The session
//! is only materialized when the first actionable hook (status/tool/subagent) arrives.
//! If `SessionEnd` arrives first the pending entry is silently discarded, preventing
//! ghost sessions from `claude -c` bootstrap processes.

use std::sync::Arc;
use tracing::warn;

#[path = "routing.rs"]
mod routing;
#[path = "session_end.rs"]
mod session_end;
#[path = "session_start.rs"]
mod session_start;
#[path = "status_events.rs"]
mod status_events;
#[path = "subagent_events.rs"]
mod subagent_events;
#[path = "subagent_updates.rs"]
mod subagent_updates;
#[path = "tool_events.rs"]
mod tool_events;
#[path = "transcript_sync.rs"]
mod transcript_sync;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_registry::SessionRegistry;

use self::routing::ClaudeHookHandlingOptions;
use self::session_end::handle_claude_session_end;
use self::session_start::{handle_claude_session_start, ClaudeSessionStartEvent};
use self::status_events::handle_claude_status_event;
use self::subagent_events::handle_claude_subagent_event;
use self::tool_events::{handle_claude_tool_event, ClaudeToolEventPayload};
pub(super) use super::approval;
pub(super) use super::session_materialization;

/// Process a Claude hook message.
/// These handlers never need `client_tx` or `conn_id` — only `state`.
pub async fn handle_hook_message(msg: ClientMessage, state: &Arc<SessionRegistry>) {
  handle_hook_message_with_options(msg, state, ClaudeHookHandlingOptions::default()).await;
}

pub async fn handle_hook_message_with_options(
  msg: ClientMessage,
  state: &Arc<SessionRegistry>,
  options: ClaudeHookHandlingOptions,
) {
  match msg {
    ClientMessage::ClaudeSessionStart {
      session_id,
      cwd,
      model,
      source,
      context_label,
      transcript_path,
      permission_mode,
      agent_type,
      terminal_session_id,
      terminal_app,
    } => {
      handle_claude_session_start(
        state,
        ClaudeSessionStartEvent {
          session_id,
          cwd,
          model,
          source,
          context_label,
          transcript_path,
          permission_mode,
          agent_type,
          terminal_session_id,
          terminal_app,
        },
      )
      .await;
    }

    ClientMessage::ClaudeSessionEnd { session_id, reason } => {
      handle_claude_session_end(state, session_id, reason).await;
    }

    ClientMessage::ClaudeStatusEvent {
      session_id,
      cwd,
      transcript_path,
      hook_event_name,
      notification_type,
      tool_name,
      stop_hook_active: _,
      prompt,
      message: _,
      title: _,
      trigger: _,
      custom_instructions: _,
      permission_mode,
      last_assistant_message: _,
      teammate_name: _,
      team_name: _,
      task_id: _,
      task_subject: _,
      task_description: _,
      config_source: _,
      config_file_path: _,
    } => {
      handle_claude_status_event(
        state,
        &options,
        session_id,
        cwd,
        transcript_path,
        hook_event_name,
        notification_type,
        tool_name,
        prompt,
        permission_mode,
      )
      .await;
    }

    ClientMessage::ClaudeToolEvent {
      session_id,
      cwd,
      hook_event_name,
      tool_name,
      tool_input,
      tool_response: _,
      tool_use_id,
      permission_suggestions,
      error: _,
      is_interrupt,
      permission_mode,
    } => {
      handle_claude_tool_event(
        state,
        &options,
        ClaudeToolEventPayload {
          session_id,
          cwd,
          hook_event_name,
          tool_name,
          tool_input,
          tool_use_id,
          permission_suggestions,
          is_interrupt,
          permission_mode,
        },
      )
      .await;
    }

    ClientMessage::ClaudeSubagentEvent {
      session_id,
      hook_event_name,
      agent_id,
      agent_type,
      agent_transcript_path,
      stop_hook_active: _,
      last_assistant_message: _,
    } => {
      handle_claude_subagent_event(
        state,
        session_id,
        hook_event_name,
        agent_id,
        agent_type,
        agent_transcript_path,
      )
      .await;
    }

    _ => {
      warn!(
        component = "hook_handler",
        event = "hook_handler.unexpected_message",
        "Received non-hook message type in hook handler"
      );
    }
  }
}

#[cfg(test)]
#[path = "handler_tests.rs"]
mod tests;
