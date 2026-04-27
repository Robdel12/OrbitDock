//! Client → Server messages

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::types::{
  CodexApprovalPolicy, CodexApprovalsReviewer, CodexSandboxPolicy, ImageInput, MentionInput,
  PermissionGrantScope, SkillInput, ToolApprovalDecision,
};

/// Messages sent from client to server
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
  // Subscriptions
  SubscribeSessionsSummary {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    since_revision: Option<u64>,
  },
  UnsubscribeSessionsSummary,
  SubscribeActiveSessions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    since_revision: Option<u64>,
  },
  UnsubscribeActiveSessions,
  SubscribeArchivedSessions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    since_revision: Option<u64>,
  },
  UnsubscribeArchivedSessions,
  SubscribeMissions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    since_revision: Option<u64>,
  },
  UnsubscribeMissions,
  SubscribeMission {
    mission_id: String,
  },
  UnsubscribeMission {
    mission_id: String,
  },
  SubscribeSessionSurface {
    session_id: String,
    surface: crate::types::SessionSurface,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    since_revision: Option<u64>,
  },
  UnsubscribeSessionSurface {
    session_id: String,
    surface: crate::types::SessionSurface,
  },

  // Actions
  SendMessage {
    session_id: String,
    content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    effort: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    skills: Vec<SkillInput>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    images: Vec<ImageInput>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    mentions: Vec<MentionInput>,
  },
  ApproveTool {
    session_id: String,
    request_id: String,
    decision: ToolApprovalDecision,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    interrupt: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    updated_input: Option<Value>,
  },
  AnswerQuestion {
    session_id: String,
    request_id: String,
    answer: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    question_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    answers: Option<HashMap<String, Vec<String>>>,
  },
  RespondToPermissionRequest {
    session_id: String,
    request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    permissions: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    scope: Option<PermissionGrantScope>,
  },
  InterruptSession {
    session_id: String,
  },
  EndSession {
    session_id: String,
  },

  // Session config
  UpdateSessionConfig {
    session_id: String,
    approval_policy: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval_policy_details: Option<CodexApprovalPolicy>,
    sandbox_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sandbox_policy_details: Option<CodexSandboxPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approvals_reviewer: Option<CodexApprovalsReviewer>,
    permission_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    collaboration_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    multi_agent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    personality: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    service_tier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    developer_instructions: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    effort: Option<String>,
  },

  // Session naming
  RenameSession {
    session_id: String,
    name: Option<String>,
  },

  // Turn steering
  SteerTurn {
    session_id: String,
    content: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    images: Vec<ImageInput>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    mentions: Vec<MentionInput>,
  },

  // Context management
  CompactContext {
    session_id: String,
  },
  UndoLastTurn {
    session_id: String,
  },
  RollbackTurns {
    session_id: String,
    num_turns: u32,
  },
  StopTask {
    session_id: String,
    task_id: String,
  },
  RewindFiles {
    session_id: String,
    user_message_id: String,
  },

  // Claude hook transport (server-owned write path)
  ClaudeSessionStart {
    session_id: String,
    cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context_label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    terminal_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    terminal_app: Option<String>,
  },
  ClaudeSessionEnd {
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
  },
  ClaudeStatusEvent {
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_path: Option<String>,
    hook_event_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    notification_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stop_hook_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    trigger: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    custom_instructions: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_assistant_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    teammate_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    team_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    task_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    task_subject: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    task_description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "source")]
    config_source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "file_path")]
    config_file_path: Option<String>,
  },
  ClaudeToolEvent {
    session_id: String,
    cwd: String,
    hook_event_name: String,
    tool_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_input: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_response: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_use_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_suggestions: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    is_interrupt: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_mode: Option<String>,
  },
  ClaudeSubagentEvent {
    session_id: String,
    hook_event_name: String,
    agent_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stop_hook_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_assistant_message: Option<String>,
  },

  // Codex hook transport (server-owned write path)
  CodexSessionStart {
    session_id: String,
    cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<String>,
  },
  CodexUserPromptSubmit {
    session_id: String,
    cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    turn_id: String,
    prompt: String,
  },
  CodexStopEvent {
    session_id: String,
    cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    turn_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    stop_hook_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_assistant_message: Option<String>,
  },
  CodexToolEvent {
    session_id: String,
    cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    hook_event_name: String,
    turn_id: String,
    tool_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_use_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_input: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_response: Option<Value>,
  },

  // Shell execution (provider-independent, user-initiated)
  ExecuteShell {
    session_id: String,
    command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    cwd: Option<String>,
    #[serde(default = "default_shell_timeout")]
    timeout_secs: u64,
  },
  CancelShell {
    session_id: String,
    request_id: String,
  },

  // Interactive terminal sessions (PTY-backed)
  CreateTerminal {
    terminal_id: String,
    cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    shell: Option<String>,
    cols: u16,
    rows: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
  },
  TerminalInput {
    terminal_id: String,
    /// Base64-encoded bytes to write to the PTY.
    data: String,
  },
  TerminalResize {
    terminal_id: String,
    cols: u16,
    rows: u16,
  },
  DestroyTerminal {
    terminal_id: String,
  },

  // Tool PTY streaming (for live bash tool output)
  SubscribeToolPty {
    tool_id: String,
    session_id: String,
  },
  UnsubscribeToolPty {
    tool_id: String,
  },
}

fn default_shell_timeout() -> u64 {
  30
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod tests;
