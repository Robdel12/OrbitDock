use clap::{CommandFactory, Parser, Subcommand, ValueEnum};

#[derive(Parser, Debug)]
#[command(
    name = "orbitdock",
    about = "OrbitDock — mission control for AI coding agents",
    version
)]
pub struct BinaryCli {
    /// Data directory (default: ~/.orbitdock)
    #[arg(long, global = true, env = "ORBITDOCK_DATA_DIR")]
    pub data_dir: Option<std::path::PathBuf>,

    /// Bind address (top-level, for backward compat — prefer `start --bind`)
    #[arg(long, env = "ORBITDOCK_BIND_ADDR")]
    pub bind: Option<std::net::SocketAddr>,

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
        #[arg(long, default_value = "127.0.0.1:4000", env = "ORBITDOCK_BIND_ADDR")]
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
    },

    /// Bootstrap a fresh machine (create dirs and run migrations)
    Init {
        #[arg(long, default_value = "http://127.0.0.1:4000")]
        server_url: String,
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

        #[arg(long)]
        server_url: Option<String>,

        #[arg(long)]
        auth_token: Option<String>,
    },

    /// Generate and install a launchd/systemd service file
    InstallService {
        #[arg(long, default_value = "127.0.0.1:4000")]
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
    RevokeToken {
        token_id: String,
    },

    /// Run diagnostics and check system health
    Doctor,

    /// Interactive setup wizard (init + hooks + token + service)
    Setup {
        #[arg(long, conflicts_with = "remote")]
        local: bool,

        #[arg(long, conflicts_with = "local")]
        remote: bool,

        #[arg(long)]
        bind: Option<std::net::SocketAddr>,

        #[arg(long)]
        server_url: Option<String>,

        #[arg(long)]
        skip_service: bool,

        #[arg(long)]
        skip_hooks: bool,
    },

    /// Guide secure remote exposure for an existing install
    RemoteSetup,

    /// Expose the server via Cloudflare Tunnel
    Tunnel {
        #[arg(long, default_value = "4000")]
        port: u16,

        #[arg(long)]
        name: Option<String>,
    },

    /// Generate a connection URL and QR code for pairing clients
    Pair {
        #[arg(long)]
        tunnel_url: Option<String>,

        #[arg(long)]
        no_qr: bool,
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

    /// Generate shell completions
    Completions {
        shell: clap_complete::Shell,
    },
}

pub fn binary_to_client_command(command: &BinaryCommand) -> Option<Command> {
    match command {
        BinaryCommand::Health => Some(Command::Health),
        BinaryCommand::Session { action } => Some(Command::Session {
            action: action.clone(),
        }),
        BinaryCommand::Approval { action } => Some(Command::Approval {
            action: action.clone(),
        }),
        BinaryCommand::Review { action } => Some(Command::Review {
            action: action.clone(),
        }),
        BinaryCommand::Model { action } => Some(Command::Model {
            action: action.clone(),
        }),
        BinaryCommand::Usage { action } => Some(Command::Usage {
            action: action.clone(),
        }),
        BinaryCommand::CodexAccount { action } => Some(Command::Codex {
            action: action.clone(),
        }),
        BinaryCommand::Worktree { action } => Some(Command::Worktree {
            action: action.clone(),
        }),
        BinaryCommand::Mcp { action } => Some(Command::Mcp {
            action: action.clone(),
        }),
        BinaryCommand::Fs { action } => Some(Command::Fs {
            action: action.clone(),
        }),
        BinaryCommand::Shell { action } => Some(Command::Shell {
            action: action.clone(),
        }),
        _ => None,
    }
}

#[derive(Parser)]
#[command(
    name = "orbitdock",
    about = "OrbitDock CLI — interact with AI coding sessions",
    version
)]
pub struct Cli {
    /// Server URL (default: http://127.0.0.1:4000)
    #[arg(long, short = 's', env = "ORBITDOCK_URL")]
    pub server: Option<String>,

    /// Bearer auth token
    #[arg(long, short = 't', env = "ORBITDOCK_TOKEN")]
    pub token: Option<String>,

    /// Output as JSON (auto-enabled when stdout is not a TTY)
    #[arg(long, short = 'j', global = true)]
    pub json: bool,

    /// Path to config file
    #[arg(long, env = "ORBITDOCK_CONFIG")]
    pub config: Option<String>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Clone, Debug, Subcommand)]
pub enum Command {
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

    /// Codex account management
    Codex {
        #[command(subcommand)]
        action: CodexAction,
    },

    /// Git worktree management
    Worktree {
        #[command(subcommand)]
        action: WorktreeAction,
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

    /// Generate shell completions
    Completions {
        /// Shell to generate completions for
        shell: clap_complete::Shell,
    },
}

// ── Session ──────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum SessionAction {
    /// List all sessions
    List {
        /// Filter by provider
        #[arg(long, short = 'p')]
        provider: Option<ProviderFilter>,

        /// Filter by status
        #[arg(long)]
        status: Option<StatusFilter>,

        /// Filter by project path
        #[arg(long)]
        project: Option<String>,
    },

    /// Show session details
    Get {
        /// Session ID
        session_id: String,

        /// Include conversation messages
        #[arg(long, short = 'm')]
        messages: bool,
    },

    /// Create a new session
    Create {
        /// Provider (claude or codex)
        #[arg(long, short = 'p')]
        provider: ProviderFilter,

        /// Working directory (defaults to current directory)
        #[arg(long)]
        cwd: Option<String>,

        /// Model to use
        #[arg(long)]
        model: Option<String>,

        /// Permission mode
        #[arg(long)]
        permission_mode: Option<PermissionMode>,

        /// Reasoning effort
        #[arg(long)]
        effort: Option<Effort>,

        /// System prompt
        #[arg(long)]
        system_prompt: Option<String>,
    },

    /// Send a message to a session (reads from stdin if content is "-")
    Send {
        /// Session ID
        session_id: String,

        /// Message content (use "-" to read from stdin)
        #[arg(allow_hyphen_values = true)]
        content: String,

        /// Model override
        #[arg(long)]
        model: Option<String>,

        /// Reasoning effort
        #[arg(long)]
        effort: Option<Effort>,

        /// Don't wait for turn completion
        #[arg(long, short = 'n')]
        no_wait: bool,
    },

    /// Approve or deny a pending tool execution
    Approve {
        /// Session ID
        session_id: String,

        /// Decision
        #[arg(long, short = 'd', default_value = "approved")]
        decision: ApprovalDecision,

        /// Message (for denied decisions)
        #[arg(long)]
        message: Option<String>,

        /// Request ID (auto-resolved from pending approval if omitted)
        #[arg(long)]
        request_id: Option<String>,
    },

    /// Answer a question from the assistant (reads from stdin if answer is "-")
    Answer {
        /// Session ID
        session_id: String,

        /// Answer text (use "-" to read from stdin)
        #[arg(allow_hyphen_values = true)]
        answer: String,

        /// Request ID (auto-resolved if omitted)
        #[arg(long)]
        request_id: Option<String>,
    },

    /// Interrupt the current turn
    Interrupt {
        /// Session ID
        session_id: String,
    },

    /// End a session
    End {
        /// Session ID
        session_id: String,
    },

    /// Fork a session
    Fork {
        /// Source session ID
        session_id: String,

        /// Fork from this user message index (0-based)
        #[arg(long)]
        nth_user_message: Option<u32>,

        /// Model for new session
        #[arg(long)]
        model: Option<String>,
    },

    /// Inject guidance into an active turn (reads from stdin if content is "-")
    Steer {
        /// Session ID
        session_id: String,

        /// Guidance text (use "-" to read from stdin)
        #[arg(allow_hyphen_values = true)]
        content: String,
    },

    /// Compact the session context
    Compact {
        /// Session ID
        session_id: String,
    },

    /// Undo the last turn
    Undo {
        /// Session ID
        session_id: String,
    },

    /// Rollback multiple turns
    Rollback {
        /// Session ID
        session_id: String,

        /// Number of turns to rollback
        #[arg(long)]
        turns: u32,
    },

    /// Watch session events in real-time (runs until session ends or Ctrl+C)
    Watch {
        /// Session ID
        session_id: String,

        /// Filter by event type (e.g. message_appended, session_delta)
        #[arg(long, short = 'f')]
        filter: Vec<String>,

        /// Timeout in seconds (omit for no timeout)
        #[arg(long)]
        timeout: Option<u64>,
    },

    /// Rename a session
    Rename {
        /// Session ID
        session_id: String,

        /// New name
        #[arg(long)]
        name: String,
    },

    /// Resume a session
    Resume {
        /// Session ID
        session_id: String,
    },
}

#[derive(Clone, Debug, ValueEnum)]
pub enum ProviderFilter {
    Claude,
    Codex,
}

#[derive(Clone, Debug, ValueEnum)]
pub enum StatusFilter {
    Active,
    Ended,
}

#[derive(Clone, Debug, ValueEnum)]
pub enum ApprovalDecision {
    Approved,
    ApprovedForSession,
    ApprovedAlways,
    Denied,
    Abort,
}

impl ApprovalDecision {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::ApprovedForSession => "approved_for_session",
            Self::ApprovedAlways => "approved_always",
            Self::Denied => "denied",
            Self::Abort => "abort",
        }
    }
}

#[derive(Clone, Debug, ValueEnum)]
pub enum PermissionMode {
    Default,
    AcceptEdits,
    Plan,
    BypassPermissions,
}

impl PermissionMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::AcceptEdits => "acceptEdits",
            Self::Plan => "plan",
            Self::BypassPermissions => "bypassPermissions",
        }
    }
}

#[derive(Clone, Debug, ValueEnum)]
pub enum Effort {
    Low,
    Medium,
    High,
    #[value(name = "xhigh")]
    XHigh,
}

impl Effort {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::XHigh => "xhigh",
        }
    }
}

// ── Approvals ────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum ApprovalAction {
    /// List approval history
    List {
        /// Filter by session
        #[arg(long)]
        session: Option<String>,

        /// Max results
        #[arg(long)]
        limit: Option<u32>,
    },

    /// Delete an approval from history
    Delete {
        /// Approval ID
        approval_id: i64,
    },
}

// ── Review ───────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum ReviewAction {
    /// List review comments for a session
    List {
        /// Session ID
        session_id: String,

        /// Filter by turn
        #[arg(long)]
        turn: Option<String>,
    },

    /// Create a review comment
    Create {
        /// Session ID
        session_id: String,

        /// File path
        #[arg(long)]
        file: String,

        /// Line number
        #[arg(long)]
        line: u32,

        /// End line number
        #[arg(long)]
        line_end: Option<u32>,

        /// Comment body
        #[arg(long)]
        body: String,

        /// Tag
        #[arg(long)]
        tag: Option<ReviewTagFilter>,

        /// Turn ID
        #[arg(long)]
        turn: Option<String>,
    },

    /// Update a review comment
    Update {
        /// Comment ID
        comment_id: String,

        /// New body
        #[arg(long)]
        body: Option<String>,

        /// New tag
        #[arg(long)]
        tag: Option<ReviewTagFilter>,

        /// New status
        #[arg(long)]
        status: Option<ReviewStatusFilter>,
    },

    /// Delete a review comment
    Delete {
        /// Comment ID
        comment_id: String,
    },
}

#[derive(Clone, Debug, ValueEnum)]
pub enum ReviewTagFilter {
    Clarity,
    Scope,
    Risk,
    Nit,
}

impl ReviewTagFilter {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Clarity => "clarity",
            Self::Scope => "scope",
            Self::Risk => "risk",
            Self::Nit => "nit",
        }
    }
}

#[derive(Clone, Debug, ValueEnum)]
pub enum ReviewStatusFilter {
    Open,
    Resolved,
}

impl ReviewStatusFilter {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Resolved => "resolved",
        }
    }
}

// ── Models ───────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum ModelAction {
    /// List available models
    List {
        /// Filter by provider
        #[arg(long, short = 'p')]
        provider: Option<ProviderFilter>,
    },
}

// ── Usage ────────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum UsageAction {
    /// Show usage and rate limits
    Show {
        /// Filter by provider
        #[arg(long, short = 'p')]
        provider: Option<ProviderFilter>,
    },
}

// ── Server ───────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum ServerAction {
    /// Check server status
    Status,

    /// Set server role
    Role {
        /// Set as primary
        #[arg(long, conflicts_with = "secondary")]
        primary: bool,

        /// Set as secondary
        #[arg(long, conflicts_with = "primary")]
        secondary: bool,
    },
}

// ── Codex ────────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum CodexAction {
    /// Show Codex account status
    Account,

    /// Start Codex login
    Login,

    /// Logout from Codex
    Logout,
}

// ── Worktree ─────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum WorktreeAction {
    /// List worktrees
    List {
        /// Filter by repo root
        #[arg(long)]
        repo: Option<String>,
    },

    /// Create a new worktree
    Create {
        /// Repository path
        #[arg(long)]
        repo: String,

        /// Branch name
        #[arg(long)]
        branch: String,

        /// Base branch
        #[arg(long)]
        base: Option<String>,
    },

    /// Discover existing worktrees
    Discover {
        /// Repository path
        #[arg(long)]
        repo: String,
    },

    /// Remove a worktree
    Remove {
        /// Worktree ID
        worktree_id: String,

        /// Force removal
        #[arg(long)]
        force: bool,

        /// Delete local branch
        #[arg(long)]
        delete_branch: bool,

        /// Delete remote branch
        #[arg(long)]
        delete_remote_branch: bool,
    },
}

// ── MCP ──────────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum McpAction {
    /// List MCP tools and resources
    Tools {
        /// Session ID
        session_id: String,
    },

    /// Refresh MCP servers
    Refresh {
        /// Session ID
        session_id: String,
    },
}

// ── Filesystem ───────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum FsAction {
    /// Browse a directory
    Browse {
        /// Path to browse (defaults to home)
        path: Option<String>,
    },

    /// List recent projects
    Recent,
}

// ── Shell ────────────────────────────────────────────────────

#[derive(Clone, Debug, Subcommand)]
pub enum ShellAction {
    /// Execute a shell command via a session
    Exec {
        /// Session ID (for cwd context)
        session_id: String,

        /// Command to execute
        #[arg(allow_hyphen_values = true)]
        command: String,

        /// Working directory override
        #[arg(long)]
        cwd: Option<String>,

        /// Timeout in seconds
        #[arg(long, default_value = "30")]
        timeout: u64,
    },
}

/// Generate shell completions to stdout.
pub fn generate_completions(shell: clap_complete::Shell) {
    let mut cmd = Cli::command();
    clap_complete::generate(shell, &mut cmd, "orbitdock", &mut std::io::stdout());
}

pub fn generate_binary_completions(shell: clap_complete::Shell) {
    let mut cmd = BinaryCli::command();
    clap_complete::generate(shell, &mut cmd, "orbitdock", &mut std::io::stdout());
}

/// Read content from stdin if the value is "-", otherwise return as-is.
pub fn resolve_stdin(value: &str) -> std::io::Result<String> {
    if value == "-" {
        use std::io::Read;
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        Ok(buf)
    } else {
        Ok(value.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::config::ClientConfig;
    use crate::commands::dispatch_binary;

    #[test]
    fn binary_cli_parses_start_command() {
        let cli = BinaryCli::try_parse_from(["orbitdock", "start", "--bind", "0.0.0.0:4000"])
            .expect("binary cli should parse start");

        match cli.command {
            Some(BinaryCommand::Start { bind, .. }) => {
                assert_eq!(bind, "0.0.0.0:4000".parse().unwrap());
            }
            other => panic!("expected start command, got {other:?}"),
        }
    }

    #[test]
    fn binary_cli_maps_session_command_to_client_command() {
        let cli =
            BinaryCli::try_parse_from(["orbitdock", "session", "list"]).expect("should parse");
        let command = binary_to_client_command(cli.command.as_ref().expect("command present"))
            .expect("session should map to client command");

        match command {
            Command::Session {
                action: SessionAction::List { .. },
            } => {}
            other => panic!("expected session list, got {other:?}"),
        }
    }

    #[test]
    fn binary_cli_resolves_client_config_from_merged_flags() {
        let cli = BinaryCli::try_parse_from([
            "orbitdock",
            "--server",
            "http://example.test:4000",
            "--token",
            "abc123",
            "--json",
            "health",
        ])
        .expect("should parse merged cli");

        let config = ClientConfig::resolve_binary(&cli).expect("binary config should resolve");
        assert_eq!(config.server_url, "http://example.test:4000");
        assert_eq!(config.token.as_deref(), Some("abc123"));
        assert!(config.json);
    }

    #[tokio::test]
    async fn dispatch_binary_returns_none_for_admin_commands() {
        let config = ClientConfig::from_sources(None, None, true, None);
        let command = BinaryCommand::GenerateToken;

        let result = dispatch_binary(&command, &config).await;
        assert!(result.is_none());
    }
}
