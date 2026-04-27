use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};

pub(crate) fn is_passive_rollout_session(
  provider: Provider,
  codex_integration_mode: Option<CodexIntegrationMode>,
  transcript_path_present: bool,
) -> bool {
  provider == Provider::Codex
    && (codex_integration_mode == Some(CodexIntegrationMode::Passive)
      || (codex_integration_mode != Some(CodexIntegrationMode::Direct) && transcript_path_present))
}

pub(crate) fn is_takeover_eligible_passive_session(
  provider: Provider,
  codex_integration_mode: Option<CodexIntegrationMode>,
  claude_integration_mode: Option<ClaudeIntegrationMode>,
  transcript_path_present: bool,
) -> bool {
  match provider {
    Provider::Codex => {
      codex_integration_mode == Some(CodexIntegrationMode::Passive)
        || (codex_integration_mode.is_none() && transcript_path_present)
    }
    Provider::Claude => claude_integration_mode != Some(ClaudeIntegrationMode::Direct),
  }
}

#[cfg(test)]
#[path = "session_modes_tests.rs"]
mod tests;
