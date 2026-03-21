use super::*;

/// Read a config value from the database.
///
/// Transparently decrypts values with the `enc:` prefix.
/// Plaintext values pass through unchanged (no migration needed).
pub fn load_config_value(key: &str) -> Option<String> {
    let db_path = crate::infrastructure::paths::db_path();
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

    crate::infrastructure::crypto::decrypt(&raw)
}
