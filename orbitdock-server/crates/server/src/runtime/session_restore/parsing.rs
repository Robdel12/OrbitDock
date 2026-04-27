use orbitdock_protocol::{Provider, SessionStatus, WorkStatus};
use tracing::warn;

pub(crate) fn parse_provider(raw: &str) -> Provider {
  let normalised = raw.to_ascii_lowercase();
  match normalised.as_str() {
    "claude" | "codex" => normalised.parse::<Provider>().unwrap_or(Provider::Claude),
    _ => {
      warn!(
          stored_value = %raw,
          "unrecognised provider in restored session, falling back to Claude"
      );
      Provider::Claude
    }
  }
}

pub(crate) fn parse_session_status(end_reason: Option<&String>, value: &str) -> SessionStatus {
  if end_reason.is_some() {
    return SessionStatus::Ended;
  }

  if value.eq_ignore_ascii_case("ended") {
    SessionStatus::Ended
  } else {
    SessionStatus::Active
  }
}

pub(crate) fn parse_work_status(status: SessionStatus, value: &str) -> WorkStatus {
  if status == SessionStatus::Ended {
    return WorkStatus::Ended;
  }

  match value.to_ascii_lowercase().as_str() {
    "working" => WorkStatus::Working,
    "waiting" => WorkStatus::Waiting,
    "permission" => WorkStatus::Permission,
    "question" => WorkStatus::Question,
    "reply" => WorkStatus::Reply,
    "ended" => WorkStatus::Ended,
    _ => WorkStatus::Waiting,
  }
}
