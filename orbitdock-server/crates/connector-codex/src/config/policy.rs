use codex_app_server_protocol::SandboxMode as AppServerSandboxMode;
use codex_protocol::config_types::{ApprovalsReviewer, Personality, ReasoningSummary, ServiceTier};
use orbitdock_protocol::{CodexSandboxMode, CodexSandboxPolicy};
use tracing::warn;

const REASONING_SUMMARY_NONE: &str = "none";
const ENV_CODEX_REASONING_SUMMARY: &str = "ORBITDOCK_CODEX_REASONING_SUMMARY";

pub fn requested_sandbox_policy_details(
  sandbox_mode: Option<&str>,
  sandbox_policy_details: Option<&CodexSandboxPolicy>,
) -> Option<CodexSandboxPolicy> {
  sandbox_policy_details
    .cloned()
    .or_else(|| sandbox_mode.and_then(CodexSandboxPolicy::from_storage_text))
}

pub fn config_loader_sandbox_mode(
  sandbox_mode: Option<&str>,
  sandbox_policy_details: Option<&CodexSandboxPolicy>,
) -> Option<String> {
  if let Some(details) = requested_sandbox_policy_details(sandbox_mode, sandbox_policy_details) {
    return match details.mode {
      CodexSandboxMode::DangerFullAccess => Some("danger-full-access".to_string()),
      CodexSandboxMode::ReadOnly => Some("read-only".to_string()),
      CodexSandboxMode::WorkspaceWrite => Some("workspace-write".to_string()),
      CodexSandboxMode::ExternalSandbox => None,
    };
  }

  sandbox_mode
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(ToOwned::to_owned)
}

pub(crate) fn app_server_sandbox_mode(
  sandbox_mode: Option<&str>,
  sandbox_policy_details: Option<&CodexSandboxPolicy>,
) -> Option<AppServerSandboxMode> {
  requested_sandbox_policy_details(sandbox_mode, sandbox_policy_details)
    .map(|details| match details.mode {
      CodexSandboxMode::DangerFullAccess => AppServerSandboxMode::DangerFullAccess,
      CodexSandboxMode::ReadOnly => AppServerSandboxMode::ReadOnly,
      CodexSandboxMode::WorkspaceWrite => AppServerSandboxMode::WorkspaceWrite,
      CodexSandboxMode::ExternalSandbox => AppServerSandboxMode::WorkspaceWrite,
    })
    .or_else(|| {
      match sandbox_mode
        .map(str::trim)
        .filter(|value| !value.is_empty())
      {
        Some("danger-full-access") => Some(AppServerSandboxMode::DangerFullAccess),
        Some("read-only") | Some("read-only-network") => Some(AppServerSandboxMode::ReadOnly),
        Some("workspace-write")
        | Some("workspace-write-network")
        | Some("external-sandbox")
        | Some("external-sandbox-network") => Some(AppServerSandboxMode::WorkspaceWrite),
        _ => None,
      }
    })
}

pub(crate) fn parse_approvals_reviewer(value: Option<&str>) -> Option<ApprovalsReviewer> {
  match value.map(str::trim).filter(|value| !value.is_empty()) {
    Some("user") => Some(ApprovalsReviewer::User),
    Some("guardian_subagent") | Some("auto_review") => Some(ApprovalsReviewer::AutoReview),
    _ => None,
  }
}

pub(crate) fn parse_reasoning_summary_env(name: &str) -> Option<String> {
  let value = std::env::var(name).ok()?;
  let trimmed = value.trim();
  if trimmed.is_empty() {
    return None;
  }

  let normalized = trimmed.to_ascii_lowercase();
  match normalized.as_str() {
    "auto" | "concise" | "detailed" | REASONING_SUMMARY_NONE => Some(normalized),
    other => {
      warn!(
        "Ignoring invalid reasoning summary env {}={} (expected auto|concise|detailed|none)",
        name, other
      );
      None
    }
  }
}

pub(crate) fn parse_reasoning_summary(value: &str) -> Option<ReasoningSummary> {
  match value.trim().to_ascii_lowercase().as_str() {
    "auto" => Some(ReasoningSummary::Auto),
    "concise" => Some(ReasoningSummary::Concise),
    "detailed" => Some(ReasoningSummary::Detailed),
    REASONING_SUMMARY_NONE => Some(ReasoningSummary::None),
    _ => None,
  }
}

pub(crate) fn preferred_reasoning_summary() -> ReasoningSummary {
  parse_reasoning_summary_env(ENV_CODEX_REASONING_SUMMARY)
    .as_deref()
    .and_then(parse_reasoning_summary)
    .unwrap_or(ReasoningSummary::Detailed)
}

pub(crate) fn model_rejects_reasoning_summary(model: Option<&str>) -> bool {
  model
    .map(|value| value.trim().to_ascii_lowercase().contains("codex-spark"))
    .unwrap_or(false)
}

pub(crate) fn reasoning_summary_for_model(
  model: Option<&str>,
  preferred: ReasoningSummary,
) -> ReasoningSummary {
  if model_rejects_reasoning_summary(model) {
    ReasoningSummary::None
  } else {
    preferred
  }
}

pub(crate) fn reasoning_summary_storage_text(summary: ReasoningSummary) -> &'static str {
  match summary {
    ReasoningSummary::Auto => "auto",
    ReasoningSummary::Concise => "concise",
    ReasoningSummary::Detailed => "detailed",
    ReasoningSummary::None => "none",
  }
}

#[cfg(test)]
pub(crate) fn should_disable_reasoning_summary(
  model: Option<&str>,
  supports_reasoning_summaries: bool,
) -> bool {
  !supports_reasoning_summaries || model_rejects_reasoning_summary(model)
}

pub(crate) fn parse_personality(value: Option<&str>) -> Option<Personality> {
  value
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(str::to_ascii_lowercase)
    .as_deref()
    .and_then(|value| match value {
      "none" => Some(Personality::None),
      "friendly" => Some(Personality::Friendly),
      "pragmatic" => Some(Personality::Pragmatic),
      _ => None,
    })
}

pub(crate) fn parse_service_tier_override(value: Option<&str>) -> Option<Option<ServiceTier>> {
  value
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(str::to_ascii_lowercase)
    .and_then(|value| match value.as_str() {
      "none" | "off" => Some(None),
      "fast" => Some(Some(ServiceTier::Fast)),
      "flex" => Some(Some(ServiceTier::Flex)),
      _ => None,
    })
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod policy_tests;
