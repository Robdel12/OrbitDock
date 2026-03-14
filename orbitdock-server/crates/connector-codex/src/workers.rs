use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use codex_protocol::protocol::AgentStatus;
use orbitdock_protocol::{Provider, SubagentInfo, SubagentStatus};

static ISO_NOW_FALLBACK_COUNTER: AtomicU64 = AtomicU64::new(0);

pub(crate) fn collab_agent_label(
    thread_id: &str,
    agent_nickname: Option<&str>,
    agent_role: Option<&str>,
) -> String {
    let mut parts = vec![thread_id.to_string()];
    if let Some(nickname) = agent_nickname {
        let trimmed = nickname.trim();
        if !trimmed.is_empty() {
            parts.push(format!("nickname={trimmed}"));
        }
    }
    if let Some(role) = agent_role {
        let trimmed = role.trim();
        if !trimmed.is_empty() {
            parts.push(format!("role={trimmed}"));
        }
    }
    parts.join(" · ")
}

pub(crate) fn agent_status_failed(status: &AgentStatus) -> bool {
    matches!(status, AgentStatus::Errored(_) | AgentStatus::NotFound)
}

pub(crate) fn build_authoritative_codex_subagent(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
    status: &AgentStatus,
) -> SubagentInfo {
    let now = iso_now();
    let (mapped_status, ended_at, result_summary, error_summary) = map_agent_status(status, &now);

    SubagentInfo {
        id: id.clone(),
        agent_type: normalized_agent_type(agent_role.as_deref()),
        started_at: now.clone(),
        ended_at,
        provider: Some(Provider::Codex),
        label: normalized_agent_label(agent_nickname.as_deref(), agent_role.as_deref(), &id),
        status: mapped_status,
        task_summary: task_summary.and_then(|summary| {
            let trimmed = summary.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }),
        result_summary,
        error_summary,
        parent_subagent_id,
        model: None,
        last_activity_at: Some(now),
    }
}

pub(crate) fn build_inflight_codex_subagent(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
    status: &AgentStatus,
) -> Option<SubagentInfo> {
    let mapped_status = match status {
        AgentStatus::PendingInit => SubagentStatus::Pending,
        AgentStatus::Running => SubagentStatus::Running,
        AgentStatus::Completed(_)
        | AgentStatus::Errored(_)
        | AgentStatus::Shutdown
        | AgentStatus::NotFound => return None,
    };

    let now = iso_now();
    Some(SubagentInfo {
        id: id.clone(),
        agent_type: normalized_agent_type(agent_role.as_deref()),
        started_at: now.clone(),
        ended_at: None,
        provider: Some(Provider::Codex),
        label: normalized_agent_label(agent_nickname.as_deref(), agent_role.as_deref(), &id),
        status: mapped_status,
        task_summary: task_summary.and_then(|summary| {
            let trimmed = summary.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }),
        result_summary: None,
        error_summary: None,
        parent_subagent_id,
        model: None,
        last_activity_at: Some(now),
    })
}

pub(crate) fn build_running_codex_subagent(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
) -> SubagentInfo {
    build_inflight_codex_subagent(
        id,
        agent_role,
        agent_nickname,
        task_summary,
        parent_subagent_id,
        &AgentStatus::Running,
    )
    .expect("running subagent should always build")
}

pub(crate) fn build_codex_subagent_for_status(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
    status: &AgentStatus,
) -> SubagentInfo {
    match status {
        AgentStatus::PendingInit | AgentStatus::Running => build_inflight_codex_subagent(
            id,
            agent_role,
            agent_nickname,
            task_summary,
            parent_subagent_id,
            status,
        )
        .expect("non-terminal subagent should always build"),
        AgentStatus::Completed(_)
        | AgentStatus::Errored(_)
        | AgentStatus::Shutdown
        | AgentStatus::NotFound => build_authoritative_codex_subagent(
            id,
            agent_role,
            agent_nickname,
            task_summary,
            parent_subagent_id,
            status,
        ),
    }
}

fn map_agent_status(
    status: &AgentStatus,
    now: &str,
) -> (
    SubagentStatus,
    Option<String>,
    Option<String>,
    Option<String>,
) {
    match status {
        AgentStatus::PendingInit => (SubagentStatus::Pending, None, None, None),
        AgentStatus::Running => (SubagentStatus::Running, None, None, None),
        AgentStatus::Completed(summary) => (
            SubagentStatus::Completed,
            Some(now.to_string()),
            summary.as_ref().and_then(|summary| {
                let trimmed = summary.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_string())
            }),
            None,
        ),
        AgentStatus::Errored(message) => (
            SubagentStatus::Failed,
            Some(now.to_string()),
            None,
            Some(message.trim().to_string()),
        ),
        AgentStatus::Shutdown => (SubagentStatus::Shutdown, Some(now.to_string()), None, None),
        AgentStatus::NotFound => (
            SubagentStatus::NotFound,
            Some(now.to_string()),
            None,
            Some("Agent not found".to_string()),
        ),
    }
}

fn normalized_agent_type(role: Option<&str>) -> String {
    role.map(str::trim)
        .filter(|role| !role.is_empty())
        .unwrap_or("agent")
        .to_string()
}

fn normalized_agent_label(nickname: Option<&str>, role: Option<&str>, id: &str) -> Option<String> {
    nickname
        .map(str::trim)
        .filter(|nickname| !nickname.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            role.map(str::trim)
                .filter(|role| !role.is_empty())
                .map(ToOwned::to_owned)
        })
        .or_else(|| Some(id.to_string()))
}

pub(crate) fn iso_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| {
            let fallback = ISO_NOW_FALLBACK_COUNTER.fetch_add(1, Ordering::Relaxed);
            std::time::Duration::from_secs(fallback)
        })
        .as_secs();

    let days_since_epoch = secs / 86400;
    let time_of_day = secs % 86400;
    let hours = time_of_day / 3600;
    let minutes = (time_of_day % 3600) / 60;
    let seconds = time_of_day % 60;

    let mut days = days_since_epoch as i64;
    let mut year = 1970i64;
    loop {
        let d = if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
            366
        } else {
            365
        };
        if days < d {
            break;
        }
        days -= d;
        year += 1;
    }

    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let months = if leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };

    let mut month = 1;
    for m in months {
        if days < m {
            break;
        }
        days -= m;
        month += 1;
    }

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year,
        month,
        days + 1,
        hours,
        minutes,
        seconds
    )
}
