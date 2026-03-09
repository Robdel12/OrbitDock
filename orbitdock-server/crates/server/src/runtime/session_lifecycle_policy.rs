use orbitdock_protocol::Provider;

#[derive(Debug, Clone)]
pub(crate) struct TakeoverConfigInputs {
    pub provider: Provider,
    pub session_model: Option<String>,
    pub session_effort: Option<String>,
    pub session_approval_policy: Option<String>,
    pub session_sandbox_mode: Option<String>,
    pub requested_model: Option<String>,
    pub requested_approval_policy: Option<String>,
    pub requested_sandbox_mode: Option<String>,
    pub requested_permission_mode: Option<String>,
    pub turn_context_model: Option<String>,
    pub turn_context_effort: Option<String>,
    pub stored_permission_mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TakeoverConfigPlan {
    pub effective_model: Option<String>,
    pub effective_effort: Option<String>,
    pub effective_approval_policy: Option<String>,
    pub effective_sandbox_mode: Option<String>,
    pub requested_permission_mode: Option<String>,
    pub effective_permission_mode: Option<String>,
}

pub(crate) fn plan_takeover_config(input: TakeoverConfigInputs) -> TakeoverConfigPlan {
    let effective_model = input
        .requested_model
        .or(input.turn_context_model)
        .or(input.session_model);
    let effective_effort = input.session_effort.or(input.turn_context_effort);
    let effective_approval_policy = input
        .requested_approval_policy
        .or(input.session_approval_policy);
    let effective_sandbox_mode = input.requested_sandbox_mode.or(input.session_sandbox_mode);
    let requested_permission_mode = input.requested_permission_mode;
    let effective_permission_mode = if input.provider == Provider::Claude {
        requested_permission_mode
            .clone()
            .or(input.stored_permission_mode)
    } else {
        None
    };

    TakeoverConfigPlan {
        effective_model,
        effective_effort,
        effective_approval_policy,
        effective_sandbox_mode,
        requested_permission_mode,
        effective_permission_mode,
    }
}

#[cfg(test)]
mod tests {
    use super::{plan_takeover_config, TakeoverConfigInputs};
    use orbitdock_protocol::Provider;

    #[test]
    fn takeover_plan_prefers_requested_values_and_uses_turn_context_fallbacks() {
        let plan = plan_takeover_config(TakeoverConfigInputs {
            provider: Provider::Codex,
            session_model: Some("gpt-4".into()),
            session_effort: Some("medium".into()),
            session_approval_policy: Some("on-request".into()),
            session_sandbox_mode: Some("workspace-write".into()),
            requested_model: Some("gpt-5".into()),
            requested_approval_policy: Some("never".into()),
            requested_sandbox_mode: None,
            requested_permission_mode: Some("acceptEdits".into()),
            turn_context_model: Some("turn-model".into()),
            turn_context_effort: Some("high".into()),
            stored_permission_mode: Some("bypassPermissions".into()),
        });

        assert_eq!(plan.effective_model.as_deref(), Some("gpt-5"));
        assert_eq!(plan.effective_effort.as_deref(), Some("medium"));
        assert_eq!(plan.effective_approval_policy.as_deref(), Some("never"));
        assert_eq!(
            plan.effective_sandbox_mode.as_deref(),
            Some("workspace-write")
        );
        assert_eq!(
            plan.requested_permission_mode.as_deref(),
            Some("acceptEdits")
        );
        assert_eq!(plan.effective_permission_mode, None);
    }

    #[test]
    fn takeover_plan_uses_stored_claude_permission_when_request_is_missing() {
        let plan = plan_takeover_config(TakeoverConfigInputs {
            provider: Provider::Claude,
            session_model: Some("claude-old".into()),
            session_effort: None,
            session_approval_policy: Some("on-request".into()),
            session_sandbox_mode: Some("workspace-write".into()),
            requested_model: None,
            requested_approval_policy: None,
            requested_sandbox_mode: Some("danger-full-access".into()),
            requested_permission_mode: None,
            turn_context_model: Some("claude-turn".into()),
            turn_context_effort: Some("low".into()),
            stored_permission_mode: Some("acceptEdits".into()),
        });

        assert_eq!(plan.effective_model.as_deref(), Some("claude-turn"));
        assert_eq!(plan.effective_effort.as_deref(), Some("low"));
        assert_eq!(
            plan.effective_approval_policy.as_deref(),
            Some("on-request")
        );
        assert_eq!(
            plan.effective_sandbox_mode.as_deref(),
            Some("danger-full-access")
        );
        assert_eq!(plan.requested_permission_mode, None);
        assert_eq!(
            plan.effective_permission_mode.as_deref(),
            Some("acceptEdits")
        );
    }
}
