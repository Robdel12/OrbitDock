use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState,
  SessionStatus, WorkStatus,
};

pub fn control_mode_from_parts(
  provider: Provider,
  codex_integration_mode: Option<CodexIntegrationMode>,
  claude_integration_mode: Option<ClaudeIntegrationMode>,
) -> SessionControlMode {
  match provider {
    Provider::Codex => match codex_integration_mode {
      Some(CodexIntegrationMode::Direct) => SessionControlMode::Direct,
      Some(CodexIntegrationMode::Passive) | None => SessionControlMode::Passive,
    },
    Provider::Claude => match claude_integration_mode {
      Some(ClaudeIntegrationMode::Direct) => SessionControlMode::Direct,
      Some(ClaudeIntegrationMode::Passive) | None => SessionControlMode::Passive,
    },
  }
}

pub(crate) fn accepts_user_input_from_parts(
  status: SessionStatus,
  control_mode: SessionControlMode,
  lifecycle_state: SessionLifecycleState,
) -> bool {
  status == SessionStatus::Active
    && control_mode == SessionControlMode::Direct
    && lifecycle_state == SessionLifecycleState::Open
}

pub(crate) fn steerable_from_parts(
  status: SessionStatus,
  work_status: WorkStatus,
  control_mode: SessionControlMode,
  lifecycle_state: SessionLifecycleState,
) -> bool {
  accepts_user_input_from_parts(status, control_mode, lifecycle_state)
    && work_status == WorkStatus::Working
}
