use crate::runtime::row_entry;
use crate::workers::iso_now;
use codex_protocol::protocol::{
    GetHistoryEntryResponseEvent, ListCustomPromptsResponseEvent, ListRemoteSkillsResponseEvent,
    ListSkillsResponseEvent, McpListToolsResponseEvent, McpStartupCompleteEvent,
    McpStartupUpdateEvent, RemoteSkillDownloadedEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) fn handle_list_skills_response(event: ListSkillsResponseEvent) -> Vec<ConnectorEvent> {
    let skills = event
        .skills
        .into_iter()
        .map(|entry| orbitdock_protocol::SkillsListEntry {
            cwd: entry.cwd.to_string_lossy().to_string(),
            skills: entry
                .skills
                .into_iter()
                .map(|skill| orbitdock_protocol::SkillMetadata {
                    name: skill.name,
                    description: skill.description,
                    short_description: skill.short_description,
                    path: skill.path.to_string_lossy().to_string(),
                    scope: match skill.scope {
                        codex_protocol::protocol::SkillScope::User => {
                            orbitdock_protocol::SkillScope::User
                        }
                        codex_protocol::protocol::SkillScope::Repo => {
                            orbitdock_protocol::SkillScope::Repo
                        }
                        codex_protocol::protocol::SkillScope::System => {
                            orbitdock_protocol::SkillScope::System
                        }
                        codex_protocol::protocol::SkillScope::Admin => {
                            orbitdock_protocol::SkillScope::Admin
                        }
                    },
                    enabled: skill.enabled,
                })
                .collect(),
            errors: entry
                .errors
                .into_iter()
                .map(|error| orbitdock_protocol::SkillErrorInfo {
                    path: error.path.to_string_lossy().to_string(),
                    message: error.message,
                })
                .collect(),
        })
        .collect();

    vec![ConnectorEvent::SkillsList {
        skills,
        errors: Vec::new(),
    }]
}

pub(crate) fn handle_list_remote_skills_response(
    event: ListRemoteSkillsResponseEvent,
) -> Vec<ConnectorEvent> {
    let skills = event
        .skills
        .into_iter()
        .map(|skill| orbitdock_protocol::RemoteSkillSummary {
            id: skill.id,
            name: skill.name,
            description: skill.description,
        })
        .collect();
    vec![ConnectorEvent::RemoteSkillsList { skills }]
}

pub(crate) fn handle_remote_skill_downloaded(
    event: RemoteSkillDownloadedEvent,
) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::RemoteSkillDownloaded {
        id: event.id,
        name: event.name,
        path: event.path.to_string_lossy().to_string(),
    }]
}

pub(crate) fn handle_list_custom_prompts_response(
    event_id: &str,
    event: ListCustomPromptsResponseEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let mut lines = vec![format!(
        "Custom prompts available: {}",
        event.custom_prompts.len()
    )];
    for prompt in event.custom_prompts.iter().take(20) {
        let mut line = format!("/prompts:{}", prompt.name);
        if let Some(description) = &prompt.description {
            let trimmed = description.trim();
            if !trimmed.is_empty() {
                line.push_str(&format!(" - {}", trimmed));
            }
        }
        lines.push(line);
    }
    if event.custom_prompts.len() > 20 {
        lines.push(format!("... {} more", event.custom_prompts.len() - 20));
    }

    let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: format!("custom-prompts-{}-{}", event_id, seq),
        content: lines.join("\n"),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) fn handle_get_history_entry_response(
    event_id: &str,
    event: GetHistoryEntryResponseEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let content = if let Some(entry) = event.entry {
        format!(
            "History entry offset {} (log {}):\n{}\n\nConversation: {}\nTimestamp: {}",
            event.offset, event.log_id, entry.text, entry.conversation_id, entry.ts
        )
    } else {
        format!(
            "No history entry available for offset {} (log {}).",
            event.offset, event.log_id
        )
    };

    let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: format!("history-entry-{}-{}", event_id, seq),
        content,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) fn handle_mcp_list_tools_response(
    event: McpListToolsResponseEvent,
) -> Vec<ConnectorEvent> {
    let tools: HashMap<String, orbitdock_protocol::McpTool> = event
        .tools
        .into_iter()
        .map(|(key, tool)| {
            let value = serde_json::to_value(&tool).unwrap_or_default();
            let mapped: orbitdock_protocol::McpTool =
                serde_json::from_value(value).unwrap_or(orbitdock_protocol::McpTool {
                    name: tool.name,
                    title: tool.title,
                    description: tool.description,
                    input_schema: tool.input_schema,
                    output_schema: tool.output_schema,
                    annotations: tool.annotations,
                });
            (key, mapped)
        })
        .collect();

    let resources: HashMap<String, Vec<orbitdock_protocol::McpResource>> = event
        .resources
        .into_iter()
        .map(|(key, resources)| {
            let mapped: Vec<orbitdock_protocol::McpResource> = resources
                .into_iter()
                .filter_map(|resource| {
                    let value = serde_json::to_value(&resource).ok()?;
                    serde_json::from_value(value).ok()
                })
                .collect();
            (key, mapped)
        })
        .collect();

    let resource_templates: HashMap<String, Vec<orbitdock_protocol::McpResourceTemplate>> = event
        .resource_templates
        .into_iter()
        .map(|(key, templates)| {
            let mapped: Vec<orbitdock_protocol::McpResourceTemplate> = templates
                .into_iter()
                .filter_map(|template| {
                    let value = serde_json::to_value(&template).ok()?;
                    serde_json::from_value(value).ok()
                })
                .collect();
            (key, mapped)
        })
        .collect();

    let auth_statuses: HashMap<String, orbitdock_protocol::McpAuthStatus> = event
        .auth_statuses
        .into_iter()
        .map(|(key, status)| {
            let mapped = match status {
                codex_protocol::protocol::McpAuthStatus::Unsupported => {
                    orbitdock_protocol::McpAuthStatus::Unsupported
                }
                codex_protocol::protocol::McpAuthStatus::NotLoggedIn => {
                    orbitdock_protocol::McpAuthStatus::NotLoggedIn
                }
                codex_protocol::protocol::McpAuthStatus::BearerToken => {
                    orbitdock_protocol::McpAuthStatus::BearerToken
                }
                codex_protocol::protocol::McpAuthStatus::OAuth => {
                    orbitdock_protocol::McpAuthStatus::OAuth
                }
            };
            (key, mapped)
        })
        .collect();

    vec![ConnectorEvent::McpToolsList {
        tools,
        resources,
        resource_templates,
        auth_statuses,
    }]
}

pub(crate) fn handle_mcp_startup_update(event: McpStartupUpdateEvent) -> Vec<ConnectorEvent> {
    let status = match event.status {
        codex_protocol::protocol::McpStartupStatus::Starting => {
            orbitdock_protocol::McpStartupStatus::Starting
        }
        codex_protocol::protocol::McpStartupStatus::Ready => {
            orbitdock_protocol::McpStartupStatus::Ready
        }
        codex_protocol::protocol::McpStartupStatus::Failed { error } => {
            orbitdock_protocol::McpStartupStatus::Failed { error }
        }
        codex_protocol::protocol::McpStartupStatus::Cancelled => {
            orbitdock_protocol::McpStartupStatus::Cancelled
        }
    };
    vec![ConnectorEvent::McpStartupUpdate {
        server: event.server,
        status,
    }]
}

pub(crate) fn handle_mcp_startup_complete(event: McpStartupCompleteEvent) -> Vec<ConnectorEvent> {
    let failed = event
        .failed
        .into_iter()
        .map(|failure| orbitdock_protocol::McpStartupFailure {
            server: failure.server,
            error: failure.error,
        })
        .collect();
    vec![ConnectorEvent::McpStartupComplete {
        ready: event.ready,
        failed,
        cancelled: event.cancelled,
    }]
}
