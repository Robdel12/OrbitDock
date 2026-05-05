use codex_app_server_protocol::{ServerNotification, ServerRequest};
use orbitdock_connector_core::ConnectorOutput;

use super::AppServerSessionRoute;

pub(super) fn notification_thread_id(notification: &ServerNotification) -> Option<String> {
  Some(match notification {
    ServerNotification::ThreadStarted(event) => event.thread.id.clone(),
    ServerNotification::ThreadStatusChanged(event) => event.thread_id.clone(),
    ServerNotification::ThreadArchived(event) => event.thread_id.clone(),
    ServerNotification::ThreadUnarchived(event) => event.thread_id.clone(),
    ServerNotification::ThreadClosed(event) => event.thread_id.clone(),
    ServerNotification::ThreadNameUpdated(event) => event.thread_id.clone(),
    ServerNotification::ThreadTokenUsageUpdated(event) => event.thread_id.clone(),
    ServerNotification::TurnStarted(event) => event.thread_id.clone(),
    ServerNotification::HookStarted(event) => event.thread_id.clone(),
    ServerNotification::TurnCompleted(event) => event.thread_id.clone(),
    ServerNotification::HookCompleted(event) => event.thread_id.clone(),
    ServerNotification::TurnDiffUpdated(event) => event.thread_id.clone(),
    ServerNotification::TurnPlanUpdated(event) => event.thread_id.clone(),
    ServerNotification::ItemStarted(event) => event.thread_id.clone(),
    ServerNotification::ItemGuardianApprovalReviewStarted(event) => event.thread_id.clone(),
    ServerNotification::ItemGuardianApprovalReviewCompleted(event) => event.thread_id.clone(),
    ServerNotification::ItemCompleted(event) => event.thread_id.clone(),
    ServerNotification::AgentMessageDelta(event) => event.thread_id.clone(),
    ServerNotification::PlanDelta(event) => event.thread_id.clone(),
    ServerNotification::ReasoningSummaryTextDelta(event) => event.thread_id.clone(),
    ServerNotification::ReasoningSummaryPartAdded(event) => event.thread_id.clone(),
    ServerNotification::ReasoningTextDelta(event) => event.thread_id.clone(),
    ServerNotification::CommandExecutionOutputDelta(event) => event.thread_id.clone(),
    ServerNotification::TerminalInteraction(event) => event.thread_id.clone(),
    ServerNotification::FileChangeOutputDelta(event) => event.thread_id.clone(),
    ServerNotification::ServerRequestResolved(event) => event.thread_id.clone(),
    ServerNotification::McpToolCallProgress(event) => event.thread_id.clone(),
    ServerNotification::Error(event) => event.thread_id.clone(),
    ServerNotification::ContextCompacted(event) => event.thread_id.clone(),
    ServerNotification::ModelRerouted(event) => event.thread_id.clone(),
    ServerNotification::Warning(event) => return event.thread_id.clone(),
    _ => return None,
  })
}

pub(super) fn request_thread_id(request: &ServerRequest) -> Option<String> {
  Some(match request {
    ServerRequest::CommandExecutionRequestApproval { params, .. } => params.thread_id.clone(),
    ServerRequest::FileChangeRequestApproval { params, .. } => params.thread_id.clone(),
    ServerRequest::ToolRequestUserInput { params, .. } => params.thread_id.clone(),
    ServerRequest::McpServerElicitationRequest { params, .. } => params.thread_id.clone(),
    ServerRequest::PermissionsRequestApproval { params, .. } => params.thread_id.clone(),
    ServerRequest::DynamicToolCall { params, .. } => params.thread_id.clone(),
    _ => return None,
  })
}

pub(super) async fn send_outputs(route: &AppServerSessionRoute, outputs: Vec<ConnectorOutput>) {
  for output in outputs {
    if route.forward_tx.send(output).is_err() {
      tracing::debug!("Typed codex app-server output channel closed");
      return;
    }
  }
}
