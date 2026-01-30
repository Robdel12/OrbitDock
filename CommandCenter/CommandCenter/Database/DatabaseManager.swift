//
//  DatabaseManager.swift
//  CommandCenter
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
    private let contextLabel = SQLite.Expression<String?>("context_label")
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
        dbPath = homeDir.appendingPathComponent(".claude/dashboard.db").path

        do {
            db = try Connection(dbPath)
            // Enable WAL mode for better concurrent access (handles multiple writers/readers)
            try db?.execute("PRAGMA journal_mode = WAL")
            // Set busy timeout to 5 seconds - wait instead of failing immediately
            try db?.execute("PRAGMA busy_timeout = 5000")
            // Synchronous NORMAL is safer with WAL and still fast
            try db?.execute("PRAGMA synchronous = NORMAL")
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
                Session(
                    id: row[id],
                    projectPath: row[projectPath],
                    projectName: row[projectName],
                    branch: row[branch],
                    model: row[model],
                    contextLabel: row[contextLabel],
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
                    terminalApp: row[terminalApp]
                )
            }
        } catch {
            print("Failed to fetch sessions: \(error)")
            return []
        }
    }

    func updateContextLabel(sessionId: String, label: String?) {
        guard let db = db else { return }

        let session = sessions.filter(id == sessionId)
        do {
            try db.run(session.update(contextLabel <- label))
        } catch {
            print("Failed to update context label: \(error)")
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
