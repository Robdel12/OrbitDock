//! `orbitdock remote-setup` — guide secure remote exposure for an existing install.

use std::fs;
use std::io::{self, BufRead, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use crate::{auth_tokens, cmd_install_hooks, cmd_install_service, cmd_status};

const LOCAL_BIND_ADDR: &str = "127.0.0.1:4000";
const REMOTE_BIND_ADDR: &str = "0.0.0.0:4000";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ExposureMode {
    Cloudflare,
    Tailscale,
    ReverseProxy,
    Direct,
}

impl ExposureMode {
    fn label(self) -> &'static str {
        match self {
            Self::Cloudflare => "Cloudflare Tunnel",
            Self::Tailscale => "Tailscale",
            Self::ReverseProxy => "Existing HTTPS reverse proxy",
            Self::Direct => "Direct bind / LAN / public IP",
        }
    }

    fn desired_bind(self) -> SocketAddr {
        match self {
            Self::Cloudflare | Self::ReverseProxy => LOCAL_BIND_ADDR.parse().unwrap(),
            Self::Tailscale | Self::Direct => REMOTE_BIND_ADDR.parse().unwrap(),
        }
    }

    fn default_public_url(self) -> Option<String> {
        match self {
            Self::Tailscale => detect_tailscale_url(),
            Self::Direct => Some("http://your-server.example.com:4000".to_string()),
            Self::Cloudflare | Self::ReverseProxy => None,
        }
    }

    fn public_url_prompt(self) -> Option<&'static str> {
        match self {
            Self::Cloudflare => {
                Some("Public HTTPS URL for clients (leave blank if you'll create the tunnel later)")
            }
            Self::ReverseProxy => {
                Some("Public HTTPS URL for clients (leave blank if you'll finish the proxy later)")
            }
            Self::Tailscale => None,
            Self::Direct => Some("Reachable URL for clients (leave blank to use a placeholder)"),
        }
    }
}

#[derive(Debug)]
struct ServiceState {
    path: PathBuf,
    installed: bool,
    bind: Option<SocketAddr>,
}

pub fn run(data_dir: &Path) -> anyhow::Result<()> {
    println!();
    println!("  OrbitDock Remote Setup");
    println!("  ======================");
    println!();

    let service_state = detect_service_state()?;
    let active_tokens = auth_tokens::active_token_count().unwrap_or(0);

    println!("  Current state:");
    if service_state.installed {
        if let Some(bind) = service_state.bind {
            println!(
                "  Service: {} (bind {})",
                service_state.path.display(),
                bind
            );
        } else {
            println!(
                "  Service: {} (installed, bind unknown)",
                service_state.path.display()
            );
        }
    } else {
        println!("  Service: not installed");
    }
    println!("  Auth tokens: {} active", active_tokens);
    println!();

    let exposure = prompt_exposure_mode()?;
    let desired_bind = exposure.desired_bind();
    let public_url = resolve_public_url(exposure)?;
    let configure_service = prompt_service_choice(&service_state, desired_bind)?;
    let configure_local_hooks =
        prompt_yes_no("Will Claude Code run on this machine too? [y/N]", false)?;

    println!();
    println!("  Generating a fresh auth token for this remote setup...");
    let token = cmd_status::create_token(data_dir)?;
    println!("  Token: {}", token);
    println!("  Copy it now and store it somewhere secure.");
    println!("  (Stored hashed in the database; OrbitDock will not print it again.)");

    if configure_service {
        println!();
        println!(
            "  Configuring background service for {} (bind {})...",
            exposure.label(),
            desired_bind
        );
        cmd_install_service::run(data_dir, desired_bind, true, None)?;
    } else if service_state.installed {
        println!();
        println!("  Leaving the existing background service unchanged.");
    } else {
        println!();
        println!("  Background service not installed.");
    }

    if configure_local_hooks {
        println!();
        println!("  Configuring local Claude Code hooks for http://127.0.0.1:4000...");
        std::env::set_var("ORBITDOCK_INSTALLER_MODE", "1");
        let hook_result =
            cmd_install_hooks::run(None, Some("http://127.0.0.1:4000"), Some(token.as_str()));
        std::env::remove_var("ORBITDOCK_INSTALLER_MODE");
        hook_result?;
    } else {
        println!();
        println!("  Local Claude Code hooks were left unchanged.");
    }

    print_summary(
        exposure,
        desired_bind,
        service_state,
        configure_service,
        configure_local_hooks,
        public_url.as_deref(),
    );

    Ok(())
}

fn prompt_exposure_mode() -> anyhow::Result<ExposureMode> {
    println!("  How should other devices reach this server?");
    println!();
    println!("    1) Cloudflare Tunnel (recommended)");
    println!("    2) Tailscale");
    println!("    3) Existing HTTPS reverse proxy");
    println!("    4) Direct bind / LAN / public IP (advanced)");
    println!();

    loop {
        print!("  Choice [1]: ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().lock().read_line(&mut input)?;

        match input.trim() {
            "" | "1" | "cloudflare" => return Ok(ExposureMode::Cloudflare),
            "2" | "tailscale" => return Ok(ExposureMode::Tailscale),
            "3" | "proxy" | "reverse-proxy" => return Ok(ExposureMode::ReverseProxy),
            "4" | "direct" | "lan" => return Ok(ExposureMode::Direct),
            _ => println!("  Please choose 1, 2, 3, or 4."),
        }
    }
}

fn prompt_service_choice(
    service_state: &ServiceState,
    desired_bind: SocketAddr,
) -> anyhow::Result<bool> {
    println!();
    if service_state.installed {
        let current = service_state
            .bind
            .map(|bind| bind.to_string())
            .unwrap_or_else(|| "unknown".to_string());
        return prompt_yes_no(
            &format!(
                "Update the existing background service (current bind {}, desired bind {})? [Y/n]",
                current, desired_bind
            ),
            true,
        );
    }

    prompt_yes_no(
        "Install OrbitDock as a background service on this machine? [Y/n]",
        true,
    )
}

fn prompt_yes_no(prompt: &str, default_yes: bool) -> anyhow::Result<bool> {
    loop {
        print!("  {} ", prompt);
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().lock().read_line(&mut input)?;
        let trimmed = input.trim();

        if trimmed.is_empty() {
            return Ok(default_yes);
        }

        match trimmed.to_ascii_lowercase().as_str() {
            "y" | "yes" => return Ok(true),
            "n" | "no" => return Ok(false),
            _ => println!("  Please answer y or n."),
        }
    }
}

fn resolve_public_url(exposure: ExposureMode) -> anyhow::Result<Option<String>> {
    let default_url = exposure.default_public_url();
    let Some(prompt) = exposure.public_url_prompt() else {
        return Ok(default_url);
    };

    println!();
    print!("  {}: ", prompt);
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let trimmed = input.trim();

    if trimmed.is_empty() {
        return Ok(default_url);
    }

    let default_scheme = match exposure {
        ExposureMode::Cloudflare | ExposureMode::ReverseProxy => "https",
        ExposureMode::Tailscale | ExposureMode::Direct => "http",
    };

    Ok(Some(normalize_public_url(trimmed, default_scheme)))
}

fn normalize_public_url(value: &str, default_scheme: &str) -> String {
    let trimmed = value.trim().trim_end_matches('/');
    if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("{default_scheme}://{trimmed}")
    }
}

fn detect_service_state() -> anyhow::Result<ServiceState> {
    let path = service_file_path();
    if !path.exists() {
        return Ok(ServiceState {
            path,
            installed: false,
            bind: None,
        });
    }

    let content = fs::read_to_string(&path)?;
    let bind = if cfg!(target_os = "macos") {
        parse_launchd_bind(&content)
    } else {
        parse_systemd_bind(&content)
    };

    Ok(ServiceState {
        path,
        installed: true,
        bind,
    })
}

fn service_file_path() -> PathBuf {
    let home = dirs::home_dir().expect("HOME not found");
    if cfg!(target_os = "macos") {
        home.join("Library/LaunchAgents/com.orbitdock.server.plist")
    } else {
        home.join(".config/systemd/user/orbitdock-server.service")
    }
}

fn parse_launchd_bind(content: &str) -> Option<SocketAddr> {
    let lines = content.lines().collect::<Vec<_>>();
    for window in lines.windows(3) {
        if window[0].contains("<string>--bind</string>") {
            let raw = strip_string_tag(window[1])?;
            return raw.parse().ok();
        }
    }
    None
}

fn parse_systemd_bind(content: &str) -> Option<SocketAddr> {
    let exec_line = content
        .lines()
        .find(|line| line.trim_start().starts_with("ExecStart="))?;
    let bind_flag = exec_line.find("--bind")?;
    let after_flag = &exec_line[bind_flag + "--bind".len()..];
    let bind_value = after_flag.trim_start().split_whitespace().next()?;
    bind_value.parse().ok()
}

fn strip_string_tag(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    let start = trimmed.strip_prefix("<string>")?;
    start.strip_suffix("</string>")
}

fn detect_tailscale_url() -> Option<String> {
    let output = std::process::Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let self_node = json.get("Self")?;
    let addrs = self_node.get("TailscaleIPs")?.as_array()?;
    let ip = addrs
        .iter()
        .find(|a| a.as_str().map(|s| !s.contains(':')).unwrap_or(false))
        .or_else(|| addrs.first())?
        .as_str()?;

    Some(format!("http://{}:4000", ip))
}

fn print_summary(
    exposure: ExposureMode,
    desired_bind: SocketAddr,
    previous_service_state: ServiceState,
    service_configured: bool,
    local_hooks_configured: bool,
    public_url: Option<&str>,
) {
    println!();
    println!("  Remote setup complete!");
    println!("  ─────────────────────");
    println!();
    println!("  Exposure: {}", exposure.label());
    println!("  Bind:     {}", desired_bind);

    if service_configured {
        println!("  Service:  configured for {}", desired_bind);
    } else if previous_service_state.installed {
        let current = previous_service_state
            .bind
            .map(|bind| bind.to_string())
            .unwrap_or_else(|| "unknown".to_string());
        println!("  Service:  left unchanged ({})", current);
    } else {
        println!("  Service:  not installed");
    }

    println!(
        "  Hooks:    {}",
        if local_hooks_configured {
            "local Claude Code hooks configured"
        } else {
            "local Claude Code hooks left unchanged"
        }
    );
    println!();

    match exposure {
        ExposureMode::Cloudflare => {
            println!("  Recommended next step:");
            println!("    Put Cloudflare in front of http://127.0.0.1:4000");
            println!(
                "    `orbitdock tunnel` is fine for quick testing, but not the long-term setup."
            );
        }
        ExposureMode::ReverseProxy => {
            println!("  Recommended next step:");
            println!("    Point your reverse proxy at http://127.0.0.1:4000");
        }
        ExposureMode::Tailscale => {
            println!("  Recommended next step:");
            println!(
                "    Confirm your Tailscale device can reach {}",
                desired_bind
            );
        }
        ExposureMode::Direct => {
            println!("  Recommended next step:");
            println!("    Lock down firewall/network exposure before connecting clients.");
        }
    }
    println!();

    let url = public_url.unwrap_or_else(|| match exposure {
        ExposureMode::Cloudflare | ExposureMode::ReverseProxy => "https://your-server.example.com",
        ExposureMode::Tailscale => "http://100.x.y.z:4000",
        ExposureMode::Direct => "http://your-server.example.com:4000",
    });

    println!("  Connect the macOS/iOS app:");
    println!("    Server URL: {}", url);
    println!("    Auth token: use the token printed above");
    println!();
    println!("  Pair with QR / connection URL:");
    println!("    orbitdock pair --tunnel-url {}", url);
    println!();
    println!("  Connect another developer machine (hooks only):");
    println!("    orbitdock install-hooks --server-url {}", url);
    println!("    # Enter the auth token when prompted.");
    println!();

    if !service_configured && !previous_service_state.installed {
        println!("  Start manually when you're ready:");
        println!("    orbitdock start --bind {}", desired_bind);
        println!();
    } else if !service_configured && previous_service_state.bind != Some(desired_bind) {
        println!("  Your current background service is still using a different bind.");
        println!("  To use this remote exposure mode without changing the service:");
        println!("    orbitdock start --bind {}", desired_bind);
        println!();
    }
}

#[cfg(test)]
mod tests {
    use super::{normalize_public_url, parse_launchd_bind, parse_systemd_bind};

    #[test]
    fn normalize_public_url_adds_https_scheme() {
        assert_eq!(
            normalize_public_url("orbitdock.example.com:4000/", "https"),
            "https://orbitdock.example.com:4000"
        );
    }

    #[test]
    fn parse_launchd_bind_reads_bind_address() {
        let content = r#"
        <string>start</string>
        <string>--bind</string>
        <string>127.0.0.1:4000</string>
        "#;
        let bind = parse_launchd_bind(content).expect("bind");
        assert_eq!(bind.to_string(), "127.0.0.1:4000");
    }

    #[test]
    fn parse_systemd_bind_reads_bind_address() {
        let content = r#"ExecStart=/Users/test/.orbitdock/bin/orbitdock start --bind 0.0.0.0:4000 --data-dir /Users/test/.orbitdock"#;
        let bind = parse_systemd_bind(content).expect("bind");
        assert_eq!(bind.to_string(), "0.0.0.0:4000");
    }
}
