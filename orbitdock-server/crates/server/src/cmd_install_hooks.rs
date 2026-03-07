//! `orbitdock install-hooks` — configure Claude Code hooks.
//!
//! Safely merges OrbitDock hook entries into `~/.claude/settings.json`.
//! Hooks invoke `orbitdock hook-forward ...` directly; no shell script
//! install is required.

use std::io::{Read, Write};
#[cfg(unix)]
use std::mem::MaybeUninit;
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::{fs::OpenOptions, os::fd::AsRawFd};

use crate::{cmd_hook_forward, paths};

/// All Claude Code hook types we register for.
const HOOK_TYPES: &[(&str, &str)] = &[
    ("hooks.SessionStart", "claude_session_start"),
    ("hooks.SessionEnd", "claude_session_end"),
    ("hooks.UserPromptSubmit", "claude_status_event"),
    ("hooks.Stop", "claude_status_event"),
    ("hooks.Notification", "claude_status_event"),
    ("hooks.PreCompact", "claude_status_event"),
    ("hooks.TeammateIdle", "claude_status_event"),
    ("hooks.TaskCompleted", "claude_status_event"),
    ("hooks.ConfigChange", "claude_status_event"),
    ("hooks.PreToolUse", "claude_tool_event"),
    ("hooks.PostToolUse", "claude_tool_event"),
    ("hooks.PostToolUseFailure", "claude_tool_event"),
    ("hooks.PermissionRequest", "claude_tool_event"),
    ("hooks.SubagentStart", "claude_subagent_event"),
    ("hooks.SubagentStop", "claude_subagent_event"),
    // Intentionally excluded:
    // - WorktreeCreate: adding this hook replaces Claude's default git worktree behavior.
    // - WorktreeRemove: companion cleanup hook for custom worktree providers.
];

pub fn run(
    settings_path: Option<&Path>,
    server_url: Option<&str>,
    auth_token: Option<&str>,
) -> anyhow::Result<()> {
    let installer_mode = installer_mode();
    let settings_file = settings_path.map(PathBuf::from).unwrap_or_else(|| {
        dirs::home_dir()
            .expect("HOME not found")
            .join(".claude/settings.json")
    });

    let target_url = server_url.unwrap_or("http://127.0.0.1:4000");
    let resolved_auth_token = resolve_auth_token(target_url, auth_token)?;
    let transport_config_path =
        cmd_hook_forward::write_transport_config(target_url, resolved_auth_token.as_deref())?;
    let hook_binary = quote_for_shell(&resolve_hook_binary_path());

    // Read existing settings or start with empty object
    let existing = if settings_file.exists() {
        let content = std::fs::read_to_string(&settings_file)?;
        serde_json::from_str::<serde_json::Value>(&content)?
    } else {
        serde_json::json!({})
    };

    let mut settings = existing.clone();
    let obj = settings
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("settings.json is not a JSON object"))?;

    let mut added = Vec::new();
    let mut updated = Vec::new();

    for &(hook_key, hook_type) in HOOK_TYPES {
        let command = format!("{hook_binary} hook-forward {hook_type}");

        // Navigate to the nested key (e.g. hooks.SessionStart)
        let parts: Vec<&str> = hook_key.split('.').collect();
        let parent_key = parts[0];
        let child_key = parts[1];

        let hooks_obj = obj
            .entry(parent_key)
            .or_insert_with(|| serde_json::json!({}));
        let hooks_map = hooks_obj
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("settings.json '{}' is not an object", parent_key))?;

        // Claude Code hook format: each array entry wraps hooks in a `hooks` array
        let hook_entry = serde_json::json!({
            "hooks": [{
                "type": "command",
                "command": command,
                "async": true
            }]
        });

        if let Some(existing_hooks) = hooks_map.get_mut(child_key) {
            if !existing_hooks.is_array() {
                // Normalize legacy/object forms (e.g. Notification object) to array form.
                let normalized = existing_hooks.take();
                *existing_hooks = serde_json::json!([normalized]);
            }
            if let Some(arr) = existing_hooks.as_array_mut() {
                // Check if we already have an OrbitDock hook (could be nested or bare)
                let orbitdock_idx = arr.iter().position(|entry| {
                    // Check nested format: entry.hooks[].command
                    if let Some(hooks_arr) = entry.get("hooks").and_then(|h| h.as_array()) {
                        return hooks_arr.iter().any(|h| {
                            h.get("command")
                                .and_then(|c| c.as_str())
                                .map(|c| {
                                    c.contains("orbitdock")
                                        || c.contains("hook.sh")
                                        || c.contains("hook-forward")
                                })
                                .unwrap_or(false)
                        });
                    }
                    // Check bare format (legacy/broken): entry.command
                    entry
                        .get("command")
                        .and_then(|c| c.as_str())
                        .map(|c| {
                            c.contains("orbitdock")
                                || c.contains("hook.sh")
                                || c.contains("hook-forward")
                        })
                        .unwrap_or(false)
                });

                if let Some(idx) = orbitdock_idx {
                    arr[idx] = hook_entry;
                    updated.push(hook_key);
                } else {
                    arr.push(hook_entry);
                    added.push(hook_key);
                }
            }
        } else {
            hooks_map.insert(child_key.to_string(), serde_json::json!([hook_entry]));
            added.push(hook_key);
        }
    }

    // Back up original
    if settings_file.exists() {
        let backup = settings_file.with_extension("json.bak");
        std::fs::copy(&settings_file, &backup)?;
        if !installer_mode {
            println!(
                "  Backed up {} → {}",
                settings_file.display(),
                backup.display()
            );
        }
    }

    // Ensure parent dir exists
    if let Some(parent) = settings_file.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Write updated settings
    let formatted = serde_json::to_string_pretty(&settings)?;
    std::fs::write(&settings_file, formatted)?;

    println!();
    if installer_mode {
        println!("  Claude Code hooks ready in {}", settings_file.display());
    } else {
        if !added.is_empty() {
            println!("  Added {} hook(s):", added.len());
            for h in &added {
                println!("    + {}", h);
            }
        }
        if !updated.is_empty() {
            println!("  Updated {} hook(s):", updated.len());
            for h in &updated {
                println!("    ~ {}", h);
            }
        }
        println!();
        println!("  Settings written to {}", settings_file.display());
    }
    println!(
        "  Hook transport config: {}",
        transport_config_path.display()
    );
    match resolved_auth_token.as_deref() {
        Some(_) => println!("  Hook auth token: configured"),
        None if should_prompt_for_auth_token(target_url) => {
            println!("  Hook auth token: not configured");
            println!(
                "  Remote requests may be rejected until you rerun `orbitdock install-hooks` with a token."
            );
        }
        None if !installer_mode => println!("  Hook auth token: not configured"),
        None => {}
    }
    if !installer_mode {
        println!("  Hook forward binary: {}", resolve_hook_binary_path());
        println!("  Spool directory: {}", paths::spool_dir().display());
    }
    println!();

    Ok(())
}

fn installer_mode() -> bool {
    std::env::var_os("ORBITDOCK_INSTALLER_MODE").is_some()
}

fn resolve_auth_token(
    server_url: &str,
    auth_token: Option<&str>,
) -> anyhow::Result<Option<String>> {
    let explicit_token = normalized_non_empty(auth_token);
    if explicit_token.is_some() || !should_prompt_for_auth_token(server_url) {
        return Ok(explicit_token);
    }

    let prompted_token = prompt_auth_token(server_url)?;
    Ok(prompted_token)
}

fn should_prompt_for_auth_token(server_url: &str) -> bool {
    !is_local_server_url(server_url)
}

fn is_local_server_url(server_url: &str) -> bool {
    let trimmed = server_url.trim();
    if trimmed.is_empty() {
        return true;
    }

    if let Ok(url) = reqwest::Url::parse(trimmed) {
        return url.host_str().map(is_local_host).unwrap_or(false);
    }

    trimmed.contains("127.0.0.1")
        || trimmed.contains("localhost")
        || trimmed.contains("[::1]")
        || trimmed.contains("://0.0.0.0")
}

fn is_local_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1" | "0.0.0.0")
}

fn normalized_non_empty(value: Option<&str>) -> Option<String> {
    let value = value?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(unix)]
fn prompt_auth_token(server_url: &str) -> anyhow::Result<Option<String>> {
    let mut tty = match OpenOptions::new().read(true).write(true).open("/dev/tty") {
        Ok(file) => file,
        Err(_) => return Ok(None),
    };

    writeln!(tty)?;
    writeln!(tty, "  Remote server detected: {server_url}")?;
    writeln!(
        tty,
        "  Enter the auth token to store in the local hook transport config."
    )?;
    writeln!(
        tty,
        "  Press Enter only if this remote server is intentionally running without auth."
    )?;
    write!(tty, "  Auth token: ")?;
    tty.flush()?;

    let token = read_hidden_line(&mut tty)?;
    writeln!(tty)?;
    Ok(normalized_non_empty(Some(token.as_str())))
}

#[cfg(not(unix))]
fn prompt_auth_token(_server_url: &str) -> anyhow::Result<Option<String>> {
    Ok(None)
}

#[cfg(unix)]
fn read_hidden_line(file: &mut std::fs::File) -> anyhow::Result<String> {
    let fd = file.as_raw_fd();
    let original = current_termios(fd)?;
    let mut hidden = original;
    hidden.c_lflag &= !libc::ECHO;

    if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &hidden) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }

    let _restore = TermiosRestoreGuard { fd, original };
    let mut bytes = Vec::new();

    loop {
        let mut buf = [0u8; 1];
        match file.read(&mut buf) {
            Ok(0) => break,
            Ok(_) if matches!(buf[0], b'\n' | b'\r') => break,
            Ok(_) => bytes.push(buf[0]),
            Err(err) => return Err(err.into()),
        }
    }

    Ok(String::from_utf8(bytes)?)
}

#[cfg(unix)]
fn current_termios(fd: i32) -> anyhow::Result<libc::termios> {
    let mut termios = MaybeUninit::<libc::termios>::uninit();
    if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(unsafe { termios.assume_init() })
}

#[cfg(unix)]
struct TermiosRestoreGuard {
    fd: i32,
    original: libc::termios,
}

#[cfg(unix)]
impl Drop for TermiosRestoreGuard {
    fn drop(&mut self) {
        let _ = unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, &self.original) };
    }
}

fn resolve_hook_binary_path() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok())
        .unwrap_or_else(|| "orbitdock".to_string())
}

fn quote_for_shell(path: &str) -> String {
    format!("\"{}\"", path.replace('\\', "\\\\").replace('"', "\\\""))
}
