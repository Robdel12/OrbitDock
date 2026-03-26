//! `orbitdock setup` — interactive setup wizard.
//!
//! Combines `init` + `install-hooks` + `generate-token` + `install-service`
//! into a single guided flow for both local and remote deployments.

use std::io::{self, BufRead, Write};
use std::net::SocketAddr;
use std::path::Path;

use orbitdock_protocol::WorkspaceProviderKind;

use super::{init, install_hooks, install_service, status};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mode {
    Local,
    Remote,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SetupOptions {
    pub mode: Option<Mode>,
    pub bind: Option<SocketAddr>,
    pub server_url: Option<String>,
    pub workspace_provider: Option<WorkspaceProviderKind>,
    pub skip_service: bool,
    pub skip_hooks: bool,
}

#[derive(Debug, Clone, PartialEq)]
struct SetupPlan {
    mode: Mode,
    bind: SocketAddr,
    workspace_provider: WorkspaceProviderKind,
    init_url: String,
    hook_url: Option<String>,
    should_issue_token: bool,
    should_install_hooks: bool,
    should_install_service: bool,
    warn_missing_remote_server_url: bool,
}

pub fn run_setup_wizard(data_dir: &Path, opts: SetupOptions) -> anyhow::Result<()> {
    println!();
    println!("  OrbitDock Server Setup");
    println!("  =====================");
    println!();

    let mode = match opts.mode {
        Some(m) => m,
        None => prompt_mode()?,
    };
    let workspace_provider = match opts.workspace_provider {
        Some(provider) => provider,
        None => prompt_workspace_provider()?,
    };
    let plan = plan_setup(mode, workspace_provider, &opts);

    let auth_token = if plan.should_issue_token {
        println!("  Generating auth token...");
        let token = status::issue_auth_token(data_dir)?;
        println!("  Auth token: {}", token);
        println!("  Copy it now and store it somewhere secure.");
        println!("  (Stored hashed in the database; OrbitDock will not print it again.)");
        println!();
        Some(token)
    } else {
        None
    };

    render_setup_warnings(&plan);

    println!("  Running init...");
    init::initialize_data_dir(data_dir, &plan.init_url, plan.workspace_provider)?;

    if plan.should_install_hooks {
        println!("  Installing Claude Code hooks...");
        install_hooks::install_claude_hooks(None, plan.hook_url.as_deref(), auth_token.as_deref())?;
    } else {
        println!("  Skipping hook installation.");
    }

    if plan.should_install_service {
        println!("  Installing system service...");
        install_service::install_background_service(data_dir, plan.bind, true, None)?;
    } else {
        println!("  Skipping service installation.");
    }

    render_setup_summary(&plan, auth_token.is_some());

    Ok(())
}

fn plan_setup(
    mode: Mode,
    workspace_provider: WorkspaceProviderKind,
    opts: &SetupOptions,
) -> SetupPlan {
    let bind = opts.bind.unwrap_or_else(|| match mode {
        Mode::Local => "0.0.0.0:4000".parse().unwrap(),
        Mode::Remote => "0.0.0.0:4000".parse().unwrap(),
    });
    let local_connect_url = crate::admin::normalize_client_server_url(&format!("http://{bind}"));

    SetupPlan {
        mode,
        bind,
        workspace_provider,
        init_url: match mode {
            Mode::Local => local_connect_url.clone(),
            Mode::Remote => "http://127.0.0.1:4000".to_string(),
        },
        hook_url: match mode {
            Mode::Local => None,
            Mode::Remote => opts.server_url.clone(),
        },
        should_issue_token: mode == Mode::Remote,
        should_install_hooks: !opts.skip_hooks,
        should_install_service: !opts.skip_service,
        warn_missing_remote_server_url: mode == Mode::Remote && opts.server_url.is_none(),
    }
}

fn render_setup_warnings(plan: &SetupPlan) {
    if !plan.warn_missing_remote_server_url {
        return;
    }

    println!("  \x1b[33m[WARN]\x1b[0m No --server-url provided for remote mode.");
    println!("         Hooks on this machine will keep pointing to localhost.");
    println!("         For remote machines, use a public HTTPS URL when running:");
    println!("         orbitdock install-hooks --server-url https://your-server.example.com:4000");
    println!();
}

fn render_setup_summary(plan: &SetupPlan, auth_token_issued: bool) {
    println!();
    println!("  Setup complete!");
    println!("  ──────────────");
    println!();

    match plan.mode {
        Mode::Local => {
            println!("  Mode:    Local");
            println!("  Provider: {}", plan.workspace_provider.as_str());
            println!("  Bind:    {}", plan.bind);
            println!(
                "  Health:  {}/health",
                crate::admin::normalize_client_server_url(&format!("http://{}", plan.bind))
            );
            println!();
            println!("  Your Claude Code sessions will auto-report to this server.");
        }
        Mode::Remote => {
            println!("  Mode:    Remote");
            println!("  Provider: {}", plan.workspace_provider.as_str());
            println!("  Bind:    {}", plan.bind);
            println!();
            println!("  Start the server:");
            println!("    orbitdock start --bind {}", plan.bind);
            println!();
            println!("  Connect a remote developer machine (hooks only):");
            let remote_url = plan
                .hook_url
                .clone()
                .unwrap_or_else(|| "https://your-server.example.com:4000".to_string());
            println!("    orbitdock install-hooks --server-url {}", remote_url);
            if auth_token_issued {
                println!("  The installer will prompt for the auth token.");
                println!("  You can also set ORBITDOCK_AUTH_TOKEN before running it.");
            }
        }
    }
    println!();
}

fn prompt_mode() -> anyhow::Result<Mode> {
    println!("  How will you use this server?");
    println!();
    println!("    1) Local    — runs on this machine and is reachable on your LAN");
    println!("    2) Remote   — accessible from other machines (generates auth token)");
    println!();
    print!("  Choice [1]: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let trimmed = input.trim();

    match trimmed {
        "" | "1" | "local" => Ok(Mode::Local),
        "2" | "remote" => Ok(Mode::Remote),
        _ => {
            println!("  Invalid choice, defaulting to local.");
            Ok(Mode::Local)
        }
    }
}

fn prompt_workspace_provider() -> anyhow::Result<WorkspaceProviderKind> {
    println!("  Which workspace provider should OrbitDock use?");
    println!();
    println!("    1) Local    — create git worktrees and run agents on this machine");
    println!();
    print!("  Choice [1]: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let trimmed = input.trim();

    match trimmed {
        "" | "1" | "local" => Ok(WorkspaceProviderKind::Local),
        _ => {
            println!("  Invalid choice, defaulting to local.");
            Ok(WorkspaceProviderKind::Local)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{plan_setup, Mode, SetupOptions};
    use orbitdock_protocol::WorkspaceProviderKind;

    #[test]
    fn local_setup_plan_defaults_to_lan_bind() {
        let plan = plan_setup(
            Mode::Local,
            WorkspaceProviderKind::Local,
            &SetupOptions {
                mode: Some(Mode::Local),
                bind: None,
                server_url: None,
                workspace_provider: Some(WorkspaceProviderKind::Local),
                skip_service: false,
                skip_hooks: false,
            },
        );

        assert_eq!(plan.workspace_provider, WorkspaceProviderKind::Local);
        assert_eq!(plan.bind.to_string(), "0.0.0.0:4000");
        assert_eq!(plan.init_url, "http://127.0.0.1:4000");
        assert_eq!(plan.hook_url, None);
        assert!(!plan.should_issue_token);
        assert!(plan.should_install_hooks);
        assert!(plan.should_install_service);
        assert!(!plan.warn_missing_remote_server_url);
    }

    #[test]
    fn remote_setup_plan_defaults_to_remote_bind_and_warns_without_public_url() {
        let plan = plan_setup(
            Mode::Remote,
            WorkspaceProviderKind::Local,
            &SetupOptions {
                mode: Some(Mode::Remote),
                bind: None,
                server_url: None,
                workspace_provider: Some(WorkspaceProviderKind::Local),
                skip_service: false,
                skip_hooks: false,
            },
        );

        assert_eq!(plan.bind.to_string(), "0.0.0.0:4000");
        assert_eq!(plan.init_url, "http://127.0.0.1:4000");
        assert_eq!(plan.hook_url, None);
        assert!(plan.should_issue_token);
        assert!(plan.warn_missing_remote_server_url);
    }

    #[test]
    fn setup_plan_respects_skip_flags_and_explicit_remote_url() {
        let plan = plan_setup(
            Mode::Remote,
            WorkspaceProviderKind::Local,
            &SetupOptions {
                mode: Some(Mode::Remote),
                bind: Some("10.0.0.5:4000".parse().unwrap()),
                server_url: Some("https://dock.example.com:4000".to_string()),
                workspace_provider: Some(WorkspaceProviderKind::Local),
                skip_service: true,
                skip_hooks: true,
            },
        );

        assert_eq!(plan.bind.to_string(), "10.0.0.5:4000");
        assert_eq!(plan.init_url, "http://127.0.0.1:4000");
        assert_eq!(
            plan.hook_url.as_deref(),
            Some("https://dock.example.com:4000")
        );
        assert!(!plan.should_install_hooks);
        assert!(!plan.should_install_service);
        assert!(!plan.warn_missing_remote_server_url);
    }
}
