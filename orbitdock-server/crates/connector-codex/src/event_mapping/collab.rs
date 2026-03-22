use crate::runtime::row_entry;
use crate::workers::{
    agent_status_failed, build_authoritative_codex_subagent, build_codex_subagent_for_status,
    build_running_codex_subagent, collab_agent_label, iso_now,
};
use codex_protocol::protocol::{
    CollabAgentInteractionBeginEvent, CollabAgentInteractionEndEvent, CollabAgentSpawnBeginEvent,
    CollabAgentSpawnEndEvent, CollabCloseBeginEvent, CollabCloseEndEvent, CollabResumeBeginEvent,
    CollabResumeEndEvent, CollabWaitingBeginEvent, CollabWaitingEndEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{
    compute_tool_display, ConversationRow, ConversationRowEntry, ToolDisplayInput, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::json;

fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
    let row = with_display(row);
    row_entry(ConversationRow::Tool(row))
}

fn with_display(mut row: ToolRow) -> ToolRow {
    let invocation_ref = if row.invocation.is_object() {
        Some(&row.invocation)
    } else {
        None
    };
    let result_str = row
        .result
        .as_ref()
        .and_then(|v| v.get("output").and_then(|o| o.as_str()))
        .map(String::from);
    row.tool_display = Some(compute_tool_display(ToolDisplayInput {
        kind: row.kind,
        family: row.family,
        status: row.status,
        title: &row.title,
        subtitle: row.subtitle.as_deref(),
        summary: row.summary.as_deref(),
        duration_ms: row.duration_ms,
        invocation_input: invocation_ref,
        result_output: result_str.as_deref(),
    }));
    row
}

pub(crate) fn handle_collab_agent_spawn_begin(
    event: CollabAgentSpawnBeginEvent,
) -> Vec<ConnectorEvent> {
    let description = if event.prompt.trim().is_empty() {
        "Spawning agent".to_string()
    } else {
        event.prompt.clone()
    };

    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Agent,
            kind: ToolKind::SpawnAgent,
            status: ToolStatus::Running,
            title: "Spawn agent".to_string(),
            subtitle: Some(description),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "agent_type": "spawn_agent",
                "task_summary": event.prompt,
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        },
    ))]
}

pub(crate) fn handle_collab_agent_spawn_end(
    event: CollabAgentSpawnEndEvent,
) -> Vec<ConnectorEvent> {
    let receiver = event
        .new_thread_id
        .map(|id| id.to_string())
        .unwrap_or_else(|| "none".to_string());
    let receiver_label = collab_agent_label(
        &receiver,
        event.new_agent_nickname.as_deref(),
        event.new_agent_role.as_deref(),
    );
    let status_text = format!("{:?}", event.status);
    let output = format!(
        "sender: {}\nspawned: {}\nstatus: {}",
        event.sender_thread_id, receiver_label, status_text
    );
    let is_error = agent_status_failed(&event.status);
    let status = if is_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Agent,
        kind: ToolKind::SpawnAgent,
        status,
        title: String::new(),
        subtitle: None,
        summary: Some(output.clone()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: json!({
            "agent_type": "spawn_agent",
        }),
        result: Some(json!({
            "worker_id": receiver.clone(),
            "summary": output,
        })),
        render_hints: Default::default(),
        tool_display: None,
    });

    let mut connector_events = vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }];
    if let Some(thread_id) = event.new_thread_id {
        connector_events.push(ConnectorEvent::SubagentsUpdated {
            subagents: vec![build_codex_subagent_for_status(
                thread_id.to_string(),
                event.new_agent_role.clone(),
                event.new_agent_nickname.clone(),
                Some(event.prompt.clone()),
                Some(event.sender_thread_id.to_string()),
                &event.status,
            )],
        });
    }
    connector_events
}

pub(crate) fn handle_collab_agent_interaction_begin(
    event: CollabAgentInteractionBeginEvent,
) -> Vec<ConnectorEvent> {
    vec![
        ConnectorEvent::ConversationRowCreated(tool_row_entry(ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Agent,
            kind: ToolKind::SendAgentInput,
            status: ToolStatus::Running,
            title: "Agent interaction".to_string(),
            subtitle: Some(event.prompt.clone()),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "worker_id": event.receiver_thread_id.to_string(),
                "agent_type": "agent",
                "task_summary": event.prompt.clone(),
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        })),
        ConnectorEvent::SubagentsUpdated {
            subagents: vec![build_running_codex_subagent(
                event.receiver_thread_id.to_string(),
                None,
                None,
                Some(event.prompt),
                Some(event.sender_thread_id.to_string()),
            )],
        },
    ]
}

pub(crate) fn handle_collab_agent_interaction_end(
    event: CollabAgentInteractionEndEvent,
) -> Vec<ConnectorEvent> {
    let status_text = format!("{:?}", event.status);
    let receiver_label = collab_agent_label(
        &event.receiver_thread_id.to_string(),
        event.receiver_agent_nickname.as_deref(),
        event.receiver_agent_role.as_deref(),
    );
    let output = format!(
        "sender: {}\nreceiver: {}\nstatus: {}",
        event.sender_thread_id, receiver_label, status_text
    );
    let is_error = agent_status_failed(&event.status);
    let status = if is_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Agent,
        kind: ToolKind::SendAgentInput,
        status,
        title: String::new(),
        subtitle: None,
        summary: Some(output.clone()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: json!({
            "worker_id": event.receiver_thread_id.to_string(),
        }),
        result: Some(json!({
            "worker_id": event.receiver_thread_id.to_string(),
            "summary": output,
        })),
        render_hints: Default::default(),
        tool_display: None,
    });

    let mut connector_events = vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }];
    connector_events.push(ConnectorEvent::SubagentsUpdated {
        subagents: vec![build_codex_subagent_for_status(
            event.receiver_thread_id.to_string(),
            event.receiver_agent_role.clone(),
            event.receiver_agent_nickname.clone(),
            Some(event.prompt.clone()),
            Some(event.sender_thread_id.to_string()),
            &event.status,
        )],
    });
    connector_events
}

pub(crate) fn handle_collab_waiting_begin(event: CollabWaitingBeginEvent) -> Vec<ConnectorEvent> {
    let receiver_ids: Vec<String> = event
        .receiver_thread_ids
        .iter()
        .map(ToString::to_string)
        .collect();

    let subagents = if !event.receiver_agents.is_empty() {
        event
            .receiver_agents
            .iter()
            .map(|agent| {
                build_running_codex_subagent(
                    agent.thread_id.to_string(),
                    agent.agent_role.clone(),
                    agent.agent_nickname.clone(),
                    None,
                    Some(event.sender_thread_id.to_string()),
                )
            })
            .collect()
    } else {
        event
            .receiver_thread_ids
            .iter()
            .map(|thread_id| {
                build_running_codex_subagent(
                    thread_id.to_string(),
                    None,
                    None,
                    None,
                    Some(event.sender_thread_id.to_string()),
                )
            })
            .collect()
    };

    vec![
        ConnectorEvent::ConversationRowCreated(tool_row_entry(ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Agent,
            kind: ToolKind::WaitAgent,
            status: ToolStatus::Running,
            title: "Waiting for agents".to_string(),
            subtitle: Some(format!("Waiting for {} agent(s)", receiver_ids.len())),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "agent_type": "wait",
                "task_summary": format!("Waiting for {} agent(s)", receiver_ids.len()),
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        })),
        ConnectorEvent::SubagentsUpdated { subagents },
    ]
}

pub(crate) fn handle_collab_waiting_end(event: CollabWaitingEndEvent) -> Vec<ConnectorEvent> {
    let mut lines: Vec<String> = Vec::new();
    let mut has_error = false;
    let mut subagents = Vec::new();
    lines.push(format!("sender: {}", event.sender_thread_id));
    if !event.agent_statuses.is_empty() {
        for entry in &event.agent_statuses {
            let status_text = format!("{:?}", entry.status);
            let label = collab_agent_label(
                &entry.thread_id.to_string(),
                entry.agent_nickname.as_deref(),
                entry.agent_role.as_deref(),
            );
            lines.push(format!("{label}: {status_text}"));
            has_error = has_error || agent_status_failed(&entry.status);
            subagents.push(build_authoritative_codex_subagent(
                entry.thread_id.to_string(),
                entry.agent_role.clone(),
                entry.agent_nickname.clone(),
                None,
                Some(event.sender_thread_id.to_string()),
                &entry.status,
            ));
        }
    } else {
        for (thread_id, status) in &event.statuses {
            let status_text = format!("{:?}", status);
            lines.push(format!("{thread_id}: {status_text}"));
            has_error = has_error || agent_status_failed(status);
            subagents.push(build_authoritative_codex_subagent(
                thread_id.to_string(),
                None,
                None,
                None,
                Some(event.sender_thread_id.to_string()),
                status,
            ));
        }
    }
    let output = if lines.is_empty() {
        "No agent statuses reported".to_string()
    } else {
        lines.join("\n")
    };

    let status = if has_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Agent,
        kind: ToolKind::WaitAgent,
        status,
        title: String::new(),
        subtitle: None,
        summary: Some(output.clone()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: json!({
            "agent_type": "wait",
        }),
        result: Some(json!({
            "summary": output,
        })),
        render_hints: Default::default(),
        tool_display: None,
    });

    let mut connector_events = vec![ConnectorEvent::ConversationRowUpdated {
        row_id: event.call_id,
        entry,
    }];
    if !subagents.is_empty() {
        connector_events.push(ConnectorEvent::SubagentsUpdated { subagents });
    }
    connector_events
}

pub(crate) fn handle_collab_close_begin(event: CollabCloseBeginEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Agent,
            kind: ToolKind::CloseAgent,
            status: ToolStatus::Running,
            title: "Close agent".to_string(),
            subtitle: Some(event.receiver_thread_id.to_string()),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "worker_id": event.receiver_thread_id.to_string(),
                "agent_type": "close",
                "task_summary": "Closing agent",
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        },
    ))]
}

pub(crate) fn handle_collab_close_end(event: CollabCloseEndEvent) -> Vec<ConnectorEvent> {
    let status_text = format!("{:?}", event.status);
    let receiver_label = collab_agent_label(
        &event.receiver_thread_id.to_string(),
        event.receiver_agent_nickname.as_deref(),
        event.receiver_agent_role.as_deref(),
    );
    let output = format!(
        "sender: {}\nreceiver: {}\nstatus: {}",
        event.sender_thread_id, receiver_label, status_text
    );
    let is_error = agent_status_failed(&event.status);
    let status = if is_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Agent,
        kind: ToolKind::CloseAgent,
        status,
        title: String::new(),
        subtitle: None,
        summary: Some(output.clone()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: json!({
            "worker_id": event.receiver_thread_id.to_string(),
            "agent_type": "close",
        }),
        result: Some(json!({
            "worker_id": event.receiver_thread_id.to_string(),
            "summary": output,
        })),
        render_hints: Default::default(),
        tool_display: None,
    });

    vec![
        ConnectorEvent::ConversationRowUpdated {
            row_id: event.call_id,
            entry,
        },
        ConnectorEvent::SubagentsUpdated {
            subagents: vec![build_codex_subagent_for_status(
                event.receiver_thread_id.to_string(),
                event.receiver_agent_role.clone(),
                event.receiver_agent_nickname.clone(),
                None,
                Some(event.sender_thread_id.to_string()),
                &event.status,
            )],
        },
    ]
}

pub(crate) fn handle_collab_resume_begin(event: CollabResumeBeginEvent) -> Vec<ConnectorEvent> {
    vec![
        ConnectorEvent::ConversationRowCreated(tool_row_entry(ToolRow {
            id: event.call_id,
            provider: Provider::Codex,
            family: ToolFamily::Agent,
            kind: ToolKind::ResumeAgent,
            status: ToolStatus::Running,
            title: "Resume agent".to_string(),
            subtitle: Some(event.receiver_thread_id.to_string()),
            summary: None,
            preview: None,
            started_at: Some(iso_now()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "worker_id": event.receiver_thread_id.to_string(),
                "agent_type": "resume",
                "task_summary": "Resuming agent",
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        })),
        ConnectorEvent::SubagentsUpdated {
            subagents: vec![build_running_codex_subagent(
                event.receiver_thread_id.to_string(),
                event.receiver_agent_role.clone(),
                event.receiver_agent_nickname.clone(),
                None,
                Some(event.sender_thread_id.to_string()),
            )],
        },
    ]
}

pub(crate) fn handle_collab_resume_end(event: CollabResumeEndEvent) -> Vec<ConnectorEvent> {
    let status_text = format!("{:?}", event.status);
    let receiver_label = collab_agent_label(
        &event.receiver_thread_id.to_string(),
        event.receiver_agent_nickname.as_deref(),
        event.receiver_agent_role.as_deref(),
    );
    let output = format!(
        "sender: {}\nreceiver: {}\nstatus: {}",
        event.sender_thread_id, receiver_label, status_text
    );
    let is_error = agent_status_failed(&event.status);
    let status = if is_error {
        ToolStatus::Failed
    } else {
        ToolStatus::Completed
    };

    let entry = tool_row_entry(ToolRow {
        id: event.call_id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Agent,
        kind: ToolKind::ResumeAgent,
        status,
        title: String::new(),
        subtitle: None,
        summary: Some(output.clone()),
        preview: None,
        started_at: None,
        ended_at: Some(iso_now()),
        duration_ms: None,
        grouping_key: None,
        invocation: json!({
            "worker_id": event.receiver_thread_id.to_string(),
            "agent_type": "resume",
        }),
        result: Some(json!({
            "worker_id": event.receiver_thread_id.to_string(),
            "summary": output,
        })),
        render_hints: Default::default(),
        tool_display: None,
    });

    vec![
        ConnectorEvent::ConversationRowUpdated {
            row_id: event.call_id,
            entry,
        },
        ConnectorEvent::SubagentsUpdated {
            subagents: vec![build_authoritative_codex_subagent(
                event.receiver_thread_id.to_string(),
                event.receiver_agent_role.clone(),
                event.receiver_agent_nickname.clone(),
                None,
                Some(event.sender_thread_id.to_string()),
                &event.status,
            )],
        },
    ]
}
