use super::{is_passive_rollout_session, is_takeover_eligible_passive_session};
use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};

#[test]
fn passive_rollout_detection_matches_codex_transcript_rules() {
  assert!(is_passive_rollout_session(
    Provider::Codex,
    Some(CodexIntegrationMode::Passive),
    true,
  ));
  assert!(is_passive_rollout_session(Provider::Codex, None, true));
  assert!(!is_passive_rollout_session(
    Provider::Codex,
    Some(CodexIntegrationMode::Direct),
    true,
  ));
  assert!(!is_passive_rollout_session(
    Provider::Claude,
    Some(CodexIntegrationMode::Passive),
    true,
  ));
}

#[test]
fn takeover_eligibility_matches_provider_specific_directness() {
  assert!(is_takeover_eligible_passive_session(
    Provider::Codex,
    Some(CodexIntegrationMode::Passive),
    None,
    true,
  ));
  assert!(is_takeover_eligible_passive_session(
    Provider::Codex,
    None,
    None,
    true,
  ));
  assert!(!is_takeover_eligible_passive_session(
    Provider::Codex,
    Some(CodexIntegrationMode::Direct),
    None,
    true,
  ));
  assert!(is_takeover_eligible_passive_session(
    Provider::Claude,
    None,
    None,
    false,
  ));
  assert!(!is_takeover_eligible_passive_session(
    Provider::Claude,
    None,
    Some(ClaudeIntegrationMode::Direct),
    false,
  ));
}
