//! Database migrations powered by refinery.
//!
//! New installs use refinery's migration history table. Existing installs may
//! still have the legacy `schema_versions` table from OrbitDock's prior custom
//! runner, so startup performs a one-time import before running pending
//! migrations.

use std::collections::HashMap;

use anyhow::Context;
use rusqlite::{params, Connection, OptionalExtension};
use tracing::{info, warn};

mod embedded {
    use refinery::embed_migrations;

    embed_migrations!("../../../migrations");
}

const LEGACY_MIGRATION_TABLE: &str = "schema_versions";
const REFINERY_MIGRATION_TABLE: &str = "refinery_schema_history";

/// Run all pending migrations against the given connection.
///
/// Call this at startup before any other database operations.
pub fn run_migrations(conn: &mut Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;",
    )?;

    import_legacy_history(conn)?;

    let report = embedded::migrations::runner()
        .run(conn)
        .context("run refinery migrations")?;

    info!(
        component = "migrations",
        event = "migrations.complete",
        applied = report.applied_migrations().len(),
        "Migration check complete"
    );

    Ok(())
}

fn import_legacy_history(conn: &mut Connection) -> anyhow::Result<()> {
    if refinery_history_count(conn)? > 0 {
        return Ok(());
    }

    if !table_exists(conn, LEGACY_MIGRATION_TABLE)? {
        return Ok(());
    }

    let legacy_history = load_legacy_history(conn)?;
    if legacy_history.is_empty() {
        return Ok(());
    }

    let migrations = embedded::migrations::runner().get_migrations().to_vec();
    ensure_refinery_history_table(conn)?;
    let mut imported = 0usize;

    for migration in &migrations {
        let version = i64::from(migration.version());
        let Some(applied_on) = legacy_history.get(&version) else {
            continue;
        };

        conn.execute(
            "INSERT INTO refinery_schema_history (version, name, applied_on, checksum)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                migration.version(),
                migration.name(),
                applied_on,
                migration.checksum().to_string()
            ],
        )
        .with_context(|| format!("import legacy migration v{version}"))?;

        imported += 1;
    }

    let unmatched: Vec<i64> = legacy_history
        .keys()
        .copied()
        .filter(|version| {
            !migrations
                .iter()
                .any(|migration| i64::from(migration.version()) == *version)
        })
        .collect();

    if !unmatched.is_empty() {
        warn!(
            component = "migrations",
            event = "migrations.legacy_versions_unmatched",
            unmatched = ?unmatched,
            "Legacy schema versions contained versions not present in refinery migrations"
        );
    }

    if imported > 0 {
        info!(
            component = "migrations",
            event = "migrations.legacy_history_imported",
            imported = imported,
            "Imported legacy schema_versions rows into refinery history"
        );
    }

    Ok(())
}

fn load_legacy_history(conn: &Connection) -> anyhow::Result<HashMap<i64, String>> {
    let mut stmt = conn
        .prepare("SELECT version, applied_at FROM schema_versions")
        .context("prepare legacy schema_versions query")?;

    let history = stmt
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })
        .context("query legacy schema_versions")?
        .filter_map(Result::ok)
        .collect();

    Ok(history)
}

fn ensure_refinery_history_table(conn: &Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS refinery_schema_history(
            version int4 PRIMARY KEY,
            name VARCHAR(255),
            applied_on VARCHAR(255),
            checksum VARCHAR(255)
        );",
    )
    .context("create refinery_schema_history table")?;

    Ok(())
}

fn refinery_history_count(conn: &Connection) -> anyhow::Result<i64> {
    if !table_exists(conn, REFINERY_MIGRATION_TABLE)? {
        return Ok(0);
    }

    let count = conn
        .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
            row.get(0)
        })
        .context("count refinery_schema_history rows")?;

    Ok(count)
}

fn table_exists(conn: &Connection, table_name: &str) -> anyhow::Result<bool> {
    let exists = conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            [table_name],
            |_row| Ok(true),
        )
        .optional()
        .context("check table existence")?
        .unwrap_or(false);

    Ok(exists)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_migrations_on_fresh_db() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        run_migrations(&mut conn).expect("migrations should succeed");

        let migration_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
                row.get(0)
            })
            .expect("count refinery history rows");
        assert_eq!(migration_count, 18);

        let sessions_table_exists: i64 = conn
            .query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(sessions_table_exists, 1);

        let legacy_table_exists: i64 = conn
            .query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'schema_versions'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(legacy_table_exists, 0);

        let mut stmt = conn
            .prepare("PRAGMA table_info(approval_history)")
            .expect("prepare pragma");
        let columns: Vec<String> = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .expect("query columns")
            .filter_map(Result::ok)
            .collect();
        for expected in [
            "tool_input",
            "diff",
            "question",
            "question_prompts",
            "preview",
            "permission_suggestions",
        ] {
            assert!(
                columns.iter().any(|column| column == expected),
                "expected approval_history to include column {expected}"
            );
        }
    }

    #[test]
    fn imports_legacy_schema_versions_before_running_pending_migrations() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        for migration in embedded::migrations::runner().get_migrations() {
            if migration.version() > 13 {
                break;
            }

            conn.execute_batch(migration.sql().expect("legacy migration sql"))
                .expect("apply legacy schema migration");
        }

        conn.execute_batch(
            "CREATE TABLE schema_versions (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );",
        )
        .expect("create legacy schema_versions");

        for version in 1..=13 {
            let name = if version == 4 {
                "quest_inbox".to_string()
            } else {
                format!("{version:03}_legacy")
            };

            conn.execute(
                "INSERT INTO schema_versions (version, name) VALUES (?1, ?2)",
                params![version, name],
            )
            .expect("insert legacy schema_versions row");
        }

        run_migrations(&mut conn).expect("migrations should succeed");

        let migration_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
                row.get(0)
            })
            .expect("count refinery history rows");
        assert_eq!(migration_count, 18);

        let imported_name: String = conn
            .query_row(
                "SELECT name FROM refinery_schema_history WHERE version = 4",
                [],
                |row| row.get(0),
            )
            .expect("load imported version 4");
        assert_eq!(imported_name, "claude_models");

        let legacy_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM schema_versions", [], |row| row.get(0))
            .expect("count legacy rows");
        assert_eq!(legacy_count, 13);
    }

    #[test]
    fn idempotent_migrations() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        run_migrations(&mut conn).expect("first run");
        run_migrations(&mut conn).expect("second run should be idempotent");

        let migration_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
                row.get(0)
            })
            .expect("count refinery history rows");
        assert_eq!(migration_count, 18);
    }
}
