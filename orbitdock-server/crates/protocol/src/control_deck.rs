use serde::{Deserialize, Serialize};

use crate::{
  CodexApprovalPolicy, CodexConfigMode, Provider, SessionControlMode, SessionLifecycleState,
  TokenUsage, TokenUsageSnapshotKind,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlDeckDensity {
  Comfortable,
  Compact,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlDeckEmptyVisibility {
  Auto,
  Always,
  Hidden,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlDeckModule {
  Connection,
  Autonomy,
  ApprovalMode,
  CollaborationMode,
  AutoReview,
  Tokens,
  Model,
  Effort,
  Branch,
  Cwd,
  Attachments,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckModulePreference {
  pub module: ControlDeckModule,
  pub visible: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckPreferences {
  pub density: ControlDeckDensity,
  pub show_when_empty: ControlDeckEmptyVisibility,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub modules: Vec<ControlDeckModulePreference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckConfigState {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub permission_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub collaboration_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub developer_instructions: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub codex_config_mode: Option<CodexConfigMode>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub codex_config_profile: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub codex_model_provider: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckState {
  pub provider: Provider,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub accepts_user_input: bool,
  pub steerable: bool,
  pub project_path: String,
  #[serde(default)]
  pub current_cwd: Option<String>,
  #[serde(default)]
  pub git_branch: Option<String>,
  pub config: ControlDeckConfigState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckPickerOption {
  pub value: String,
  pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckAutoReviewOption {
  pub value: String,
  pub label: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckCapabilities {
  pub supports_skills: bool,
  pub supports_mentions: bool,
  pub supports_images: bool,
  pub supports_steer: bool,
  pub allow_per_turn_model_override: bool,
  pub allow_per_turn_effort_override: bool,
  #[serde(default)]
  pub approval_mode_options: Vec<ControlDeckPickerOption>,
  #[serde(default)]
  pub permission_mode_options: Vec<ControlDeckPickerOption>,
  #[serde(default)]
  pub collaboration_mode_options: Vec<ControlDeckPickerOption>,
  #[serde(default)]
  pub auto_review_options: Vec<ControlDeckAutoReviewOption>,
  #[serde(default)]
  pub available_status_modules: Vec<ControlDeckModule>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlDeckTokenStatusTone {
  Muted,
  Normal,
  Caution,
  Critical,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckTokenStatus {
  pub label: String,
  pub tone: ControlDeckTokenStatusTone,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlDeckSnapshot {
  pub revision: u64,
  pub session_id: String,
  pub state: ControlDeckState,
  pub capabilities: ControlDeckCapabilities,
  pub preferences: ControlDeckPreferences,
  pub token_usage: TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub token_status: ControlDeckTokenStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ControlDeckConfigUpdate {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub permission_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub collaboration_mode: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ControlDeckMentionKind {
  File,
  McpResource,
  Url,
  Symbol,
  Generic,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckMentionRef {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub mention_id: Option<String>,
  pub kind: ControlDeckMentionKind,
  pub name: String,
  pub path: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub relative_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckImageAttachmentRef {
  pub attachment_id: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub display_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ControlDeckAttachmentRef {
  Mention(ControlDeckMentionRef),
  Image(ControlDeckImageAttachmentRef),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckSkillRef {
  pub name: String,
  pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ControlDeckTurnOverrides {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlDeckSubmitTurnRequest {
  pub text: String,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub attachments: Vec<ControlDeckAttachmentRef>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub skills: Vec<ControlDeckSkillRef>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub overrides: Option<ControlDeckTurnOverrides>,
}
