#[path = "cli/binary.rs"]
mod binary;
#[path = "cli/shared.rs"]
mod shared;

pub use binary::{BinaryCli, BinaryCommand, HookForwardType, SetupPath};
pub use shared::{
  binary_to_client_command, resolve_stdin, ApprovalAction, ApprovalDecision, AuthAction, Cli,
  CodexAction, Command, ConfigAction, ConfigKey, Effort, FsAction, McpAction, MissionAction,
  MissionProviderAction, MissionProviderConfigAction, MissionProviderConfigKey, ModelAction,
  PermissionMode, ProviderFilter, ReviewAction, ReviewStatusFilter, ReviewTagFilter, ServerAction,
  SessionAction, ShellAction, StatusFilter, UsageAction, WorktreeAction,
};

#[cfg(test)]
mod tests;
