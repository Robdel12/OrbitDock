import Foundation
import SQLite

/// Lightweight database wrapper for CLI use
/// No @Observable, no file monitoring, just fast database access
public final class CLIDatabase {
    public let connection: Connection

    private static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.orbitdock/orbitdock.db"
    }()

    public init(path: String? = nil) throws {
        let dbPath = path ?? Self.defaultPath

        // Ensure directory exists
        let directory = (dbPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        connection = try Connection(dbPath)

        // Enable WAL mode for concurrent access
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA busy_timeout = 5000")
        try connection.execute("PRAGMA synchronous = NORMAL")
    }

    /// Notify the OrbitDock app that data has changed
    public func notifyApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        task.arguments = ["-p", "com.orbitdock.session.updated"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}

// MARK: - Table Definitions

extension CLIDatabase {
    static let sessions = Table("sessions")
    static let repos = Table("repos")
    static let workstreams = Table("workstreams")

    // Session columns
    static let id = SQLite.Expression<String>("id")
    static let projectPath = SQLite.Expression<String>("project_path")
    static let projectName = SQLite.Expression<String?>("project_name")
    static let branch = SQLite.Expression<String?>("branch")
    static let model = SQLite.Expression<String?>("model")
    static let contextLabel = SQLite.Expression<String?>("context_label")
    static let transcriptPath = SQLite.Expression<String?>("transcript_path")
    static let status = SQLite.Expression<String>("status")
    static let workStatus = SQLite.Expression<String?>("work_status")
    static let attentionReason = SQLite.Expression<String?>("attention_reason")
    static let startedAt = SQLite.Expression<String?>("started_at")
    static let endedAt = SQLite.Expression<String?>("ended_at")
    static let endReason = SQLite.Expression<String?>("end_reason")
    static let lastActivityAt = SQLite.Expression<String?>("last_activity_at")
    static let lastTool = SQLite.Expression<String?>("last_tool")
    static let lastToolAt = SQLite.Expression<String?>("last_tool_at")
    static let promptCount = SQLite.Expression<Int?>("prompt_count")
    static let toolCount = SQLite.Expression<Int?>("tool_count")
    static let terminalSessionId = SQLite.Expression<String?>("terminal_session_id")
    static let terminalApp = SQLite.Expression<String?>("terminal_app")
    static let workstreamId = SQLite.Expression<String?>("workstream_id")
    static let pendingToolName = SQLite.Expression<String?>("pending_tool_name")
    static let pendingToolInput = SQLite.Expression<String?>("pending_tool_input")
    static let pendingQuestion = SQLite.Expression<String?>("pending_question")
    static let provider = SQLite.Expression<String?>("provider")

    // Repo columns
    static let repoId = SQLite.Expression<String>("id")
    static let repoName = SQLite.Expression<String>("name")
    static let repoPath = SQLite.Expression<String>("path")
    static let githubOwner = SQLite.Expression<String?>("github_owner")
    static let githubName = SQLite.Expression<String?>("github_name")
    static let repoCreatedAt = SQLite.Expression<String>("created_at")

    // Workstream columns
    static let wsId = SQLite.Expression<String>("id")
    static let wsRepoId = SQLite.Expression<String>("repo_id")
    static let wsBranch = SQLite.Expression<String>("branch")
    static let wsDirectory = SQLite.Expression<String?>("directory")
    static let wsName = SQLite.Expression<String?>("name")
    static let wsStage = SQLite.Expression<String>("stage")
    static let wsSessionCount = SQLite.Expression<Int>("session_count")
    static let wsLastActivityAt = SQLite.Expression<String?>("last_activity_at")
    static let wsCreatedAt = SQLite.Expression<String>("created_at")
    static let wsUpdatedAt = SQLite.Expression<String>("updated_at")
    static let wsIsArchived = SQLite.Expression<Int>("is_archived")
}

// MARK: - Date Formatting

extension CLIDatabase {
    public static func formatDate(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
