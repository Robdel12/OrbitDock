use orbitdock_protocol::{
  CodexConfigMode, SessionControlMode, SessionLifecycleState, SessionStatus,
};

pub(crate) fn infer_codex_config_mode(raw_mode: Option<&str>) -> Option<CodexConfigMode> {
  match raw_mode {
    Some("inherit") => Some(CodexConfigMode::Inherit),
    Some("profile") => Some(CodexConfigMode::Profile),
    Some("custom") => Some(CodexConfigMode::Custom),
    _ => None,
  }
}

pub(crate) fn parse_lifecycle_state(value: Option<String>) -> SessionLifecycleState {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("resumable") => SessionLifecycleState::Resumable,
    Some("ended") => SessionLifecycleState::Ended,
    _ => SessionLifecycleState::Open,
  }
}

pub(crate) fn parse_session_status(value: &str) -> SessionStatus {
  match value.to_ascii_lowercase().as_str() {
    "ended" => SessionStatus::Ended,
    _ => SessionStatus::Active,
  }
}

pub(crate) fn parse_control_mode(value: Option<String>) -> Option<SessionControlMode> {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("direct") => Some(SessionControlMode::Direct),
    Some("passive") => Some(SessionControlMode::Passive),
    _ => None,
  }
}
