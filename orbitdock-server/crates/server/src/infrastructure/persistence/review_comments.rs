use super::*;

pub async fn list_review_comments(
    session_id: &str,
    turn_id: Option<&str>,
) -> Result<Vec<orbitdock_protocol::ReviewComment>, anyhow::Error> {
    let session_id = session_id.to_string();
    let turn_id = turn_id.map(ToString::to_string);
    let db_path = crate::paths::db_path();

    let comments = tokio::task::spawn_blocking(
        move || -> Result<Vec<orbitdock_protocol::ReviewComment>, anyhow::Error> {
            if !db_path.exists() {
                return Ok(Vec::new());
            }
            let conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
            )?;

            let table_exists: i64 = conn.query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'review_comments'",
                [],
                |row| row.get(0),
            )?;
            if table_exists == 0 {
                return Ok(Vec::new());
            }

            let (sql, params_vec): (String, Vec<Box<dyn rusqlite::ToSql>>) =
                if let Some(ref turn_id) = turn_id {
                    (
                        "SELECT id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at, updated_at
                         FROM review_comments WHERE session_id = ?1 AND turn_id = ?2 ORDER BY created_at"
                            .to_string(),
                        vec![
                            Box::new(session_id.clone()) as Box<dyn rusqlite::ToSql>,
                            Box::new(turn_id.clone()),
                        ],
                    )
                } else {
                    (
                        "SELECT id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at, updated_at
                         FROM review_comments WHERE session_id = ?1 ORDER BY created_at"
                            .to_string(),
                        vec![Box::new(session_id.clone()) as Box<dyn rusqlite::ToSql>],
                    )
                };

            let params_refs: Vec<&dyn rusqlite::ToSql> =
                params_vec.iter().map(|value| value.as_ref()).collect();
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(params_refs), decode_review_comment_row)?;

            let mut comments = Vec::new();
            for row in rows {
                comments.push(row?);
            }
            Ok(comments)
        },
    )
    .await??;

    Ok(comments)
}

pub async fn load_review_comment_by_id(
    comment_id: &str,
) -> Result<Option<orbitdock_protocol::ReviewComment>, anyhow::Error> {
    let comment_id = comment_id.to_string();
    let db_path = crate::paths::db_path();

    tokio::task::spawn_blocking(
        move || -> Result<Option<orbitdock_protocol::ReviewComment>, anyhow::Error> {
            if !db_path.exists() {
                return Ok(None);
            }
            let conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
            )?;

            let table_exists: i64 = conn.query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'review_comments'",
                [],
                |row| row.get(0),
            )?;
            if table_exists == 0 {
                return Ok(None);
            }

            let comment = conn
                .query_row(
                    "SELECT id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at, updated_at
                     FROM review_comments WHERE id = ?1",
                    params![comment_id],
                    decode_review_comment_row,
                )
                .optional()?;

            Ok(comment)
        },
    )
    .await?
}

fn decode_review_comment_row(
    row: &rusqlite::Row<'_>,
) -> Result<orbitdock_protocol::ReviewComment, rusqlite::Error> {
    let tag_str: Option<String> = row.get(7)?;
    let status_str: String = row.get(8)?;

    let tag = tag_str.and_then(|tag| match tag.as_str() {
        "clarity" => Some(orbitdock_protocol::ReviewCommentTag::Clarity),
        "scope" => Some(orbitdock_protocol::ReviewCommentTag::Scope),
        "risk" => Some(orbitdock_protocol::ReviewCommentTag::Risk),
        "nit" => Some(orbitdock_protocol::ReviewCommentTag::Nit),
        _ => None,
    });

    let status = match status_str.as_str() {
        "resolved" => orbitdock_protocol::ReviewCommentStatus::Resolved,
        _ => orbitdock_protocol::ReviewCommentStatus::Open,
    };

    Ok(orbitdock_protocol::ReviewComment {
        id: row.get(0)?,
        session_id: row.get(1)?,
        turn_id: row.get(2)?,
        file_path: row.get(3)?,
        line_start: row.get(4)?,
        line_end: row.get(5)?,
        body: row.get(6)?,
        tag,
        status,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
    })
}
