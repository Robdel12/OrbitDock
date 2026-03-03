//! `orbitdock-server install-service` — generate and optionally enable a system service.
//!
//! macOS: ~/Library/LaunchAgents/com.orbitdock.server.plist
//! Linux: ~/.config/systemd/user/orbitdock-server.service

use std::io::Write as IoWrite;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Stdio;

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

const PATH_PROBE_SENTINEL: &str = "__ORBITDOCK_PATH__";
const COMMON_PATH_DIRS: [&str; 6] = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
];
const COMMON_CODEX_PATHS: [&str; 4] = [
    "/usr/local/bin/codex",
    "/opt/homebrew/bin/codex",
    "/usr/bin/codex",
    "/bin/codex",
];

const LAUNCHD_TEMPLATE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.orbitdock.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>{{BINARY_PATH}}</string>
        <string>start</string>
        <string>--bind</string>
        <string>{{BIND_ADDR}}</string>
        <string>--data-dir</string>
        <string>{{DATA_DIR}}</string>
    </array>
{{ENVIRONMENT_VARIABLES}}
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{{DATA_DIR}}/logs/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>{{DATA_DIR}}/logs/launchd-stderr.log</string>
</dict>
</plist>
"#;

const SYSTEMD_TEMPLATE: &str = r#"[Unit]
Description=OrbitDock Server — mission control for AI coding agents
After=network.target

[Service]
Type=simple
{{AUTH_TOKEN_ENV}}
ExecStart={{BINARY_PATH}} start --bind {{BIND_ADDR}} --data-dir {{DATA_DIR}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
"#;

pub struct ServiceOptions {
    pub bind: SocketAddr,
    pub enable: bool,
    pub tls_cert: Option<PathBuf>,
    pub tls_key: Option<PathBuf>,
    pub auth_token: Option<String>,
}

pub fn run(
    data_dir: &Path,
    bind: SocketAddr,
    enable: bool,
    auth_token: Option<String>,
) -> anyhow::Result<()> {
    run_with_opts(
        data_dir,
        ServiceOptions {
            bind,
            enable,
            tls_cert: None,
            tls_key: None,
            auth_token,
        },
    )
}

pub fn run_with_opts(data_dir: &Path, opts: ServiceOptions) -> anyhow::Result<()> {
    let binary_path = std::env::current_exe()?.to_string_lossy().to_string();
    let data_dir_str = data_dir.to_string_lossy().to_string();
    let bind_str = opts.bind.to_string();

    // Build extra args for TLS
    let mut extra_args = Vec::new();
    if let Some(ref cert) = opts.tls_cert {
        extra_args.push(format!("--tls-cert {}", cert.display()));
    }
    if let Some(ref key) = opts.tls_key {
        extra_args.push(format!("--tls-key {}", key.display()));
    }
    let extra = extra_args.join(" ");
    let auth_token = opts
        .auth_token
        .as_deref()
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(ToString::to_string);

    if cfg!(target_os = "macos") {
        install_launchd(
            &binary_path,
            &bind_str,
            &data_dir_str,
            &extra,
            auth_token.as_deref(),
            opts.enable,
        )
    } else {
        install_systemd(
            &binary_path,
            &bind_str,
            &data_dir_str,
            &extra,
            auth_token.as_deref(),
            opts.enable,
        )
    }
}

fn install_launchd(
    binary_path: &str,
    bind: &str,
    data_dir: &str,
    extra_args: &str,
    auth_token: Option<&str>,
    enable: bool,
) -> anyhow::Result<()> {
    let service_environment = resolve_service_environment();
    let mut environment_variables = vec![("PATH".to_string(), service_environment.path)];
    if let Some(codex_bin) = service_environment.codex_bin {
        environment_variables.push(("ORBITDOCK_CODEX_PATH".to_string(), codex_bin));
    }
    if let Some(claude_bin) = service_environment.claude_bin {
        environment_variables.push(("CLAUDE_BIN".to_string(), claude_bin));
    }
    if let Some(token) = auth_token {
        environment_variables.push(("ORBITDOCK_AUTH_TOKEN".to_string(), token.to_string()));
    }
    let environment_xml = render_launchd_environment_variables(&environment_variables);

    let mut plist = LAUNCHD_TEMPLATE
        .replace("{{BINARY_PATH}}", binary_path)
        .replace("{{BIND_ADDR}}", bind)
        .replace("{{DATA_DIR}}", data_dir)
        .replace("{{ENVIRONMENT_VARIABLES}}", &environment_xml);

    // Insert extra args (e.g. --tls-cert, --tls-key) into ProgramArguments
    if !extra_args.is_empty() {
        let extra_strings: String = extra_args
            .split_whitespace()
            .map(|arg| format!("        <string>{}</string>", arg))
            .collect::<Vec<_>>()
            .join("\n");
        plist = plist.replace(
            &format!("        <string>{}</string>\n    </array>", data_dir),
            &format!(
                "        <string>{}</string>\n{}\n    </array>",
                data_dir, extra_strings
            ),
        );
    }

    let agents_dir = dirs::home_dir()
        .expect("HOME not found")
        .join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents_dir)?;

    let plist_path = agents_dir.join("com.orbitdock.server.plist");
    write_service_file(&plist_path, &plist)?;
    println!("  Wrote {}", plist_path.display());

    if enable {
        // Unload first in case it's already loaded (ignore errors)
        let _ = std::process::Command::new("launchctl")
            .args(["unload", &plist_path.to_string_lossy()])
            .output();

        let output = std::process::Command::new("launchctl")
            .args(["load", &plist_path.to_string_lossy()])
            .output()?;

        if output.status.success() {
            println!("  Service loaded and started");
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            println!("  Warning: launchctl load failed: {}", stderr.trim());
        }
    } else {
        println!();
        println!("  To enable:");
        println!("    launchctl load {}", plist_path.display());
    }

    println!();
    Ok(())
}

struct ServiceEnvironment {
    path: String,
    codex_bin: Option<String>,
    claude_bin: Option<String>,
}

fn resolve_service_environment() -> ServiceEnvironment {
    let path = resolve_path_for_service();
    let path_entries = split_path_entries(&path);
    let codex_bin = resolve_codex_binary_for_service(&path_entries);
    let claude_bin = resolve_claude_binary_for_service(&path_entries);
    ServiceEnvironment {
        path,
        codex_bin,
        claude_bin,
    }
}

/// Resolve a PATH suitable for the launchd service environment.
///
/// Uses the current process PATH first (captured from the invoking shell).
/// Falls back to probing the login shell PATH and then to common defaults.
fn resolve_path_for_service() -> String {
    if let Some(path_env) = std::env::var_os("PATH") {
        let entries = std::env::split_paths(&path_env)
            .map(|path| path.to_string_lossy().to_string())
            .collect::<Vec<_>>();
        if let Some(path) = dedup_non_empty(entries) {
            return path;
        }
    }

    if let Some(path) = probe_login_shell_path().and_then(|value| normalize_path_env(&value)) {
        return path;
    }

    let mut entries = Vec::new();
    for dir in COMMON_PATH_DIRS {
        entries.push(dir.to_string());
    }

    if let Some(home) = dirs::home_dir() {
        for rel in [".local/bin", ".cargo/bin"] {
            let dir = home.join(rel);
            if dir.is_dir() {
                entries.push(dir.to_string_lossy().to_string());
            }
        }
    }

    dedup_non_empty(entries).unwrap_or_else(|| COMMON_PATH_DIRS.join(":"))
}

fn resolve_codex_binary_for_service(path_entries: &[String]) -> Option<String> {
    if let Some(path) = resolve_explicit_binary_env("ORBITDOCK_CODEX_PATH") {
        return Some(path);
    }

    for candidate in COMMON_CODEX_PATHS {
        let path = Path::new(candidate);
        if is_executable_file(path) {
            return Some(candidate.to_string());
        }
    }

    find_binary_in_path_entries("codex", path_entries)
}

fn resolve_claude_binary_for_service(path_entries: &[String]) -> Option<String> {
    if let Some(path) = resolve_explicit_binary_env("CLAUDE_BIN") {
        return Some(path);
    }

    if let Some(home) = dirs::home_dir() {
        let candidate = home.join(".claude/local/claude");
        if is_executable_file(&candidate) {
            return Some(candidate.to_string_lossy().to_string());
        }
    }

    find_binary_in_path_entries("claude", path_entries)
}

fn resolve_explicit_binary_env(env_var: &str) -> Option<String> {
    let value = std::env::var(env_var).ok()?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let path = Path::new(trimmed);
    if is_executable_file(path) {
        Some(path.to_string_lossy().to_string())
    } else {
        None
    }
}

fn find_binary_in_path_entries(binary_name: &str, path_entries: &[String]) -> Option<String> {
    for entry in path_entries {
        let candidate = Path::new(entry).join(binary_name);
        if is_executable_file(&candidate) {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
}

fn split_path_entries(path_env: &str) -> Vec<String> {
    std::env::split_paths(std::ffi::OsStr::new(path_env))
        .map(|path| path.to_string_lossy().to_string())
        .collect::<Vec<_>>()
}

fn normalize_path_env(path_env: &str) -> Option<String> {
    dedup_non_empty(split_path_entries(path_env))
}

fn probe_login_shell_path() -> Option<String> {
    let command = format!("printf '{}%s\\n' \"$PATH\"", PATH_PROBE_SENTINEL);
    let arg_sets = [
        vec!["-ilc".to_string(), command.clone()],
        vec!["-lc".to_string(), command.clone()],
        vec!["-c".to_string(), command],
    ];

    for shell in candidate_shells() {
        for args in arg_sets.iter().cloned() {
            let output = match std::process::Command::new(&shell)
                .args(args)
                .stderr(Stdio::null())
                .output()
            {
                Ok(output) => output,
                Err(_) => continue,
            };
            if !output.status.success() {
                continue;
            }
            let text = match String::from_utf8(output.stdout) {
                Ok(text) => text,
                Err(_) => continue,
            };
            if let Some(path) = extract_probe_path(&text) {
                return Some(path);
            }
        }
    }

    None
}

fn extract_probe_path(output: &str) -> Option<String> {
    let start = output.rfind(PATH_PROBE_SENTINEL)?;
    let path = &output[start + PATH_PROBE_SENTINEL.len()..];
    let first_line = path.lines().next()?.trim();
    if first_line.is_empty() {
        None
    } else {
        Some(first_line.to_string())
    }
}

fn candidate_shells() -> Vec<String> {
    let mut shells = Vec::new();
    if let Ok(shell) = std::env::var("SHELL") {
        shells.push(shell);
    }
    for fallback in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
        shells.push(fallback.to_string());
    }
    dedup_values(shells)
}

fn dedup_values(values: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut deduped = Vec::new();

    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        let normalized = trimmed.to_string();
        if seen.insert(normalized.clone()) {
            deduped.push(normalized);
        }
    }

    deduped
}

fn dedup_non_empty(values: Vec<String>) -> Option<String> {
    let deduped = dedup_values(values);
    if deduped.is_empty() {
        None
    } else {
        Some(deduped.join(":"))
    }
}

fn render_launchd_environment_variables(entries: &[(String, String)]) -> String {
    let mut xml = Vec::new();
    xml.push("    <key>EnvironmentVariables</key>".to_string());
    xml.push("    <dict>".to_string());
    for (key, value) in entries {
        xml.push(format!("        <key>{}</key>", escape_xml(key)));
        xml.push(format!("        <string>{}</string>", escape_xml(value)));
    }
    xml.push("    </dict>".to_string());
    xml.join("\n")
}

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|meta| meta.is_file())
        .unwrap_or(false)
}

fn install_systemd(
    binary_path: &str,
    bind: &str,
    data_dir: &str,
    extra_args: &str,
    auth_token: Option<&str>,
    enable: bool,
) -> anyhow::Result<()> {
    let auth_env = auth_token
        .map(|token| {
            format!(
                "Environment=\"ORBITDOCK_AUTH_TOKEN={}\"",
                escape_systemd_env(token)
            )
        })
        .unwrap_or_default();

    let mut unit = SYSTEMD_TEMPLATE
        .replace("{{BINARY_PATH}}", binary_path)
        .replace("{{BIND_ADDR}}", bind)
        .replace("{{DATA_DIR}}", data_dir)
        .replace("{{AUTH_TOKEN_ENV}}", &auth_env);

    // Append TLS flags to ExecStart line if present
    if !extra_args.is_empty() {
        unit = unit.replace(
            &format!("--data-dir {}", data_dir),
            &format!("--data-dir {} {}", data_dir, extra_args),
        );
    }

    let systemd_dir = dirs::home_dir()
        .expect("HOME not found")
        .join(".config/systemd/user");
    std::fs::create_dir_all(&systemd_dir)?;

    let unit_path = systemd_dir.join("orbitdock-server.service");
    write_service_file(&unit_path, &unit)?;
    println!("  Wrote {}", unit_path.display());

    // Reload systemd to pick up new/changed unit file
    let _ = std::process::Command::new("systemctl")
        .args(["--user", "daemon-reload"])
        .output();

    if enable {
        let output = std::process::Command::new("systemctl")
            .args(["--user", "enable", "--now", "orbitdock-server.service"])
            .output()?;

        if output.status.success() {
            println!("  Service enabled and started");
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            println!("  Warning: systemctl enable failed: {}", stderr.trim());
        }
    } else {
        println!();
        println!("  To enable:");
        println!("    systemctl --user enable --now orbitdock-server.service");
    }

    println!();
    Ok(())
}

fn escape_systemd_env(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn write_service_file(path: &Path, content: &str) -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        file.write_all(content.as_bytes())?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        Ok(())
    }

    #[cfg(not(unix))]
    {
        std::fs::write(path, content)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_probe_path_prefers_last_probe_output() {
        let output = "__ORBITDOCK_PATH__/tmp/old\nnoise\n__ORBITDOCK_PATH__/usr/bin:/bin\n";
        let path = extract_probe_path(output);
        assert_eq!(path.as_deref(), Some("/usr/bin:/bin"));
    }

    #[test]
    fn extract_probe_path_rejects_empty_paths() {
        let output = "__ORBITDOCK_PATH__\n";
        assert_eq!(extract_probe_path(output), None);
    }

    #[test]
    fn dedup_non_empty_removes_blanks_and_duplicates() {
        let values = vec![
            "".to_string(),
            " /usr/bin ".to_string(),
            "/bin".to_string(),
            "/usr/bin".to_string(),
            "   ".to_string(),
        ];
        assert_eq!(dedup_non_empty(values).as_deref(), Some("/usr/bin:/bin"));
    }

    #[test]
    fn normalize_path_env_dedups_empty_segments() {
        let path = normalize_path_env("/usr/bin::/bin:/usr/bin");
        assert_eq!(path.as_deref(), Some("/usr/bin:/bin"));
    }

    #[test]
    fn render_launchd_environment_variables_escapes_values() {
        let xml = render_launchd_environment_variables(&[
            ("PATH".to_string(), "/usr/bin:/bin".to_string()),
            (
                "CLAUDE_BIN".to_string(),
                "/tmp/claude & \"beta\"".to_string(),
            ),
        ]);
        assert!(xml.contains("<key>EnvironmentVariables</key>"));
        assert!(xml.contains("<key>PATH</key>"));
        assert!(xml.contains("<string>/usr/bin:/bin</string>"));
        assert!(xml.contains("<key>CLAUDE_BIN</key>"));
        assert!(xml.contains("<string>/tmp/claude &amp; &quot;beta&quot;</string>"));
    }
}
