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

        // Run migrations
        try runMigrations()
    }

    /// Run any pending migrations
    private func runMigrations() throws {
        // Ensure schema_versions table exists
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS schema_versions (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at TEXT NOT NULL
            )
        """)

        // Get current version
        let currentVersion = (try? connection.scalar("SELECT MAX(version) FROM schema_versions") as? Int64) ?? 0

        // Load and apply migrations
        let migrations = loadMigrations()
        let pending = migrations.filter { $0.version > Int(currentVersion) }

        for migration in pending {
            let now = Self.formatDate()
            try connection.transaction {
                try connection.execute(migration.sql)
                try connection.run(
                    "INSERT INTO schema_versions (version, name, applied_at) VALUES (?, ?, ?)",
                    migration.version, migration.name, now
                )
            }
            // Log using the shared log function
            logToFile("[Migration] Applied \(migration.version): \(migration.name)")
        }
    }

    /// Load migrations from the repo's migrations folder
    private func loadMigrations() -> [(version: Int, name: String, sql: String)] {
        var migrations: [(version: Int, name: String, sql: String)] = []

        // Try common paths
        let possiblePaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Developer/claude-dashboard/migrations"),
        ]

        for migrationsDir in possiblePaths {
            guard FileManager.default.fileExists(atPath: migrationsDir.path) else { continue }

            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: migrationsDir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "sql" }

                for file in files {
                    let filename = file.deletingPathExtension().lastPathComponent
                    // Parse "001_initial" format
                    let parts = filename.split(separator: "_", maxSplits: 1)
                    guard parts.count == 2,
                          let version = Int(parts[0]) else { continue }

                    let name = String(parts[1])
                    let sql = try String(contentsOf: file, encoding: .utf8)
                    migrations.append((version, name, sql))
                }
            } catch {
                continue
            }
        }

        return migrations.sorted { $0.version < $1.version }
    }

    /// Log to the CLI log file
    private func logToFile(_ message: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logPath = "\(home)/.orbitdock/cli.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
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
    static let inboxItems = Table("inbox_items")

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

    // Inbox columns
    static let inboxId = SQLite.Expression<String>("id")
    static let inboxContent = SQLite.Expression<String>("content")
    static let inboxSource = SQLite.Expression<String?>("source")
    static let inboxSessionId = SQLite.Expression<String?>("session_id")
    static let inboxQuestId = SQLite.Expression<String?>("quest_id")
    static let inboxCreatedAt = SQLite.Expression<String?>("created_at")
    static let inboxAttachedAt = SQLite.Expression<String?>("attached_at")
    static let inboxStatus = SQLite.Expression<String?>("status")
}

// MARK: - Inbox Operations

extension CLIDatabase {
    /// Capture a detected link to the inbox
    /// - Parameters:
    ///   - content: The content/description (e.g., "PR #123: Add new feature")
    ///   - source: Where it was detected from (e.g., "cli_detected")
    ///   - sessionId: The session that generated this link
    /// - Returns: The created inbox item ID, or nil if failed
    @discardableResult
    public func captureToInbox(content: String, source: String, sessionId: String?) -> String? {
        let itemId = UUID().uuidString
        let now = Self.formatDate()

        do {
            try connection.run(Self.inboxItems.insert(
                Self.inboxId <- itemId,
                Self.inboxContent <- content,
                Self.inboxSource <- source,
                Self.inboxSessionId <- sessionId,
                Self.inboxCreatedAt <- now,
                Self.inboxStatus <- "pending"
            ))
            return itemId
        } catch {
            logToFile("[Inbox] Failed to capture: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Date Formatting

extension CLIDatabase {
    public static func formatDate(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
