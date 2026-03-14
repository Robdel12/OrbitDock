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
use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry, ToolRow};
use orbitdock_protocol::domain_events::{
    ToolFamily, ToolInvocationPayload, ToolKind, ToolResultPayload, ToolStatus,
    WorkerInvocationPayload, WorkerResultPayload,
};
use orbitdock_protocol::Provider;

fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
    row_entry(ConversationRow::Tool(row))
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
            invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
                worker_id: None,
                label: None,
                agent_type: Some("spawn_agent".to_string()),
                task_summary: Some(event.prompt),
                input: None,
            }),
            result: None,
            render_hints: Default::default(),
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
        invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
            worker_id: None,
            label: None,
            agent_type: Some("spawn_agent".to_string()),
            task_summary: None,
            input: None,
        }),
        result: Some(ToolResultPayload::Worker(WorkerResultPayload {
            worker_id: Some(receiver.clone()),
            summary: Some(output),
            output: None,
        })),
        render_hints: Default::default(),
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
            invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
                worker_id: Some(event.receiver_thread_id.to_string()),
                label: None,
                agent_type: Some("agent".to_string()),
                task_summary: Some(event.prompt.clone()),
                input: None,
            }),
            result: None,
            render_hints: Default::default(),
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
        invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
            worker_id: Some(event.receiver_thread_id.to_string()),
            label: None,
            agent_type: None,
            task_summary: None,
            input: None,
        }),
        result: Some(ToolResultPayload::Worker(WorkerResultPayload {
            worker_id: Some(event.receiver_thread_id.to_string()),
            summary: Some(output),
            output: None,
        })),
        render_hints: Default::default(),
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
            invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
                worker_id: None,
                label: None,
                agent_type: Some("wait".to_string()),
                task_summary: Some(format!("Waiting for {} agent(s)", receiver_ids.len())),
                input: None,
            }),
            result: None,
            render_hints: Default::default(),
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
        invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
            worker_id: None,
            label: None,
            agent_type: Some("wait".to_string()),
            task_summary: None,
            input: None,
        }),
        result: Some(ToolResultPayload::Worker(WorkerResultPayload {
            worker_id: None,
            summary: Some(output),
            output: None,
        })),
        render_hints: Default::default(),
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
            invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
                worker_id: Some(event.receiver_thread_id.to_string()),
                label: None,
                agent_type: Some("close".to_string()),
                task_summary: Some("Closing agent".to_string()),
                input: None,
            }),
            result: None,
            render_hints: Default::default(),
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
        invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
            worker_id: Some(event.receiver_thread_id.to_string()),
            label: None,
            agent_type: Some("close".to_string()),
            task_summary: None,
            input: None,
        }),
        result: Some(ToolResultPayload::Worker(WorkerResultPayload {
            worker_id: Some(event.receiver_thread_id.to_string()),
            summary: Some(output),
            output: None,
        })),
        render_hints: Default::default(),
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
            invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
                worker_id: Some(event.receiver_thread_id.to_string()),
                label: None,
                agent_type: Some("resume".to_string()),
                task_summary: Some("Resuming agent".to_string()),
                input: None,
            }),
            result: None,
            render_hints: Default::default(),
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
        invocation: ToolInvocationPayload::Worker(WorkerInvocationPayload {
            worker_id: Some(event.receiver_thread_id.to_string()),
            label: None,
            agent_type: Some("resume".to_string()),
            task_summary: None,
            input: None,
        }),
        result: Some(ToolResultPayload::Worker(WorkerResultPayload {
            worker_id: Some(event.receiver_thread_id.to_string()),
            summary: Some(output),
            output: None,
        })),
        render_hints: Default::default(),
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
