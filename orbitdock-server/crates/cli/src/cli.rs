use clap::{Parser, Subcommand, ValueEnum};

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
    #[arg(long, global = true)]
    pub json: bool,

    /// Path to config file
    #[arg(long, env = "ORBITDOCK_CONFIG")]
    pub config: Option<String>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
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
}

// ── Session ──────────────────────────────────────────────────

#[derive(Subcommand)]
pub enum SessionAction {
    /// List all sessions
    List {
        /// Filter by provider
        #[arg(long)]
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
        #[arg(long)]
        messages: bool,
    },

    /// Create a new session
    Create {
        /// Provider (claude or codex)
        #[arg(long)]
        provider: ProviderFilter,

        /// Working directory
        #[arg(long)]
        cwd: String,

        /// Model to use
        #[arg(long)]
        model: Option<String>,

        /// Permission mode
        #[arg(long)]
        permission_mode: Option<String>,

        /// Reasoning effort (low, medium, high)
        #[arg(long)]
        effort: Option<String>,

        /// System prompt
        #[arg(long)]
        system_prompt: Option<String>,
    },

    /// Send a message to a session
    Send {
        /// Session ID
        session_id: String,

        /// Message content
        content: String,

        /// Model override
        #[arg(long)]
        model: Option<String>,

        /// Reasoning effort
        #[arg(long)]
        effort: Option<String>,

        /// Don't wait for turn completion
        #[arg(long)]
        no_wait: bool,
    },

    /// Approve or deny a pending tool execution
    Approve {
        /// Session ID
        session_id: String,

        /// Decision: approved, approved_for_session, approved_always, denied, abort
        #[arg(long, default_value = "approved")]
        decision: String,

        /// Message (for denied decisions)
        #[arg(long)]
        message: Option<String>,

        /// Request ID (auto-resolved from pending approval if omitted)
        #[arg(long)]
        request_id: Option<String>,
    },

    /// Answer a question from the assistant
    Answer {
        /// Session ID
        session_id: String,

        /// Answer text
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

    /// Inject guidance into an active turn
    Steer {
        /// Session ID
        session_id: String,

        /// Guidance text
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

    /// Watch session events in real-time
    Watch {
        /// Session ID
        session_id: String,

        /// Filter by event type (e.g. message_appended, session_delta)
        #[arg(long)]
        filter: Vec<String>,

        /// Timeout in seconds
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

#[derive(Clone, ValueEnum)]
pub enum ProviderFilter {
    Claude,
    Codex,
}

#[derive(Clone, ValueEnum)]
pub enum StatusFilter {
    Active,
    Ended,
}

// ── Approvals ────────────────────────────────────────────────

#[derive(Subcommand)]
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

#[derive(Subcommand)]
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

#[derive(Clone, ValueEnum)]
pub enum ReviewTagFilter {
    Clarity,
    Scope,
    Risk,
    Nit,
}

#[derive(Clone, ValueEnum)]
pub enum ReviewStatusFilter {
    Open,
    Resolved,
}

// ── Models ───────────────────────────────────────────────────

#[derive(Subcommand)]
pub enum ModelAction {
    /// List available models
    List {
        /// Filter by provider
        #[arg(long)]
        provider: Option<ProviderFilter>,
    },
}

// ── Usage ────────────────────────────────────────────────────

#[derive(Subcommand)]
pub enum UsageAction {
    /// Show usage and rate limits
    Show {
        /// Filter by provider
        #[arg(long)]
        provider: Option<ProviderFilter>,
    },
}

// ── Server ───────────────────────────────────────────────────

#[derive(Subcommand)]
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

#[derive(Subcommand)]
pub enum CodexAction {
    /// Show Codex account status
    Account,

    /// Start Codex login
    Login,

    /// Logout from Codex
    Logout,
}

// ── Worktree ─────────────────────────────────────────────────

#[derive(Subcommand)]
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

#[derive(Subcommand)]
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

#[derive(Subcommand)]
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

#[derive(Subcommand)]
pub enum ShellAction {
    /// Execute a shell command via a session
    Exec {
        /// Session ID (for cwd context)
        session_id: String,

        /// Command to execute
        command: String,

        /// Working directory override
        #[arg(long)]
        cwd: Option<String>,

        /// Timeout in seconds
        #[arg(long, default_value = "30")]
        timeout: u64,
    },
}
