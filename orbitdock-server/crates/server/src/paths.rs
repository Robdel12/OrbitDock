//! Central path resolution for all OrbitDock data files.
//!
//! Resolved once at startup from: CLI `--data-dir` > `ORBITDOCK_DATA_DIR` env > `~/.orbitdock`.
//! All callsites use these helpers instead of constructing paths from `HOME`.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

static DATA_DIR: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Initialize the global data directory. Returns the resolved path.
///
/// Priority: `explicit` arg > `ORBITDOCK_DATA_DIR` env > `~/.orbitdock` default.
/// Panics if no valid path can be resolved.
pub fn init_data_dir(explicit: Option<&Path>) -> PathBuf {
    let dir = if let Some(p) = explicit {
        p.to_path_buf()
    } else if let Ok(env_val) = std::env::var("ORBITDOCK_DATA_DIR") {
        PathBuf::from(env_val)
    } else {
        dirs::home_dir()
            .expect("HOME directory not found")
            .join(".orbitdock")
    };

    let mut guard = DATA_DIR.write().expect("DATA_DIR lock poisoned");
    *guard = Some(dir.clone());
    dir
}

/// Return the current data directory. Panics if `init_data_dir` hasn't been called.
pub fn data_dir() -> PathBuf {
    DATA_DIR
        .read()
        .expect("DATA_DIR lock poisoned")
        .clone()
        .expect("data_dir() called before init_data_dir()")
}

pub fn db_path() -> PathBuf {
    data_dir().join("orbitdock.db")
}

pub fn log_dir() -> PathBuf {
    data_dir().join("logs")
}

pub fn spool_dir() -> PathBuf {
    data_dir().join("spool")
}

pub fn rollout_state_path() -> PathBuf {
    data_dir().join("codex-rollout-state.json")
}

pub fn hook_script_path() -> PathBuf {
    data_dir().join("hook.sh")
}

pub fn pid_file_path() -> PathBuf {
    data_dir().join("orbitdock.pid")
}

pub fn token_file_path() -> PathBuf {
    data_dir().join("auth-token")
}

pub fn images_dir() -> PathBuf {
    data_dir().join("images")
}

pub fn encryption_key_path() -> PathBuf {
    data_dir().join("encryption.key")
}

/// Create all required subdirectories under the data dir.
pub fn ensure_dirs() -> io::Result<()> {
    let base = data_dir();
    std::fs::create_dir_all(&base)?;
    std::fs::create_dir_all(base.join("logs"))?;
    std::fs::create_dir_all(base.join("spool"))?;
    std::fs::create_dir_all(base.join("images"))?;
    Ok(())
}

/// Reset data dir — for test isolation only.
#[cfg(test)]
pub fn reset_data_dir() {
    let mut guard = DATA_DIR.write().expect("DATA_DIR lock poisoned");
    *guard = None;
}
