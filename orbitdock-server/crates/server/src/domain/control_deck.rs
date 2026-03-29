use orbitdock_protocol::{
  ControlDeckAttachmentRef, ControlDeckCapabilities, ControlDeckConfigState, ControlDeckDensity,
  ControlDeckEmptyVisibility, ControlDeckImageAttachmentRef, ControlDeckMentionRef,
  ControlDeckModule, ControlDeckModulePreference, ControlDeckPickerOption, ControlDeckPreferences,
  ControlDeckSkillRef, ControlDeckSnapshot, ControlDeckState, ControlDeckSubmitTurnRequest,
  ControlDeckTokenStatus, ControlDeckTokenStatusTone, ControlDeckTurnOverrides, ImageInput,
  MentionInput, Provider, SessionState, SkillInput, TokenUsage, TokenUsageSnapshotKind,
};

pub(crate) const CONTROL_DECK_PREFERENCES_CONFIG_KEY: &str = "control_deck_preferences_v1";

pub(crate) fn default_control_deck_preferences() -> ControlDeckPreferences {
  ControlDeckPreferences {
    density: ControlDeckDensity::Comfortable,
    show_when_empty: ControlDeckEmptyVisibility::Auto,
    modules: default_control_deck_module_preferences(),
  }
}

/// Default module preferences include all possible modules. The capabilities
/// builder filters which ones are actually available per provider.
pub(crate) fn default_control_deck_module_preferences() -> Vec<ControlDeckModulePreference> {
  all_control_deck_modules()
    .into_iter()
    .map(|module| ControlDeckModulePreference {
      module,
      visible: true,
    })
    .collect()
}

/// All possible modules (superset). Used for default preferences.
fn all_control_deck_modules() -> Vec<ControlDeckModule> {
  vec![
    ControlDeckModule::Autonomy,
    ControlDeckModule::ApprovalMode,
    ControlDeckModule::CollaborationMode,
    ControlDeckModule::AutoReview,
    ControlDeckModule::Attachments,
    ControlDeckModule::Model,
    ControlDeckModule::Effort,
    ControlDeckModule::Tokens,
    ControlDeckModule::Branch,
    ControlDeckModule::Cwd,
  ]
}

/// Shared modules shown for all providers.
fn shared_status_modules() -> Vec<ControlDeckModule> {
  vec![
    ControlDeckModule::Model,
    ControlDeckModule::Effort,
    ControlDeckModule::Tokens,
    ControlDeckModule::Branch,
    ControlDeckModule::Cwd,
  ]
}

fn picker_option(value: &str, label: &str) -> ControlDeckPickerOption {
  ControlDeckPickerOption {
    value: value.to_string(),
    label: label.to_string(),
  }
}

fn claude_permission_mode_options() -> Vec<ControlDeckPickerOption> {
  vec![
    picker_option("plan", "Plan Mode"),
    picker_option("dontAsk", "Don't Ask"),
    picker_option("default", "Default"),
    picker_option("acceptEdits", "Accept Edits"),
    picker_option("bypassPermissions", "Bypass Permissions"),
  ]
}

fn codex_approval_mode_options() -> Vec<ControlDeckPickerOption> {
  vec![
    picker_option("untrusted", "Trusted Only"),
    picker_option("on-failure", "On Failure"),
    picker_option("on-request", "Default"),
    picker_option("never", "Never Ask"),
  ]
}

fn codex_collaboration_mode_options() -> Vec<ControlDeckPickerOption> {
  vec![
    picker_option("default", "Default"),
    picker_option("plan", "Plan"),
  ]
}

/// Provider-aware module list. Claude and Codex have different control surfaces.
pub(crate) fn control_deck_status_modules(provider: Provider) -> Vec<ControlDeckModule> {
  let mut modules = Vec::new();

  match provider {
    Provider::Claude => {
      modules.push(ControlDeckModule::Autonomy);
    }
    Provider::Codex => {
      modules.push(ControlDeckModule::ApprovalMode);
      modules.push(ControlDeckModule::CollaborationMode);
      modules.push(ControlDeckModule::Attachments);
    }
  }

  modules.extend(shared_status_modules());
  modules
}

pub(crate) fn build_control_deck_capabilities(
  provider: Provider,
  steerable: bool,
  _codex_config_mode: Option<orbitdock_protocol::CodexConfigMode>,
) -> ControlDeckCapabilities {
  ControlDeckCapabilities {
    supports_skills: provider == Provider::Codex,
    supports_mentions: provider == Provider::Codex,
    supports_images: true,
    supports_steer: steerable,
    allow_per_turn_model_override: provider == Provider::Claude || provider == Provider::Codex,
    allow_per_turn_effort_override: provider == Provider::Codex,
    approval_mode_options: if provider == Provider::Codex {
      codex_approval_mode_options()
    } else {
      Vec::new()
    },
    permission_mode_options: if provider == Provider::Claude {
      claude_permission_mode_options()
    } else {
      Vec::new()
    },
    collaboration_mode_options: if provider == Provider::Codex {
      codex_collaboration_mode_options()
    } else {
      Vec::new()
    },
    auto_review_options: Vec::new(),
    available_status_modules: control_deck_status_modules(provider),
  }
}

pub(crate) fn build_control_deck_snapshot(
  session: &SessionState,
  preferences: ControlDeckPreferences,
) -> ControlDeckSnapshot {
  let state = ControlDeckState {
    provider: session.provider,
    control_mode: session.control_mode,
    lifecycle_state: session.lifecycle_state,
    accepts_user_input: session.accepts_user_input,
    steerable: session.steerable,
    project_path: session.project_path.clone(),
    current_cwd: session.current_cwd.clone(),
    git_branch: session.git_branch.clone(),
    config: ControlDeckConfigState {
      model: session.model.clone(),
      effort: session.effort.clone(),
      approval_policy: session.approval_policy.clone(),
      approval_policy_details: session.approval_policy_details.clone(),
      sandbox_mode: session.sandbox_mode.clone(),
      approvals_reviewer: session
        .codex_config_overrides
        .as_ref()
        .and_then(|overrides| overrides.approvals_reviewer),
      permission_mode: session.permission_mode.clone(),
      collaboration_mode: session.collaboration_mode.clone(),
      developer_instructions: session.developer_instructions.clone(),
      codex_config_mode: session.codex_config_mode,
      codex_config_profile: session.codex_config_profile.clone(),
      codex_model_provider: session.codex_model_provider.clone(),
    },
  };

  ControlDeckSnapshot {
    revision: session.revision.unwrap_or_default(),
    session_id: session.id.clone(),
    capabilities: build_control_deck_capabilities(
      session.provider,
      session.steerable,
      session.codex_config_mode,
    ),
    preferences,
    state,
    token_usage: session.token_usage.clone(),
    token_usage_snapshot_kind: session.token_usage_snapshot_kind,
    token_status: build_control_deck_token_status(
      session.provider,
      &session.token_usage,
      session.token_usage_snapshot_kind,
    ),
  }
}

fn build_control_deck_token_status(
  provider: Provider,
  usage: &TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> ControlDeckTokenStatus {
  if usage.context_window == 0 {
    return ControlDeckTokenStatus {
      label: "—".to_string(),
      tone: ControlDeckTokenStatusTone::Muted,
    };
  }

  let effective_input = effective_context_input_tokens(provider, usage, snapshot_kind);
  let fill_percent = if usage.context_window == 0 {
    0.0
  } else {
    (effective_input as f64 / usage.context_window as f64) * 100.0
  };
  let display_percent = if effective_input > 0 && fill_percent > 0.0 && fill_percent < 1.0 {
    "<1".to_string()
  } else {
    format!("{}", fill_percent.floor() as u64)
  };

  ControlDeckTokenStatus {
    label: format!(
      "{}% · {}/{}",
      display_percent,
      format_token_count(effective_input),
      format_token_count(usage.context_window)
    ),
    tone: if fill_percent > 90.0 {
      ControlDeckTokenStatusTone::Critical
    } else if fill_percent > 70.0 {
      ControlDeckTokenStatusTone::Caution
    } else {
      ControlDeckTokenStatusTone::Normal
    },
  }
}

fn effective_context_input_tokens(
  provider: Provider,
  usage: &TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> u64 {
  match snapshot_kind {
    TokenUsageSnapshotKind::MixedLegacy => usage.input_tokens.saturating_add(usage.cached_tokens),
    TokenUsageSnapshotKind::CompactionReset => 0,
    TokenUsageSnapshotKind::ContextTurn => {
      if provider == Provider::Claude {
        usage.input_tokens.saturating_add(usage.cached_tokens)
      } else {
        usage.input_tokens
      }
    }
    TokenUsageSnapshotKind::LifetimeTotals => usage.input_tokens,
    TokenUsageSnapshotKind::Unknown => {
      if provider == Provider::Codex {
        usage.input_tokens
      } else {
        usage.input_tokens.saturating_add(usage.cached_tokens)
      }
    }
  }
}

fn format_token_count(count: u64) -> String {
  if count >= 1_000_000 {
    format!("{:.1}M", count as f64 / 1_000_000.0)
  } else if count >= 1_000 {
    format!("{:.0}K", count as f64 / 1_000.0)
  } else {
    count.to_string()
  }
}

#[derive(Debug, Clone)]
pub(crate) struct ControlDeckSubmitPlan {
  pub text: String,
  pub model: Option<String>,
  pub effort: Option<String>,
  pub skills: Vec<SkillInput>,
  pub images: Vec<ImageInput>,
  pub mentions: Vec<MentionInput>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ControlDeckSubmitValidationError {
  EmptyRequest,
}

impl ControlDeckSubmitValidationError {
  pub(crate) fn message(&self) -> &'static str {
    match self {
      Self::EmptyRequest => "Provide text, attachments, or skills to submit a Control Deck turn",
    }
  }
}

pub(crate) fn validate_control_deck_submit_request(
  request: ControlDeckSubmitTurnRequest,
) -> Result<ControlDeckSubmitPlan, ControlDeckSubmitValidationError> {
  let (images, mentions) = map_control_deck_attachments(request.attachments);
  let skills = map_control_deck_skills(request.skills);
  let ControlDeckTurnOverrides { model, effort } = request.overrides.unwrap_or_default();

  if request.text.is_empty() && images.is_empty() && mentions.is_empty() && skills.is_empty() {
    return Err(ControlDeckSubmitValidationError::EmptyRequest);
  }

  Ok(ControlDeckSubmitPlan {
    text: request.text,
    model,
    effort,
    skills,
    images,
    mentions,
  })
}

fn map_control_deck_attachments(
  attachments: Vec<ControlDeckAttachmentRef>,
) -> (Vec<ImageInput>, Vec<MentionInput>) {
  let mut images = Vec::new();
  let mut mentions = Vec::new();

  for attachment in attachments {
    match attachment {
      ControlDeckAttachmentRef::Image(ControlDeckImageAttachmentRef {
        attachment_id,
        display_name,
      }) => {
        images.push(ImageInput {
          input_type: "attachment".to_string(),
          value: attachment_id,
          mime_type: None,
          byte_count: None,
          display_name,
          pixel_width: None,
          pixel_height: None,
        });
      }
      ControlDeckAttachmentRef::Mention(ControlDeckMentionRef {
        name,
        path,
        kind: _kind,
        mention_id: _mention_id,
        relative_path: _relative_path,
      }) => {
        mentions.push(MentionInput { name, path });
      }
    }
  }

  (images, mentions)
}

fn map_control_deck_skills(skills: Vec<ControlDeckSkillRef>) -> Vec<SkillInput> {
  skills
    .into_iter()
    .map(|skill| SkillInput {
      name: skill.name,
      path: skill.path,
    })
    .collect()
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::{
    CodexConfigMode, ControlDeckMentionKind, SessionControlMode, SessionLifecycleState,
    SessionState, SessionStatus, WorkStatus,
  };

  fn sample_session_state() -> SessionState {
    SessionState {
      id: "session-1".to_string(),
      provider: Provider::Codex,
      project_path: "/workspace/project".to_string(),
      transcript_path: None,
      project_name: Some("project".to_string()),
      model: Some("gpt-5.4".to_string()),
      custom_name: Some("Project".to_string()),
      summary: None,
      first_prompt: None,
      last_message: None,
      status: SessionStatus::Active,
      work_status: WorkStatus::Working,
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      accepts_user_input: true,
      steerable: true,
      pending_approval: None,
      permission_mode: Some("default".to_string()),
      allow_bypass_permissions: true,
      collaboration_mode: Some("default".to_string()),
      multi_agent: Some(false),
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: Some(CodexConfigMode::Custom),
      codex_config_profile: Some("default".to_string()),
      codex_model_provider: Some("openai".to_string()),
      codex_config_source: None,
      codex_config_overrides: None,
      pending_tool_name: None,
      pending_tool_input: None,
      pending_question: None,
      pending_approval_id: None,
      token_usage: Default::default(),
      token_usage_snapshot_kind: Default::default(),
      current_diff: None,
      cumulative_diff: None,
      current_plan: None,
      codex_integration_mode: None,
      claude_integration_mode: None,
      approval_policy: None,
      approval_policy_details: None,
      sandbox_mode: None,
      started_at: None,
      last_activity_at: None,
      last_progress_at: None,
      forked_from_session_id: None,
      revision: Some(42),
      current_turn_id: None,
      turn_count: 0,
      turn_diffs: vec![],
      git_branch: Some("main".to_string()),
      git_sha: None,
      current_cwd: Some("/workspace/project".to_string()),
      subagents: vec![],
      effort: Some("medium".to_string()),
      terminal_session_id: None,
      terminal_app: None,
      approval_version: None,
      repository_root: None,
      is_worktree: false,
      worktree_id: None,
      unread_count: 0,
      mission_id: None,
      issue_identifier: None,
      rows: vec![],
      total_row_count: 0,
      has_more_before: false,
      oldest_sequence: None,
      newest_sequence: None,
    }
  }

  #[test]
  fn uses_default_preferences_when_empty() {
    let prefs = default_control_deck_preferences();
    assert_eq!(prefs.density, ControlDeckDensity::Comfortable);
    assert_eq!(prefs.show_when_empty, ControlDeckEmptyVisibility::Auto);
    assert!(!prefs.modules.is_empty());
  }

  #[test]
  fn builds_snapshot_from_session_state() {
    let session = sample_session_state();
    let snapshot = build_control_deck_snapshot(&session, default_control_deck_preferences());

    assert_eq!(snapshot.session_id, "session-1");
    assert_eq!(snapshot.revision, 42);
    assert!(snapshot.capabilities.supports_skills);
  }

  #[test]
  fn rejects_empty_submit_requests() {
    let request = ControlDeckSubmitTurnRequest {
      text: String::new(),
      attachments: vec![],
      skills: vec![],
      overrides: None,
    };

    let result = validate_control_deck_submit_request(request);
    assert!(matches!(
      result,
      Err(ControlDeckSubmitValidationError::EmptyRequest)
    ));
  }

  #[test]
  fn maps_control_deck_submit_payload_into_connector_plan() {
    let request = ControlDeckSubmitTurnRequest {
      text: "Refine the header".to_string(),
      attachments: vec![
        ControlDeckAttachmentRef::Image(ControlDeckImageAttachmentRef {
          attachment_id: "img-123".to_string(),
          display_name: Some("mock.png".to_string()),
        }),
        ControlDeckAttachmentRef::Mention(ControlDeckMentionRef {
          mention_id: Some("mention-1".to_string()),
          kind: ControlDeckMentionKind::File,
          name: "design-system".to_string(),
          path: "/workspace/design-system".to_string(),
          relative_path: Some("design-system".to_string()),
        }),
      ],
      skills: vec![ControlDeckSkillRef {
        name: "design-system".to_string(),
        path: "/workspace/.skills/design-system".to_string(),
      }],
      overrides: Some(ControlDeckTurnOverrides {
        model: Some("gpt-5.4".to_string()),
        effort: Some("high".to_string()),
      }),
    };

    let plan = validate_control_deck_submit_request(request).expect("request should be valid");
    assert_eq!(plan.text, "Refine the header");
    assert_eq!(plan.images.len(), 1);
    assert_eq!(plan.images[0].input_type, "attachment");
    assert_eq!(plan.images[0].value, "img-123");
    assert_eq!(plan.images[0].display_name.as_deref(), Some("mock.png"));
    assert_eq!(plan.mentions.len(), 1);
    assert_eq!(plan.mentions[0].name, "design-system");
    assert_eq!(plan.mentions[0].path, "/workspace/design-system");
    assert_eq!(plan.skills.len(), 1);
    assert_eq!(plan.skills[0].name, "design-system");
    assert_eq!(plan.model.as_deref(), Some("gpt-5.4"));
    assert_eq!(plan.effort.as_deref(), Some("high"));
  }
}
