//! Provider-side event normalization.
//!
//! This module defines a small provider/domain/action skeleton that provider-
//! specific adapters can map into without forcing the rest of the protocol to
//! understand every SDK or hook vocabulary directly.

use serde::{Deserialize, Serialize};

use crate::Provider;

pub mod claude;
pub mod codex;
pub mod shared;

/// Top-level normalized provider event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedProviderEvent<P> {
    pub provider: Provider,
    pub source: ProviderEventSource,
    pub domain: ProviderEventDomain,
    pub action: ProviderEventAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<ProviderEventStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub correlation: Option<ProviderEventCorrelation>,
    pub payload: P,
}

/// Broad source channel for normalized provider events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderEventSource {
    Hook,
    Rollout,
    SdkMessage,
    SdkControlRequest,
    ResponseItem,
}

/// Domain bucket for routing or downstream interpretation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderEventDomain {
    Session,
    Message,
    Tool,
    Permission,
    Plan,
    Hook,
    Task,
    Subagent,
    RateLimit,
    Auth,
    Files,
    Elicitation,
    Prompt,
    Unknown,
}

/// Coarse action applied within a domain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderEventAction {
    Started,
    Updated,
    Completed,
    Failed,
    Requested,
    Responded,
    Changed,
    Suggested,
    Persisted,
    Emitted,
    Unknown,
}

/// Optional lifecycle/status summary for a normalized event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderEventStatus {
    InProgress,
    Success,
    Failed,
    Cancelled,
    Allowed,
    Denied,
    Compacted,
    Idle,
    Unknown,
}

/// Common correlation identifiers carried across provider events.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderEventCorrelation {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_tool_use_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hook_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elicitation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}
