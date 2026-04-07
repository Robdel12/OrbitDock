//! Lightweight SQLite read connection pool.
//!
//! Connections are pre-configured with `PRAGMA busy_timeout` and reused across
//! `spawn_blocking` tasks to avoid repeated open/close overhead (file descriptor
//! allocation, WAL index reads, statement cache cold-starts).

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use rusqlite::Connection;

/// A pool of reusable read-only SQLite connections.
///
/// When a connection is requested via [`get`](ReadPool::get), the pool either
/// returns a cached connection or opens a new one. Connections are returned to
/// the pool on drop (up to `max_idle`).
pub struct ReadPool {
  db_path: PathBuf,
  idle: Arc<Mutex<Vec<Connection>>>,
  max_idle: usize,
}

impl ReadPool {
  pub fn new(db_path: PathBuf, max_idle: usize) -> Self {
    Self {
      db_path,
      idle: Arc::new(Mutex::new(Vec::with_capacity(max_idle))),
      max_idle,
    }
  }

  /// Acquire a connection. Returns a guard that returns the connection to the
  /// pool on drop. Safe to move into `spawn_blocking` closures.
  pub fn get(&self) -> Result<PooledConnection, rusqlite::Error> {
    let conn = {
      let mut pool = self.idle.lock().expect("read pool lock poisoned");
      pool.pop()
    };

    let conn = match conn {
      Some(c) => c,
      None => {
        let c = Connection::open(&self.db_path)?;
        c.execute_batch("PRAGMA busy_timeout = 5000;")?;
        c
      }
    };

    Ok(PooledConnection {
      idle: Arc::clone(&self.idle),
      max_idle: self.max_idle,
      conn: Some(conn),
    })
  }
}

/// RAII guard that returns the connection to the pool on drop.
pub struct PooledConnection {
  idle: Arc<Mutex<Vec<Connection>>>,
  max_idle: usize,
  conn: Option<Connection>,
}

impl std::ops::Deref for PooledConnection {
  type Target = Connection;
  fn deref(&self) -> &Connection {
    self.conn.as_ref().expect("connection already returned")
  }
}

impl Drop for PooledConnection {
  fn drop(&mut self) {
    if let Some(conn) = self.conn.take() {
      let mut pool = self.idle.lock().expect("read pool lock poisoned");
      if pool.len() < self.max_idle {
        pool.push(conn);
      }
      // else: pool is full, connection is dropped (closed)
    }
  }
}
