use std::sync::Arc;

use tokio::sync::oneshot;

use crate::connectors::claude_session::{
  ClaudeAction, ClaudeAllowToolApproval, ClaudeAllowToolApprovalScope, ClaudeDenyToolApproval,
  ClaudeToolApprovalResponse,
};
use crate::connectors::codex_session::{CodexAction, CodexExecApproval, CodexPatchApproval};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::normalization::work_status_for_approval_decision;
use codex_protocol::approvals::{NetworkPolicyAmendment, NetworkPolicyRuleAction};
use orbitdock_protocol::{ApprovalType, ToolApprovalDecision};

pub(crate) struct ApprovalDispatchResult {
  pub outcome: String,
  pub active_request_id: Option<String>,
  pub approval_version: u64,
}

enum ProviderApprovalAction {
  Codex(Box<CodexAction>),
  Claude(Box<ClaudeAction>),
}

fn claude_allow_response(
  scope: ClaudeAllowToolApprovalScope,
  updated_input: Option<serde_json::Value>,
) -> ClaudeToolApprovalResponse {
  ClaudeToolApprovalResponse::Allow(ClaudeAllowToolApproval {
    scope,
    updated_input,
  })
}

fn claude_deny_response(
  message: Option<String>,
  interrupt: Option<bool>,
) -> ClaudeToolApprovalResponse {
  ClaudeToolApprovalResponse::Deny(ClaudeDenyToolApproval {
    message,
    interrupt: interrupt.unwrap_or(false),
  })
}

struct ProviderApprovalContext {
  approval_type: Option<ApprovalType>,
  request_id: String,
  decision: ToolApprovalDecision,
  message: Option<String>,
  interrupt: Option<bool>,
  updated_input: Option<serde_json::Value>,
  proposed_amendment: Option<Vec<String>>,
  is_codex: bool,
}

fn provider_approval_action(
  context: ProviderApprovalContext,
) -> Result<ProviderApprovalAction, &'static str> {
  let ProviderApprovalContext {
    approval_type,
    request_id,
    decision,
    message,
    interrupt,
    updated_input,
    proposed_amendment,
    is_codex,
  } = context;

  if is_codex {
    let network_policy_amendment = parse_network_policy_amendment(updated_input.as_ref())?;
    let action = match approval_type {
      Some(ApprovalType::Patch) => CodexAction::ApprovePatch {
        request_id,
        decision: match decision {
          ToolApprovalDecision::Approved => CodexPatchApproval::Approved,
          ToolApprovalDecision::ApprovedForSession => CodexPatchApproval::ApprovedForSession,
          ToolApprovalDecision::Denied => CodexPatchApproval::Denied,
          ToolApprovalDecision::Abort => CodexPatchApproval::Abort,
          ToolApprovalDecision::ApprovedAlways => {
            return Err("invalid_patch_approval_decision");
          }
        },
      },
      Some(ApprovalType::Permissions) => return Err("invalid_permissions_dispatch"),
      _ => CodexAction::ApproveExec {
        request_id,
        decision: match decision {
          ToolApprovalDecision::Approved => CodexExecApproval::Approved,
          ToolApprovalDecision::ApprovedForSession => CodexExecApproval::ApprovedForSession,
          ToolApprovalDecision::ApprovedAlways => match network_policy_amendment {
            Some(network_policy_amendment) => CodexExecApproval::NetworkPolicyAmendment {
              network_policy_amendment,
            },
            None => CodexExecApproval::ApprovedAlways { proposed_amendment },
          },
          ToolApprovalDecision::Denied => CodexExecApproval::Denied,
          ToolApprovalDecision::Abort => CodexExecApproval::Abort,
        },
      },
    };
    return Ok(ProviderApprovalAction::Codex(Box::new(action)));
  }

  let response = match decision {
    ToolApprovalDecision::Approved => {
      claude_allow_response(ClaudeAllowToolApprovalScope::Once, updated_input)
    }
    ToolApprovalDecision::ApprovedForSession => {
      claude_allow_response(ClaudeAllowToolApprovalScope::Session, updated_input)
    }
    ToolApprovalDecision::ApprovedAlways => {
      claude_allow_response(ClaudeAllowToolApprovalScope::Always, updated_input)
    }
    ToolApprovalDecision::Denied => claude_deny_response(message, interrupt),
    ToolApprovalDecision::Abort => ClaudeToolApprovalResponse::Deny(ClaudeDenyToolApproval {
      message,
      interrupt: interrupt.unwrap_or(true),
    }),
  };

  Ok(ProviderApprovalAction::Claude(Box::new(
    ClaudeAction::ApproveTool {
      request_id,
      response,
    },
  )))
}

fn parse_network_policy_amendment(
  updated_input: Option<&serde_json::Value>,
) -> Result<Option<NetworkPolicyAmendment>, &'static str> {
  let Some(updated_input) = updated_input else {
    return Ok(None);
  };

  let candidate = updated_input
    .get("network_policy_amendment")
    .unwrap_or(updated_input);
  let Some(host) = candidate
    .get("host")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|value| !value.is_empty())
  else {
    return Ok(None);
  };

  let Some(action_raw) = candidate
    .get("action")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|value| !value.is_empty())
  else {
    return Ok(None);
  };

  let action = match action_raw {
    "allow" => NetworkPolicyRuleAction::Allow,
    "deny" => NetworkPolicyRuleAction::Deny,
    _ => return Err("invalid_network_policy_action"),
  };

  Ok(Some(NetworkPolicyAmendment {
    host: host.to_string(),
    action,
  }))
}

pub(crate) async fn dispatch_approve_tool(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  request_id: String,
  decision: ToolApprovalDecision,
  message: Option<String>,
  interrupt: Option<bool>,
  updated_input: Option<serde_json::Value>,
) -> Result<ApprovalDispatchResult, &'static str> {
  let fallback_work_status = work_status_for_approval_decision(decision.as_str());

  let (approval_type, proposed_amendment, next_pending_request_id, approval_version) =
    if let Some(actor) = state.get_session(session_id) {
      let (reply_tx, reply_rx) = oneshot::channel();
      actor
        .send(SessionCommand::ResolvePendingApproval {
          request_id: request_id.clone(),
          fallback_work_status,
          reply: reply_tx,
        })
        .await;
      if let Ok(resolution) = reply_rx.await {
        (
          resolution.approval_type,
          resolution.proposed_amendment,
          resolution.next_pending_approval.map(|approval| approval.id),
          resolution.approval_version,
        )
      } else {
        (None, None, None, 0)
      }
    } else {
      return Err("not_found");
    };

  if state.get_session(session_id).is_some() && approval_type.is_none() {
    return Ok(ApprovalDispatchResult {
      outcome: "stale".to_string(),
      active_request_id: next_pending_request_id,
      approval_version,
    });
  }

  let _ = state
    .persist()
    .send(PersistCommand::ApprovalDecision {
      session_id: session_id.to_string(),
      request_id: request_id.clone(),
      decision: decision.to_string(),
    })
    .await;

  let codex_tx = state.get_codex_action_tx(session_id);
  let claude_tx = state.get_claude_action_tx(session_id);
  let is_codex = codex_tx.is_some();
  let action = provider_approval_action(ProviderApprovalContext {
    approval_type,
    request_id,
    decision,
    message,
    interrupt,
    updated_input,
    proposed_amendment,
    is_codex,
  })?;

  match action {
    ProviderApprovalAction::Codex(action) => {
      if let Some(tx) = codex_tx {
        let _ = tx.send(*action).await;
      }
    }
    ProviderApprovalAction::Claude(action) => {
      if let Some(tx) = claude_tx {
        let _ = tx.send(*action).await;
      }
    }
  }

  Ok(ApprovalDispatchResult {
    outcome: "applied".to_string(),
    active_request_id: next_pending_request_id,
    approval_version,
  })
}

#[cfg(test)]
#[path = "approval_dispatch_tests.rs"]
mod approval_dispatch_tests;
