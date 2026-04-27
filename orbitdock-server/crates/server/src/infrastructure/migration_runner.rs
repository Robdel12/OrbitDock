//! Database migrations powered by refinery.

use anyhow::Context;
use rusqlite::{params, Connection, OptionalExtension};
use tracing::info;

mod embedded {
  use refinery::embed_migrations;

  embed_migrations!("../../migrations");
}

const REFINERY_MIGRATION_TABLE: &str = "refinery_schema_history";

/// Run all pending migrations against the given connection.
///
/// Call this at startup before any other database operations.
pub fn run_migrations(conn: &mut Connection) -> anyhow::Result<()> {
  conn.execute_batch(
    "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
  )?;

  let had_v042_before = refinery_history_has_version(conn, 42)?;

  let report = embedded::migrations::runner()
    .run(conn)
    .context("run refinery migrations")?;

  ensure_session_runtime_columns(conn)?;
  crate::infrastructure::persistence::repair_usage_accounting_if_needed(conn)
    .context("repair usage accounting")?;

  let applied = report.applied_migrations();
  let has_v042_after = refinery_history_has_version(conn, 42)?;

  // V042 drops dead columns. Some columns (images_json, thinking) were added
  // ad-hoc on existing installs but never by a migration, so we drop them
  // conditionally here rather than in the SQL file.
  let mut dropped_ad_hoc_columns = false;
  if has_v042_after {
    for col in &["images_json", "thinking"] {
      if column_exists(conn, "messages", col)? {
        conn
          .execute(&format!("ALTER TABLE messages DROP COLUMN {col}"), [])
          .with_context(|| format!("drop messages.{col}"))?;
        dropped_ad_hoc_columns = true;
      }
    }
  }

  if should_run_post_v042_vacuum(had_v042_before, has_v042_after, dropped_ad_hoc_columns) {
    // VACUUM must run outside a transaction to actually reclaim disk space.
    // Critical for Pi deployments where 2+ GB of dead data is untenable.
    info!(
      component = "migrations",
      event = "migrations.vacuum_start",
      "Running VACUUM to reclaim disk space after column drops"
    );
    conn
      .execute_batch("VACUUM;")
      .context("VACUUM after V042 column drops")?;
    info!(
      component = "migrations",
      event = "migrations.vacuum_complete",
      "VACUUM complete"
    );
  }

  info!(
    component = "migrations",
    event = "migrations.complete",
    applied = applied.len(),
    "Migration check complete"
  );

  Ok(())
}

fn should_run_post_v042_vacuum(
  had_v042_before: bool,
  has_v042_after: bool,
  dropped_ad_hoc_columns: bool,
) -> bool {
  (!had_v042_before && has_v042_after) || dropped_ad_hoc_columns
}

fn ensure_session_runtime_columns(conn: &Connection) -> anyhow::Result<()> {
  if !table_exists(conn, "sessions")? {
    return Ok(());
  }

  ensure_column(conn, "sessions", "collaboration_mode", "TEXT")?;
  ensure_column(conn, "sessions", "multi_agent", "INTEGER")?;
  ensure_column(conn, "sessions", "personality", "TEXT")?;
  ensure_column(conn, "sessions", "service_tier", "TEXT")?;
  ensure_column(conn, "sessions", "developer_instructions", "TEXT")?;
  ensure_column(conn, "sessions", "last_progress_at", "TEXT")?;
  ensure_column(conn, "sessions", "control_mode", "TEXT")?;
  ensure_column(
    conn,
    "sessions",
    "lifecycle_state",
    "TEXT NOT NULL DEFAULT 'open'",
  )?;
  ensure_column(
    conn,
    "sessions",
    "allow_bypass_permissions",
    "INTEGER DEFAULT 0",
  )?;

  conn.execute(
    "UPDATE sessions
         SET control_mode = CASE
             WHEN provider = 'codex' AND codex_integration_mode = 'direct' THEN 'direct'
             WHEN provider = 'claude' AND claude_integration_mode = 'direct' THEN 'direct'
             ELSE 'passive'
         END
         WHERE control_mode IS NULL OR trim(control_mode) = ''",
    [],
  )?;

  Ok(())
}

fn ensure_column(
  conn: &Connection,
  table_name: &str,
  column_name: &str,
  column_def: &str,
) -> anyhow::Result<()> {
  if column_exists(conn, table_name, column_name)? {
    return Ok(());
  }

  conn
    .execute(
      &format!("ALTER TABLE {table_name} ADD COLUMN {column_name} {column_def}"),
      [],
    )
    .with_context(|| format!("add missing column {table_name}.{column_name}"))?;

  Ok(())
}

fn column_exists(conn: &Connection, table_name: &str, column_name: &str) -> anyhow::Result<bool> {
  let mut stmt = conn
    .prepare(&format!("PRAGMA table_info({table_name})"))
    .with_context(|| format!("prepare pragma table_info for {table_name}"))?;

  let exists = stmt
    .query_map([], |row| row.get::<_, String>(1))
    .with_context(|| format!("query pragma table_info for {table_name}"))?
    .filter_map(Result::ok)
    .any(|name| name == column_name);

  Ok(exists)
}

fn refinery_history_has_version(conn: &Connection, version: i64) -> anyhow::Result<bool> {
  if !table_exists(conn, REFINERY_MIGRATION_TABLE)? {
    return Ok(false);
  }

  let exists = conn.query_row(
    "SELECT EXISTS(
         SELECT 1
         FROM refinery_schema_history
         WHERE version = ?1
     )",
    params![version],
    |row| row.get::<_, i64>(0),
  )?;

  Ok(exists == 1)
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
#[path = "migration_runner_tests.rs"]
mod tests;
