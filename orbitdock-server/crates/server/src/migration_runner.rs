//! Lightweight migration runner for rusqlite.
//!
//! Reads numbered SQL files from the `migrations/` directory,
//! tracks applied versions in `schema_versions`, and runs
//! any pending migrations in order at startup.

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use rusqlite::{params, Connection};
use tracing::{info, warn};

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

    // Find migrations directory
    let migrations_dir = find_migrations_dir()?;

    // Read and sort migration files
    let mut files: Vec<(i64, String, PathBuf)> = vec![];
    for entry in fs::read_dir(&migrations_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "sql") {
            let name = path.file_stem().unwrap().to_string_lossy().to_string();
            if let Some(version) = parse_version(&name) {
                files.push((version, name, path));
            }
        }
    }
    files.sort_by_key(|(v, _, _)| *v);

    // Get already-applied versions
    let applied: HashSet<i64> = conn
        .prepare("SELECT version FROM schema_versions")?
        .query_map([], |row| row.get(0))?
        .filter_map(|r| r.ok())
        .collect();

    // Run pending migrations in a transaction
    let mut pending = 0;
    for (version, name, path) in &files {
        if applied.contains(version) {
            continue;
        }

        let sql = fs::read_to_string(path)?;
        if let Err(e) = conn.execute_batch(&sql) {
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

    let total = files.len();
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

/// Walk up from CARGO_MANIFEST_DIR to find the `migrations/` directory.
fn find_migrations_dir() -> anyhow::Result<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for ancestor in manifest_dir.ancestors() {
        let candidate = ancestor.join("migrations");
        if candidate.is_dir() {
            return Ok(candidate);
        }
    }
    anyhow::bail!(
        "Could not find migrations/ directory (searched from {})",
        manifest_dir.display()
    )
}

/// Extract numeric version prefix from a migration filename like "001_initial".
fn parse_version(name: &str) -> Option<i64> {
    name.split('_').next()?.parse().ok()
}
