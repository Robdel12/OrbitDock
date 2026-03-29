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

  embed_migrations!("../../migrations");
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
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
  )?;

  import_legacy_history(conn)?;
  let had_v042_before = refinery_history_has_version(conn, 42)?;

  let report = embedded::migrations::runner()
    .run(conn)
    .context("run refinery migrations")?;

  ensure_session_control_plane_columns(conn)?;

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

fn ensure_session_control_plane_columns(conn: &Connection) -> anyhow::Result<()> {
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

    conn
      .execute(
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
  conn
    .execute_batch(
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
mod tests {
  use super::*;

  #[test]
  fn run_migrations_on_fresh_db() {
    let mut conn = Connection::open_in_memory().expect("open in-memory db");
    run_migrations(&mut conn).expect("migrations should succeed");
    let expected_migration_count = embedded::migrations::runner().get_migrations().len() as i64;

    let migration_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
        row.get(0)
      })
      .expect("count refinery history rows");
    assert_eq!(migration_count, expected_migration_count);

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
      "permission_reason",
      "requested_permissions",
      "granted_permissions",
    ] {
      assert!(
        columns.iter().any(|column| column == expected),
        "expected approval_history to include column {expected}"
      );
    }

    let mut session_stmt = conn
      .prepare("PRAGMA table_info(sessions)")
      .expect("prepare sessions pragma");
    let session_columns: Vec<String> = session_stmt
      .query_map([], |row| row.get::<_, String>(1))
      .expect("query session columns")
      .filter_map(Result::ok)
      .collect();
    for expected in [
      "collaboration_mode",
      "personality",
      "service_tier",
      "developer_instructions",
      "last_progress_at",
      "allow_bypass_permissions",
    ] {
      assert!(
        session_columns.iter().any(|column| column == expected),
        "expected sessions to include column {expected}"
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

      conn
        .execute_batch(migration.sql().expect("legacy migration sql"))
        .expect("apply legacy schema migration");
    }

    conn
      .execute_batch(
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

      conn
        .execute(
          "INSERT INTO schema_versions (version, name) VALUES (?1, ?2)",
          params![version, name],
        )
        .expect("insert legacy schema_versions row");
    }

    run_migrations(&mut conn).expect("migrations should succeed");
    let expected_migration_count = embedded::migrations::runner().get_migrations().len() as i64;

    let migration_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
        row.get(0)
      })
      .expect("count refinery history rows");
    assert_eq!(migration_count, expected_migration_count);

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
    let expected_migration_count = embedded::migrations::runner().get_migrations().len() as i64;

    let migration_count: i64 = conn
      .query_row("SELECT COUNT(*) FROM refinery_schema_history", [], |row| {
        row.get(0)
      })
      .expect("count refinery history rows");
    assert_eq!(migration_count, expected_migration_count);
  }

  #[test]
  fn direct_claude_owner_alias_must_be_unique() {
    let mut conn = Connection::open_in_memory().expect("open in-memory db");
    run_migrations(&mut conn).expect("migrations should succeed");

    conn
      .execute(
        "INSERT INTO sessions (
                id, provider, status, work_status, lifecycle_state, control_mode,
                claude_integration_mode, project_path, started_at, last_activity_at
             ) VALUES (
                ?1, 'claude', 'active', 'waiting', 'open', 'direct',
                'direct', '/tmp/alpha', '2026-03-26T10:00:00Z', '2026-03-26T10:00:00Z'
             )",
        ["od-direct-1"],
      )
      .expect("insert first direct Claude session");
    conn
      .execute(
        "UPDATE sessions SET claude_sdk_session_id = ?1 WHERE id = ?2",
        ["claude-sdk-1", "od-direct-1"],
      )
      .expect("assign first owner alias");

    conn
      .execute(
        "INSERT INTO sessions (
                id, provider, status, work_status, lifecycle_state, control_mode,
                claude_integration_mode, project_path, started_at, last_activity_at
             ) VALUES (
                ?1, 'claude', 'active', 'waiting', 'open', 'direct',
                'direct', '/tmp/beta', '2026-03-26T10:05:00Z', '2026-03-26T10:05:00Z'
             )",
        ["od-direct-2"],
      )
      .expect("insert second direct Claude session");

    let err = conn
      .execute(
        "UPDATE sessions SET claude_sdk_session_id = ?1 WHERE id = ?2",
        ["claude-sdk-1", "od-direct-2"],
      )
      .expect_err("duplicate direct owner alias should be rejected");

    assert!(
      err
        .to_string()
        .contains("claude direct session owner already exists"),
      "unexpected error: {err}"
    );
  }

  #[test]
  fn backfills_last_progress_at_from_last_activity_at() {
    let conn = Connection::open_in_memory().expect("open in-memory db");
    conn
      .execute_batch(
        "CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                last_activity_at TEXT
            );
            INSERT INTO sessions (id, last_activity_at) VALUES ('session-1', '123Z');",
      )
      .expect("seed pre-migration schema");

    conn
      .execute_batch(include_str!(
        "../../../../migrations/V033__last_progress_at.sql"
      ))
      .expect("apply V033 migration");

    let last_progress_at: Option<String> = conn
      .query_row(
        "SELECT last_progress_at FROM sessions WHERE id = 'session-1'",
        [],
        |row| row.get(0),
      )
      .expect("read progress timestamp");

    assert_eq!(last_progress_at.as_deref(), Some("123Z"));
  }

  #[test]
  fn post_v042_vacuum_runs_only_when_newly_applied_or_columns_dropped() {
    assert!(should_run_post_v042_vacuum(false, true, false));
    assert!(should_run_post_v042_vacuum(true, true, true));
    assert!(!should_run_post_v042_vacuum(true, true, false));
    assert!(!should_run_post_v042_vacuum(false, false, false));
  }
}
