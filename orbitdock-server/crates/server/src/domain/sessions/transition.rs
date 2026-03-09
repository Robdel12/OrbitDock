//! Re-exports the pure transition function from connector-core and provides
//! the server-specific `persist_op_to_command` bridge.

pub use orbitdock_connector_core::transition::*;

use crate::persistence::PersistCommand;

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
        PersistOp::MessageAppend {
            session_id,
            message,
        } => PersistCommand::MessageAppend {
            session_id,
            message,
        },
        PersistOp::MessageUpdate {
            session_id,
            message_id,
            content,
            tool_output,
            duration_ms,
            is_error,
            is_in_progress,
        } => PersistCommand::MessageUpdate {
            session_id,
            message_id,
            content,
            tool_output,
            duration_ms,
            is_error,
            is_in_progress,
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
            cwd,
            proposed_amendment,
            permission_suggestions,
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
            cwd,
            proposed_amendment,
            permission_suggestions,
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
            permission_mode: Some(permission_mode),
        },
    }
}
