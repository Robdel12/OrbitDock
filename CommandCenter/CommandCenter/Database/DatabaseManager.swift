//
//  DatabaseManager.swift
//  OrbitDock
//

import Foundation
import SQLite

@Observable
class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: Connection?
    private let dbPath: String

    // Table definitions
    private let sessions = Table("sessions")
    private let activities = Table("activities")
    private let repos = Table("repos")
    private let workstreams = Table("workstreams")
    private let projects = Table("projects")
    private let projectWorkstreams = Table("project_workstreams")

    // Session columns
    private let id = SQLite.Expression<String>("id")
    private let projectPath = SQLite.Expression<String>("project_path")
    private let projectName = SQLite.Expression<String?>("project_name")
    private let branch = SQLite.Expression<String?>("branch")
    private let model = SQLite.Expression<String?>("model")
    private let sessionSummary = SQLite.Expression<String?>("summary")  // Claude-generated title
    private let customName = SQLite.Expression<String?>("custom_name")  // User-defined name
    private let contextLabel = SQLite.Expression<String?>("context_label")  // Legacy, mapped to custom_name
    private let transcriptPath = SQLite.Expression<String?>("transcript_path")
    private let status = SQLite.Expression<String>("status")
    private let workStatus = SQLite.Expression<String?>("work_status")
    private let startedAt = SQLite.Expression<String?>("started_at")
    private let endedAt = SQLite.Expression<String?>("ended_at")
    private let endReason = SQLite.Expression<String?>("end_reason")
    private let totalTokens = SQLite.Expression<Int>("total_tokens")
    private let totalCostUSD = SQLite.Expression<Double>("total_cost_usd")
    private let lastActivityAt = SQLite.Expression<String?>("last_activity_at")
    private let lastTool = SQLite.Expression<String?>("last_tool")
    private let lastToolAt = SQLite.Expression<String?>("last_tool_at")
    private let promptCount = SQLite.Expression<Int?>("prompt_count")
    private let toolCount = SQLite.Expression<Int?>("tool_count")
    private let terminalSessionId = SQLite.Expression<String?>("terminal_session_id")
    private let terminalApp = SQLite.Expression<String?>("terminal_app")
    private let attentionReason = SQLite.Expression<String?>("attention_reason")
    private let pendingToolName = SQLite.Expression<String?>("pending_tool_name")
    private let pendingQuestion = SQLite.Expression<String?>("pending_question")

    // Activity columns
    private let activityId = SQLite.Expression<Int>("id")
    private let sessionId = SQLite.Expression<String>("session_id")
    private let timestamp = SQLite.Expression<String>("timestamp")
    private let eventType = SQLite.Expression<String?>("event_type")
    private let toolName = SQLite.Expression<String?>("tool_name")
    private let filePath = SQLite.Expression<String?>("file_path")
    private let summary = SQLite.Expression<String?>("summary")
    private let tokensUsed = SQLite.Expression<Int?>("tokens_used")
    private let costUSD = SQLite.Expression<Double?>("cost_usd")

    // Repo columns
    private let repoId = SQLite.Expression<String>("id")
    private let repoName = SQLite.Expression<String>("name")
    private let repoPath = SQLite.Expression<String>("path")
    private let githubOwner = SQLite.Expression<String?>("github_owner")
    private let githubName = SQLite.Expression<String?>("github_name")
    private let repoCreatedAt = SQLite.Expression<String>("created_at")

    // Workstream columns
    private let workstreamId = SQLite.Expression<String>("id")
    private let workstreamRepoId = SQLite.Expression<String>("repo_id")
    private let workstreamBranch = SQLite.Expression<String>("branch")
    private let workstreamDirectory = SQLite.Expression<String?>("directory")
    private let workstreamName = SQLite.Expression<String?>("name")
    private let workstreamDescription = SQLite.Expression<String?>("description")
    private let linearIssueId = SQLite.Expression<String?>("linear_issue_id")
    private let linearIssueTitle = SQLite.Expression<String?>("linear_issue_title")
    private let linearIssueState = SQLite.Expression<String?>("linear_issue_state")
    private let linearIssueURL = SQLite.Expression<String?>("linear_issue_url")
    private let githubIssueNumber = SQLite.Expression<Int?>("github_issue_number")
    private let githubIssueTitle = SQLite.Expression<String?>("github_issue_title")
    private let githubIssueState = SQLite.Expression<String?>("github_issue_state")
    private let githubPRNumber = SQLite.Expression<Int?>("github_pr_number")
    private let githubPRTitle = SQLite.Expression<String?>("github_pr_title")
    private let githubPRState = SQLite.Expression<String?>("github_pr_state")
    private let githubPRURL = SQLite.Expression<String?>("github_pr_url")
    private let githubPRAdditions = SQLite.Expression<Int?>("github_pr_additions")
    private let githubPRDeletions = SQLite.Expression<Int?>("github_pr_deletions")
    private let reviewState = SQLite.Expression<String?>("review_state")
    private let reviewApprovals = SQLite.Expression<Int>("review_approvals")
    private let reviewComments = SQLite.Expression<Int>("review_comments")
    private let workstreamStage = SQLite.Expression<String>("stage")
    private let sessionCount = SQLite.Expression<Int>("session_count")
    private let totalSessionSeconds = SQLite.Expression<Int>("total_session_seconds")
    private let commitCount = SQLite.Expression<Int>("commit_count")
    private let workstreamLastActivityAt = SQLite.Expression<String?>("last_activity_at")
    private let workstreamCreatedAt = SQLite.Expression<String>("created_at")
    private let workstreamUpdatedAt = SQLite.Expression<String>("updated_at")

    // Workstream tickets table and columns
    private let workstreamTickets = Table("workstream_tickets")
    private let ticketId = SQLite.Expression<String>("id")
    private let ticketWorkstreamId = SQLite.Expression<String>("workstream_id")
    private let ticketSource = SQLite.Expression<String>("source")
    private let ticketLinearIssueId = SQLite.Expression<String?>("linear_issue_id")
    private let ticketLinearTeamId = SQLite.Expression<String?>("linear_team_id")
    private let ticketGithubOwner = SQLite.Expression<String?>("github_owner")
    private let ticketGithubRepo = SQLite.Expression<String?>("github_repo")
    private let ticketGithubNumber = SQLite.Expression<Int?>("github_number")
    private let ticketTitle = SQLite.Expression<String?>("title")
    private let ticketState = SQLite.Expression<String?>("state")
    private let ticketUrl = SQLite.Expression<String?>("url")
    private let ticketIsPrimary = SQLite.Expression<Int>("is_primary")
    private let ticketLinkedAt = SQLite.Expression<String>("linked_at")
    private let ticketUpdatedAt = SQLite.Expression<String>("updated_at")

    // Workstream notes table and columns
    private let workstreamNotes = Table("workstream_notes")
    private let noteId = SQLite.Expression<String>("id")
    private let noteWorkstreamId = SQLite.Expression<String>("workstream_id")
    private let noteSessionId = SQLite.Expression<String?>("session_id")
    private let noteType = SQLite.Expression<String>("type")
    private let noteContent = SQLite.Expression<String>("content")
    private let noteMetadata = SQLite.Expression<String?>("metadata")
    private let noteCreatedAt = SQLite.Expression<String>("created_at")
    private let noteResolvedAt = SQLite.Expression<String?>("resolved_at")

    // Project columns
    private let projectId = SQLite.Expression<String>("id")
    private let projectDisplayName = SQLite.Expression<String>("name")
    private let projectDescription = SQLite.Expression<String?>("description")
    private let projectColor = SQLite.Expression<String?>("color")
    private let projectStatus = SQLite.Expression<String>("status")
    private let projectCreatedAt = SQLite.Expression<String>("created_at")
    private let projectUpdatedAt = SQLite.Expression<String>("updated_at")

    // Project-Workstream junction columns
    private let pwProjectId = SQLite.Expression<String>("project_id")
    private let pwWorkstreamId = SQLite.Expression<String>("workstream_id")

    // Session-Workstream link
    private let sessionWorkstreamId = SQLite.Expression<String?>("workstream_id")

    private var fileMonitor: DispatchSourceFileSystemObject?
    var onDatabaseChanged: (() -> Void)?

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        dbPath = homeDir.appendingPathComponent(".orbitdock/orbitdock.db").path

        do {
            db = try Connection(dbPath)
            // Enable WAL mode for better concurrent access (handles multiple writers/readers)
            try db?.execute("PRAGMA journal_mode = WAL")
            // Set busy timeout to 5 seconds - wait instead of failing immediately
            try db?.execute("PRAGMA busy_timeout = 5000")
            // Synchronous NORMAL is safer with WAL and still fast
            try db?.execute("PRAGMA synchronous = NORMAL")

            // Ensure schema has new columns
            ensureSchema()

            // Sync summaries from Claude's sessions-index.json
            syncSummariesFromClaude()
        } catch {
            print("Failed to connect to database: \(error)")
        }

        startFileMonitoring()
    }

    deinit {
        fileMonitor?.cancel()
    }

    // MARK: - File Monitoring

    private func startFileMonitoring() {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        let fileDescriptor = open(dbPath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: .main
        )

        fileMonitor?.setEventHandler { [weak self] in
            self?.onDatabaseChanged?()
        }

        fileMonitor?.setCancelHandler {
            close(fileDescriptor)
        }

        fileMonitor?.resume()
    }

    // MARK: - Session Operations

    func fetchSessions(statusFilter: Session.SessionStatus? = nil) -> [Session] {
        guard let db = db else { return [] }

        var query = sessions.order(lastActivityAt.desc)

        if let filter = statusFilter {
            query = query.filter(status == filter.rawValue)
        }

        do {
            return try db.prepare(query).map { row in
                // Try new columns first, fall back to legacy context_label
                let summaryValue = try? row.get(sessionSummary)
                let customNameValue = (try? row.get(customName)) ?? row[contextLabel]

                // Parse attention reason with fallback logic
                let attentionReasonValue: Session.AttentionReason = {
                    if let reasonStr = try? row.get(attentionReason),
                       let reason = Session.AttentionReason(rawValue: reasonStr) {
                        return reason
                    }
                    // Fallback: derive from workStatus for backward compatibility
                    let ws = Session.WorkStatus(rawValue: row[workStatus] ?? "unknown") ?? .unknown
                    switch ws {
                    case .permission: return .awaitingPermission
                    case .waiting: return .awaitingReply
                    default: return .none
                    }
                }()

                return Session(
                    id: row[id],
                    projectPath: row[projectPath],
                    projectName: row[projectName],
                    branch: row[branch],
                    model: row[model],
                    summary: summaryValue,
                    customName: customNameValue,
                    transcriptPath: row[transcriptPath],
                    status: Session.SessionStatus(rawValue: row[status]) ?? .ended,
                    workStatus: Session.WorkStatus(rawValue: row[workStatus] ?? "unknown") ?? .unknown,
                    startedAt: parseDate(row[startedAt]),
                    endedAt: parseDate(row[endedAt]),
                    endReason: row[endReason],
                    totalTokens: row[totalTokens],
                    totalCostUSD: row[totalCostUSD],
                    lastActivityAt: parseDate(row[lastActivityAt]),
                    lastTool: row[lastTool],
                    lastToolAt: parseDate(row[lastToolAt]),
                    promptCount: row[promptCount] ?? 0,
                    toolCount: row[toolCount] ?? 0,
                    terminalSessionId: row[terminalSessionId],
                    terminalApp: row[terminalApp],
                    attentionReason: attentionReasonValue,
                    pendingToolName: (try? row.get(pendingToolName)) ?? nil,
                    pendingQuestion: (try? row.get(pendingQuestion)) ?? nil
                )
            }
        } catch {
            print("Failed to fetch sessions: \(error)")
            return []
        }
    }

    func updateContextLabel(sessionId: String, label: String?) {
        updateCustomName(sessionId: sessionId, name: label)
    }

    func updateCustomName(sessionId: String, name: String?) {
        guard let db = db else { return }

        let session = sessions.filter(id == sessionId)
        do {
            // Try new column first, fall back to legacy
            if columnExists("custom_name", in: "sessions") {
                try db.run(session.update(customName <- name))
            } else {
                try db.run(session.update(contextLabel <- name))
            }
        } catch {
            print("Failed to update custom name: \(error)")
        }
    }

    func updateSummary(sessionId: String, summary: String?) {
        guard let db = db else { return }

        let session = sessions.filter(id == sessionId)
        do {
            if columnExists("summary", in: "sessions") {
                try db.run(session.update(sessionSummary <- summary))
            }
        } catch {
            print("Failed to update summary: \(error)")
        }
    }

    /// Sync summaries from Claude's sessions-index.json files
    func syncSummariesFromClaude() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for projectDir in projectDirs {
            let indexPath = projectDir.appendingPathComponent("sessions-index.json")
            guard let data = try? Data(contentsOf: indexPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else { continue }

            for entry in entries {
                guard let sessionId = entry["sessionId"] as? String,
                      let summary = entry["summary"] as? String else { continue }
                updateSummary(sessionId: sessionId, summary: summary)
            }
        }
    }

    private func columnExists(_ column: String, in table: String) -> Bool {
        guard let db = db else { return false }
        do {
            let result = try db.prepare("PRAGMA table_info(\(table))")
            for row in result {
                if let name = row[1] as? String, name == column {
                    return true
                }
            }
        } catch {}
        return false
    }

    /// Ensure the database has the required columns (migration)
    func ensureSchema() {
        guard let db = db else { return }

        // Add summary column if it doesn't exist
        if !columnExists("summary", in: "sessions") {
            do {
                try db.run("ALTER TABLE sessions ADD COLUMN summary TEXT")
            } catch {
                print("Failed to add summary column: \(error)")
            }
        }

        // Add custom_name column if it doesn't exist
        if !columnExists("custom_name", in: "sessions") {
            do {
                try db.run("ALTER TABLE sessions ADD COLUMN custom_name TEXT")
            } catch {
                print("Failed to add custom_name column: \(error)")
            }
        }

        // Add attention_reason column if it doesn't exist
        if !columnExists("attention_reason", in: "sessions") {
            do {
                try db.run("ALTER TABLE sessions ADD COLUMN attention_reason TEXT")
            } catch {
                print("Failed to add attention_reason column: \(error)")
            }
        }

        // Add pending_tool_name column if it doesn't exist
        if !columnExists("pending_tool_name", in: "sessions") {
            do {
                try db.run("ALTER TABLE sessions ADD COLUMN pending_tool_name TEXT")
            } catch {
                print("Failed to add pending_tool_name column: \(error)")
            }
        }

        // Add pending_question column if it doesn't exist
        if !columnExists("pending_question", in: "sessions") {
            do {
                try db.run("ALTER TABLE sessions ADD COLUMN pending_question TEXT")
            } catch {
                print("Failed to add pending_question column: \(error)")
            }
        }

        // Add workstream_id to sessions
        if !columnExists("workstream_id", in: "sessions") {
            do {
                try db.run("ALTER TABLE sessions ADD COLUMN workstream_id TEXT REFERENCES workstreams(id)")
            } catch {
                print("Failed to add workstream_id column: \(error)")
            }
        }

        // Create repos table
        createReposTable()

        // Create workstreams table
        createWorkstreamsTable()

        // Create projects table
        createProjectsTable()

        // Create project_workstreams junction table
        createProjectWorkstreamsTable()
    }

    private func tableExists(_ tableName: String) -> Bool {
        guard let db = db else { return false }
        do {
            let count = try db.scalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                tableName
            ) as? Int64
            return (count ?? 0) > 0
        } catch {
            return false
        }
    }

    private func createReposTable() {
        guard let db = db, !tableExists("repos") else { return }

        do {
            try db.run("""
                CREATE TABLE repos (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    github_owner TEXT,
                    github_name TEXT,
                    created_at TEXT NOT NULL
                )
            """)
        } catch {
            print("Failed to create repos table: \(error)")
        }
    }

    private func createWorkstreamsTable() {
        guard let db = db, !tableExists("workstreams") else { return }

        do {
            try db.run("""
                CREATE TABLE workstreams (
                    id TEXT PRIMARY KEY,
                    repo_id TEXT NOT NULL REFERENCES repos(id),
                    branch TEXT NOT NULL,
                    directory TEXT,
                    linear_issue_id TEXT,
                    linear_issue_title TEXT,
                    linear_issue_state TEXT,
                    linear_issue_url TEXT,
                    github_issue_number INTEGER,
                    github_issue_title TEXT,
                    github_issue_state TEXT,
                    github_pr_number INTEGER,
                    github_pr_title TEXT,
                    github_pr_state TEXT,
                    github_pr_url TEXT,
                    github_pr_additions INTEGER,
                    github_pr_deletions INTEGER,
                    review_state TEXT,
                    review_approvals INTEGER DEFAULT 0,
                    review_comments INTEGER DEFAULT 0,
                    stage TEXT DEFAULT 'working',
                    session_count INTEGER DEFAULT 0,
                    total_session_seconds INTEGER DEFAULT 0,
                    commit_count INTEGER DEFAULT 0,
                    last_activity_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(repo_id, branch)
                )
            """)
        } catch {
            print("Failed to create workstreams table: \(error)")
        }
    }

    private func createProjectsTable() {
        guard let db = db, !tableExists("projects") else { return }

        do {
            try db.run("""
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    color TEXT,
                    status TEXT DEFAULT 'active',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """)
        } catch {
            print("Failed to create projects table: \(error)")
        }
    }

    private func createProjectWorkstreamsTable() {
        guard let db = db, !tableExists("project_workstreams") else { return }

        do {
            try db.run("""
                CREATE TABLE project_workstreams (
                    project_id TEXT NOT NULL REFERENCES projects(id),
                    workstream_id TEXT NOT NULL REFERENCES workstreams(id),
                    PRIMARY KEY (project_id, workstream_id)
                )
            """)
        } catch {
            print("Failed to create project_workstreams table: \(error)")
        }
    }

    // MARK: - Activity Operations

    func fetchActivities(forSessionId sid: String, limit: Int = 50) -> [Activity] {
        guard let db = db else { return [] }

        let query = activities
            .filter(sessionId == sid)
            .order(timestamp.desc)
            .limit(limit)

        do {
            return try db.prepare(query).map { row in
                Activity(
                    id: row[activityId],
                    sessionId: row[sessionId],
                    timestamp: parseDate(row[timestamp]) ?? Date(),
                    eventType: row[eventType],
                    toolName: row[toolName],
                    filePath: row[filePath],
                    summary: row[summary],
                    tokensUsed: row[tokensUsed],
                    costUSD: row[costUSD]
                )
            }
        } catch {
            print("Failed to fetch activities: \(error)")
            return []
        }
    }

    // MARK: - Stats

    func activeSessionCount() -> Int {
        guard let db = db else { return 0 }
        let query = sessions.filter(status == "active")
        return (try? db.scalar(query.count)) ?? 0
    }

    func waitingSessionCount() -> Int {
        guard let db = db else { return 0 }
        let query = sessions.filter(status == "active" && (workStatus == "waiting" || workStatus == "permission"))
        return (try? db.scalar(query.count)) ?? 0
    }

    func totalCostToday() -> Double {
        guard let db = db else { return 0 }

        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        let query = sessions.filter(startedAt >= today)

        do {
            let costs = try db.prepare(query).map { row in row[totalCostUSD] }
            return costs.reduce(0, +)
        } catch {
            return 0
        }
    }

    // MARK: - Repo Operations

    func fetchRepos() -> [Repo] {
        guard let db = db else { return [] }

        do {
            return try db.prepare(repos.order(repoName.asc)).map { row in
                Repo(
                    id: row[repoId],
                    name: row[repoName],
                    path: row[repoPath],
                    githubOwner: row[githubOwner],
                    githubName: row[githubName],
                    createdAt: parseDate(row[repoCreatedAt]) ?? Date()
                )
            }
        } catch {
            print("Failed to fetch repos: \(error)")
            return []
        }
    }

    func findOrCreateRepo(path: String, name: String, ghOwner: String? = nil, ghName: String? = nil) -> Repo? {
        guard let db = db else { return nil }

        // Try to find existing repo by path
        if let existing = try? db.pluck(repos.filter(repoPath == path)) {
            return Repo(
                id: existing[repoId],
                name: existing[repoName],
                path: existing[repoPath],
                githubOwner: existing[githubOwner],
                githubName: existing[githubName],
                createdAt: parseDate(existing[repoCreatedAt]) ?? Date()
            )
        }

        // Create new repo
        let newId = UUID().uuidString
        let now = formatDate(Date())

        do {
            try db.run(repos.insert(
                repoId <- newId,
                repoName <- name,
                repoPath <- path,
                githubOwner <- ghOwner,
                githubName <- ghName,
                repoCreatedAt <- now
            ))

            return Repo(
                id: newId,
                name: name,
                path: path,
                githubOwner: ghOwner,
                githubName: ghName,
                createdAt: Date()
            )
        } catch {
            print("Failed to create repo: \(error)")
            return nil
        }
    }

    // MARK: - Workstream Operations

    func fetchWorkstreams(repoId: String? = nil, stage: Workstream.Stage? = nil) -> [Workstream] {
        guard let db = db else { return [] }

        var query = workstreams.order(workstreamLastActivityAt.desc)

        if let repoId = repoId {
            query = query.filter(workstreamRepoId == repoId)
        }

        if let stage = stage {
            query = query.filter(workstreamStage == stage.rawValue)
        }

        do {
            return try db.prepare(query).map { row in
                Workstream(
                    id: row[workstreamId],
                    repoId: row[workstreamRepoId],
                    branch: row[workstreamBranch],
                    directory: row[workstreamDirectory],
                    name: row[workstreamName],
                    description: row[workstreamDescription],
                    linearIssueId: row[linearIssueId],
                    linearIssueTitle: row[linearIssueTitle],
                    linearIssueState: row[linearIssueState],
                    linearIssueURL: row[linearIssueURL],
                    githubIssueNumber: row[githubIssueNumber],
                    githubIssueTitle: row[githubIssueTitle],
                    githubIssueState: row[githubIssueState],
                    githubPRNumber: row[githubPRNumber],
                    githubPRTitle: row[githubPRTitle],
                    githubPRState: Workstream.PRState(rawValue: row[githubPRState] ?? ""),
                    githubPRURL: row[githubPRURL],
                    githubPRAdditions: row[githubPRAdditions],
                    githubPRDeletions: row[githubPRDeletions],
                    reviewState: Workstream.ReviewState(rawValue: row[reviewState] ?? ""),
                    reviewApprovals: row[reviewApprovals],
                    reviewComments: row[reviewComments],
                    stage: Workstream.Stage(rawValue: row[workstreamStage]) ?? .working,
                    sessionCount: row[sessionCount],
                    totalSessionSeconds: row[totalSessionSeconds],
                    commitCount: row[commitCount],
                    lastActivityAt: parseDate(row[workstreamLastActivityAt]),
                    createdAt: parseDate(row[workstreamCreatedAt]) ?? Date(),
                    updatedAt: parseDate(row[workstreamUpdatedAt]) ?? Date()
                )
            }
        } catch {
            print("Failed to fetch workstreams: \(error)")
            return []
        }
    }

    func fetchActiveWorkstreams() -> [Workstream] {
        guard let db = db else { return [] }

        let activeStages = ["working", "pr_open", "in_review", "approved"]
        let query = workstreams
            .filter(activeStages.contains(workstreamStage))
            .order(workstreamLastActivityAt.desc)

        do {
            return try db.prepare(query).map { row in
                Workstream(
                    id: row[workstreamId],
                    repoId: row[workstreamRepoId],
                    branch: row[workstreamBranch],
                    directory: row[workstreamDirectory],
                    name: row[workstreamName],
                    description: row[workstreamDescription],
                    linearIssueId: row[linearIssueId],
                    linearIssueTitle: row[linearIssueTitle],
                    linearIssueState: row[linearIssueState],
                    linearIssueURL: row[linearIssueURL],
                    githubIssueNumber: row[githubIssueNumber],
                    githubIssueTitle: row[githubIssueTitle],
                    githubIssueState: row[githubIssueState],
                    githubPRNumber: row[githubPRNumber],
                    githubPRTitle: row[githubPRTitle],
                    githubPRState: Workstream.PRState(rawValue: row[githubPRState] ?? ""),
                    githubPRURL: row[githubPRURL],
                    githubPRAdditions: row[githubPRAdditions],
                    githubPRDeletions: row[githubPRDeletions],
                    reviewState: Workstream.ReviewState(rawValue: row[reviewState] ?? ""),
                    reviewApprovals: row[reviewApprovals],
                    reviewComments: row[reviewComments],
                    stage: Workstream.Stage(rawValue: row[workstreamStage]) ?? .working,
                    sessionCount: row[sessionCount],
                    totalSessionSeconds: row[totalSessionSeconds],
                    commitCount: row[commitCount],
                    lastActivityAt: parseDate(row[workstreamLastActivityAt]),
                    createdAt: parseDate(row[workstreamCreatedAt]) ?? Date(),
                    updatedAt: parseDate(row[workstreamUpdatedAt]) ?? Date()
                )
            }
        } catch {
            print("Failed to fetch active workstreams: \(error)")
            return []
        }
    }

    // MARK: - Workstream Tickets

    func fetchTickets(workstreamId: String) -> [WorkstreamTicket] {
        guard let db = db else { return [] }

        let query = workstreamTickets
            .filter(ticketWorkstreamId == workstreamId)
            .order(ticketIsPrimary.desc, ticketLinkedAt.desc)

        do {
            return try db.prepare(query).map { row in
                WorkstreamTicket(
                    id: row[ticketId],
                    workstreamId: row[ticketWorkstreamId],
                    source: WorkstreamTicket.Source(rawValue: row[ticketSource]) ?? .linear,
                    linearIssueId: row[ticketLinearIssueId],
                    linearTeamId: row[ticketLinearTeamId],
                    githubOwner: row[ticketGithubOwner],
                    githubRepo: row[ticketGithubRepo],
                    githubNumber: row[ticketGithubNumber],
                    title: row[ticketTitle],
                    state: row[ticketState],
                    url: row[ticketUrl],
                    isPrimary: row[ticketIsPrimary] == 1,
                    linkedAt: parseDate(row[ticketLinkedAt]) ?? Date(),
                    updatedAt: parseDate(row[ticketUpdatedAt]) ?? Date()
                )
            }
        } catch {
            print("Failed to fetch tickets: \(error)")
            return []
        }
    }

    func addTicket(to workstreamId: String, source: WorkstreamTicket.Source, linearIssueId: String? = nil, linearTeamId: String? = nil, githubOwner: String? = nil, githubRepo: String? = nil, githubNumber: Int? = nil, title: String? = nil, state: String? = nil, url: String? = nil, isPrimary: Bool = false) {
        guard let db = db else { return }

        let now = dateFormatter.string(from: Date())
        let id = UUID().uuidString.lowercased()

        do {
            try db.run(workstreamTickets.insert(or: .ignore,
                ticketId <- id,
                ticketWorkstreamId <- workstreamId,
                ticketSource <- source.rawValue,
                ticketLinearIssueId <- linearIssueId,
                ticketLinearTeamId <- linearTeamId,
                ticketGithubOwner <- githubOwner,
                ticketGithubRepo <- githubRepo,
                ticketGithubNumber <- githubNumber,
                ticketTitle <- title,
                ticketState <- state,
                ticketUrl <- url,
                ticketIsPrimary <- (isPrimary ? 1 : 0),
                ticketLinkedAt <- now,
                ticketUpdatedAt <- now
            ))
        } catch {
            print("Failed to add ticket: \(error)")
        }
    }

    // MARK: - Workstream Notes

    func fetchNotes(workstreamId: String) -> [WorkstreamNote] {
        guard let db = db else { return [] }

        let query = workstreamNotes
            .filter(noteWorkstreamId == workstreamId)
            .order(noteCreatedAt.desc)

        do {
            return try db.prepare(query).map { row in
                WorkstreamNote(
                    id: row[noteId],
                    workstreamId: row[noteWorkstreamId],
                    sessionId: row[noteSessionId],
                    type: WorkstreamNote.NoteType(rawValue: row[noteType]) ?? .note,
                    content: row[noteContent],
                    createdAt: parseDate(row[noteCreatedAt]) ?? Date(),
                    resolvedAt: parseDate(row[noteResolvedAt])
                )
            }
        } catch {
            print("Failed to fetch notes: \(error)")
            return []
        }
    }

    func addNote(to workstreamId: String, sessionId: String? = nil, type: WorkstreamNote.NoteType, content: String) {
        guard let db = db else { return }

        let now = dateFormatter.string(from: Date())
        let id = UUID().uuidString.lowercased()

        do {
            try db.run(workstreamNotes.insert(
                noteId <- id,
                noteWorkstreamId <- workstreamId,
                noteSessionId <- sessionId,
                noteType <- type.rawValue,
                noteContent <- content,
                noteCreatedAt <- now
            ))
        } catch {
            print("Failed to add note: \(error)")
        }
    }

    func resolveNote(noteId: String) {
        guard let db = db else { return }

        let now = dateFormatter.string(from: Date())
        let note = workstreamNotes.filter(self.noteId == noteId)

        do {
            try db.run(note.update(noteResolvedAt <- now))
        } catch {
            print("Failed to resolve note: \(error)")
        }
    }

    // MARK: - Workstream with Relations

    func fetchWorkstreamWithRelations(id workstreamIdValue: String) -> Workstream? {
        var workstream = fetchWorkstreams().first { $0.id == workstreamIdValue }
        guard workstream != nil else { return nil }

        workstream?.tickets = fetchTickets(workstreamId: workstreamIdValue)
        workstream?.notes = fetchNotes(workstreamId: workstreamIdValue)

        return workstream
    }

    func findOrCreateWorkstream(repoId: String, branch: String, directory: String?) -> Workstream? {
        guard let db = db else { return nil }

        // Skip main branches - they're not workstreams
        let mainBranches = ["main", "master", "develop", "development"]
        if mainBranches.contains(branch.lowercased()) {
            return nil
        }

        // Try to find existing workstream
        if let existing = try? db.pluck(workstreams.filter(workstreamRepoId == repoId && workstreamBranch == branch)) {
            return Workstream(
                id: existing[workstreamId],
                repoId: existing[workstreamRepoId],
                branch: existing[workstreamBranch],
                directory: existing[workstreamDirectory],
                linearIssueId: existing[linearIssueId],
                linearIssueTitle: existing[linearIssueTitle],
                linearIssueState: existing[linearIssueState],
                linearIssueURL: existing[linearIssueURL],
                githubIssueNumber: existing[githubIssueNumber],
                githubIssueTitle: existing[githubIssueTitle],
                githubIssueState: existing[githubIssueState],
                githubPRNumber: existing[githubPRNumber],
                githubPRTitle: existing[githubPRTitle],
                githubPRState: Workstream.PRState(rawValue: existing[githubPRState] ?? ""),
                githubPRURL: existing[githubPRURL],
                githubPRAdditions: existing[githubPRAdditions],
                githubPRDeletions: existing[githubPRDeletions],
                reviewState: Workstream.ReviewState(rawValue: existing[reviewState] ?? ""),
                reviewApprovals: existing[reviewApprovals],
                reviewComments: existing[reviewComments],
                stage: Workstream.Stage(rawValue: existing[workstreamStage]) ?? .working,
                sessionCount: existing[sessionCount],
                totalSessionSeconds: existing[totalSessionSeconds],
                commitCount: existing[commitCount],
                lastActivityAt: parseDate(existing[workstreamLastActivityAt]),
                createdAt: parseDate(existing[workstreamCreatedAt]) ?? Date(),
                updatedAt: parseDate(existing[workstreamUpdatedAt]) ?? Date()
            )
        }

        // Create new workstream
        let newId = UUID().uuidString
        let now = formatDate(Date())

        // Parse Linear issue from branch name
        let parsedLinearId = Workstream.parseLinearIssue(from: branch)

        do {
            try db.run(workstreams.insert(
                workstreamId <- newId,
                workstreamRepoId <- repoId,
                workstreamBranch <- branch,
                workstreamDirectory <- directory,
                linearIssueId <- parsedLinearId,
                workstreamStage <- "working",
                reviewApprovals <- 0,
                reviewComments <- 0,
                sessionCount <- 0,
                totalSessionSeconds <- 0,
                commitCount <- 0,
                workstreamCreatedAt <- now,
                workstreamUpdatedAt <- now
            ))

            return Workstream(
                id: newId,
                repoId: repoId,
                branch: branch,
                directory: directory,
                linearIssueId: parsedLinearId,
                reviewApprovals: 0,
                reviewComments: 0,
                stage: .working,
                sessionCount: 0,
                totalSessionSeconds: 0,
                commitCount: 0,
                createdAt: Date(),
                updatedAt: Date()
            )
        } catch {
            print("Failed to create workstream: \(error)")
            return nil
        }
    }

    func updateWorkstreamActivity(workstreamId: String) {
        guard let db = db else { return }

        let now = formatDate(Date())
        let ws = workstreams.filter(self.workstreamId == workstreamId)

        do {
            try db.run(ws.update(
                workstreamLastActivityAt <- now,
                workstreamUpdatedAt <- now
            ))
        } catch {
            print("Failed to update workstream activity: \(error)")
        }
    }

    func incrementWorkstreamSessionCount(workstreamId: String) {
        guard let db = db else { return }

        let ws = workstreams.filter(self.workstreamId == workstreamId)
        let now = formatDate(Date())

        do {
            try db.run(ws.update(
                sessionCount += 1,
                workstreamLastActivityAt <- now,
                workstreamUpdatedAt <- now
            ))
        } catch {
            print("Failed to increment session count: \(error)")
        }
    }

    func linkSessionToWorkstream(sessionId: String, workstreamId: String) {
        guard let db = db else { return }

        let session = sessions.filter(id == sessionId)

        do {
            try db.run(session.update(sessionWorkstreamId <- workstreamId))
        } catch {
            print("Failed to link session to workstream: \(error)")
        }
    }

    // MARK: - Project Operations

    func fetchProjects(status: Project.Status? = nil) -> [Project] {
        guard let db = db else { return [] }

        var query = projects.order(projectUpdatedAt.desc)

        if let status = status {
            query = query.filter(projectStatus == status.rawValue)
        }

        do {
            return try db.prepare(query).map { row in
                Project(
                    id: row[projectId],
                    name: row[projectDisplayName],
                    description: row[projectDescription],
                    color: row[projectColor],
                    status: Project.Status(rawValue: row[projectStatus]) ?? .active,
                    createdAt: parseDate(row[projectCreatedAt]) ?? Date(),
                    updatedAt: parseDate(row[projectUpdatedAt]) ?? Date()
                )
            }
        } catch {
            print("Failed to fetch projects: \(error)")
            return []
        }
    }

    func createProject(name: String, description: String? = nil, color: String? = nil) -> Project? {
        guard let db = db else { return nil }

        let newId = UUID().uuidString
        let now = formatDate(Date())

        do {
            try db.run(projects.insert(
                projectId <- newId,
                projectDisplayName <- name,
                projectDescription <- description,
                projectColor <- color,
                projectStatus <- "active",
                projectCreatedAt <- now,
                projectUpdatedAt <- now
            ))

            return Project(
                id: newId,
                name: name,
                description: description,
                color: color,
                status: .active,
                createdAt: Date(),
                updatedAt: Date()
            )
        } catch {
            print("Failed to create project: \(error)")
            return nil
        }
    }

    func addWorkstreamToProject(workstreamId: String, projectId: String) {
        guard let db = db else { return }

        do {
            try db.run(projectWorkstreams.insert(or: .ignore,
                pwProjectId <- projectId,
                pwWorkstreamId <- workstreamId
            ))
        } catch {
            print("Failed to add workstream to project: \(error)")
        }
    }

    func fetchWorkstreamsForProject(projectId: String) -> [Workstream] {
        guard let db = db else { return [] }

        let query = workstreams
            .join(projectWorkstreams, on: workstreamId == pwWorkstreamId)
            .filter(pwProjectId == projectId)
            .order(workstreamLastActivityAt.desc)

        do {
            return try db.prepare(query).map { row in
                Workstream(
                    id: row[workstreamId],
                    repoId: row[workstreamRepoId],
                    branch: row[workstreamBranch],
                    directory: row[workstreamDirectory],
                    name: row[workstreamName],
                    description: row[workstreamDescription],
                    linearIssueId: row[linearIssueId],
                    linearIssueTitle: row[linearIssueTitle],
                    linearIssueState: row[linearIssueState],
                    linearIssueURL: row[linearIssueURL],
                    githubIssueNumber: row[githubIssueNumber],
                    githubIssueTitle: row[githubIssueTitle],
                    githubIssueState: row[githubIssueState],
                    githubPRNumber: row[githubPRNumber],
                    githubPRTitle: row[githubPRTitle],
                    githubPRState: Workstream.PRState(rawValue: row[githubPRState] ?? ""),
                    githubPRURL: row[githubPRURL],
                    githubPRAdditions: row[githubPRAdditions],
                    githubPRDeletions: row[githubPRDeletions],
                    reviewState: Workstream.ReviewState(rawValue: row[reviewState] ?? ""),
                    reviewApprovals: row[reviewApprovals],
                    reviewComments: row[reviewComments],
                    stage: Workstream.Stage(rawValue: row[workstreamStage]) ?? .working,
                    sessionCount: row[sessionCount],
                    totalSessionSeconds: row[totalSessionSeconds],
                    commitCount: row[commitCount],
                    lastActivityAt: parseDate(row[workstreamLastActivityAt]),
                    createdAt: parseDate(row[workstreamCreatedAt]) ?? Date(),
                    updatedAt: parseDate(row[workstreamUpdatedAt]) ?? Date()
                )
            }
        } catch {
            print("Failed to fetch workstreams for project: \(error)")
            return []
        }
    }

    // MARK: - Helpers

    private func parseDate(_ dateString: String?) -> Date? {
        guard let str = dateString else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")

        return formatter.date(from: str)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
