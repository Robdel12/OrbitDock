//! `orbitdock-server install-service` — generate and optionally enable a system service.
//!
//! macOS: ~/Library/LaunchAgents/com.orbitdock.server.plist
//! Linux: ~/.config/systemd/user/orbitdock-server.service

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

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
}

pub fn run(data_dir: &Path, bind: SocketAddr, enable: bool) -> anyhow::Result<()> {
    run_with_opts(
        data_dir,
        ServiceOptions {
            bind,
            enable,
            tls_cert: None,
            tls_key: None,
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

    if cfg!(target_os = "macos") {
        install_launchd(&binary_path, &bind_str, &data_dir_str, &extra, opts.enable)
    } else {
        install_systemd(&binary_path, &bind_str, &data_dir_str, &extra, opts.enable)
    }
}

fn install_launchd(
    binary_path: &str,
    bind: &str,
    data_dir: &str,
    extra_args: &str,
    enable: bool,
) -> anyhow::Result<()> {
    let mut plist = LAUNCHD_TEMPLATE
        .replace("{{BINARY_PATH}}", binary_path)
        .replace("{{BIND_ADDR}}", bind)
        .replace("{{DATA_DIR}}", data_dir);

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
    std::fs::write(&plist_path, &plist)?;
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

fn install_systemd(
    binary_path: &str,
    bind: &str,
    data_dir: &str,
    extra_args: &str,
    enable: bool,
) -> anyhow::Result<()> {
    let mut unit = SYSTEMD_TEMPLATE
        .replace("{{BINARY_PATH}}", binary_path)
        .replace("{{BIND_ADDR}}", bind)
        .replace("{{DATA_DIR}}", data_dir);

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
    std::fs::write(&unit_path, &unit)?;
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
