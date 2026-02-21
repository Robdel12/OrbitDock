//! `orbitdock-server install-service` — generate and optionally enable a system service.
//!
//! macOS: ~/Library/LaunchAgents/com.orbitdock.server.plist
//! Linux: ~/.config/systemd/user/orbitdock-server.service

use std::net::SocketAddr;
use std::path::Path;

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

pub fn run(data_dir: &Path, bind: SocketAddr, enable: bool) -> anyhow::Result<()> {
    let binary_path = std::env::current_exe()?.to_string_lossy().to_string();
    let data_dir_str = data_dir.to_string_lossy().to_string();
    let bind_str = bind.to_string();

    if cfg!(target_os = "macos") {
        install_launchd(&binary_path, &bind_str, &data_dir_str, enable)
    } else {
        install_systemd(&binary_path, &bind_str, &data_dir_str, enable)
    }
}

fn install_launchd(
    binary_path: &str,
    bind: &str,
    data_dir: &str,
    enable: bool,
) -> anyhow::Result<()> {
    let plist = LAUNCHD_TEMPLATE
        .replace("{{BINARY_PATH}}", binary_path)
        .replace("{{BIND_ADDR}}", bind)
        .replace("{{DATA_DIR}}", data_dir);

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
    enable: bool,
) -> anyhow::Result<()> {
    let unit = SYSTEMD_TEMPLATE
        .replace("{{BINARY_PATH}}", binary_path)
        .replace("{{BIND_ADDR}}", bind)
        .replace("{{DATA_DIR}}", data_dir);

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
