use orbitdock_protocol::{SessionDetailSnapshot, SessionPermissionRules};
use serde::{Deserialize, Serialize};

mod handlers;
mod query;
mod settings_files;
mod snapshot;

pub use handlers::{add_permission_rule, get_permission_rules, remove_permission_rule};

#[derive(Debug, Serialize)]
pub struct PermissionRulesResponse {
  pub session_id: String,
  pub rules: SessionPermissionRules,
}

#[derive(Debug, Deserialize)]
pub struct ModifyPermissionRuleRequest {
  pub pattern: String,
  pub behavior: String,
  #[serde(default = "default_scope")]
  pub scope: String,
}

#[derive(Debug, Serialize)]
pub struct ModifyPermissionRuleResponse {
  pub ok: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_detail_snapshot: Option<SessionDetailSnapshot>,
}

fn default_scope() -> String {
  "project".into()
}
