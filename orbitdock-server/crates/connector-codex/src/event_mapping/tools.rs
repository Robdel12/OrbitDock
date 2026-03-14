use super::{SharedEnvironmentTracker, SharedStringBuffers};
use crate::runtime::row_entry;
use crate::timeline::dynamic_tool_output_to_text;
use crate::workers::iso_now;
use codex_protocol::dynamic_tools::DynamicToolCallRequest;
use codex_protocol::protocol::DynamicToolCallResponseEvent;
use codex_protocol::protocol::{
    ExecCommandBeginEvent, ExecCommandEndEvent, ExecCommandOutputDeltaEvent, FileChange,
    McpToolCallBeginEvent, McpToolCallEndEvent, PatchApplyBeginEvent, PatchApplyEndEvent,
    TerminalInteractionEvent, ViewImageToolCallEvent, WebSearchBeginEvent, WebSearchEndEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry, ToolRow};
use orbitdock_protocol::domain_events::{
    CommandExecutionPayload, FileChangePayload, GenericInvocationPayload, GenericResultPayload,
    ImageViewPayload, McpToolPayload, ToolFamily, ToolInvocationPayload, ToolKind,
    ToolResultPayload, ToolStatus, WebSearchPayload,
};
use orbitdock_protocol::Provider;
use serde_json::json;

fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
    row_entry(ConversationRow::Tool(row))
}

pub(crate) async fn handle_exec_command_begin(
    event: ExecCommandBeginEvent,
    output_buffers: &SharedStringBuffers,
    env_tracker: &SharedEnvironmentTracker,
) -> Vec<ConnectorEvent> {
    let command_str = event.command.join(" ");

    {
        let mut buffers = output_buffers.lock().await;
        buffers.insert(event.call_id.clone(), String::new());
    }

    let new_cwd = event.cwd.to_string_lossy().to_string();
    let git_info = codex_core::git_info::collect_git_info(&event.cwd).await;
    let (new_branch, new_sha) = match git_info {
        Some(info) => (info.branch, info.commit_hash),
        None => (None, None),
    };

    let mut connector_events = Vec::new();
    {
        let mut tracker = env_tracker.lock().await;
        let cwd_changed = tracker.cwd.as_deref() != Some(&new_cwd);
        let branch_changed = tracker.branch != new_branch;
        let sha_changed = tracker.sha != new_sha;
        if cwd_changed || branch_changed || sha_changed {
            tracker.cwd = Some(new_cwd.clone());
            tracker.branch = new_branch.clone();
            tracker.sha = new_sha.clone();
            connector_events.push(ConnectorEvent::EnvironmentChanged {
                cwd: Some(new_cwd.clone()),
                git_branch: new_branch,
                git_sha: new_sha,
            });
        }
    }

    connector_events.push(ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: event.call_id.clone(),
            provider: Provider::Codex,
            family: ToolFamily::Shell,
            kind: ToolKind::Bash,
            status: ToolStatus::Running,
            title: command_str.clone(),
            subtitle: Some(new_cwd),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::Shell(CommandExecutionPayload {
                command: command_str,
                cwd: Some(event.cwd.display().to_string()),
                input: None,
                output: None,
                exit_code: None,
            }),
            result: None,
            render_hints: Default::default(),
        },
    )));

    connector_events
}

pub(crate) async fn handle_exec_command_output_delta(
    event: ExecCommandOutputDeltaEvent,
    output_buffers: &SharedStringBuffers,
) -> Vec<ConnectorEvent> {
    let chunk_str = String::from_utf8_lossy(&event.chunk).to_string();
    let accumulated = {
        let mut buffers = output_buffers.lock().await;
        if let Some(buffer) = buffers.get_mut(&event.call_id) {
            buffer.push_str(&chunk_str);
            buffer.clone()
        } else {
            return vec![];
        }
    };

    if accumulated.is_empty() {
        vec![]
    } else {
        let entry = tool_row_entry(ToolRow {
            id: event.call_id.clone(),
            provider: Provider::Codex,
            family: ToolFamily::Shell,
            kind: ToolKind::Bash,
            status: ToolStatus::Running,
            title: String::new(),
            subtitle: None,
            summary: None,
            preview: None,
            started_at: None,
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::Shell(CommandExecutionPayload {
                command: String::new(),
                cwd: None,
                input: None,
                output: Some(accumulated),
                exit_code: None,
            }),
            result: None,
            render_hints: Default::default(),
        });
        vec![ConnectorEvent::ConversationRowUpdated {
            row_id: event.call_id,
            entry,
        }]
    }
}

pub(crate) async fn handle_exec_command_end(
    event: ExecCommandEndEvent,
    output_buffers: &SharedStringBuffers,
) -> Vec<ConnectorEvent> {
    let output = {
        let mut buffers = output_buffers.lock().await;
        buffers
            .remove(&event.call_id)
            .unwrap_or_else(|| event.aggregated_output.clone())
    };

    let output_str = if output.is_empty() {
        event.aggregated_output.clone()
    } else {
        output
    };

    let is_error = event.exit_code != 0;
    let duration_ms = Some(event.duration.as_millis() as u64);
    let status = if is_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Shell,
        kind: ToolKind::Bash,
        status,
        title: String::new(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms,
        grouping_key: None,
        invocation: ToolInvocationPayload::Shell(CommandExecutionPayload {
            command: String::new(),
            cwd: None,
            input: None,
            output: None,
            exit_code: Some(event.exit_code),
        }),
        result: Some(ToolResultPayload::Shell(CommandExecutionPayload {
            command: String::new(),
            cwd: None,
            input: None,
            output: Some(output_str),
            exit_code: Some(event.exit_code),
        })),
        render_hints: Default::default(),
    });
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }]
}

pub(crate) fn handle_patch_apply_begin(event: PatchApplyBeginEvent) -> Vec<ConnectorEvent> {
    let files: Vec<String> = event
        .changes
        .keys()
        .map(|path| path.display().to_string())
        .collect();
    let first_file = files.first().cloned().unwrap_or_default();

    let unified_diff = event
        .changes
        .iter()
        .map(|(path, change)| match change {
            FileChange::Add { content } => {
                format!(
                    "--- /dev/null\n+++ {}\n{}",
                    path.display(),
                    content
                        .lines()
                        .map(|line| format!("+{}", line))
                        .collect::<Vec<_>>()
                        .join("\n")
                )
            }
            FileChange::Delete { content } => {
                format!(
                    "--- {}\n+++ /dev/null\n{}",
                    path.display(),
                    content
                        .lines()
                        .map(|line| format!("-{}", line))
                        .collect::<Vec<_>>()
                        .join("\n")
                )
            }
            FileChange::Update { unified_diff, .. } => {
                format!(
                    "--- {}\n+++ {}\n{}",
                    path.display(),
                    path.display(),
                    unified_diff
                )
            }
        })
        .collect::<Vec<_>>()
        .join("\n\n");

    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: event.call_id.clone(),
            provider: Provider::Codex,
            family: ToolFamily::FileChange,
            kind: ToolKind::Edit,
            status: ToolStatus::Running,
            title: first_file.clone(),
            subtitle: Some(files.join(", ")),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::FileChange(FileChangePayload {
                path: Some(first_file),
                diff: Some(unified_diff),
                summary: None,
                additions: None,
                deletions: None,
            }),
            result: None,
            render_hints: Default::default(),
        },
    ))]
}

pub(crate) fn handle_patch_apply_end(event: PatchApplyEndEvent) -> Vec<ConnectorEvent> {
    let mut output_lines: Vec<String> = Vec::new();
    output_lines.push(format!("status: {:?}", event.status));
    if event.success {
        output_lines.push("result: applied successfully".to_string());
    } else {
        output_lines.push("result: failed".to_string());
    }
    if !event.stdout.trim().is_empty() {
        output_lines.push(String::new());
        output_lines.push("stdout:".to_string());
        output_lines.push(event.stdout);
    }
    if !event.stderr.trim().is_empty() {
        output_lines.push(String::new());
        output_lines.push("stderr:".to_string());
        output_lines.push(event.stderr);
    }
    let output = output_lines.join("\n");

    let status = if event.success {
        ToolStatus::Completed
    } else {
        ToolStatus::Failed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::FileChange,
        kind: ToolKind::Edit,
        status,
        title: String::new(),
        subtitle: None,
        summary: Some(output.clone()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: ToolInvocationPayload::FileChange(FileChangePayload {
            path: None,
            diff: None,
            summary: Some(output.clone()),
            additions: None,
            deletions: None,
        }),
        result: Some(ToolResultPayload::Generic(GenericResultPayload {
            tool_name: "Edit".to_string(),
            raw_output: Some(json!(output)),
            summary: None,
        })),
        render_hints: Default::default(),
    });
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }]
}

pub(crate) fn handle_mcp_tool_call_begin(event: McpToolCallBeginEvent) -> Vec<ConnectorEvent> {
    let server = event.invocation.server.clone();
    let tool = event.invocation.tool.clone();
    let call_id = event.call_id.clone();

    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: call_id,
            provider: Provider::Codex,
            family: ToolFamily::Mcp,
            kind: ToolKind::McpToolCall,
            status: ToolStatus::Running,
            title: tool.clone(),
            subtitle: Some(server.clone()),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::McpTool(McpToolPayload {
                server,
                tool_name: tool,
                input: event
                    .invocation
                    .arguments
                    .as_ref()
                    .and_then(|args| serde_json::to_value(args).ok()),
                output: None,
            }),
            result: None,
            render_hints: Default::default(),
        },
    ))]
}

pub(crate) fn handle_mcp_tool_call_end(event: McpToolCallEndEvent) -> Vec<ConnectorEvent> {
    let (output_value, is_error) = match &event.result {
        Ok(result) => (serde_json::to_value(result).ok(), false),
        Err(message) => (Some(json!(message)), true),
    };

    let status = if is_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Mcp,
        kind: ToolKind::McpToolCall,
        status,
        title: String::new(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: Some(event.duration.as_millis() as u64),
        grouping_key: None,
        invocation: ToolInvocationPayload::McpTool(McpToolPayload {
            server: event.invocation.server.clone(),
            tool_name: event.invocation.tool.clone(),
            input: None,
            output: output_value.clone(),
        }),
        result: Some(ToolResultPayload::McpTool(GenericResultPayload {
            tool_name: event.invocation.tool.clone(),
            raw_output: output_value,
            summary: None,
        })),
        render_hints: Default::default(),
    });
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }]
}

pub(crate) fn handle_web_search_begin(event: WebSearchBeginEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Web,
            kind: ToolKind::WebSearch,
            status: ToolStatus::Running,
            title: "Searching the web".to_string(),
            subtitle: None,
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::WebSearch(WebSearchPayload {
                query: String::new(),
                results: vec![],
            }),
            result: None,
            render_hints: Default::default(),
        },
    ))]
}

pub(crate) fn handle_web_search_end(event: WebSearchEndEvent) -> Vec<ConnectorEvent> {
    let output = serde_json::to_string_pretty(&event.action)
        .or_else(|_| serde_json::to_string(&event.action))
        .unwrap_or_default();
    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Web,
        kind: ToolKind::WebSearch,
        status: ToolStatus::Completed,
        title: event.query.clone(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: ToolInvocationPayload::WebSearch(WebSearchPayload {
            query: event.query,
            results: vec![],
        }),
        result: Some(ToolResultPayload::Generic(GenericResultPayload {
            tool_name: "websearch".to_string(),
            raw_output: Some(json!(output)),
            summary: None,
        })),
        render_hints: Default::default(),
    });
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }]
}

pub(crate) fn handle_view_image_tool_call(event: ViewImageToolCallEvent) -> Vec<ConnectorEvent> {
    let path = event.path.to_string_lossy().to_string();
    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Image,
            kind: ToolKind::ViewImage,
            status: ToolStatus::Completed,
            title: path.clone(),
            subtitle: None,
            summary: Some("Image loaded".to_string()),
            preview: None,
            started_at: Some(iso_now()),
            ended_at: Some(iso_now()),
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::ImageView(ImageViewPayload {
                image_paths: vec![path],
                caption: None,
            }),
            result: Some(ToolResultPayload::ImageView(ImageViewPayload {
                image_paths: vec![event.path.to_string_lossy().to_string()],
                caption: Some("Image loaded".to_string()),
            })),
            render_hints: Default::default(),
        },
    ))]
}

pub(crate) fn handle_dynamic_tool_call_request(
    event: DynamicToolCallRequest,
) -> Vec<ConnectorEvent> {
    let call_id = event.call_id.clone();
    let tool = event.tool.clone();
    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: call_id,
            provider: Provider::Codex,
            family: ToolFamily::Generic,
            kind: ToolKind::DynamicToolCall,
            status: ToolStatus::Running,
            title: tool.clone(),
            subtitle: None,
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: ToolInvocationPayload::Generic(GenericInvocationPayload {
                tool_name: tool,
                raw_input: Some(event.arguments),
            }),
            result: None,
            render_hints: Default::default(),
        },
    ))]
}

pub(crate) fn handle_dynamic_tool_call_response(
    event: DynamicToolCallResponseEvent,
) -> Vec<ConnectorEvent> {
    let output = dynamic_tool_output_to_text(&event.content_items, event.error);
    let status = if event.success {
        ToolStatus::Completed
    } else {
        ToolStatus::Failed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Generic,
        kind: ToolKind::DynamicToolCall,
        status,
        title: String::new(),
        subtitle: None,
        summary: output.clone(),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: Some(event.duration.as_millis() as u64),
        grouping_key: None,
        invocation: ToolInvocationPayload::Generic(GenericInvocationPayload {
            tool_name: String::new(),
            raw_input: None,
        }),
        result: Some(ToolResultPayload::Generic(GenericResultPayload {
            tool_name: String::new(),
            raw_output: output.as_ref().map(|o| json!(o)),
            summary: output,
        })),
        render_hints: Default::default(),
    });
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }]
}

pub(crate) async fn handle_terminal_interaction(
    event: TerminalInteractionEvent,
    output_buffers: &SharedStringBuffers,
) -> Vec<ConnectorEvent> {
    let snippet = format!("\n[stdin] {}\n", event.stdin);
    let next_output = {
        let mut buffers = output_buffers.lock().await;
        let entry = buffers.entry(event.call_id.clone()).or_default();
        entry.push_str(&snippet);
        entry.clone()
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Shell,
        kind: ToolKind::Bash,
        status: ToolStatus::Running,
        title: String::new(),
        subtitle: None,
        summary: None,
        preview: None,
        started_at: None,
        ended_at: None,
        duration_ms: None,
        grouping_key: None,
        invocation: ToolInvocationPayload::Shell(CommandExecutionPayload {
            command: String::new(),
            cwd: None,
            input: Some(event.stdin),
            output: Some(next_output),
            exit_code: None,
        }),
        result: None,
        render_hints: Default::default(),
    });
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }]
}
