//! `orbitdock doctor` — diagnostics checklist.
//!
//! Runs a battery of health checks and prints a summary.

use std::path::Path;

use crate::infrastructure::{auth_tokens, crypto, paths};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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

struct DoctorReport {
    checks: Vec<Check>,
    passed: u32,
    warned: u32,
    failed: u32,
}

struct HookTransportConfigStatus<'a> {
    path: &'a Path,
    server_url: Option<&'a str>,
    encrypted_token_present: bool,
    legacy_plaintext_token: bool,
    encrypted_token_decryptable: bool,
}

pub fn print_diagnostics(data_dir: &Path) -> anyhow::Result<()> {
    println!();
    println!("  OrbitDock Doctor");
    println!("  ───────────────");
    println!();

    let report = build_doctor_report(vec![
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
    ]);

    for check in &report.checks {
        println!("  {} {}: {}", check.status, check.name, check.detail);
    }

    println!();
    println!(
        "  Summary: {} passed, {} warnings, {} failed ({} total)",
        report.passed,
        report.warned,
        report.failed,
        report.checks.len()
    );
    println!();

    Ok(())
}

fn build_doctor_report(checks: Vec<Check>) -> DoctorReport {
    let mut passed = 0u32;
    let mut warned = 0u32;
    let mut failed = 0u32;

    for check in &checks {
        match check.status {
            Status::Pass => passed += 1,
            Status::Warn => warned += 1,
            Status::Fail => failed += 1,
        }
    }

    DoctorReport {
        checks,
        passed,
        warned,
        failed,
    }
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
            detail: "not found — run `orbitdock init`".to_string(),
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

    classify_auth_token(
        env_token.as_deref(),
        auth_tokens::active_token_count().map_err(|error| error.to_string()),
    )
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

    let encrypted_token_decryptable = parsed
        .get("auth_token_enc")
        .and_then(|v| v.as_str())
        .and_then(crypto::decrypt)
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false);

    classify_hook_transport_config(HookTransportConfigStatus {
        path: &config_path,
        server_url: parsed.get("server_url").and_then(|v| v.as_str()),
        encrypted_token_present: token_present,
        legacy_plaintext_token,
        encrypted_token_decryptable,
    })
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

    let found = count_registered_hooks(&content, &expected_hooks);
    classify_hook_registration(found, expected_hooks.len())
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
        Ok(meta) => classify_wal_size(meta.len() / 1024),
        Err(e) => Check {
            name: "WAL file",
            status: Status::Warn,
            detail: format!("cannot stat: {}", e),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_doctor_report, classify_auth_token, classify_disk_space_gb,
        classify_hook_registration, classify_hook_transport_config, classify_wal_size,
        count_registered_hooks, Check, HookTransportConfigStatus, Status,
    };
    #[test]
    fn doctor_report_counts_statuses() {
        let report = build_doctor_report(vec![
            Check {
                name: "one",
                status: Status::Pass,
                detail: "ok".to_string(),
            },
            Check {
                name: "two",
                status: Status::Warn,
                detail: "warn".to_string(),
            },
            Check {
                name: "three",
                status: Status::Fail,
                detail: "fail".to_string(),
            },
            Check {
                name: "four",
                status: Status::Pass,
                detail: "ok".to_string(),
            },
        ]);

        assert_eq!(report.passed, 2);
        assert_eq!(report.warned, 1);
        assert_eq!(report.failed, 1);
        assert_eq!(report.checks.len(), 4);
    }

    #[test]
    fn classify_hook_registration_distinguishes_full_partial_and_missing() {
        let pass = classify_hook_registration(15, 15);
        let warn = classify_hook_registration(4, 15);
        let fail = classify_hook_registration(0, 15);

        assert_eq!(pass.status, Status::Pass);
        assert_eq!(warn.status, Status::Warn);
        assert_eq!(fail.status, Status::Fail);
    }

    #[test]
    fn count_registered_hooks_requires_orbitdock_transport_markers() {
        let expected = ["SessionStart", "SessionEnd", "Notification"];
        let full = r#"{"hooks":{"SessionStart":"orbitdock hook-forward","SessionEnd":"orbitdock hook-forward","Notification":"orbitdock hook-forward"}}"#;
        let unrelated =
            r#"{"hooks":{"SessionStart":"python something","SessionEnd":"python something"}}"#;

        assert_eq!(count_registered_hooks(full, &expected), 3);
        assert_eq!(count_registered_hooks(unrelated, &expected), 0);
    }

    #[test]
    fn classify_hook_transport_config_handles_warning_cases() {
        let path = std::path::PathBuf::from("/tmp/hook-forward.json");

        let missing_server_url = classify_hook_transport_config(HookTransportConfigStatus {
            path: &path,
            server_url: None,
            encrypted_token_present: false,
            legacy_plaintext_token: false,
            encrypted_token_decryptable: false,
        });
        assert_eq!(missing_server_url.status, Status::Fail);

        let legacy_token = classify_hook_transport_config(HookTransportConfigStatus {
            path: &path,
            server_url: Some("http://127.0.0.1:4000"),
            encrypted_token_present: false,
            legacy_plaintext_token: true,
            encrypted_token_decryptable: false,
        });
        assert_eq!(legacy_token.status, Status::Warn);

        let undecryptable_token = classify_hook_transport_config(HookTransportConfigStatus {
            path: &path,
            server_url: Some("http://127.0.0.1:4000"),
            encrypted_token_present: true,
            legacy_plaintext_token: false,
            encrypted_token_decryptable: false,
        });
        assert_eq!(undecryptable_token.status, Status::Warn);

        let healthy = classify_hook_transport_config(HookTransportConfigStatus {
            path: &path,
            server_url: Some("http://127.0.0.1:4000"),
            encrypted_token_present: true,
            legacy_plaintext_token: false,
            encrypted_token_decryptable: true,
        });
        assert_eq!(healthy.status, Status::Pass);
    }

    #[test]
    fn wal_and_disk_classifiers_apply_thresholds() {
        assert_eq!(classify_wal_size(10).status, Status::Pass);
        assert_eq!(classify_wal_size(60_000).status, Status::Warn);

        assert_eq!(classify_disk_space_gb(0).status, Status::Fail);
        assert_eq!(classify_disk_space_gb(3).status, Status::Warn);
        assert_eq!(classify_disk_space_gb(12).status, Status::Pass);
    }

    #[test]
    fn auth_token_classifier_matches_user_facing_states() {
        let env_only = classify_auth_token(Some("abcd1234"), Ok(0));
        let db_only = classify_auth_token(None, Ok(2));
        let missing = classify_auth_token(None, Ok(0));

        assert_eq!(env_only.status, Status::Pass);
        assert_eq!(db_only.status, Status::Pass);
        assert_eq!(missing.status, Status::Warn);
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

                return classify_disk_space_gb(free_gb);
            }
        }
    }

    Check {
        name: "Disk space",
        status: Status::Warn,
        detail: "cannot determine".to_string(),
    }
}

fn classify_auth_token(env_token: Option<&str>, active_db_tokens: Result<i64, String>) -> Check {
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

fn classify_hook_transport_config(status: HookTransportConfigStatus<'_>) -> Check {
    let Some(server_url) = status.server_url else {
        return Check {
            name: "Hook transport",
            status: Status::Fail,
            detail: format!(
                "{} missing required field `server_url`",
                status.path.display()
            ),
        };
    };

    if status.legacy_plaintext_token && !status.encrypted_token_present {
        return Check {
            name: "Hook transport",
            status: Status::Warn,
            detail: format!(
                "{} uses legacy plaintext auth_token; rerun `orbitdock install-hooks`",
                status.path.display()
            ),
        };
    }

    if status.encrypted_token_present && !status.encrypted_token_decryptable {
        return Check {
            name: "Hook transport",
            status: Status::Warn,
            detail: format!(
                "{} has encrypted auth token but decryption failed (check encryption key)",
                status.path.display()
            ),
        };
    }

    Check {
        name: "Hook transport",
        status: Status::Pass,
        detail: format!(
            "{} (server_url={}, auth_token={})",
            status.path.display(),
            server_url,
            if status.encrypted_token_present {
                "set"
            } else {
                "unset"
            }
        ),
    }
}

fn count_registered_hooks(content: &str, expected_hooks: &[&str]) -> usize {
    if !(content.contains("orbitdock")
        || content.contains("hook.sh")
        || content.contains("hook-forward"))
    {
        return 0;
    }

    expected_hooks
        .iter()
        .filter(|hook| content.contains(**hook))
        .count()
}

fn classify_hook_registration(found: usize, expected_total: usize) -> Check {
    if found == expected_total {
        Check {
            name: "Claude hooks",
            status: Status::Pass,
            detail: format!("{}/{} hooks registered", found, expected_total),
        }
    } else if found > 0 {
        Check {
            name: "Claude hooks",
            status: Status::Warn,
            detail: format!(
                "{}/{} hooks registered (run install-hooks to fix)",
                found, expected_total
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

fn classify_wal_size(size_kb: u64) -> Check {
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

fn classify_disk_space_gb(free_gb: u64) -> Check {
    if free_gb < 1 {
        Check {
            name: "Disk space",
            status: Status::Fail,
            detail: format!("{} GB free (critically low)", free_gb),
        }
    } else if free_gb < 5 {
        Check {
            name: "Disk space",
            status: Status::Warn,
            detail: format!("{} GB free (low)", free_gb),
        }
    } else {
        Check {
            name: "Disk space",
            status: Status::Pass,
            detail: format!("{} GB free", free_gb),
        }
    }
}
