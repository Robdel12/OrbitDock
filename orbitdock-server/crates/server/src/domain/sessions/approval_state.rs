//! Pure approval-queue helpers.
//!
//! This module keeps approval matching, queue promotion, persisted-field
//! bootstrap, and related parsing logic separate from the mutable session shell.

use std::collections::VecDeque;
use std::fmt;

use orbitdock_protocol::domain_events::ToolFamily;
use orbitdock_protocol::{
  ApprovalPreview, ApprovalQuestionOption, ApprovalQuestionPrompt, ApprovalRequest, ApprovalType,
  CodexApprovalPolicy, CodexSandboxPolicy, CodexSessionOverrides, WorkStatus,
};
use serde::Serialize;

use crate::domain::sessions::transition::{approval_preview, ApprovalPreviewInput};

#[derive(Debug, Clone)]
pub struct PendingApprovalEntry {
  pub request: ApprovalRequest,
  pub approval_type: ApprovalType,
  pub proposed_amendment: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PendingApprovalMutation {
  Unchanged,
  Updated,
  Enqueued,
}

#[derive(Debug, Clone)]
pub struct PendingApprovalResolution {
  pub approval_type: Option<ApprovalType>,
  pub proposed_amendment: Option<Vec<String>>,
  pub active_approval: Option<ApprovalRequest>,
  pub work_status: WorkStatus,
}

#[derive(Debug, Clone)]
pub struct ApprovalQueueState {
  pub pending_approval: Option<ApprovalRequest>,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub pending_approval_id: Option<String>,
  pub pending_approvals: VecDeque<PendingApprovalEntry>,
  pub approval_version: u64,
  pub work_status: WorkStatus,
}

impl ApprovalQueueState {
  pub fn new(work_status: WorkStatus) -> Self {
    Self {
      pending_approval: None,
      pending_tool_name: None,
      pending_tool_input: None,
      pending_question: None,
      pending_approval_id: None,
      pending_approvals: VecDeque::new(),
      approval_version: 0,
      work_status,
    }
  }

  pub fn queue_pending_approval(
    mut self,
    approval: ApprovalRequest,
    approval_type: ApprovalType,
    proposed_amendment: Option<Vec<String>>,
  ) -> (Self, PendingApprovalMutation) {
    let normalized_request_id = normalize_request_id(&approval.id).to_string();
    let next_entry = PendingApprovalEntry {
      request: approval,
      approval_type,
      proposed_amendment,
    };
    if let Some(index) = self
      .pending_approvals
      .iter()
      .position(|entry| normalize_request_id(&entry.request.id) == normalized_request_id)
    {
      if let Some(existing) = self.pending_approvals.get_mut(index) {
        if pending_approval_entries_effectively_equal(existing, &next_entry) {
          return (self, PendingApprovalMutation::Unchanged);
        }
        *existing = next_entry;
      }
      self.approval_version += 1;
      return (self, PendingApprovalMutation::Updated);
    }

    self.pending_approvals.push_back(next_entry);
    self.approval_version += 1;
    (self, PendingApprovalMutation::Enqueued)
  }

  pub fn promote_queue_front(mut self) -> Self {
    if let Some(entry) = self.pending_approvals.front() {
      if self.is_active_pending_approval(entry) {
        return self;
      }
      self.pending_approval = Some(entry.request.clone());
      self.pending_tool_name = fallback_tool_name(&entry.request);
      self.pending_tool_input = fallback_tool_input(&entry.request);
      self.pending_question = entry.request.question.clone();
      self.pending_approval_id = Some(entry.request.id.clone());
      self.work_status = work_status_for_approval_type(entry.approval_type);
      return self;
    }

    let had_active_pending = self.pending_approval.is_some()
      || self.pending_tool_name.is_some()
      || self.pending_tool_input.is_some()
      || self.pending_question.is_some()
      || self.pending_approval_id.is_some();
    if !had_active_pending {
      return self;
    }

    self.pending_approval = None;
    self.pending_tool_name = None;
    self.pending_tool_input = None;
    self.pending_question = None;
    self.pending_approval_id = None;
    self
  }

  pub fn clear_pending_approvals(mut self) -> Self {
    let had_approvals = !self.pending_approvals.is_empty() || self.pending_approval.is_some();
    self.pending_approvals.clear();
    self.pending_approval = None;
    self.pending_tool_name = None;
    self.pending_tool_input = None;
    self.pending_question = None;
    self.pending_approval_id = None;
    if had_approvals {
      self.approval_version += 1;
    }
    self
  }

  pub fn bootstrap_from_persisted_fields(self, session_id: &str) -> Self {
    if !self.pending_approvals.is_empty() {
      return self;
    }

    let Some(request_id) = self.pending_approval_id.clone() else {
      return self;
    };

    let approval_type = self.inferred_approval_type_from_pending_fields();
    let approval = ApprovalRequest {
      id: request_id,
      session_id: session_id.to_string(),
      approval_type,
      tool_name: self.pending_tool_name.clone(),
      tool_input: self.pending_tool_input.clone(),
      command: None,
      file_path: None,
      diff: None,
      question: self.pending_question.clone(),
      question_prompts: extract_question_prompts(
        self.pending_tool_input.as_deref(),
        self.pending_question.as_deref(),
      ),
      preview: preview_for_pending_approval(
        self.pending_approval_id.as_deref(),
        approval_type,
        self.pending_tool_name.as_deref(),
        self.pending_tool_input.as_deref(),
        self.pending_question.as_deref(),
      ),
      permission_reason: None,
      requested_permissions: None,
      granted_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    };

    let (state, _) = self.queue_pending_approval(approval, approval_type, None);
    state.promote_queue_front()
  }

  pub fn resolve_pending_approval(
    mut self,
    request_id: &str,
    fallback_work_status: WorkStatus,
  ) -> (Self, PendingApprovalResolution) {
    let active_approval = self.pending_approval.clone();
    let work_status = self.work_status;
    let Some(head) = self.pending_approvals.front() else {
      return (
        self,
        PendingApprovalResolution {
          approval_type: None,
          proposed_amendment: None,
          active_approval,
          work_status,
        },
      );
    };
    if normalize_request_id(&head.request.id) != normalize_request_id(request_id) {
      return (
        self,
        PendingApprovalResolution {
          approval_type: None,
          proposed_amendment: None,
          active_approval,
          work_status,
        },
      );
    }

    let removed = self
      .pending_approvals
      .pop_front()
      .expect("pending approval queue should have head entry");
    let removed_request_id = normalize_request_id(&removed.request.id);
    while matches!(
      self.pending_approvals.front(),
      Some(entry) if normalize_request_id(&entry.request.id) == removed_request_id
    ) {
      let _ = self.pending_approvals.pop_front();
    }
    self.approval_version += 1;
    self = self.promote_queue_front();
    if self.pending_approvals.is_empty() {
      self.work_status = fallback_work_status;
    }

    let active_approval = self.pending_approval.clone();
    let work_status = self.work_status;
    (
      self,
      PendingApprovalResolution {
        approval_type: Some(removed.approval_type),
        proposed_amendment: removed.proposed_amendment,
        active_approval,
        work_status,
      },
    )
  }

  pub fn inferred_approval_type_from_pending_fields(&self) -> ApprovalType {
    if self.pending_question.is_some() {
      return ApprovalType::Question;
    }
    if let Some(tool_name) = self.pending_tool_name.as_ref() {
      let normalized = tool_name.to_ascii_lowercase();
      if normalized.contains("edit") || normalized.contains("patch") || normalized.contains("write")
      {
        return ApprovalType::Patch;
      }
    }
    ApprovalType::Exec
  }

  fn is_active_pending_approval(&self, entry: &PendingApprovalEntry) -> bool {
    self
      .pending_approval
      .as_ref()
      .is_some_and(|current| approval_requests_effectively_equal(current, &entry.request))
      && self.pending_tool_name == fallback_tool_name(&entry.request)
      && self.pending_tool_input == fallback_tool_input(&entry.request)
      && self.pending_question.as_deref() == entry.request.question.as_deref()
      && self.pending_approval_id.as_deref() == Some(entry.request.id.as_str())
      && self.work_status == work_status_for_approval_type(entry.approval_type)
  }
}

pub fn normalize_request_id(value: &str) -> &str {
  value.trim()
}

pub fn fallback_tool_name(approval: &ApprovalRequest) -> Option<String> {
  if let Some(name) = approval.tool_name.as_ref().filter(|name| !name.is_empty()) {
    return Some(name.clone());
  }

  match approval.approval_type {
    ApprovalType::Exec => Some("Bash".to_string()),
    ApprovalType::Patch => Some("Edit".to_string()),
    ApprovalType::Permissions => Some("Permissions".to_string()),
    ApprovalType::Question => None,
  }
}

pub fn fallback_tool_input(approval: &ApprovalRequest) -> Option<String> {
  if let Some(input) = approval
    .tool_input
    .as_ref()
    .filter(|input| !input.is_empty())
  {
    return Some(input.clone());
  }

  let mut payload = serde_json::Map::new();
  if let Some(command) = approval.command.as_ref().filter(|cmd| !cmd.is_empty()) {
    payload.insert(
      "command".to_string(),
      serde_json::Value::String(command.clone()),
    );
  }
  if let Some(path) = approval.file_path.as_ref().filter(|path| !path.is_empty()) {
    payload.insert(
      "file_path".to_string(),
      serde_json::Value::String(path.clone()),
    );
  }
  if payload.is_empty() {
    if let Some(preview) = approval.preview.as_ref() {
      let key = match preview.preview_type {
        orbitdock_protocol::ApprovalPreviewType::ShellCommand => "command",
        orbitdock_protocol::ApprovalPreviewType::Url => "url",
        orbitdock_protocol::ApprovalPreviewType::SearchQuery => "query",
        orbitdock_protocol::ApprovalPreviewType::Pattern => "pattern",
        orbitdock_protocol::ApprovalPreviewType::Prompt => "prompt",
        orbitdock_protocol::ApprovalPreviewType::Diff => "diff",
        orbitdock_protocol::ApprovalPreviewType::FilePath => "file_path",
        orbitdock_protocol::ApprovalPreviewType::Value
        | orbitdock_protocol::ApprovalPreviewType::Action => "value",
      };
      payload.insert(
        key.to_string(),
        serde_json::Value::String(preview.value.clone()),
      );
    }
  }

  if payload.is_empty() {
    None
  } else {
    Some(serde_json::Value::Object(payload).to_string())
  }
}

pub fn serialized_value_eq<T: Serialize>(left: &T, right: &T) -> bool {
  serde_json::to_value(left).ok() == serde_json::to_value(right).ok()
}

pub fn resolve_approval_policy_details(
  approval_policy: Option<&str>,
  codex_config_overrides: Option<&CodexSessionOverrides>,
) -> Option<CodexApprovalPolicy> {
  codex_config_overrides
    .and_then(|overrides| overrides.approval_policy_details.clone())
    .or_else(|| {
      approval_policy.and_then(orbitdock_protocol::CodexApprovalPolicy::from_storage_text)
    })
}

pub fn resolve_sandbox_policy_details(
  sandbox_mode: Option<&str>,
  codex_config_overrides: Option<&CodexSessionOverrides>,
) -> Option<CodexSandboxPolicy> {
  codex_config_overrides
    .and_then(|overrides| overrides.sandbox_policy_details.clone())
    .or_else(|| sandbox_mode.and_then(orbitdock_protocol::CodexSandboxPolicy::from_storage_text))
}

pub fn approval_requests_effectively_equal(
  left: &ApprovalRequest,
  right: &ApprovalRequest,
) -> bool {
  serialized_value_eq(left, right)
}

pub fn pending_approval_entries_effectively_equal(
  left: &PendingApprovalEntry,
  right: &PendingApprovalEntry,
) -> bool {
  left.approval_type == right.approval_type
    && left.proposed_amendment == right.proposed_amendment
    && approval_requests_effectively_equal(&left.request, &right.request)
}

pub fn parse_bool_value(value: Option<&serde_json::Value>) -> bool {
  let Some(value) = value else {
    return false;
  };
  if let Some(flag) = value.as_bool() {
    return flag;
  }
  if let Some(number) = value.as_u64() {
    return number > 0;
  }
  if let Some(text) = value.as_str() {
    let normalized = text.trim().to_ascii_lowercase();
    return normalized == "true" || normalized == "1" || normalized == "yes";
  }
  false
}

pub fn parse_question_options(
  payload: &serde_json::Map<String, serde_json::Value>,
) -> Vec<ApprovalQuestionOption> {
  let Some(options) = payload.get("options").and_then(serde_json::Value::as_array) else {
    return vec![];
  };

  options
    .iter()
    .filter_map(|raw_option| {
      let option = raw_option.as_object()?;
      let label = option
        .get("label")
        .or_else(|| option.get("value"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())?
        .to_string();
      let description = option
        .get("description")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToString::to_string);
      Some(ApprovalQuestionOption { label, description })
    })
    .collect()
}

pub fn parse_question_prompt(
  payload: &serde_json::Map<String, serde_json::Value>,
  fallback_id: &str,
) -> Option<ApprovalQuestionPrompt> {
  let id = payload
    .get("id")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .unwrap_or(fallback_id)
    .to_string();
  let header = payload
    .get("header")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .map(ToString::to_string);
  let question = payload
    .get("question")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .unwrap_or("Question")
    .to_string();
  if question.is_empty() {
    return None;
  }

  Some(ApprovalQuestionPrompt {
    id,
    header,
    question,
    options: parse_question_options(payload),
    allows_multiple_selection: parse_bool_value(
      payload
        .get("multiSelect")
        .or_else(|| payload.get("multi_select")),
    ),
    allows_other: parse_bool_value(payload.get("isOther").or_else(|| payload.get("is_other"))),
    is_secret: parse_bool_value(payload.get("isSecret").or_else(|| payload.get("is_secret"))),
  })
}

pub fn extract_question_prompts(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
  let from_tool_input: Vec<ApprovalQuestionPrompt> = tool_input
    .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
    .and_then(|value| value.as_object().cloned())
    .map(|payload| {
      if let Some(questions) = payload
        .get("questions")
        .and_then(serde_json::Value::as_array)
      {
        return questions
          .iter()
          .enumerate()
          .filter_map(|(index, raw_question)| {
            let prompt = raw_question.as_object()?;
            parse_question_prompt(prompt, index.to_string().as_str())
          })
          .collect();
      }
      if payload.contains_key("question") || payload.contains_key("options") {
        return parse_question_prompt(&payload, "0")
          .map(|prompt| vec![prompt])
          .unwrap_or_default();
      }
      vec![]
    })
    .unwrap_or_default();

  if !from_tool_input.is_empty() {
    return from_tool_input;
  }

  let fallback_question = fallback_question
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .map(ToString::to_string);
  match fallback_question {
    Some(question) => vec![ApprovalQuestionPrompt {
      id: "0".to_string(),
      header: None,
      question,
      options: vec![],
      allows_multiple_selection: false,
      allows_other: true,
      is_secret: false,
    }],
    None => vec![],
  }
}

pub fn preview_for_pending_approval(
  request_id: Option<&str>,
  approval_type: ApprovalType,
  tool_name: Option<&str>,
  tool_input: Option<&str>,
  question: Option<&str>,
) -> Option<ApprovalPreview> {
  let request_id = request_id
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .unwrap_or("pending-approval");
  approval_preview(ApprovalPreviewInput {
    request_id,
    approval_type,
    tool_name,
    tool_input,
    command: None,
    file_path: None,
    diff: None,
    question,
    permission_reason: None,
  })
}

pub fn pending_tool_family_from_state(
  pending_approval: Option<&ApprovalRequest>,
  pending_tool_name: Option<&str>,
  pending_question: Option<&str>,
) -> Option<ToolFamily> {
  if pending_question.is_some()
    || pending_approval.is_some_and(|request| request.approval_type == ApprovalType::Question)
  {
    return Some(ToolFamily::Question);
  }

  pending_tool_name.map(|name| match name {
    "Bash" | "bash" => ToolFamily::Shell,
    "Read" | "read" | "FileRead" => ToolFamily::FileRead,
    "Edit" | "edit" | "FileEdit" | "MultiEdit" | "Write" | "write" | "FileWrite"
    | "NotebookEdit" => ToolFamily::FileChange,
    "Glob" | "glob" | "Grep" | "grep" | "ToolSearch" => ToolFamily::Search,
    "WebSearch" | "websearch" | "WebFetch" | "webfetch" => ToolFamily::Web,
    "Agent" | "agent" | "task" => ToolFamily::Agent,
    "AskUserQuestion" => ToolFamily::Question,
    "EnterPlanMode" | "ExitPlanMode" => ToolFamily::Plan,
    "TodoWrite" => ToolFamily::Todo,
    "CompactContext" => ToolFamily::Context,
    value if value.starts_with("mcp__") => ToolFamily::Mcp,
    _ => ToolFamily::Generic,
  })
}

pub fn work_status_for_approval_type(approval_type: ApprovalType) -> WorkStatus {
  match approval_type {
    ApprovalType::Question => WorkStatus::Question,
    ApprovalType::Exec | ApprovalType::Patch | ApprovalType::Permissions => WorkStatus::Permission,
  }
}

impl fmt::Display for PendingApprovalMutation {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    match self {
      Self::Unchanged => write!(f, "unchanged"),
      Self::Updated => write!(f, "updated"),
      Self::Enqueued => write!(f, "enqueued"),
    }
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::{ApprovalPreviewType, ApprovalRiskLevel};
  use serde_json::json;

  struct ApprovalRequestFixture<'a> {
    id: &'a str,
    approval_type: ApprovalType,
    tool_name: Option<&'a str>,
    tool_input: Option<&'a str>,
    command: Option<&'a str>,
    file_path: Option<&'a str>,
    question: Option<&'a str>,
    preview: Option<ApprovalPreview>,
  }

  fn base_fixture<'a>(approval_type: ApprovalType) -> ApprovalRequestFixture<'a> {
    ApprovalRequestFixture {
      id: "a",
      approval_type,
      tool_name: None,
      tool_input: None,
      command: None,
      file_path: None,
      question: None,
      preview: None,
    }
  }

  fn approval_request(fixture: ApprovalRequestFixture<'_>) -> ApprovalRequest {
    ApprovalRequest {
      id: fixture.id.to_string(),
      session_id: "session-1".to_string(),
      approval_type: fixture.approval_type,
      tool_name: fixture.tool_name.map(ToString::to_string),
      tool_input: fixture.tool_input.map(ToString::to_string),
      command: fixture.command.map(ToString::to_string),
      file_path: fixture.file_path.map(ToString::to_string),
      diff: None,
      question: fixture.question.map(ToString::to_string),
      question_prompts: vec![],
      preview: fixture.preview,
      permission_reason: None,
      requested_permissions: None,
      granted_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    }
  }

  #[test]
  fn fallback_tool_shape_matches_approval_type() {
    let exec = approval_request(ApprovalRequestFixture {
      ..base_fixture(ApprovalType::Exec)
    });
    let patch = approval_request(ApprovalRequestFixture {
      ..base_fixture(ApprovalType::Patch)
    });
    let question = approval_request(ApprovalRequestFixture {
      ..base_fixture(ApprovalType::Question)
    });

    assert_eq!(fallback_tool_name(&exec), Some("Bash".to_string()));
    assert_eq!(fallback_tool_name(&patch), Some("Edit".to_string()));
    assert_eq!(fallback_tool_name(&question), None);

    let with_command = approval_request(ApprovalRequestFixture {
      tool_name: None,
      tool_input: None,
      command: Some("ls"),
      file_path: Some("/tmp"),
      ..base_fixture(ApprovalType::Exec)
    });
    assert_eq!(
      fallback_tool_input(&with_command),
      Some("{\"command\":\"ls\",\"file_path\":\"/tmp\"}".to_string())
    );
  }

  #[test]
  fn fallback_tool_input_uses_preview_value_when_needed() {
    let approval = approval_request(ApprovalRequestFixture {
      preview: Some(ApprovalPreview {
        preview_type: ApprovalPreviewType::Url,
        value: "https://example.com".to_string(),
        shell_segments: vec![],
        compact: None,
        decision_scope: None,
        risk_level: ApprovalRiskLevel::Normal,
        risk_findings: vec![],
        manifest: None,
      }),
      ..base_fixture(ApprovalType::Exec)
    });

    assert_eq!(
      fallback_tool_input(&approval),
      Some("{\"url\":\"https://example.com\"}".to_string())
    );
  }

  #[test]
  fn parse_question_prompt_and_fallback_question_are_consistent() {
    let payload = json!({
      "questions": [
        {
          "id": "0",
          "header": "Header",
          "question": "Continue?",
          "options": [
            {"label": "Yes", "description": "keep going"}
          ],
          "multiSelect": true,
          "isOther": false,
          "isSecret": true
        }
      ]
    });

    let prompts = extract_question_prompts(Some(&payload.to_string()), Some("Fallback question"));

    assert_eq!(prompts.len(), 1);
    assert_eq!(prompts[0].question, "Continue?");
    assert!(prompts[0].allows_multiple_selection);
    assert!(prompts[0].is_secret);
    assert_eq!(prompts[0].options[0].label, "Yes");

    let fallback = extract_question_prompts(None, Some("Fallback question"));
    assert_eq!(fallback.len(), 1);
    assert_eq!(fallback[0].question, "Fallback question");
  }

  #[test]
  fn queue_resolve_and_bootstrap_follow_queue_semantics() {
    let base = ApprovalQueueState::new(WorkStatus::Waiting);
    let request = approval_request(ApprovalRequestFixture {
      id: " approval-1 ",
      tool_name: Some("AskUserQuestion"),
      tool_input: Some("{\"question\":\"Ship it?\"}"),
      question: Some("Ship it?"),
      ..base_fixture(ApprovalType::Question)
    });

    let (state, mutation) =
      base
        .clone()
        .queue_pending_approval(request.clone(), ApprovalType::Question, None);
    assert_eq!(mutation, PendingApprovalMutation::Enqueued);
    assert_eq!(state.approval_version, 1);

    let (state, mutation) =
      state
        .clone()
        .queue_pending_approval(request.clone(), ApprovalType::Question, None);
    assert_eq!(mutation, PendingApprovalMutation::Unchanged);
    assert_eq!(state.approval_version, 1);

    let updated = approval_request(ApprovalRequestFixture {
      id: "approval-1",
      tool_name: Some("AskUserQuestion"),
      tool_input: Some("{\"question\":\"Ship now?\"}"),
      question: Some("Ship now?"),
      ..base_fixture(ApprovalType::Question)
    });
    let (state, mutation) =
      state.queue_pending_approval(updated.clone(), ApprovalType::Question, None);
    assert_eq!(mutation, PendingApprovalMutation::Updated);
    assert_eq!(state.approval_version, 2);

    let state = state.promote_queue_front();
    assert_eq!(state.pending_approval_id.as_deref(), Some("approval-1"));
    assert_eq!(state.work_status, WorkStatus::Question);

    let (state, resolution) = state.resolve_pending_approval("approval-1", WorkStatus::Waiting);
    assert_eq!(resolution.approval_type, Some(ApprovalType::Question));
    assert_eq!(resolution.work_status, WorkStatus::Waiting);
    assert!(resolution.active_approval.is_none());
    assert!(state.pending_approvals.is_empty());
    assert_eq!(state.work_status, WorkStatus::Waiting);
  }

  #[test]
  fn pending_tool_family_prefers_question_and_known_tool_mappings() {
    let request = approval_request(base_fixture(ApprovalType::Question));
    assert_eq!(
      pending_tool_family_from_state(Some(&request), Some("Bash"), None),
      Some(ToolFamily::Question)
    );
    assert_eq!(
      pending_tool_family_from_state(None, Some("Write"), None),
      Some(ToolFamily::FileChange)
    );
    assert_eq!(
      pending_tool_family_from_state(None, Some("mcp__example"), None),
      Some(ToolFamily::Mcp)
    );
  }
}
