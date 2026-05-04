use clap::{Parser, Subcommand, ValueEnum};
use orbitdock_protocol::WorkspaceProviderKind;

use super::shared::{
  ApprovalAction, AuthAction, CodexAction, ConfigAction, FsAction, McpAction, MissionAction,
  ModelAction, ReviewAction, ServerAction, SessionAction, ShellAction, UsageAction, WorktreeAction,
};

#[derive(Parser, Debug)]
#[command(
  name = "orbitdock",
  about = "OrbitDock — mission control for AI coding agents",
  version = orbitdock_server::VERSION
)]
pub struct BinaryCli {
  /// Data directory (default: ~/.orbitdock)
  #[arg(long, global = true, env = "ORBITDOCK_DATA_DIR")]
  pub data_dir: Option<std::path::PathBuf>,

  /// Server URL for client commands (default: http://127.0.0.1:4000)
  #[arg(long, short = 's', global = true, env = "ORBITDOCK_URL")]
  pub server: Option<String>,

  /// Bearer auth token for client commands
  #[arg(long, short = 't', global = true, env = "ORBITDOCK_TOKEN")]
  pub token: Option<String>,

  /// Output as JSON (auto-enabled when stdout is not a TTY)
  #[arg(long, short = 'j', global = true)]
  pub json: bool,

  /// Path to config file
  #[arg(long, global = true, env = "ORBITDOCK_CONFIG")]
  pub config: Option<String>,

  #[command(subcommand)]
  pub command: Option<BinaryCommand>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum SetupPath {
  Local,
  Server,
  Client,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum HookForwardType {
  ClaudeSessionStart,
  ClaudeSessionEnd,
  ClaudeStatusEvent,
  ClaudeToolEvent,
  ClaudeSubagentEvent,
}

#[derive(Clone, Debug, Subcommand)]
pub enum BinaryCommand {
  /// Start the server (default when no subcommand given)
  Start {
    #[arg(long, default_value = "0.0.0.0:4000", env = "ORBITDOCK_BIND_ADDR")]
    bind: std::net::SocketAddr,

    #[arg(long, env = "ORBITDOCK_AUTH_TOKEN")]
    auth_token: Option<String>,

    #[arg(
      long,
      env = "ORBITDOCK_ALLOW_INSECURE_NO_AUTH",
      default_value_t = false
    )]
    allow_insecure_no_auth: bool,

    #[arg(long, env = "ORBITDOCK_SERVER_SECONDARY", default_value_t = false)]
    secondary: bool,

    #[arg(long, env = "ORBITDOCK_TLS_CERT")]
    tls_cert: Option<std::path::PathBuf>,

    #[arg(long, env = "ORBITDOCK_TLS_KEY")]
    tls_key: Option<std::path::PathBuf>,

    #[arg(long, default_value_t = false)]
    dev_console: bool,

    /// Run as a managed workspace that syncs local persistence upstream.
    #[arg(long, default_value_t = false)]
    managed: bool,

    /// Managed workspace id used for upstream sync replication.
    #[arg(long, env = "ORBITDOCK_WORKSPACE_ID")]
    workspace_id: Option<String>,

    /// Upstream sync URL for persistence replication.
    #[arg(long, env = "ORBITDOCK_SYNC_URL")]
    sync_url: Option<String>,

    /// Upstream bearer token for sync replication.
    #[arg(long, env = "ORBITDOCK_SYNC_TOKEN")]
    sync_token: Option<String>,

    /// Workspace provider to use for mission dispatch.
    #[arg(long, env = "ORBITDOCK_WORKSPACE_PROVIDER")]
    workspace_provider: Option<WorkspaceProviderKind>,
  },

  /// Bootstrap a fresh machine (create dirs and run migrations)
  Init {
    #[arg(long, default_value = "http://127.0.0.1:4000")]
    server_url: String,

    /// Default workspace provider to store in server config.
    #[arg(long, default_value = "local", env = "ORBITDOCK_WORKSPACE_PROVIDER")]
    workspace_provider: WorkspaceProviderKind,
  },

  /// Install Claude Code hooks into ~/.claude/settings.json
  InstallHooks {
    #[arg(long)]
    settings_path: Option<std::path::PathBuf>,

    #[arg(long)]
    server_url: Option<String>,

    #[arg(long, env = "ORBITDOCK_AUTH_TOKEN")]
    auth_token: Option<String>,
  },

  /// Internal: forward a Claude hook payload from stdin to OrbitDock server.
  #[command(hide = true)]
  HookForward {
    hook_type: HookForwardType,

    #[arg(long, env = "ORBITDOCK_URL")]
    server_url: Option<String>,

    #[arg(long, env = "ORBITDOCK_AUTH_TOKEN")]
    auth_token: Option<String>,
  },

  /// Internal: create a managed mission session against a local OrbitDock server.
  #[command(hide = true)]
  ManagedSessionStart {
    #[arg(long, env = "ORBITDOCK_URL")]
    server_url: Option<String>,

    #[arg(long, env = "ORBITDOCK_MANAGED_SESSION_REQUEST_B64")]
    request_base64: String,
  },

  /// Internal: MCP stdio server providing mission tools to agents
  #[command(name = "mcp-mission-tools", hide = true)]
  McpMissionTools,

  /// Generate and install a launchd/systemd service file
  InstallService {
    #[arg(long, default_value = "0.0.0.0:4000")]
    bind: std::net::SocketAddr,

    #[arg(long)]
    enable: bool,

    #[arg(long, env = "ORBITDOCK_AUTH_TOKEN")]
    auth_token: Option<String>,
  },

  /// Ensure the server binary directory is persisted on your shell PATH
  EnsurePath,

  /// Check server status (PID + health check)
  Status,

  /// Generate a secure auth token and store its hash in the database
  GenerateToken,

  /// List issued auth tokens
  ListTokens,

  /// Revoke an auth token by token id
  RevokeToken { token_id: String },

  /// Run diagnostics and check system health
  Doctor,

  /// Auth token management
  Auth {
    #[command(subcommand)]
    action: AuthAction,
  },

  /// Interactive setup wizard
  Setup {
    /// Setup path: local, server, or client
    #[arg(value_enum)]
    path: Option<SetupPath>,
  },

  /// Expose the server via Cloudflare Tunnel
  Tunnel {
    #[arg(long, default_value = "4000")]
    port: u16,

    #[arg(long)]
    name: Option<String>,
  },

  /// Generate a connection URL for pairing clients
  Pair {
    #[arg(long)]
    tunnel_url: Option<String>,
  },

  /// Check server health
  Health,

  /// Manage sessions
  Session {
    #[command(subcommand)]
    action: SessionAction,
  },

  /// Manage approval history
  Approval {
    #[command(subcommand)]
    action: ApprovalAction,
  },

  /// Manage review comments
  Review {
    #[command(subcommand)]
    action: ReviewAction,
  },

  /// List available models
  Model {
    #[command(subcommand)]
    action: ModelAction,
  },

  /// Show usage and rate limits
  Usage {
    #[command(subcommand)]
    action: UsageAction,
  },

  /// Server configuration
  Server {
    #[command(subcommand)]
    action: ServerAction,
  },

  /// Scripted configuration access
  Config {
    #[command(subcommand)]
    action: ConfigAction,
  },

  /// Codex account management
  #[command(name = "codex")]
  CodexAccount {
    #[command(subcommand)]
    action: CodexAction,
  },

  /// Git worktree management
  Worktree {
    #[command(subcommand)]
    action: WorktreeAction,
  },

  /// Mission Control — autonomous issue-driven orchestration
  Mission {
    #[command(subcommand)]
    action: MissionAction,
  },

  /// MCP tools and resources
  Mcp {
    #[command(subcommand)]
    action: McpAction,
  },

  /// Browse filesystem via server
  Fs {
    #[command(subcommand)]
    action: FsAction,
  },

  /// Execute a shell command via a session
  Shell {
    #[command(subcommand)]
    action: ShellAction,
  },

  /// Check for server updates or upgrade to a new version
  Upgrade {
    /// Only check for updates, don't install
    #[arg(long)]
    check: bool,

    /// Override the update channel for this check (stable|beta|nightly)
    #[arg(long)]
    channel: Option<String>,

    /// Install a specific version tag (e.g. v0.6.0)
    #[arg(long)]
    version: Option<String>,

    /// Force upgrade even if already on the latest version
    #[arg(long)]
    force: bool,

    /// Skip confirmation prompt
    #[arg(long, short = 'y')]
    yes: bool,

    /// Attempt to restart the service after upgrading
    #[arg(long)]
    restart: bool,
  },
}
