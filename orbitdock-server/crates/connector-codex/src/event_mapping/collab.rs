use crate::workers::{
    agent_status_failed, build_authoritative_codex_subagent, build_inflight_codex_subagent,
    collab_agent_label, iso_now,
};
use codex_protocol::protocol::{
    CollabAgentInteractionBeginEvent, CollabAgentInteractionEndEvent, CollabAgentSpawnBeginEvent,
    CollabAgentSpawnEndEvent, CollabCloseBeginEvent, CollabCloseEndEvent,
    CollabResumeBeginEvent, CollabResumeEndEvent, CollabWaitingBeginEvent,
    CollabWaitingEndEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use serde_json::json;

pub(crate) fn handle_collab_agent_spawn_begin(
    event: CollabAgentSpawnBeginEvent,
) -> Vec<ConnectorEvent> {
    let description = if event.prompt.trim().is_empty() {
        "Spawning agent".to_string()
    } else {
        event.prompt.clone()
    };
    let tool_input = serde_json::to_string(&json!({
        "subagent_type": "spawn_agent",
        "description": description,
        "sender_thread_id": event.sender_thread_id.to_string(),
        "prompt": event.prompt,
    }))
    .ok();
    vec![ConnectorEvent::MessageCreated(orbitdock_protocol::Message {
        id: event.call_id,
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Spawn agent".to_string(),
        tool_name: Some("task".to_string()),
        tool_input,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    })]
}

pub(crate) fn handle_collab_agent_spawn_end(event: CollabAgentSpawnEndEvent) -> Vec<ConnectorEvent> {
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
    let mut connector_events = vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output),
        is_error: Some(agent_status_failed(&event.status)),
        is_in_progress: Some(false),
        duration_ms: None,
    }];
    if let Some(thread_id) = event.new_thread_id {
        let maybe_subagent = build_inflight_codex_subagent(
            thread_id.to_string(),
            event.new_agent_role.clone(),
            event.new_agent_nickname.clone(),
            Some(event.prompt.clone()),
            Some(event.sender_thread_id.to_string()),
            &event.status,
        );
        if let Some(subagent) = maybe_subagent {
            connector_events.push(ConnectorEvent::SubagentsUpdated {
                subagents: vec![subagent],
            });
        }
    }
    connector_events
}

pub(crate) fn handle_collab_agent_interaction_begin(
    event: CollabAgentInteractionBeginEvent,
) -> Vec<ConnectorEvent> {
    let tool_input = serde_json::to_string(&json!({
        "subagent_type": "agent",
        "subagent_id": event.receiver_thread_id.to_string(),
        "description": event.prompt,
        "sender_thread_id": event.sender_thread_id.to_string(),
        "receiver_thread_id": event.receiver_thread_id.to_string(),
    }))
    .ok();
    vec![ConnectorEvent::MessageCreated(orbitdock_protocol::Message {
        id: event.call_id,
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Agent interaction".to_string(),
        tool_name: Some("task".to_string()),
        tool_input,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    })]
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
    let mut connector_events = vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output),
        is_error: Some(agent_status_failed(&event.status)),
        is_in_progress: Some(false),
        duration_ms: None,
    }];
    if let Some(subagent) = build_inflight_codex_subagent(
        event.receiver_thread_id.to_string(),
        event.receiver_agent_role.clone(),
        event.receiver_agent_nickname.clone(),
        Some(event.prompt.clone()),
        Some(event.sender_thread_id.to_string()),
        &event.status,
    ) {
        connector_events.push(ConnectorEvent::SubagentsUpdated {
            subagents: vec![subagent],
        });
    }
    connector_events
}

pub(crate) fn handle_collab_waiting_begin(event: CollabWaitingBeginEvent) -> Vec<ConnectorEvent> {
    let receiver_ids: Vec<String> = event
        .receiver_thread_ids
        .iter()
        .map(ToString::to_string)
        .collect();
    let receiver_agents: Vec<serde_json::Value> = event
        .receiver_agents
        .iter()
        .map(|agent| {
            json!({
                "thread_id": agent.thread_id.to_string(),
                "agent_nickname": agent.agent_nickname,
                "agent_role": agent.agent_role,
            })
        })
        .collect();
    let tool_input = serde_json::to_string(&json!({
        "subagent_type": "wait",
        "description": format!("Waiting for {} agent(s)", receiver_ids.len()),
        "sender_thread_id": event.sender_thread_id.to_string(),
        "receiver_thread_ids": receiver_ids,
        "receiver_agents": receiver_agents,
    }))
    .ok();
    vec![ConnectorEvent::MessageCreated(orbitdock_protocol::Message {
        id: event.call_id,
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Waiting for agents".to_string(),
        tool_name: Some("task".to_string()),
        tool_input,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    })]
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
    let mut connector_events = vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output),
        is_error: Some(has_error),
        is_in_progress: Some(false),
        duration_ms: None,
    }];
    if !subagents.is_empty() {
        connector_events.push(ConnectorEvent::SubagentsUpdated { subagents });
    }
    connector_events
}

pub(crate) fn handle_collab_close_begin(event: CollabCloseBeginEvent) -> Vec<ConnectorEvent> {
    let tool_input = serde_json::to_string(&json!({
        "subagent_type": "close",
        "subagent_id": event.receiver_thread_id.to_string(),
        "description": "Closing agent",
        "sender_thread_id": event.sender_thread_id.to_string(),
        "receiver_thread_id": event.receiver_thread_id.to_string(),
    }))
    .ok();
    vec![ConnectorEvent::MessageCreated(orbitdock_protocol::Message {
        id: event.call_id,
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Close agent".to_string(),
        tool_name: Some("task".to_string()),
        tool_input,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    })]
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
    vec![ConnectorEvent::MessageUpdated {
        message_id: event.call_id,
        content: None,
        tool_output: Some(output),
        is_error: Some(agent_status_failed(&event.status)),
        is_in_progress: Some(false),
        duration_ms: None,
    }]
}

pub(crate) fn handle_collab_resume_begin(event: CollabResumeBeginEvent) -> Vec<ConnectorEvent> {
    let tool_input = serde_json::to_string(&json!({
        "subagent_type": "resume",
        "subagent_id": event.receiver_thread_id.to_string(),
        "description": "Resuming agent",
        "sender_thread_id": event.sender_thread_id.to_string(),
        "receiver_thread_id": event.receiver_thread_id.to_string(),
        "receiver_agent_nickname": event.receiver_agent_nickname,
        "receiver_agent_role": event.receiver_agent_role,
    }))
    .ok();
    vec![ConnectorEvent::MessageCreated(orbitdock_protocol::Message {
        id: event.call_id,
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Resume agent".to_string(),
        tool_name: Some("task".to_string()),
        tool_input,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    })]
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
    vec![
        ConnectorEvent::MessageUpdated {
            message_id: event.call_id,
            content: None,
            tool_output: Some(output),
            is_error: Some(agent_status_failed(&event.status)),
            is_in_progress: Some(false),
            duration_ms: None,
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
