use rusqlite::{params, Connection};

use orbitdock_protocol::domain_events::AgentType;

use super::preserve_direct_owned_claude_shadow;

pub(super) fn persist_claude_session_upsert(
  conn: &Connection,
  id: String,
  project_path: String,
  project_name: Option<String>,
  branch: Option<String>,
  model: Option<String>,
  context_label: Option<String>,
  transcript_path: Option<String>,
  source: Option<String>,
  agent_type: Option<String>,
  permission_mode: Option<String>,
  terminal_session_id: Option<String>,
  terminal_app: Option<String>,
  forked_from_session_id: Option<String>,
  repository_root: Option<String>,
  is_worktree: bool,
  git_sha: Option<String>,
) -> Result<(), rusqlite::Error> {
  if preserve_direct_owned_claude_shadow(conn, &id, "direct_owner_exists")? {
    return Ok(());
  }

  let now = super::chrono_now();
  conn.execute(
    "INSERT INTO sessions (
        id, project_path, project_name, branch, model, context_label, transcript_path,
        provider, status, work_status, source, agent_type, permission_mode,
        control_mode, claude_integration_mode, terminal_session_id, terminal_app,
        started_at, last_activity_at, last_progress_at, forked_from_session_id,
        repository_root, is_worktree, git_sha
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'claude', 'active', 'waiting', ?8, ?9, ?10, 'passive', 'passive', ?11, ?12, ?13, ?13, ?13, ?14, ?15, ?16, ?17)
     ON CONFLICT(id) DO UPDATE SET
        project_path = excluded.project_path,
        project_name = COALESCE(excluded.project_name, sessions.project_name),
        branch = COALESCE(excluded.branch, sessions.branch),
        model = COALESCE(excluded.model, sessions.model),
        context_label = COALESCE(excluded.context_label, sessions.context_label),
        transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path),
        provider = 'claude',
        codex_integration_mode = NULL,
        claude_integration_mode = 'passive',
        control_mode = CASE
            WHEN sessions.control_mode = 'direct' THEN sessions.control_mode
            ELSE 'passive'
        END,
        source = COALESCE(excluded.source, sessions.source),
        agent_type = COALESCE(excluded.agent_type, sessions.agent_type),
        permission_mode = COALESCE(excluded.permission_mode, sessions.permission_mode),
        terminal_session_id = COALESCE(excluded.terminal_session_id, sessions.terminal_session_id),
        terminal_app = COALESCE(excluded.terminal_app, sessions.terminal_app),
        forked_from_session_id = COALESCE(excluded.forked_from_session_id, sessions.forked_from_session_id),
        repository_root = COALESCE(excluded.repository_root, sessions.repository_root),
        is_worktree = excluded.is_worktree,
        git_sha = COALESCE(excluded.git_sha, sessions.git_sha),
        status = 'active',
        last_activity_at = excluded.last_activity_at,
        last_progress_at = excluded.last_progress_at",
    params![
      id,
      project_path,
      project_name,
      branch,
      model,
      context_label,
      transcript_path,
      source,
      agent_type,
      permission_mode,
      terminal_session_id,
      terminal_app,
      now,
      forked_from_session_id,
      repository_root,
      is_worktree as i32,
      git_sha,
    ],
  )?;
  Ok(())
}

pub(super) fn persist_claude_session_update(
  conn: &Connection,
  id: String,
  work_status: Option<String>,
  attention_reason: Option<Option<String>>,
  last_tool: Option<Option<String>>,
  last_tool_at: Option<Option<String>>,
  pending_tool_name: Option<Option<String>>,
  pending_tool_input: Option<Option<String>>,
  pending_question: Option<Option<String>>,
  source: Option<Option<String>>,
  agent_type: Option<Option<String>>,
  permission_mode: Option<Option<String>>,
  active_subagent_id: Option<Option<String>>,
  active_subagent_type: Option<Option<AgentType>>,
  first_prompt: Option<String>,
  compact_count_increment: bool,
) -> Result<(), rusqlite::Error> {
  if preserve_direct_owned_claude_shadow(conn, &id, "direct_owner_exists")? {
    return Ok(());
  }

  let mut updates: Vec<String> = Vec::new();
  let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
  let has_attention_reason = attention_reason.is_some();
  let clears_pending = matches!(
    work_status.as_deref(),
    Some("working") | Some("waiting") | Some("reply") | Some("ended")
  );
  let lifecycle_state_is_ended = matches!(work_status.as_deref(), Some("ended"));

  if let Some(ws) = work_status {
    updates.push("work_status = ?".to_string());
    params_vec.push(Box::new(ws));
  }
  if let Some(reason) = attention_reason {
    updates.push("attention_reason = ?".to_string());
    params_vec.push(Box::new(reason));
  }
  if let Some(tool) = last_tool {
    updates.push("last_tool = ?".to_string());
    params_vec.push(Box::new(tool));
  }
  if let Some(tool_at) = last_tool_at {
    updates.push("last_tool_at = ?".to_string());
    params_vec.push(Box::new(tool_at));
  }
  if let Some(name) = pending_tool_name {
    updates.push("pending_tool_name = ?".to_string());
    params_vec.push(Box::new(name));
  }
  if let Some(input) = pending_tool_input {
    updates.push("pending_tool_input = ?".to_string());
    params_vec.push(Box::new(input));
  }
  if let Some(question) = pending_question {
    updates.push("pending_question = ?".to_string());
    params_vec.push(Box::new(question));
  }
  if clears_pending {
    updates.push("pending_tool_name = NULL".to_string());
    updates.push("pending_tool_input = NULL".to_string());
    updates.push("pending_question = NULL".to_string());
    updates.push("pending_approval_id = NULL".to_string());
    if !has_attention_reason {
      updates.push(
        "attention_reason = CASE \
            WHEN attention_reason IN ('awaitingPermission', 'awaitingQuestion') THEN 'awaitingReply' \
            ELSE attention_reason \
         END"
          .to_string(),
      );
    }
  }
  if let Some(src) = source {
    updates.push("source = ?".to_string());
    params_vec.push(Box::new(src));
  }
  if let Some(agent) = agent_type {
    updates.push("agent_type = ?".to_string());
    params_vec.push(Box::new(agent));
  }
  if let Some(permission) = permission_mode {
    updates.push("permission_mode = ?".to_string());
    params_vec.push(Box::new(permission));
  }
  if let Some(subagent_id) = active_subagent_id {
    updates.push("active_subagent_id = ?".to_string());
    params_vec.push(Box::new(subagent_id));
  }
  if let Some(subagent_type) = active_subagent_type {
    updates.push("active_subagent_type = ?".to_string());
    params_vec.push(Box::new(subagent_type.map(|at| at.as_str().to_string())));
  }
  if let Some(prompt) = first_prompt {
    updates.push("first_prompt = COALESCE(first_prompt, ?)".to_string());
    params_vec.push(Box::new(prompt));
  }
  if compact_count_increment {
    updates.push("compact_count = COALESCE(compact_count, 0) + 1".to_string());
  }

  if !updates.is_empty() {
    updates.push("last_activity_at = ?".to_string());
    params_vec.push(Box::new(super::chrono_now()));

    if lifecycle_state_is_ended {
      updates.push("lifecycle_state = 'ended'".to_string());
    } else {
      updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')".to_string());
    }

    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    params_vec.push(Box::new(id.clone()));

    let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|b| b.as_ref()).collect();
    conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
  }

  if clears_pending {
    let now = super::chrono_now();
    conn.execute(
      "UPDATE approval_history
         SET decision = 'abort',
             decided_at = COALESCE(decided_at, ?1)
         WHERE session_id = ?2
           AND decision IS NULL",
      params![now, id],
    )?;
  }

  Ok(())
}

pub(super) fn persist_claude_session_end(
  conn: &Connection,
  id: String,
  reason: Option<String>,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  conn.execute(
    "UPDATE sessions
         SET status = 'ended',
             work_status = 'ended',
             lifecycle_state = 'ended',
             ended_at = ?1,
             end_reason = COALESCE(?2, end_reason),
             attention_reason = 'none',
             pending_tool_name = NULL,
             pending_tool_input = NULL,
             pending_question = NULL,
             pending_approval_id = NULL,
             active_subagent_id = NULL,
             active_subagent_type = NULL,
             last_activity_at = ?1
         WHERE id = ?3",
    params![now, reason, id],
  )?;
  Ok(())
}

pub(super) fn persist_claude_prompt_increment(
  conn: &Connection,
  id: String,
  first_prompt: Option<String>,
) -> Result<(), rusqlite::Error> {
  if let Some(prompt) = first_prompt {
    let truncated: String = prompt.chars().take(200).collect();
    conn.execute(
      "UPDATE sessions
           SET prompt_count = COALESCE(prompt_count, 0) + 1,
               first_prompt = COALESCE(first_prompt, ?1),
               last_message = ?1,
               last_activity_at = ?2
           WHERE id = ?3",
      params![truncated, super::chrono_now(), id],
    )?;
  } else {
    conn.execute(
      "UPDATE sessions
           SET prompt_count = COALESCE(prompt_count, 0) + 1,
               last_activity_at = ?1
           WHERE id = ?2",
      params![super::chrono_now(), id],
    )?;
  }
  Ok(())
}

pub(super) fn persist_claude_tool_increment(
  conn: &Connection,
  id: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions
         SET tool_count = COALESCE(tool_count, 0) + 1,
             last_activity_at = ?1
         WHERE id = ?2",
    params![super::chrono_now(), id],
  )?;
  Ok(())
}

pub(super) fn persist_tool_count_increment(
  conn: &Connection,
  session_id: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions
         SET tool_count = COALESCE(tool_count, 0) + 1,
             last_activity_at = ?1
         WHERE id = ?2",
    params![super::chrono_now(), session_id],
  )?;
  Ok(())
}

pub(super) fn persist_codex_prompt_increment(
  conn: &Connection,
  id: String,
  first_prompt: Option<String>,
) -> Result<(), rusqlite::Error> {
  if let Some(prompt) = first_prompt {
    let truncated: String = prompt.chars().take(200).collect();
    conn.execute(
      "UPDATE sessions
           SET prompt_count = prompt_count + 1,
               first_prompt = COALESCE(first_prompt, ?1),
               last_message = ?1,
               last_activity_at = ?2
           WHERE id = ?3",
      params![truncated, super::chrono_now(), id],
    )?;
  } else {
    conn.execute(
      "UPDATE sessions
           SET prompt_count = prompt_count + 1,
               last_activity_at = ?1
           WHERE id = ?2",
      params![super::chrono_now(), id],
    )?;
  }
  Ok(())
}
