//! Codex connector
//!
//! Direct integration with codex-core library.
//! No subprocess, no JSON-RPC — just Rust function calls.

pub mod auth;
mod config;
mod event_mapping;
pub mod rollout_parser;
mod runtime;
pub mod session;
mod session_ops;
#[cfg(test)]
mod tests;
mod timeline;
mod workers;

/// Re-export codex-arg0 init for server startup.
/// Must be called before the tokio runtime starts.
pub use codex_arg0::arg0_dispatch;

use codex_core::{CodexThread, ThreadManager};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{Event, EventMsg};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::debug;

pub use self::config::discover_models;
use self::runtime::{EnvironmentTracker, ReasoningEventTracker, StreamingMessage};
use orbitdock_connector_core::ConnectorEvent;

/// Outcome of a steer_turn attempt
pub enum SteerOutcome {
    /// The steer was accepted by the active turn
    Accepted,
    /// No active turn was running; fell back to starting a new turn
    FellBackToNewTurn,
}

/// Codex connector using direct codex-core integration
pub struct CodexConnector {
    thread: Arc<CodexThread>,
    thread_manager: Arc<ThreadManager>,
    codex_home: PathBuf,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
    thread_id: String,
    current_model: Arc<tokio::sync::Mutex<Option<String>>>,
    current_reasoning_effort: Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodexControlPlane {
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodexConfigOverrides {
    pub model_provider: Option<String>,
    pub config_profile: Option<String>,
}

pub struct UpdateConfigOptions<'a> {
    pub approval_policy: Option<&'a str>,
    pub sandbox_mode: Option<&'a str>,
    pub permission_mode: Option<&'a str>,
    pub collaboration_mode: Option<&'a str>,
    pub multi_agent: Option<bool>,
    pub personality: Option<&'a str>,
    pub service_tier: Option<&'a str>,
    pub developer_instructions: Option<&'a str>,
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
}

impl CodexConnector {
    /// Translate a codex-core Event to ConnectorEvent(s)
    #[allow(clippy::too_many_arguments)]
    async fn translate_event(
        event: Event,
        output_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
        msg_counter: &AtomicU64,
        env_tracker: &Arc<tokio::sync::Mutex<EnvironmentTracker>>,
        reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
        current_model: &Arc<tokio::sync::Mutex<Option<String>>>,
        current_reasoning_effort: &Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
        patch_contexts: &Arc<tokio::sync::Mutex<HashMap<String, serde_json::Value>>>,
    ) -> Vec<ConnectorEvent> {
        #[allow(unreachable_patterns)]
        match event.msg {
            EventMsg::UserMessage(e) => {
                event_mapping::messages::handle_user_message(&event.id, e, msg_counter).await
            }

            EventMsg::TurnStarted(_) => {
                event_mapping::lifecycle::handle_turn_started(delta_buffers, reasoning_tracker)
                    .await
            }

            EventMsg::TurnComplete(_) => {
                event_mapping::lifecycle::handle_turn_complete(delta_buffers, reasoning_tracker)
                    .await
            }

            EventMsg::TurnAborted(e) => {
                event_mapping::lifecycle::handle_turn_aborted(e, delta_buffers, reasoning_tracker)
                    .await
            }

            EventMsg::SessionConfigured(e) => {
                event_mapping::lifecycle::handle_session_configured(
                    e,
                    env_tracker,
                    current_model,
                    current_reasoning_effort,
                )
                .await
            }

            EventMsg::AgentMessage(e) => {
                event_mapping::messages::handle_agent_message(&event.id, e, streaming_message).await
            }

            EventMsg::AgentReasoning(e) => {
                event_mapping::messages::handle_agent_reasoning(
                    &event.id,
                    e,
                    reasoning_tracker,
                    msg_counter,
                )
                .await
            }

            EventMsg::GuardianAssessment(e) => {
                event_mapping::guardian::handle_guardian_assessment(e)
            }

            EventMsg::ExecCommandBegin(e) => {
                event_mapping::tools::handle_exec_command_begin(e, output_buffers, env_tracker)
                    .await
            }

            EventMsg::ExecCommandOutputDelta(e) => {
                event_mapping::tools::handle_exec_command_output_delta(e, output_buffers).await
            }

            EventMsg::ExecCommandEnd(e) => {
                event_mapping::tools::handle_exec_command_end(e, output_buffers).await
            }

            EventMsg::PatchApplyBegin(e) => {
                event_mapping::tools::handle_patch_apply_begin(e, patch_contexts).await
            }

            EventMsg::PatchApplyEnd(e) => {
                event_mapping::tools::handle_patch_apply_end(e, patch_contexts).await
            }

            EventMsg::McpToolCallBegin(e) => event_mapping::tools::handle_mcp_tool_call_begin(e),

            EventMsg::McpToolCallEnd(e) => event_mapping::tools::handle_mcp_tool_call_end(e),

            EventMsg::WebSearchBegin(e) => event_mapping::tools::handle_web_search_begin(e),

            EventMsg::WebSearchEnd(e) => event_mapping::tools::handle_web_search_end(e),

            EventMsg::ViewImageToolCall(e) => event_mapping::tools::handle_view_image_tool_call(e),

            EventMsg::DynamicToolCallRequest(e) => {
                event_mapping::tools::handle_dynamic_tool_call_request(e)
            }

            EventMsg::DynamicToolCallResponse(e) => {
                event_mapping::tools::handle_dynamic_tool_call_response(e)
            }

            EventMsg::TerminalInteraction(e) => {
                event_mapping::tools::handle_terminal_interaction(e, output_buffers).await
            }

            EventMsg::CollabAgentSpawnBegin(e) => {
                event_mapping::collab::handle_collab_agent_spawn_begin(e)
            }

            EventMsg::CollabAgentSpawnEnd(e) => {
                event_mapping::collab::handle_collab_agent_spawn_end(e)
            }

            EventMsg::CollabAgentInteractionBegin(e) => {
                event_mapping::collab::handle_collab_agent_interaction_begin(e)
            }

            EventMsg::CollabAgentInteractionEnd(e) => {
                event_mapping::collab::handle_collab_agent_interaction_end(e)
            }

            EventMsg::CollabWaitingBegin(e) => {
                event_mapping::collab::handle_collab_waiting_begin(e)
            }

            EventMsg::CollabWaitingEnd(e) => event_mapping::collab::handle_collab_waiting_end(e),

            EventMsg::CollabCloseBegin(e) => event_mapping::collab::handle_collab_close_begin(e),

            EventMsg::CollabCloseEnd(e) => event_mapping::collab::handle_collab_close_end(e),

            EventMsg::CollabResumeBegin(e) => event_mapping::collab::handle_collab_resume_begin(e),

            EventMsg::CollabResumeEnd(e) => event_mapping::collab::handle_collab_resume_end(e),

            EventMsg::ExecApprovalRequest(e) => {
                event_mapping::approvals::handle_exec_approval_request(e)
            }

            EventMsg::ApplyPatchApprovalRequest(e) => {
                event_mapping::approvals::handle_apply_patch_approval_request(e)
            }

            EventMsg::RequestUserInput(e) => {
                event_mapping::approvals::handle_request_user_input(&event.id, e, msg_counter)
            }

            EventMsg::RequestPermissions(e) => {
                event_mapping::approvals::handle_request_permissions(e)
            }

            EventMsg::ElicitationRequest(e) => {
                event_mapping::approvals::handle_elicitation_request(&event.id, e, msg_counter)
            }

            EventMsg::TokenCount(e) => event_mapping::runtime_signals::handle_token_count(e),

            EventMsg::TurnDiff(e) => event_mapping::runtime_signals::handle_turn_diff(e),

            EventMsg::PlanUpdate(e) => {
                event_mapping::runtime_signals::handle_plan_update(&event.id, e, msg_counter)
            }

            EventMsg::PlanDelta(e) => {
                event_mapping::runtime_signals::handle_plan_delta(delta_buffers, e).await
            }

            EventMsg::Warning(e) => {
                event_mapping::runtime_signals::handle_warning(&event.id, e, msg_counter)
            }

            EventMsg::ModelReroute(e) => {
                event_mapping::runtime_signals::handle_model_reroute(
                    &event.id,
                    e,
                    current_model,
                    msg_counter,
                )
                .await
            }

            // Realtime lifecycle is noisy and not especially useful as transcript content.
            // We keep actual failures visible below, but treat start/close bookkeeping as
            // ephemeral state rather than assistant messages.
            EventMsg::RealtimeConversationStarted(_) => {
                event_mapping::runtime_signals::handle_realtime_conversation_started()
            }

            EventMsg::RealtimeConversationRealtime(e) => {
                event_mapping::runtime_signals::handle_realtime_conversation_realtime(
                    &event.id,
                    e,
                    msg_counter,
                )
            }

            EventMsg::RealtimeConversationClosed(_) => {
                event_mapping::runtime_signals::handle_realtime_conversation_closed()
            }

            EventMsg::DeprecationNotice(e) => {
                event_mapping::runtime_signals::handle_deprecation_notice(&event.id, e, msg_counter)
            }

            EventMsg::BackgroundEvent(e) => {
                event_mapping::runtime_signals::handle_background_event(&event.id, e, msg_counter)
            }

            EventMsg::HookStarted(e) => event_mapping::runtime_signals::handle_hook_started(e),

            EventMsg::HookCompleted(e) => event_mapping::runtime_signals::handle_hook_completed(e),

            EventMsg::ThreadNameUpdated(e) => {
                event_mapping::runtime_signals::handle_thread_name_updated(e)
            }

            EventMsg::ShutdownComplete => {
                event_mapping::runtime_signals::handle_shutdown_complete()
            }

            EventMsg::Error(e) => event_mapping::runtime_signals::handle_error(e.message),

            EventMsg::StreamError(e) => {
                event_mapping::runtime_signals::handle_stream_error(&event.id, e, msg_counter)
            }

            EventMsg::AgentMessageContentDelta(e) => {
                event_mapping::streaming::handle_agent_message_content_delta(e, streaming_message)
                    .await
            }

            // Legacy fallback — older codex-core versions send this instead.
            // Skipped when AgentMessageContentDelta is active (both fire simultaneously).
            EventMsg::AgentMessageDelta(e) => {
                event_mapping::streaming::handle_agent_message_delta(
                    &event.id,
                    e,
                    streaming_message,
                )
                .await
            }

            EventMsg::ReasoningContentDelta(e) => {
                event_mapping::streaming::handle_reasoning_content_delta(
                    delta_buffers,
                    reasoning_tracker,
                    e,
                )
                .await
            }

            EventMsg::ReasoningRawContentDelta(e) => {
                event_mapping::streaming::handle_reasoning_raw_content_delta(
                    delta_buffers,
                    reasoning_tracker,
                    e,
                )
                .await
            }

            EventMsg::AgentReasoningDelta(e) => {
                event_mapping::streaming::handle_agent_reasoning_delta(
                    &event.id,
                    delta_buffers,
                    reasoning_tracker,
                    e,
                )
                .await
            }

            EventMsg::AgentReasoningRawContent(e) => {
                event_mapping::streaming::handle_agent_reasoning_raw_content(
                    &event.id,
                    e,
                    reasoning_tracker,
                    msg_counter,
                )
                .await
            }

            EventMsg::AgentReasoningRawContentDelta(e) => {
                event_mapping::streaming::handle_agent_reasoning_raw_content_delta(
                    &event.id,
                    delta_buffers,
                    reasoning_tracker,
                    e,
                )
                .await
            }

            EventMsg::AgentReasoningSectionBreak(_) => {
                event_mapping::streaming::handle_agent_reasoning_section_break(reasoning_tracker)
                    .await
            }

            EventMsg::EnteredReviewMode(e) => {
                event_mapping::streaming::handle_entered_review_mode(&event.id, e, msg_counter)
            }

            EventMsg::ExitedReviewMode(e) => {
                event_mapping::streaming::handle_exited_review_mode(&event.id, e, msg_counter)
            }

            EventMsg::ItemStarted(e) => {
                event_mapping::streaming::handle_item_started(delta_buffers, e).await
            }

            EventMsg::ItemCompleted(e) => {
                event_mapping::streaming::handle_item_completed(delta_buffers, e).await
            }

            EventMsg::RawResponseItem(e) => {
                event_mapping::streaming::handle_raw_response_item(&event.id, e, msg_counter)
            }

            EventMsg::ListSkillsResponse(e) => {
                event_mapping::capabilities::handle_list_skills_response(e)
            }

            EventMsg::ListCustomPromptsResponse(e) => {
                event_mapping::capabilities::handle_list_custom_prompts_response(
                    &event.id,
                    e,
                    msg_counter,
                )
            }

            EventMsg::GetHistoryEntryResponse(e) => {
                event_mapping::capabilities::handle_get_history_entry_response(
                    &event.id,
                    e,
                    msg_counter,
                )
            }

            EventMsg::ContextCompacted(_) => {
                event_mapping::runtime_signals::handle_context_compacted()
            }

            EventMsg::UndoStarted(e) => event_mapping::runtime_signals::handle_undo_started(e),

            EventMsg::UndoCompleted(e) => event_mapping::runtime_signals::handle_undo_completed(e),

            EventMsg::ThreadRolledBack(e) => {
                event_mapping::runtime_signals::handle_thread_rolled_back(e)
            }

            EventMsg::SkillsUpdateAvailable => {
                event_mapping::runtime_signals::handle_skills_update_available()
            }

            EventMsg::McpListToolsResponse(e) => {
                event_mapping::capabilities::handle_mcp_list_tools_response(e)
            }

            EventMsg::McpStartupUpdate(e) => {
                event_mapping::capabilities::handle_mcp_startup_update(e)
            }

            EventMsg::McpStartupComplete(e) => {
                event_mapping::capabilities::handle_mcp_startup_complete(e)
            }

            // Log but ignore other events
            other => {
                let name = format!("{:?}", other);
                let variant = name.split('(').next().unwrap_or(&name);
                debug!("Unhandled codex event: {}", variant);
                vec![]
            }
        }
    }

    /// Get the event receiver (can only be called once)
    pub fn take_event_rx(&mut self) -> Option<mpsc::Receiver<ConnectorEvent>> {
        self.event_rx.take()
    }

    /// Get the codex-core thread ID (used to link with rollout files)
    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    /// Get the codex home directory path
    pub fn codex_home(&self) -> &std::path::Path {
        &self.codex_home
    }

    /// Find the rollout file path for this connector's thread
    pub async fn rollout_path(&self) -> Option<String> {
        codex_core::find_thread_path_by_id_str(&self.codex_home, &self.thread_id)
            .await
            .ok()
            .flatten()
            .map(|p| p.to_string_lossy().to_string())
    }
}
