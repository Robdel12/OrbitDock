//! `orbitdock-server doctor` — diagnostics checklist.
//!
//! Runs a battery of health checks and prints a summary.

use std::path::Path;

use crate::{auth_tokens, crypto, paths};

enum Status {
    Pass,
    Warn,
    Fail,
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Status::Pass => write!(f, "\x1b[32m[PASS]\x1b[0m"),
            Status::Warn => write!(f, "\x1b[33m[WARN]\x1b[0m"),
            Status::Fail => write!(f, "\x1b[31m[FAIL]\x1b[0m"),
        }
    }
}

struct Check {
    name: &'static str,
    status: Status,
    detail: String,
}

pub fn run(data_dir: &Path) -> anyhow::Result<()> {
    println!();
    println!("  OrbitDock Doctor");
    println!("  ───────────────");
    println!();

    let checks = vec![
        check_data_dir(data_dir),
        check_database(),
        check_encryption_key(),
        check_claude_cli(),
        check_auth_token(),
        check_hook_transport_config(),
        check_hooks_in_settings(),
        check_spool_queue(),
        check_wal_size(),
        check_port(),
        check_health(),
        check_disk_space(data_dir),
    ];

    // Print results
    let mut pass = 0u32;
    let mut warn = 0u32;
    let mut fail = 0u32;

    for check in &checks {
        match check.status {
            Status::Pass => pass += 1,
            Status::Warn => warn += 1,
            Status::Fail => fail += 1,
        }
        println!("  {} {}: {}", check.status, check.name, check.detail);
    }

    println!();
    println!(
        "  Summary: {} passed, {} warnings, {} failed ({} total)",
        pass,
        warn,
        fail,
        checks.len()
    );
    println!();

    Ok(())
}

fn check_data_dir(data_dir: &Path) -> Check {
    if !data_dir.exists() {
        return Check {
            name: "Data directory",
            status: Status::Fail,
            detail: format!("{} does not exist", data_dir.display()),
        };
    }

    // Test writability
    let test_file = data_dir.join(".doctor-test");
    match std::fs::write(&test_file, "test") {
        Ok(_) => {
            let _ = std::fs::remove_file(&test_file);
            Check {
                name: "Data directory",
                status: Status::Pass,
                detail: format!("{} (writable)", data_dir.display()),
            }
        }
        Err(e) => Check {
            name: "Data directory",
            status: Status::Fail,
            detail: format!("{} (not writable: {})", data_dir.display(), e),
        },
    }
}

fn check_database() -> Check {
    let db_path = paths::db_path();
    if !db_path.exists() {
        return Check {
            name: "Database",
            status: Status::Fail,
            detail: "not found — run `orbitdock-server init`".to_string(),
        };
    }

    match rusqlite::Connection::open(&db_path) {
        Ok(conn) => match conn.query_row("SELECT count(*) FROM sessions", [], |row| {
            row.get::<_, i64>(0)
        }) {
            Ok(count) => Check {
                name: "Database",
                status: Status::Pass,
                detail: format!(
                    "{} ({} sessions, {} KB)",
                    db_path.display(),
                    count,
                    std::fs::metadata(&db_path)
                        .map(|m| m.len() / 1024)
                        .unwrap_or(0)
                ),
            },
            Err(e) => Check {
                name: "Database",
                status: Status::Warn,
                detail: format!("exists but query failed: {}", e),
            },
        },
        Err(e) => Check {
            name: "Database",
            status: Status::Fail,
            detail: format!("cannot open: {}", e),
        },
    }
}

fn check_encryption_key() -> Check {
    let key_path = paths::encryption_key_path();
    if !key_path.exists() {
        return Check {
            name: "Encryption key",
            status: Status::Warn,
            detail: "not found (will be auto-generated on start)".to_string(),
        };
    }

    match std::fs::metadata(&key_path) {
        Ok(meta) => {
            let size = meta.len();
            if size != 32 {
                Check {
                    name: "Encryption key",
                    status: Status::Warn,
                    detail: format!("unexpected size ({} bytes, expected 32)", size),
                }
            } else {
                Check {
                    name: "Encryption key",
                    status: Status::Pass,
                    detail: "present (32 bytes)".to_string(),
                }
            }
        }
        Err(e) => Check {
            name: "Encryption key",
            status: Status::Fail,
            detail: format!("cannot read: {}", e),
        },
    }
}

fn check_claude_cli() -> Check {
    let found = std::env::var("CLAUDE_BIN")
        .ok()
        .filter(|p| std::path::Path::new(p).exists())
        .is_some()
        || std::env::var("HOME")
            .ok()
            .map(|h| format!("{}/.claude/local/claude", h))
            .filter(|p| std::path::Path::new(p).exists())
            .is_some()
        || std::process::Command::new("which")
            .arg("claude")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

    if found {
        Check {
            name: "Claude CLI",
            status: Status::Pass,
            detail: "available".to_string(),
        }
    } else {
        Check {
            name: "Claude CLI",
            status: Status::Warn,
            detail: "not found (Claude direct sessions won't be available)".to_string(),
        }
    }
}

fn check_auth_token() -> Check {
    let env_token = std::env::var("ORBITDOCK_AUTH_TOKEN")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let active_db_tokens = auth_tokens::active_token_count();

    match (env_token, active_db_tokens) {
        (Some(token), Ok(count)) if count > 0 => Check {
            name: "Auth token",
            status: Status::Pass,
            detail: format!(
                "configured via ORBITDOCK_AUTH_TOKEN ({}...) and {} active database token(s)",
                &token[..8.min(token.len())],
                count
            ),
        },
        (Some(token), Ok(_)) => Check {
            name: "Auth token",
            status: Status::Pass,
            detail: format!(
                "configured via ORBITDOCK_AUTH_TOKEN ({}...)",
                &token[..8.min(token.len())]
            ),
        },
        (Some(token), Err(e)) => Check {
            name: "Auth token",
            status: Status::Pass,
            detail: format!(
                "configured via ORBITDOCK_AUTH_TOKEN ({}...), database token check failed: {}",
                &token[..8.min(token.len())],
                e
            ),
        },
        (None, Ok(count)) if count > 0 => Check {
            name: "Auth token",
            status: Status::Pass,
            detail: format!("{} active database token(s)", count),
        },
        (None, Ok(_)) => Check {
            name: "Auth token",
            status: Status::Warn,
            detail: "not configured (server accepts unauthenticated requests)".to_string(),
        },
        (None, Err(e)) => Check {
            name: "Auth token",
            status: Status::Warn,
            detail: format!("not configured, and database token check failed: {}", e),
        },
    }
}

fn check_hook_transport_config() -> Check {
    let config_path = paths::hook_transport_config_path();
    if !config_path.exists() {
        return Check {
            name: "Hook transport",
            status: Status::Fail,
            detail: format!("config not found at {}", config_path.display()),
        };
    }

    let content = match std::fs::read_to_string(&config_path) {
        Ok(content) => content,
        Err(e) => {
            return Check {
                name: "Hook transport",
                status: Status::Fail,
                detail: format!("cannot read {}: {}", config_path.display(), e),
            };
        }
    };

    let parsed: serde_json::Value = match serde_json::from_str(&content) {
        Ok(parsed) => parsed,
        Err(e) => {
            return Check {
                name: "Hook transport",
                status: Status::Fail,
                detail: format!("invalid JSON in {}: {}", config_path.display(), e),
            };
        }
    };

    let Some(server_url) = parsed.get("server_url").and_then(|v| v.as_str()) else {
        return Check {
            name: "Hook transport",
            status: Status::Fail,
            detail: format!(
                "{} missing required field `server_url`",
                config_path.display()
            ),
        };
    };

    let token_present = parsed
        .get("auth_token_enc")
        .and_then(|v| v.as_str())
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false);
    let legacy_plaintext_token = parsed
        .get("auth_token")
        .and_then(|v| v.as_str())
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false);

    if legacy_plaintext_token && !token_present {
        return Check {
            name: "Hook transport",
            status: Status::Warn,
            detail: format!(
                "{} uses legacy plaintext auth_token; rerun `orbitdock-server install-hooks`",
                config_path.display()
            ),
        };
    }

    if token_present {
        let decryptable = parsed
            .get("auth_token_enc")
            .and_then(|v| v.as_str())
            .and_then(crypto::decrypt)
            .map(|v| !v.trim().is_empty())
            .unwrap_or(false);
        if !decryptable {
            return Check {
                name: "Hook transport",
                status: Status::Warn,
                detail: format!(
                    "{} has encrypted auth token but decryption failed (check encryption key)",
                    config_path.display()
                ),
            };
        }
    }

    Check {
        name: "Hook transport",
        status: Status::Pass,
        detail: format!(
            "{} (server_url={}, auth_token={})",
            config_path.display(),
            server_url,
            if token_present { "set" } else { "unset" }
        ),
    }
}

fn check_hooks_in_settings() -> Check {
    let settings_path = dirs::home_dir()
        .map(|h| h.join(".claude/settings.json"))
        .unwrap_or_default();

    if !settings_path.exists() {
        return Check {
            name: "Claude hooks",
            status: Status::Fail,
            detail: "~/.claude/settings.json not found".to_string(),
        };
    }

    let content = match std::fs::read_to_string(&settings_path) {
        Ok(c) => c,
        Err(e) => {
            return Check {
                name: "Claude hooks",
                status: Status::Fail,
                detail: format!("cannot read settings.json: {}", e),
            };
        }
    };

    let expected_hooks = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "Notification",
        "PreCompact",
        "TeammateIdle",
        "TaskCompleted",
        "ConfigChange",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "SubagentStart",
        "SubagentStop",
    ];

    let mut found = 0;
    for hook in &expected_hooks {
        if content.contains(hook)
            && (content.contains("orbitdock")
                || content.contains("hook.sh")
                || content.contains("hook-forward"))
        {
            found += 1;
        }
    }

    if found == expected_hooks.len() {
        Check {
            name: "Claude hooks",
            status: Status::Pass,
            detail: format!("{}/{} hooks registered", found, expected_hooks.len()),
        }
    } else if found > 0 {
        Check {
            name: "Claude hooks",
            status: Status::Warn,
            detail: format!(
                "{}/{} hooks registered (run install-hooks to fix)",
                found,
                expected_hooks.len()
            ),
        }
    } else {
        Check {
            name: "Claude hooks",
            status: Status::Fail,
            detail: "no OrbitDock hooks found (run install-hooks)".to_string(),
        }
    }
}

fn check_spool_queue() -> Check {
    let spool_dir = paths::spool_dir();
    if !spool_dir.exists() {
        return Check {
            name: "Spool queue",
            status: Status::Pass,
            detail: "empty (no spool dir)".to_string(),
        };
    }

    match std::fs::read_dir(&spool_dir) {
        Ok(entries) => {
            let count = entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path()
                        .extension()
                        .and_then(|ext| ext.to_str())
                        .map(|ext| ext == "json")
                        .unwrap_or(false)
                })
                .count();

            if count == 0 {
                Check {
                    name: "Spool queue",
                    status: Status::Pass,
                    detail: "empty".to_string(),
                }
            } else {
                Check {
                    name: "Spool queue",
                    status: Status::Warn,
                    detail: format!(
                        "{} queued events (retried by hook-forward and drained on server start)",
                        count
                    ),
                }
            }
        }
        Err(e) => Check {
            name: "Spool queue",
            status: Status::Warn,
            detail: format!("cannot read: {}", e),
        },
    }
}

fn check_wal_size() -> Check {
    let wal_path = paths::db_path().with_extension("db-wal");
    if !wal_path.exists() {
        return Check {
            name: "WAL file",
            status: Status::Pass,
            detail: "not present (clean)".to_string(),
        };
    }

    match std::fs::metadata(&wal_path) {
        Ok(meta) => {
            let size_kb = meta.len() / 1024;
            if size_kb > 50_000 {
                Check {
                    name: "WAL file",
                    status: Status::Warn,
                    detail: format!("{} KB (large — may indicate checkpoint issue)", size_kb),
                }
            } else {
                Check {
                    name: "WAL file",
                    status: Status::Pass,
                    detail: format!("{} KB", size_kb),
                }
            }
        }
        Err(e) => Check {
            name: "WAL file",
            status: Status::Warn,
            detail: format!("cannot stat: {}", e),
        },
    }
}

fn check_port() -> Check {
    // Try to bind port 4000 briefly to see if it's available
    match std::net::TcpListener::bind("127.0.0.1:4000") {
        Ok(_) => Check {
            name: "Port 4000",
            status: Status::Pass,
            detail: "available (server not running)".to_string(),
        },
        Err(_) => Check {
            name: "Port 4000",
            status: Status::Pass,
            detail: "in use (server likely running)".to_string(),
        },
    }
}

fn check_health() -> Check {
    let ok = std::process::Command::new("curl")
        .args([
            "-s",
            "--connect-timeout",
            "1",
            "--max-time",
            "2",
            "http://127.0.0.1:4000/health",
        ])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if ok {
        Check {
            name: "Health check",
            status: Status::Pass,
            detail: "http://127.0.0.1:4000/health → OK".to_string(),
        }
    } else {
        Check {
            name: "Health check",
            status: Status::Warn,
            detail: "unreachable (server may not be running)".to_string(),
        }
    }
}

fn check_disk_space(data_dir: &Path) -> Check {
    #[cfg(unix)]
    {
        use std::ffi::CString;

        let c_path = match CString::new(data_dir.to_string_lossy().as_bytes()) {
            Ok(p) => p,
            Err(_) => {
                return Check {
                    name: "Disk space",
                    status: Status::Warn,
                    detail: "cannot check".to_string(),
                };
            }
        };

        unsafe {
            let mut stat: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c_path.as_ptr(), &mut stat) == 0 {
                let free_bytes = stat.f_bavail as u64 * stat.f_frsize;
                let free_gb = free_bytes / (1024 * 1024 * 1024);

                if free_gb < 1 {
                    return Check {
                        name: "Disk space",
                        status: Status::Fail,
                        detail: format!("{} GB free (critically low)", free_gb),
                    };
                } else if free_gb < 5 {
                    return Check {
                        name: "Disk space",
                        status: Status::Warn,
                        detail: format!("{} GB free (low)", free_gb),
                    };
                } else {
                    return Check {
                        name: "Disk space",
                        status: Status::Pass,
                        detail: format!("{} GB free", free_gb),
                    };
                }
            }
        }
    }

    Check {
        name: "Disk space",
        status: Status::Warn,
        detail: "cannot determine".to_string(),
    }
}
