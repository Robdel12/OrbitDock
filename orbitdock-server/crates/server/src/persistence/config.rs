use super::*;

/// Read a config value from the database.
///
/// Transparently decrypts values with the `enc:` prefix.
/// Plaintext values pass through unchanged (no migration needed).
pub fn load_config_value(key: &str) -> Option<String> {
    let db_path = crate::paths::db_path();
    if !db_path.exists() {
        return None;
    }

    let conn = Connection::open(&db_path).ok()?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    )
    .ok()?;

    let raw: String = conn
        .query_row(
            "SELECT value FROM config WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .ok()
        .flatten()?;

    crate::crypto::decrypt(&raw)
}

/// Derive a human-readable display name from a Claude model string.
///
/// Handles both new-style (`claude-opus-4-6`) and legacy (`claude-3-5-sonnet-20241022`) formats.
/// Strips `claude-` prefix and date suffixes, then extracts the family name and version numbers.
/// Falls back to the raw string (minus `claude-` prefix) for unrecognized formats.
pub fn display_name_from_model_string(model: &str) -> String {
    let stripped = model.strip_prefix("claude-").unwrap_or(model);

    // Strip trailing date suffix (-YYYYMMDD)
    let without_date = if stripped.len() > 9 {
        let tail = &stripped[stripped.len() - 9..];
        if tail.starts_with('-') && tail[1..].chars().all(|c| c.is_ascii_digit()) && tail.len() == 9
        {
            &stripped[..stripped.len() - 9]
        } else {
            stripped
        }
    } else {
        stripped
    };

    let families = ["opus", "sonnet", "haiku"];
    let parts: Vec<&str> = without_date.split('-').collect();

    if let Some(family_idx) = parts
        .iter()
        .position(|p| families.contains(&p.to_lowercase().as_str()))
    {
        let family = capitalize_first(parts[family_idx]);
        let version_parts: Vec<&str> = parts
            .iter()
            .enumerate()
            .filter(|(i, p)| *i != family_idx && p.chars().all(|c| c.is_ascii_digit()))
            .map(|(_, p)| *p)
            .collect();

        if version_parts.is_empty() {
            family
        } else {
            format!("{} {}", family, version_parts.join("."))
        }
    } else {
        without_date.to_string()
    }
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(c) => c.to_uppercase().to_string() + &chars.as_str().to_lowercase(),
    }
}

/// Backfill `claude_models` from distinct model values in the `sessions` table.
///
/// Only inserts models not already present — preserves richer direct connector data.
/// Called once at server startup to seed the table from historical hook sessions.
pub async fn backfill_claude_models_from_sessions() {
    let db_path = crate::paths::db_path();
    if !db_path.exists() {
        return;
    }

    let result = tokio::task::spawn_blocking(move || -> Result<usize, anyhow::Error> {
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let mut stmt = conn.prepare(
            "SELECT DISTINCT s.model
             FROM sessions s
             LEFT JOIN claude_models cm ON cm.value = s.model
             WHERE s.provider = 'claude'
               AND s.model IS NOT NULL
               AND s.model != ''
               AND cm.value IS NULL",
        )?;

        let models: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();

        if models.is_empty() {
            return Ok(0);
        }

        let now = chrono_now();
        let mut insert = conn.prepare(
            "INSERT INTO claude_models (value, display_name, description, updated_at)
             VALUES (?1, ?2, '', ?3)
             ON CONFLICT(value) DO NOTHING",
        )?;

        let mut count = 0;
        for model in &models {
            let dn = display_name_from_model_string(model);
            insert.execute(params![model, dn, now])?;
            count += 1;
        }

        Ok(count)
    })
    .await;

    match result {
        Ok(Ok(count)) if count > 0 => {
            info!(
                component = "startup",
                event = "claude_models.backfill",
                count,
                "Backfilled claude_models from session history"
            );
        }
        Ok(Err(e)) => {
            warn!(
                component = "startup",
                event = "claude_models.backfill_failed",
                error = %e,
                "Failed to backfill claude_models"
            );
        }
        Err(e) => {
            warn!(
                component = "startup",
                event = "claude_models.backfill_failed",
                error = %e,
                "Backfill task panicked"
            );
        }
        _ => {}
    }
}

/// Load cached Claude models from the database.
///
/// Opens its own connection like `load_config_value` — safe to call from any context.
pub fn load_cached_claude_models() -> Vec<orbitdock_protocol::ClaudeModelOption> {
    let db_path = crate::paths::db_path();
    if !db_path.exists() {
        return Vec::new();
    }

    let conn = match Connection::open(&db_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let _ = conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    );

    let mut stmt = match conn.prepare("SELECT value, display_name, description FROM claude_models")
    {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    stmt.query_map([], |row| {
        Ok(orbitdock_protocol::ClaudeModelOption {
            value: row.get(0)?,
            display_name: row.get(1)?,
            description: row.get(2)?,
        })
    })
    .map(|rows| rows.filter_map(|r| r.ok()).collect())
    .unwrap_or_default()
}
