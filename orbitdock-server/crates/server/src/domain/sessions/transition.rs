//! Re-exports the pure transition function from connector-core and provides
//! the server-specific `persist_op_to_command` bridge.

pub use orbitdock_connector_core::transition::*;

use crate::infrastructure::persistence::PersistCommand;

/// Convert a transition PersistOp into the server's PersistCommand.
pub fn persist_op_to_command(op: PersistOp) -> PersistCommand {
    match op {
        PersistOp::SessionUpdate {
            id,
            status,
            work_status,
            last_activity_at,
        } => PersistCommand::SessionUpdate {
            id,
            status,
            work_status,
            last_activity_at,
        },
        PersistOp::SessionEnd { id, reason } => PersistCommand::SessionEnd { id, reason },
        PersistOp::RowAppend { session_id, entry } => PersistCommand::RowAppend {
            session_id,
            entry,
            sequence_tx: None,
        },
        PersistOp::RowUpsert { session_id, entry } => PersistCommand::RowUpsert {
            session_id,
            entry,
            sequence_tx: None,
        },
        PersistOp::TokensUpdate {
            session_id,
            usage,
            snapshot_kind,
        } => PersistCommand::TokensUpdate {
            session_id,
            usage,
            snapshot_kind,
        },
        PersistOp::TurnStateUpdate {
            session_id,
            diff,
            plan,
        } => PersistCommand::TurnStateUpdate {
            session_id,
            diff,
            plan,
        },
        PersistOp::TurnDiffInsert {
            session_id,
            turn_id,
            turn_seq,
            diff,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            snapshot_kind,
        } => PersistCommand::TurnDiffInsert {
            session_id,
            turn_id,
            turn_seq,
            diff,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            snapshot_kind,
        },
        PersistOp::SetCustomName {
            session_id,
            custom_name,
        } => PersistCommand::SetCustomName {
            session_id,
            custom_name,
        },
        PersistOp::ApprovalRequested {
            session_id,
            request_id,
            approval_type,
            tool_name,
            tool_input,
            command,
            file_path,
            diff,
            question,
            question_prompts,
            preview,
            permission_reason,
            requested_permissions,
            granted_permissions,
            cwd,
            proposed_amendment,
            permission_suggestions,
            elicitation_mode,
            elicitation_schema,
            elicitation_url,
            elicitation_message,
            mcp_server_name,
            network_host,
            network_protocol,
        } => PersistCommand::ApprovalRequested {
            session_id,
            request_id,
            approval_type,
            tool_name,
            tool_input,
            command,
            file_path,
            diff,
            question,
            question_prompts,
            preview: *preview,
            permission_reason,
            requested_permissions,
            granted_permissions,
            cwd,
            proposed_amendment,
            permission_suggestions,
            elicitation_mode,
            elicitation_schema,
            elicitation_url,
            elicitation_message,
            mcp_server_name,
            network_host,
            network_protocol,
        },
        PersistOp::EnvironmentUpdate {
            session_id,
            cwd,
            git_branch,
            git_sha,
            repository_root,
            is_worktree,
        } => PersistCommand::EnvironmentUpdate {
            session_id,
            cwd,
            git_branch,
            git_sha,
            repository_root,
            is_worktree,
        },
        PersistOp::ToolCountIncrement { session_id } => {
            PersistCommand::ToolCountIncrement { session_id }
        }
        PersistOp::ModelUpdate { session_id, model } => {
            PersistCommand::ModelUpdate { session_id, model }
        }
        PersistOp::SaveClaudeModels { models } => PersistCommand::SaveClaudeModels { models },
        PersistOp::PermissionModeUpdate {
            session_id,
            permission_mode,
        } => PersistCommand::SetSessionConfig {
            session_id,
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: Some(Some(permission_mode)),
            collaboration_mode: None,
            multi_agent: None,
            personality: None,
            service_tier: None,
            developer_instructions: None,
            model: None,
            effort: None,
            codex_config_source: None,
            codex_config_overrides_json: None,
        },
    }
}
