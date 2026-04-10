use rusqlite::{params, Connection};

pub(super) struct ReviewCommentCreateRecord {
  pub id: String,
  pub session_id: String,
  pub turn_id: Option<String>,
  pub file_path: String,
  pub line_start: Option<i64>,
  pub line_end: Option<i64>,
  pub body: String,
  pub tag: Option<String>,
}

pub(super) fn persist_review_comment_create(
  conn: &Connection,
  record: ReviewCommentCreateRecord,
) -> Result<(), rusqlite::Error> {
  let ReviewCommentCreateRecord {
    id,
    session_id,
    turn_id,
    file_path,
    line_start,
    line_end,
    body,
    tag,
  } = record;
  let now = super::chrono_now();
  conn.execute(
    "INSERT INTO review_comments (id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'open', ?9)",
    params![id, session_id, turn_id, file_path, line_start, line_end, body, tag, now],
  )?;
  Ok(())
}

pub(super) fn persist_review_comment_update(
  conn: &Connection,
  id: String,
  body: Option<String>,
  tag: Option<String>,
  status: Option<String>,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  let mut updates = Vec::new();
  let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

  if let Some(body) = body {
    updates.push("body = ?");
    params_vec.push(Box::new(body));
  }
  if let Some(tag) = tag {
    updates.push("tag = ?");
    params_vec.push(Box::new(tag));
  }
  if let Some(status) = status {
    updates.push("status = ?");
    params_vec.push(Box::new(status));
  }

  if !updates.is_empty() {
    updates.push("updated_at = ?");
    params_vec.push(Box::new(now));

    let sql = format!(
      "UPDATE review_comments SET {} WHERE id = ?",
      updates.join(", ")
    );
    params_vec.push(Box::new(id));

    let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();
    conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
  }

  Ok(())
}

pub(super) fn persist_review_comment_delete(
  conn: &Connection,
  id: String,
) -> Result<(), rusqlite::Error> {
  conn.execute("DELETE FROM review_comments WHERE id = ?1", params![id])?;
  Ok(())
}
