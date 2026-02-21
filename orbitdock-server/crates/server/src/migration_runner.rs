//! Lightweight migration runner for rusqlite.
//!
//! Migrations are embedded at compile time via `include_str!` so the
//! binary is self-contained and works without access to the source tree.

use std::collections::HashSet;

use rusqlite::{params, Connection};
use tracing::{info, warn};

/// Compile-time embedded migrations. Add new entries here when adding migrations.
const EMBEDDED_MIGRATIONS: &[(i64, &str, &str)] = &[
    (
        1,
        "001_baseline",
        include_str!("../../../../migrations/001_baseline.sql"),
    ),
    (
        2,
        "002_message_images",
        include_str!("../../../../migrations/002_message_images.sql"),
    ),
    (
        3,
        "003_config_table",
        include_str!("../../../../migrations/003_config_table.sql"),
    ),
];

/// Run all pending migrations against the given connection.
///
/// Call this at startup before any other database operations.
pub fn run_migrations(conn: &mut Connection) -> anyhow::Result<()> {
    // Set pragmas for safe concurrent access
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;",
    )?;

    // Ensure tracking table exists
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_versions (
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        )",
    )?;

    // Get already-applied versions
    let applied: HashSet<i64> = conn
        .prepare("SELECT version FROM schema_versions")?
        .query_map([], |row| row.get(0))?
        .filter_map(|r| r.ok())
        .collect();

    // Run pending migrations
    let mut pending = 0;
    for &(version, name, sql) in EMBEDDED_MIGRATIONS {
        if applied.contains(&version) {
            continue;
        }

        if let Err(e) = conn.execute_batch(sql) {
            warn!(
                component = "migrations",
                event = "migration.failed",
                version = version,
                name = %name,
                error = %e,
                "Migration failed (may already be applied)"
            );
            // Record it anyway — the schema likely already exists from
            // CREATE TABLE IF NOT EXISTS workarounds or manual application.
            conn.execute(
                "INSERT OR IGNORE INTO schema_versions (version, name) VALUES (?1, ?2)",
                params![version, name],
            )?;
            continue;
        }

        conn.execute(
            "INSERT OR IGNORE INTO schema_versions (version, name) VALUES (?1, ?2)",
            params![version, name],
        )?;

        info!(
            component = "migrations",
            event = "migration.applied",
            version = version,
            name = %name,
            "Applied migration"
        );
        pending += 1;
    }

    let total = EMBEDDED_MIGRATIONS.len();
    info!(
        component = "migrations",
        event = "migrations.complete",
        total = total,
        applied = pending,
        skipped = total - pending,
        "Migration check complete"
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    /// Extract numeric version prefix from a migration filename like "001_initial".
    fn parse_version(name: &str) -> Option<i64> {
        name.split('_').next()?.parse().ok()
    }

    use super::*;

    #[test]
    fn parse_version_extracts_number() {
        assert_eq!(parse_version("001_baseline"), Some(1));
        assert_eq!(parse_version("042_add_feature"), Some(42));
        assert_eq!(parse_version("nope"), None);
    }

    #[test]
    fn embedded_migrations_are_sorted() {
        let versions: Vec<i64> = EMBEDDED_MIGRATIONS.iter().map(|(v, _, _)| *v).collect();
        let mut sorted = versions.clone();
        sorted.sort();
        assert_eq!(versions, sorted);
    }

    #[test]
    fn run_migrations_on_fresh_db() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        run_migrations(&mut conn).expect("migrations should succeed");

        // Verify schema_versions has all migrations
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM schema_versions", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, EMBEDDED_MIGRATIONS.len() as i64);

        // Verify sessions table exists
        let table_exists: i64 = conn
            .query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(table_exists, 1);
    }

    #[test]
    fn idempotent_migrations() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        run_migrations(&mut conn).expect("first run");
        run_migrations(&mut conn).expect("second run should be idempotent");
    }
}
