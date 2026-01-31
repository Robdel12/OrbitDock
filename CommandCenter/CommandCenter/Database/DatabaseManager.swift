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

    // MARK: - Helpers

    private func parseDate(_ dateString: String?) -> Date? {
        guard let str = dateString else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")

        return formatter.date(from: str)
    }
}
