use super::*;

pub(super) fn persist_approval_requested(
    conn: &Connection,
    session_id: String,
    request_id: String,
    approval_type: ApprovalType,
    tool_name: Option<String>,
    tool_input: Option<String>,
    command: Option<String>,
    file_path: Option<String>,
    diff: Option<String>,
    question: Option<String>,
    question_prompts: Vec<ApprovalQuestionPrompt>,
    preview: Option<ApprovalPreview>,
    cwd: Option<String>,
    proposed_amendment: Option<Vec<String>>,
    permission_suggestions: Option<Value>,
) -> Result<(), rusqlite::Error> {
    let approval_type_str = match approval_type {
        ApprovalType::Exec => "exec",
        ApprovalType::Patch => "patch",
        ApprovalType::Question => "question",
    };
    let proposed_amendment_json =
        proposed_amendment.and_then(|value| serde_json::to_string(&value).ok());
    let question_prompts_json = if question_prompts.is_empty() {
        None
    } else {
        serde_json::to_string(&question_prompts).ok()
    };
    let preview_json = preview.and_then(|value| serde_json::to_string(&value).ok());
    let permission_suggestions_json =
        permission_suggestions.and_then(|value| serde_json::to_string(&value).ok());
    let now = chrono_now();
    let updated = conn.execute(
        "UPDATE approval_history
         SET approval_type = ?1,
             tool_name = ?2,
             tool_input = ?3,
             command = ?4,
             file_path = ?5,
             diff = ?6,
             question = ?7,
             question_prompts = ?8,
             preview = ?9,
             cwd = ?10,
             proposed_amendment = ?11,
             permission_suggestions = ?12
         WHERE session_id = ?13
           AND request_id = ?14
           AND decision IS NULL",
        params![
            approval_type_str,
            tool_name.as_deref(),
            tool_input.as_deref(),
            command.as_deref(),
            file_path.as_deref(),
            diff.as_deref(),
            question.as_deref(),
            question_prompts_json.as_deref(),
            preview_json.as_deref(),
            cwd.as_deref(),
            proposed_amendment_json.as_deref(),
            permission_suggestions_json.as_deref(),
            &session_id,
            &request_id
        ],
    )?;

    if updated == 0 {
        conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, tool_input, command,
                file_path, diff, question, question_prompts, preview, cwd,
                proposed_amendment, permission_suggestions, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            params![
                &session_id,
                &request_id,
                approval_type_str,
                tool_name.as_deref(),
                tool_input.as_deref(),
                command.as_deref(),
                file_path.as_deref(),
                diff.as_deref(),
                question.as_deref(),
                question_prompts_json.as_deref(),
                preview_json.as_deref(),
                cwd.as_deref(),
                proposed_amendment_json.as_deref(),
                permission_suggestions_json.as_deref(),
                now
            ],
        )?;
    }

    sync_pending_approval_head(conn, &session_id)?;
    Ok(())
}

pub(super) fn persist_approval_decision(
    conn: &Connection,
    session_id: String,
    request_id: String,
    decision: String,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE approval_history
         SET decision = ?1, decided_at = ?2
         WHERE session_id = ?3
           AND request_id = ?4
           AND decision IS NULL",
        params![decision, chrono_now(), session_id, request_id],
    )?;

    sync_pending_approval_head(conn, &session_id)?;
    Ok(())
}

pub async fn list_approvals(
    session_id: Option<String>,
    limit: Option<u32>,
) -> Result<Vec<ApprovalHistoryItem>, anyhow::Error> {
    let db_path = crate::paths::db_path();
    let limit = limit.unwrap_or(200).min(1000) as i64;

    Ok(
        tokio::task::spawn_blocking(move || -> Result<Vec<ApprovalHistoryItem>, anyhow::Error> {
            if !db_path.exists() {
                return Ok(Vec::new());
            }

            let conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
            )?;

            let table_exists: i64 = conn.query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'approval_history'",
                [],
                |row| row.get(0),
            )?;
            if table_exists == 0 {
                return Ok(Vec::new());
            }

            let mut items = Vec::new();
            if let Some(session_id) = session_id {
                let mut stmt = conn.prepare(
                    "SELECT id, session_id, request_id, approval_type, tool_name, tool_input, command,
                            file_path, diff, question, question_prompts, preview, cwd, decision,
                            proposed_amendment, permission_suggestions, created_at, decided_at
                     FROM approval_history
                     WHERE session_id = ?1
                     ORDER BY id DESC
                     LIMIT ?2",
                )?;
                let rows =
                    stmt.query_map(params![session_id, limit], decode_approval_history_item_row)?;
                for item in rows.flatten() {
                    items.push(item);
                }
            } else {
                let mut stmt = conn.prepare(
                    "SELECT id, session_id, request_id, approval_type, tool_name, tool_input, command,
                            file_path, diff, question, question_prompts, preview, cwd, decision,
                            proposed_amendment, permission_suggestions, created_at, decided_at
                     FROM approval_history
                     ORDER BY id DESC
                     LIMIT ?1",
                )?;
                let rows = stmt.query_map(params![limit], decode_approval_history_item_row)?;
                for item in rows.flatten() {
                    items.push(item);
                }
            }

            Ok(items)
        })
        .await??,
    )
}

pub async fn delete_approval(approval_id: i64) -> Result<bool, anyhow::Error> {
    let db_path = crate::paths::db_path();

    Ok(
        tokio::task::spawn_blocking(move || -> Result<bool, anyhow::Error> {
            if !db_path.exists() {
                return Ok(false);
            }

            let conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
            )?;
            let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'approval_history'",
            [],
            |row| row.get(0),
        )?;
            if table_exists == 0 {
                return Ok(false);
            }

            let rows = conn.execute(
                "DELETE FROM approval_history WHERE id = ?1",
                params![approval_id],
            )?;
            Ok(rows > 0)
        })
        .await??,
    )
}

fn sync_pending_approval_head(conn: &Connection, session_id: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE sessions
         SET pending_approval_id = (
            SELECT ah.request_id
            FROM approval_history ah
            WHERE ah.session_id = ?1
              AND ah.decision IS NULL
              AND ah.id > COALESCE(
                (
                    SELECT MAX(resolved.id)
                    FROM approval_history resolved
                    WHERE resolved.session_id = ah.session_id
                      AND resolved.request_id = ah.request_id
                      AND resolved.decision IS NOT NULL
                ),
                0
              )
            ORDER BY ah.id ASC
            LIMIT 1
         ),
         approval_version = approval_version + 1
         WHERE id = ?1",
        params![session_id],
    )?;
    Ok(())
}

fn decode_approval_history_item_row(
    row: &rusqlite::Row<'_>,
) -> Result<ApprovalHistoryItem, rusqlite::Error> {
    let approval_type_str: String = row.get(3)?;
    let approval_type = match approval_type_str.as_str() {
        "exec" => ApprovalType::Exec,
        "patch" => ApprovalType::Patch,
        "question" => ApprovalType::Question,
        _ => ApprovalType::Exec,
    };
    let question_prompts_json: Option<String> = row.get(10)?;
    let preview_json: Option<String> = row.get(11)?;
    let proposed_json: Option<String> = row.get(14)?;
    let permission_suggestions_json: Option<String> = row.get(15)?;
    let question_prompts = question_prompts_json
        .as_deref()
        .and_then(|value| serde_json::from_str::<Vec<ApprovalQuestionPrompt>>(value).ok())
        .unwrap_or_default();
    let preview = preview_json
        .as_deref()
        .and_then(|value| serde_json::from_str::<ApprovalPreview>(value).ok());
    let proposed_amendment = proposed_json
        .as_deref()
        .and_then(|value| serde_json::from_str::<Vec<String>>(value).ok());
    let permission_suggestions = permission_suggestions_json
        .as_deref()
        .and_then(|value| serde_json::from_str::<Value>(value).ok());

    Ok(ApprovalHistoryItem {
        id: row.get(0)?,
        session_id: row.get(1)?,
        request_id: row.get(2)?,
        approval_type,
        tool_name: row.get(4)?,
        tool_input: row.get(5)?,
        command: row.get(6)?,
        file_path: row.get(7)?,
        diff: row.get(8)?,
        question: row.get(9)?,
        question_prompts,
        preview,
        cwd: row.get(12)?,
        decision: row.get(13)?,
        proposed_amendment,
        permission_suggestions,
        created_at: row.get(16)?,
        decided_at: row.get(17)?,
    })
}
