use super::{SharedEnvironmentTracker, SharedStringBuffers};
use crate::timeline::{dynamic_tool_output_to_text, tool_input_with_arguments};
use crate::workers::iso_now;
use codex_protocol::dynamic_tools::DynamicToolCallRequest;
use codex_protocol::protocol::DynamicToolCallResponseEvent;
use codex_protocol::protocol::{
    ExecCommandBeginEvent, ExecCommandEndEvent, ExecCommandOutputDeltaEvent, FileChange,
    McpToolCallBeginEvent, McpToolCallEndEvent, PatchApplyBeginEvent, PatchApplyEndEvent,
    TerminalInteractionEvent, ViewImageToolCallEvent, WebSearchBeginEvent, WebSearchEndEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use serde_json::json;

pub(crate) async fn handle_exec_command_begin(
    event: ExecCommandBeginEvent,
    output_buffers: &SharedStringBuffers,
    env_tracker: &SharedEnvironmentTracker,
) -> Vec<ConnectorEvent> {
    let command_str = event.command.join(" ");
    let tool_input = serde_json::to_string(&json!({
        "command": command_str.clone(),
        "argv": event.command.clone(),
        "cwd": event.cwd.display().to_string(),
        "source": event.source.to_string(),
        "call_id": event.call_id.clone(),
        "turn_id": event.turn_id.clone(),
        "process_id": event.process_id.clone(),
        "interaction_input": event.interaction_input.clone(),
        "parsed_cmd": event.parsed_cmd.clone(),
    }))
    .ok();

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
                cwd: Some(new_cwd),
                git_branch: new_branch,
                git_sha: new_sha,
            });
        }
    }

    connector_events.push(ConnectorEvent::MessageCreated(
        orbitdock_protocol::Message {
            id: event.call_id.clone(),
            session_id: String::new(),
            sequence: None,
            message_type: orbitdock_protocol::MessageType::Tool,
            content: command_str,
            tool_name: Some("Bash".to_string()),
            tool_input,
            tool_output: None,
            is_error: false,
            is_in_progress: true,
            timestamp: iso_now(),
            duration_ms: None,
            images: vec![],
        },
    ));

    connector_events
}

pub(crate) async fn handle_exec_command_output_delta(
    event: ExecCommandOutputDeltaEvent,
    output_buffers: &SharedStringBuffers,
) -> Vec<ConnectorEvent> {
    let chunk_str = String::from_utf8_lossy(&event.chunk).to_string();
    let mut accumulated = String::new();
    {
        let mut buffers = output_buffers.lock().await;
        if let Some(buffer) = buffers.get_mut(&event.call_id) {
            buffer.push_str(&chunk_str);
            accumulated = buffer.clone();
        }
    }

    if accumulated.is_empty() {
        vec![]
    } else {
        vec![ConnectorEvent::MessageUpdated {
            message_id: event.call_id,
            content: None,
            tool_output: Some(accumulated),
            is_error: None,
            is_in_progress: Some(true),
            duration_ms: None,
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

    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output_str),
        is_error: Some(event.exit_code != 0),
        is_in_progress: Some(false),
        duration_ms: Some(event.duration.as_millis() as u64),
    }]
}

pub(crate) fn handle_patch_apply_begin(event: PatchApplyBeginEvent) -> Vec<ConnectorEvent> {
    let files: Vec<String> = event
        .changes
        .keys()
        .map(|path| path.display().to_string())
        .collect();
    let first_file = files.first().cloned().unwrap_or_default();
    let content = files.join(", ");

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

    let tool_input = serde_json::to_string(&json!({
        "file_path": first_file,
        "unified_diff": unified_diff,
        "files": files,
        "call_id": event.call_id,
        "turn_id": event.turn_id,
        "auto_approved": event.auto_approved,
    }))
    .unwrap_or_default();

    vec![ConnectorEvent::MessageCreated(
        orbitdock_protocol::Message {
            id: event.call_id.clone(),
            session_id: String::new(),
            sequence: None,
            message_type: orbitdock_protocol::MessageType::Tool,
            content,
            tool_name: Some("Edit".to_string()),
            tool_input: Some(tool_input),
            tool_output: None,
            is_error: false,
            is_in_progress: true,
            timestamp: iso_now(),
            duration_ms: None,
            images: vec![],
        },
    )]
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

    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output),
        is_error: Some(!event.success),
        is_in_progress: Some(false),
        duration_ms: None,
    }]
}

pub(crate) fn handle_mcp_tool_call_begin(event: McpToolCallBeginEvent) -> Vec<ConnectorEvent> {
    let server = event.invocation.server.clone();
    let tool = event.invocation.tool.clone();
    let call_id = event.call_id.clone();
    let tool_name = format!("mcp__{}__{}", server, tool);
    let input_str = tool_input_with_arguments(
        json!({
            "call_id": call_id.clone(),
            "server": server,
            "tool": tool,
        }),
        event.invocation.arguments.as_ref(),
    );

    vec![ConnectorEvent::MessageCreated(
        orbitdock_protocol::Message {
            id: call_id,
            session_id: String::new(),
            sequence: None,
            message_type: orbitdock_protocol::MessageType::Tool,
            content: event.invocation.tool.clone(),
            tool_name: Some(tool_name),
            tool_input: input_str,
            tool_output: None,
            is_error: false,
            is_in_progress: true,
            timestamp: iso_now(),
            duration_ms: None,
            images: vec![],
        },
    )]
}

pub(crate) fn handle_mcp_tool_call_end(event: McpToolCallEndEvent) -> Vec<ConnectorEvent> {
    let (output, is_error) = match &event.result {
        Ok(result) => (serde_json::to_string(result).unwrap_or_default(), false),
        Err(message) => (message.clone(), true),
    };

    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output),
        is_error: Some(is_error),
        is_in_progress: Some(false),
        duration_ms: Some(event.duration.as_millis() as u64),
    }]
}

pub(crate) fn handle_web_search_begin(event: WebSearchBeginEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::MessageCreated(
        orbitdock_protocol::Message {
            id: event.call_id,
            session_id: String::new(),
            sequence: None,
            message_type: orbitdock_protocol::MessageType::Tool,
            content: "Searching the web".to_string(),
            tool_name: Some("websearch".to_string()),
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: true,
            timestamp: iso_now(),
            duration_ms: None,
            images: vec![],
        },
    )]
}

pub(crate) fn handle_web_search_end(event: WebSearchEndEvent) -> Vec<ConnectorEvent> {
    let output = serde_json::to_string_pretty(&event.action)
        .or_else(|_| serde_json::to_string(&event.action))
        .unwrap_or_default();
    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: Some(event.query),
        tool_output: Some(output),
        is_error: Some(false),
        is_in_progress: Some(false),
        duration_ms: None,
    }]
}

pub(crate) fn handle_view_image_tool_call(event: ViewImageToolCallEvent) -> Vec<ConnectorEvent> {
    let path = event.path.to_string_lossy().to_string();
    vec![ConnectorEvent::MessageCreated(
        orbitdock_protocol::Message {
            id: event.call_id,
            session_id: String::new(),
            sequence: None,
            message_type: orbitdock_protocol::MessageType::Tool,
            content: path.clone(),
            tool_name: Some("view_image".to_string()),
            tool_input: serde_json::to_string(&json!({ "path": path })).ok(),
            tool_output: Some("Image loaded".to_string()),
            is_error: false,
            is_in_progress: false,
            timestamp: iso_now(),
            duration_ms: None,
            images: vec![orbitdock_protocol::ImageInput {
                input_type: "path".to_string(),
                value: event.path.to_string_lossy().to_string(),
                ..Default::default()
            }],
        },
    )]
}

pub(crate) fn handle_dynamic_tool_call_request(
    event: DynamicToolCallRequest,
) -> Vec<ConnectorEvent> {
    let call_id = event.call_id.clone();
    let turn_id = event.turn_id.clone();
    let tool = event.tool.clone();
    vec![ConnectorEvent::MessageCreated(
        orbitdock_protocol::Message {
            id: call_id.clone(),
            session_id: String::new(),
            sequence: None,
            message_type: orbitdock_protocol::MessageType::Tool,
            content: tool.clone(),
            tool_name: Some(tool),
            tool_input: tool_input_with_arguments(
                json!({
                    "call_id": call_id,
                    "turn_id": turn_id,
                }),
                Some(&event.arguments),
            ),
            tool_output: None,
            is_error: false,
            is_in_progress: true,
            timestamp: iso_now(),
            duration_ms: None,
            images: vec![],
        },
    )]
}

pub(crate) fn handle_dynamic_tool_call_response(
    event: DynamicToolCallResponseEvent,
) -> Vec<ConnectorEvent> {
    let output = dynamic_tool_output_to_text(&event.content_items, event.error);
    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: output,
        is_error: Some(!event.success),
        is_in_progress: Some(false),
        duration_ms: Some(event.duration.as_millis() as u64),
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

    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(next_output),
        is_error: None,
        is_in_progress: Some(true),
        duration_ms: None,
    }]
}
