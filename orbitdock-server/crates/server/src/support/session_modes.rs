use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus};

pub(crate) fn is_passive_rollout_session(
    provider: Provider,
    codex_integration_mode: Option<CodexIntegrationMode>,
    transcript_path_present: bool,
) -> bool {
    provider == Provider::Codex
        && (codex_integration_mode == Some(CodexIntegrationMode::Passive)
            || (codex_integration_mode != Some(CodexIntegrationMode::Direct)
                && transcript_path_present))
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

pub(crate) fn should_reactivate_passive_codex_session(
    provider: Provider,
    status: SessionStatus,
    codex_integration_mode: Option<CodexIntegrationMode>,
    transcript_path_present: bool,
    transcript_modified_at_secs: Option<u64>,
    last_activity_at_secs: Option<u64>,
) -> bool {
    if status != SessionStatus::Ended
        || !is_passive_rollout_session(provider, codex_integration_mode, transcript_path_present)
    {
        return false;
    }

    transcript_modified_at_secs
        .zip(last_activity_at_secs)
        .map(|(modified_at, last_activity_at)| modified_at > last_activity_at)
        .unwrap_or(false)
}

pub(crate) fn needs_lazy_connector(
    provider: Provider,
    status: SessionStatus,
    codex_integration_mode: Option<CodexIntegrationMode>,
    claude_integration_mode: Option<ClaudeIntegrationMode>,
    has_codex_connector: bool,
    has_claude_connector: bool,
) -> bool {
    let is_active_codex_direct = provider == Provider::Codex
        && status == SessionStatus::Active
        && codex_integration_mode == Some(CodexIntegrationMode::Direct)
        && !has_codex_connector;
    let is_claude_direct_needing_connector = provider == Provider::Claude
        && claude_integration_mode == Some(ClaudeIntegrationMode::Direct)
        && status == SessionStatus::Active
        && !has_claude_connector;

    is_active_codex_direct || is_claude_direct_needing_connector
}

#[cfg(test)]
mod tests {
    use super::{
        is_passive_rollout_session, is_takeover_eligible_passive_session, needs_lazy_connector,
        should_reactivate_passive_codex_session,
    };
    use orbitdock_protocol::{
        ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus,
    };

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

    #[test]
    fn passive_codex_reactivation_requires_newer_transcript_activity() {
        assert!(should_reactivate_passive_codex_session(
            Provider::Codex,
            SessionStatus::Ended,
            Some(CodexIntegrationMode::Passive),
            true,
            Some(200),
            Some(100),
        ));
        assert!(!should_reactivate_passive_codex_session(
            Provider::Codex,
            SessionStatus::Ended,
            Some(CodexIntegrationMode::Passive),
            true,
            Some(100),
            Some(200),
        ));
        assert!(!should_reactivate_passive_codex_session(
            Provider::Claude,
            SessionStatus::Ended,
            Some(CodexIntegrationMode::Passive),
            true,
            Some(200),
            Some(100),
        ));
    }

    #[test]
    fn lazy_connector_detection_matches_direct_active_sessions_only() {
        assert!(needs_lazy_connector(
            Provider::Codex,
            SessionStatus::Active,
            Some(CodexIntegrationMode::Direct),
            None,
            false,
            false,
        ));
        assert!(needs_lazy_connector(
            Provider::Claude,
            SessionStatus::Active,
            None,
            Some(ClaudeIntegrationMode::Direct),
            false,
            false,
        ));
        assert!(!needs_lazy_connector(
            Provider::Codex,
            SessionStatus::Ended,
            Some(CodexIntegrationMode::Direct),
            None,
            false,
            false,
        ));
        assert!(!needs_lazy_connector(
            Provider::Claude,
            SessionStatus::Active,
            None,
            Some(ClaudeIntegrationMode::Direct),
            false,
            true,
        ));
    }
}
