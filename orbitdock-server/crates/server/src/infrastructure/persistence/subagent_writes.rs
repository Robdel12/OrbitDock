use rusqlite::{params, Connection};

use orbitdock_protocol::domain_events::AgentType;
use orbitdock_protocol::{Provider, SubagentInfo};

fn persist_subagent_upsert(
  conn: &Connection,
  session_id: &str,
  info: &SubagentInfo,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "INSERT INTO subagents (
        id,
        session_id,
        agent_type,
        transcript_path,
        started_at,
        ended_at,
        provider,
        label,
        status,
        task_summary,
        result_summary,
        error_summary,
        parent_subagent_id,
        model,
        last_activity_at
     )
     VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
     ON CONFLICT(id) DO UPDATE SET
        session_id = excluded.session_id,
        agent_type = excluded.agent_type,
        ended_at = CASE
            WHEN subagents.status = 'completed'
                 AND excluded.status != 'completed'
                THEN subagents.ended_at
            WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                 AND excluded.status IN ('pending', 'running')
                THEN subagents.ended_at
            WHEN subagents.status IN ('failed', 'cancelled', 'not_found')
                 AND excluded.status = 'shutdown'
                THEN subagents.ended_at
            ELSE COALESCE(excluded.ended_at, subagents.ended_at)
        END,
        provider = COALESCE(excluded.provider, subagents.provider),
        label = COALESCE(excluded.label, subagents.label),
        status = CASE
            WHEN subagents.status = 'completed'
                 AND excluded.status != 'completed'
                THEN subagents.status
            WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                 AND excluded.status IN ('pending', 'running')
                THEN subagents.status
            WHEN subagents.status IN ('completed', 'failed', 'cancelled', 'not_found')
                 AND excluded.status = 'shutdown'
                THEN subagents.status
            ELSE excluded.status
        END,
        task_summary = COALESCE(excluded.task_summary, subagents.task_summary),
        result_summary = CASE
            WHEN subagents.status = 'completed'
                 AND excluded.status != 'completed'
                THEN subagents.result_summary
            WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                 AND excluded.status IN ('pending', 'running')
                THEN subagents.result_summary
            WHEN subagents.status IN ('completed', 'failed', 'cancelled', 'not_found')
                 AND excluded.status = 'shutdown'
                THEN subagents.result_summary
            ELSE COALESCE(excluded.result_summary, subagents.result_summary)
        END,
        error_summary = CASE
            WHEN subagents.status = 'completed'
                 AND excluded.status != 'completed'
                THEN subagents.error_summary
            WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                 AND excluded.status IN ('pending', 'running')
                THEN subagents.error_summary
            WHEN subagents.status IN ('completed', 'failed', 'cancelled', 'not_found')
                 AND excluded.status = 'shutdown'
                THEN subagents.error_summary
            ELSE COALESCE(excluded.error_summary, subagents.error_summary)
        END,
        parent_subagent_id = COALESCE(excluded.parent_subagent_id, subagents.parent_subagent_id),
        model = COALESCE(excluded.model, subagents.model),
        last_activity_at = excluded.last_activity_at",
    params![
      info.id,
      session_id,
      info.agent_type.as_str(),
      info.started_at,
      info.ended_at,
      info.provider.map(|provider| match provider {
        Provider::Claude => "claude",
        Provider::Codex => "codex",
      }),
      info.label,
      match info.status {
        orbitdock_protocol::SubagentStatus::Pending => "pending",
        orbitdock_protocol::SubagentStatus::Running => "running",
        orbitdock_protocol::SubagentStatus::Interrupted => "interrupted",
        orbitdock_protocol::SubagentStatus::Completed => "completed",
        orbitdock_protocol::SubagentStatus::Failed => "failed",
        orbitdock_protocol::SubagentStatus::Cancelled => "cancelled",
        orbitdock_protocol::SubagentStatus::Shutdown => "shutdown",
        orbitdock_protocol::SubagentStatus::NotFound => "not_found",
      },
      info.task_summary,
      info.result_summary,
      info.error_summary,
      info.parent_subagent_id,
      info.model,
      info.last_activity_at,
    ],
  )?;
  Ok(())
}

pub(super) fn persist_claude_subagent_start(
  conn: &Connection,
  id: String,
  session_id: String,
  agent_type: AgentType,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  conn.execute(
    "INSERT INTO subagents (
        id,
        session_id,
        agent_type,
        provider,
        label,
        status,
        started_at,
        last_activity_at
     )
     VALUES (?1, ?2, ?3, 'claude', ?4, 'running', ?5, ?5)
     ON CONFLICT(id) DO UPDATE SET
       session_id = excluded.session_id,
       agent_type = excluded.agent_type,
       provider = excluded.provider,
       label = excluded.label,
       status = excluded.status,
       started_at = excluded.started_at,
       last_activity_at = excluded.last_activity_at",
    params![
      id,
      session_id,
      agent_type.as_str(),
      agent_type.as_str(),
      now
    ],
  )?;
  Ok(())
}

pub(super) fn persist_claude_subagent_end(
  conn: &Connection,
  id: String,
  transcript_path: Option<String>,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  conn.execute(
    "UPDATE subagents
         SET ended_at = ?1,
             transcript_path = ?2,
             status = 'completed',
             last_activity_at = ?1
         WHERE id = ?3",
    params![now, transcript_path, id],
  )?;
  Ok(())
}

pub(super) fn persist_upsert_subagent(
  conn: &Connection,
  session_id: String,
  info: SubagentInfo,
) -> Result<(), rusqlite::Error> {
  persist_subagent_upsert(conn, &session_id, &info)
}

pub(super) fn persist_upsert_subagents(
  conn: &Connection,
  session_id: String,
  infos: Vec<SubagentInfo>,
) -> Result<(), rusqlite::Error> {
  for info in &infos {
    persist_subagent_upsert(conn, &session_id, info)?;
  }
  Ok(())
}
