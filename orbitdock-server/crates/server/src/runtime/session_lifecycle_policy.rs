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
#[path = "session_lifecycle_policy_tests.rs"]
mod session_lifecycle_policy_tests;
