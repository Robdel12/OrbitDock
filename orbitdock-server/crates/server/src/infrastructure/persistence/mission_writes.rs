use rusqlite::{params, Connection};

pub(super) fn persist_mission_create(
  conn: &Connection,
  id: String,
  name: String,
  repo_root: String,
  tracker_kind: String,
  provider: String,
  config_json: Option<String>,
  prompt_template: Option<String>,
  mission_file_path: Option<String>,
  tracker_api_key: Option<String>,
) -> Result<(), rusqlite::Error> {
  let encrypted_key = tracker_api_key.as_deref().and_then(|key| {
    crate::infrastructure::crypto::encrypt(key)
      .map_err(|error| tracing::warn!("Failed to encrypt tracker key: {error}"))
      .ok()
  });
  conn.execute(
    "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, config_json, prompt_template, mission_file_path, tracker_api_key)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
    params![
      id,
      name,
      repo_root,
      tracker_kind,
      provider,
      config_json,
      prompt_template,
      mission_file_path,
      encrypted_key,
    ],
  )?;
  Ok(())
}

pub(super) fn persist_mission_update(
  conn: &Connection,
  id: String,
  name: Option<String>,
  enabled: Option<bool>,
  paused: Option<bool>,
  tracker_kind: Option<String>,
  config_json: Option<String>,
  prompt_template: Option<String>,
  parse_error: Option<Option<String>>,
  mission_file_path: Option<Option<String>>,
) -> Result<(), rusqlite::Error> {
  if let Some(ref name) = name {
    conn.execute(
      "UPDATE missions SET name = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![name, id],
    )?;
  }
  if let Some(enabled) = enabled {
    conn.execute(
      "UPDATE missions SET enabled = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![enabled as i64, id],
    )?;
  }
  if let Some(paused) = paused {
    conn.execute(
      "UPDATE missions SET paused = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![paused as i64, id],
    )?;
  }
  if let Some(ref tracker_kind) = tracker_kind {
    conn.execute(
      "UPDATE missions SET tracker_kind = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![tracker_kind, id],
    )?;
  }
  if let Some(ref config_json) = config_json {
    conn.execute(
      "UPDATE missions SET config_json = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![config_json, id],
    )?;
  }
  if let Some(ref prompt_template) = prompt_template {
    conn.execute(
      "UPDATE missions SET prompt_template = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![prompt_template, id],
    )?;
  }
  if let Some(ref parse_error) = parse_error {
    conn.execute(
      "UPDATE missions SET parse_error = ?1, last_parsed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![parse_error, id],
    )?;
  }
  if let Some(ref mission_file_path) = mission_file_path {
    conn.execute(
      "UPDATE missions SET mission_file_path = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
      params![mission_file_path, id],
    )?;
  }
  Ok(())
}

pub(super) fn persist_mission_set_tracker_key(
  conn: &Connection,
  mission_id: String,
  key: Option<String>,
) -> Result<(), rusqlite::Error> {
  let stored = match key {
    Some(ref plaintext) => crate::infrastructure::crypto::encrypt(plaintext)
      .map_err(|error| {
        tracing::warn!("Failed to encrypt mission tracker key: {error}");
        rusqlite::Error::ToSqlConversionFailure(Box::new(error))
      })?
      .into(),
    None => None,
  };
  conn.execute(
    "UPDATE missions SET tracker_api_key = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
    params![stored, mission_id],
  )?;
  Ok(())
}

pub(super) fn persist_mission_delete(conn: &Connection, id: String) -> Result<(), rusqlite::Error> {
  conn.execute(
    "DELETE FROM mission_issues WHERE mission_id = ?1",
    params![id],
  )?;
  conn.execute("DELETE FROM missions WHERE id = ?1", params![id])?;
  Ok(())
}

pub(super) fn persist_mission_issue_upsert(
  conn: &Connection,
  id: String,
  mission_id: String,
  issue_id: String,
  issue_identifier: String,
  issue_title: Option<String>,
  issue_state: Option<String>,
  orchestration_state: String,
  provider: Option<String>,
  url: Option<String>,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, issue_title, issue_state, orchestration_state, provider, url)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
     ON CONFLICT(mission_id, issue_id) DO UPDATE SET
       issue_title = excluded.issue_title,
       issue_state = excluded.issue_state,
       url = excluded.url,
       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
    params![id, mission_id, issue_id, issue_identifier, issue_title, issue_state, orchestration_state, provider, url],
  )?;
  Ok(())
}

pub(super) fn persist_mission_issue_update_state(
  conn: &Connection,
  mission_id: String,
  issue_id: String,
  orchestration_state: String,
  session_id: Option<Option<String>>,
  workspace_id: Option<Option<String>>,
  attempt: Option<Option<u32>>,
  last_error: Option<Option<Option<String>>>,
  retry_due_at: Option<Option<Option<String>>>,
  started_at: Option<Option<Option<String>>>,
  completed_at: Option<Option<Option<String>>>,
) -> Result<(), rusqlite::Error> {
  let mut sets = vec![
    "orchestration_state = ?1".to_string(),
    "updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')".to_string(),
  ];
  let mut param_values: Vec<rusqlite::types::Value> = vec![orchestration_state.into()];

  let mut idx = 1u32;
  if let Some(ref val) = session_id {
    idx += 1;
    sets.push(format!("session_id = ?{idx}"));
    param_values.push(val.clone().into());
  }
  if let Some(ref val) = workspace_id {
    idx += 1;
    sets.push(format!("workspace_id = ?{idx}"));
    param_values.push(val.clone().into());
  }
  if let Some(val) = attempt {
    idx += 1;
    sets.push(format!("attempt = ?{idx}"));
    param_values.push(val.map_or(rusqlite::types::Value::Null, |value| (value as i64).into()));
  }
  if let Some(ref val) = last_error {
    idx += 1;
    sets.push(format!("last_error = ?{idx}"));
    param_values.push(
      val
        .clone()
        .map_or(rusqlite::types::Value::Null, |v| v.into()),
    );
  }
  if let Some(ref val) = retry_due_at {
    idx += 1;
    sets.push(format!("retry_due_at = ?{idx}"));
    param_values.push(
      val
        .clone()
        .map_or(rusqlite::types::Value::Null, |v| v.into()),
    );
  }
  if let Some(ref val) = started_at {
    idx += 1;
    sets.push(format!("started_at = ?{idx}"));
    param_values.push(
      val
        .clone()
        .map_or(rusqlite::types::Value::Null, |v| v.into()),
    );
  }
  if let Some(ref val) = completed_at {
    idx += 1;
    sets.push(format!("completed_at = ?{idx}"));
    param_values.push(
      val
        .clone()
        .map_or(rusqlite::types::Value::Null, |v| v.into()),
    );
  }

  let mid_idx = idx + 1;
  let iid_idx = idx + 2;
  param_values.push(mission_id.into());
  param_values.push(issue_id.into());

  let sql = format!(
    "UPDATE mission_issues SET {} WHERE mission_id = ?{mid_idx} AND issue_id = ?{iid_idx}",
    sets.join(", ")
  );
  let param_refs: Vec<&dyn rusqlite::types::ToSql> = param_values
    .iter()
    .map(|value| value as &dyn rusqlite::types::ToSql)
    .collect();
  conn.execute(&sql, param_refs.as_slice())?;
  Ok(())
}

pub(super) fn persist_mission_issue_set_pr_url(
  conn: &Connection,
  mission_id: String,
  issue_id: String,
  pr_url: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE mission_issues SET pr_url = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE mission_id = ?2 AND issue_id = ?3",
    params![pr_url, mission_id, issue_id],
  )?;
  Ok(())
}
