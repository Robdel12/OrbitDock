//
//  DatabaseManager.swift
//  OrbitDock
//

import Foundation
import SQLite

actor DatabaseManager {
  static let shared = DatabaseManager()

  private var db: Connection?
  private let dbPath: String
  private let iso8601WithFractionalSecondsFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private let storageDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  // Table definitions
  private let sessions = Table("sessions")
  private let activities = Table("activities")
  private let repos = Table("repos")

  // Session columns
  private let id = SQLite.Expression<String>("id")
  private let projectPath = SQLite.Expression<String>("project_path")
  private let projectName = SQLite.Expression<String?>("project_name")
  private let branch = SQLite.Expression<String?>("branch")
  private let model = SQLite.Expression<String?>("model")
  private let sessionSummary = SQLite.Expression<String?>("summary") // Claude-generated title
  private let customName = SQLite.Expression<String?>("custom_name") // User-defined name
  private let firstPrompt = SQLite.Expression<String?>("first_prompt") // First user message fallback
  private let contextLabel = SQLite.Expression<String?>("context_label") // Legacy, mapped to custom_name
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
  private let pendingToolInput = SQLite.Expression<String?>("pending_tool_input")
  private let pendingQuestion = SQLite.Expression<String?>("pending_question")
  private let sessionProvider = SQLite.Expression<String?>("provider")

  // Codex direct integration columns
  private let codexIntegrationMode = SQLite.Expression<String?>("codex_integration_mode")
  private let codexThreadId = SQLite.Expression<String?>("codex_thread_id")
  private let pendingApprovalId = SQLite.Expression<String?>("pending_approval_id")

  // Codex token usage columns
  private let codexInputTokens = SQLite.Expression<Int?>("codex_input_tokens")
  private let codexOutputTokens = SQLite.Expression<Int?>("codex_output_tokens")
  private let codexCachedTokens = SQLite.Expression<Int?>("codex_cached_tokens")
  private let codexContextWindow = SQLite.Expression<Int?>("codex_context_window")

  // Codex turn state columns
  private let currentDiff = SQLite.Expression<String?>("current_diff")
  private let currentPlan = SQLite.Expression<String?>("current_plan")

  // Quest tables
  private let quests = Table("quests")
  private let inboxItems = Table("inbox_items")
  private let questLinks = Table("quest_links")
  private let questSessions = Table("quest_sessions")
  private let questNotes = Table("quest_notes")

  // Quest columns
  private let questId = SQLite.Expression<String>("id")
  private let questName = SQLite.Expression<String>("name")
  private let questDescription = SQLite.Expression<String?>("description")
  private let questStatus = SQLite.Expression<String>("status")
  private let questColor = SQLite.Expression<String?>("color")
  private let questCreatedAt = SQLite.Expression<String>("created_at")
  private let questUpdatedAt = SQLite.Expression<String>("updated_at")
  private let questCompletedAt = SQLite.Expression<String?>("completed_at")

  // Inbox item columns
  private let inboxId = SQLite.Expression<String>("id")
  private let inboxContent = SQLite.Expression<String>("content")
  private let inboxSource = SQLite.Expression<String>("source")
  private let inboxSessionId = SQLite.Expression<String?>("session_id")
  private let inboxQuestId = SQLite.Expression<String?>("quest_id")
  private let inboxStatus = SQLite.Expression<String>("status")
  private let inboxLinearIssueId = SQLite.Expression<String?>("linear_issue_id")
  private let inboxLinearIssueUrl = SQLite.Expression<String?>("linear_issue_url")
  private let inboxCreatedAt = SQLite.Expression<String>("created_at")
  private let inboxAttachedAt = SQLite.Expression<String?>("attached_at")
  private let inboxCompletedAt = SQLite.Expression<String?>("completed_at")

  // Quest link columns
  private let linkId = SQLite.Expression<String>("id")
  private let linkQuestId = SQLite.Expression<String>("quest_id")
  private let linkSource = SQLite.Expression<String>("source")
  private let linkUrl = SQLite.Expression<String>("url")
  private let linkTitle = SQLite.Expression<String?>("title")
  private let linkExternalId = SQLite.Expression<String?>("external_id")
  private let linkDetectedFrom = SQLite.Expression<String?>("detected_from")
  private let linkCreatedAt = SQLite.Expression<String>("created_at")

  // Quest note columns
  private let noteId = SQLite.Expression<String>("id")
  private let noteQuestId = SQLite.Expression<String>("quest_id")
  private let noteTitle = SQLite.Expression<String?>("title")
  private let noteContent = SQLite.Expression<String>("content")
  private let noteCreatedAt = SQLite.Expression<String>("created_at")
  private let noteUpdatedAt = SQLite.Expression<String>("updated_at")

  // Quest-session junction columns
  private let qsQuestId = SQLite.Expression<String>("quest_id")
  private let qsSessionId = SQLite.Expression<String>("session_id")
  private let qsLinkedAt = SQLite.Expression<String>("linked_at")

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

  private var fileMonitor: DispatchSourceFileSystemObject?

  /// Callback for external change notifications (file watcher detected CLI writes)
  /// SessionStore subscribes to this to know when to reload
  nonisolated(unsafe) static var onExternalChange: (() -> Void)?

  /// Allow custom path for UI testing
  nonisolated(unsafe) static var testDatabasePath: String?

  private init() {
    // Check for test database path (set via launch arguments or static property)
    if let testPath = Self.testDatabasePath {
      dbPath = testPath
    } else if let testPath = ProcessInfo.processInfo.environment["ORBITDOCK_TEST_DB"] {
      dbPath = testPath
    } else {
      let homeDir = FileManager.default.homeDirectoryForCurrentUser
      dbPath = homeDir.appendingPathComponent(".orbitdock/orbitdock.db").path
    }

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

    // Kick off async initialization work
    Task { [weak self] in
      await self?.performSetup()
    }
  }

  /// Performs async setup work after actor initialization
  private func performSetup() {
    ensureSchema()
    syncSummariesFromClaude()
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

    fileMonitor?.setEventHandler {
      Self.onExternalChange?()
    }

    fileMonitor?.setCancelHandler {
      close(fileDescriptor)
    }

    fileMonitor?.resume()
  }

  // MARK: - Session Operations

  func fetchSessions(statusFilter: Session.SessionStatus? = nil) -> [Session] {
    guard let db else { return [] }

    var query = sessions.order(lastActivityAt.desc)

    if let filter = statusFilter {
      query = query.filter(status == filter.rawValue)
    }

    do {
      return try db.prepare(query).map { row in
        // Get name-related fields - don't use context_label as fallback (it's just source metadata)
        let summaryValue = try? row.get(sessionSummary)
        let customNameValue = try? row.get(customName)
        let firstPromptValue = try? row.get(firstPrompt)

        // Parse attention reason with fallback logic
        let attentionReasonValue: Session.AttentionReason = {
          if let reasonStr = try? row.get(attentionReason),
             let reason = Session.AttentionReason(rawValue: reasonStr)
          {
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

        // Parse provider with fallback to claude
        let providerValue: Provider = {
          if let providerStr = try? row.get(sessionProvider),
             let provider = Provider(rawValue: providerStr)
          {
            return provider
          }
          return .claude
        }()

        // Parse Codex integration mode
        let integrationModeValue: CodexIntegrationMode? = {
          if let modeStr = try? row.get(codexIntegrationMode),
             let mode = CodexIntegrationMode(rawValue: modeStr)
          {
            return mode
          }
          return nil
        }()

        return Session(
          id: row[id],
          projectPath: row[projectPath],
          projectName: row[projectName],
          branch: row[branch],
          model: row[model],
          summary: summaryValue,
          customName: customNameValue,
          firstPrompt: firstPromptValue,
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
          pendingToolInput: (try? row.get(pendingToolInput)) ?? nil,
          pendingQuestion: (try? row.get(pendingQuestion)) ?? nil,
          provider: providerValue,
          codexIntegrationMode: integrationModeValue,
          codexThreadId: (try? row.get(codexThreadId)) ?? nil,
          pendingApprovalId: (try? row.get(pendingApprovalId)) ?? nil,
          codexInputTokens: (try? row.get(codexInputTokens)) ?? nil,
          codexOutputTokens: (try? row.get(codexOutputTokens)) ?? nil,
          codexCachedTokens: (try? row.get(codexCachedTokens)) ?? nil,
          codexContextWindow: (try? row.get(codexContextWindow)) ?? nil
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

  /// Manually end a session (close it from the UI)
  func endSession(sessionId: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)
    let now = formatDate(Date())

    do {
      try db.run(session.update(
        status <- "ended",
        endedAt <- now,
        endReason <- "manual",
        workStatus <- "unknown",
        attentionReason <- Session.AttentionReason.none.rawValue,
        pendingToolName <- nil as String?,
        pendingToolInput <- nil as String?,
        pendingQuestion <- nil as String?,
        pendingApprovalId <- nil as String?
      ))

      // Notify views to refresh
    } catch {
      print("Failed to end session: \(error)")
    }
  }

  /// Fetch a single session by ID
  func fetchSession(id sessionId: String) -> Session? {
    guard let db else { return nil }

    let query = sessions.filter(id == sessionId)

    do {
      guard let row = try db.pluck(query) else { return nil }

      let providerValue = Provider(rawValue: (try? row.get(sessionProvider)) ?? "claude") ?? .claude
      let integrationModeValue: CodexIntegrationMode? = {
        if let modeStr = try? row.get(codexIntegrationMode),
           let mode = CodexIntegrationMode(rawValue: modeStr)
        {
          return mode
        }
        return nil
      }()

      return Session(
        id: row[id],
        projectPath: row[projectPath],
        projectName: row[projectName],
        branch: row[branch],
        model: row[model],
        summary: (try? row.get(sessionSummary)) ?? nil,
        customName: (try? row.get(customName)) ?? nil,
        firstPrompt: (try? row.get(firstPrompt)) ?? nil,
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
        attentionReason: Session.AttentionReason(rawValue: (try? row.get(attentionReason)) ?? "none") ?? .none,
        pendingToolName: (try? row.get(pendingToolName)) ?? nil,
        pendingToolInput: (try? row.get(pendingToolInput)) ?? nil,
        pendingQuestion: (try? row.get(pendingQuestion)) ?? nil,
        provider: providerValue,
        codexIntegrationMode: integrationModeValue,
        codexThreadId: (try? row.get(codexThreadId)) ?? nil,
        pendingApprovalId: (try? row.get(pendingApprovalId)) ?? nil,
        codexInputTokens: (try? row.get(codexInputTokens)) ?? nil,
        codexOutputTokens: (try? row.get(codexOutputTokens)) ?? nil,
        codexCachedTokens: (try? row.get(codexCachedTokens)) ?? nil,
        codexContextWindow: (try? row.get(codexContextWindow)) ?? nil
      )
    } catch {
      print("Failed to fetch session by ID: \(error)")
      return nil
    }
  }

  /// Reactivate an ended session (for resuming Codex threads)
  func reactivateSession(sessionId: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)
    let now = formatDate(Date())

    do {
      try db.run(session.update(
        status <- Session.SessionStatus.active.rawValue,
        workStatus <- Session.WorkStatus.waiting.rawValue,
        attentionReason <- Session.AttentionReason.awaitingReply.rawValue,
        endedAt <- nil as String?,
        endReason <- nil as String?,
        lastActivityAt <- now
      ))

    } catch {
      print("Failed to reactivate session: \(error)")
    }
  }

  // MARK: - Codex Direct Session Operations

  /// Create a new Codex direct session (app-server JSON-RPC integration)
  func createCodexDirectSession(
    threadId: String,
    cwd: String,
    model: String? = nil,
    projectName: String? = nil,
    branch: String? = nil,
    transcriptPath rolloutPath: String? = nil
  ) -> Session? {
    guard let db else { return nil }

    let sessionId = "codex-direct-\(threadId)"
    let now = formatDate(Date())
    let computedProjectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent

    do {
      try db.run(sessions.insert(
        or: .replace,
        id <- sessionId,
        projectPath <- cwd,
        self.projectName <- computedProjectName,
        self.branch <- branch,
        self.model <- model,
        transcriptPath <- rolloutPath,
        status <- Session.SessionStatus.active.rawValue,
        workStatus <- Session.WorkStatus.waiting.rawValue,
        startedAt <- now,
        totalTokens <- 0,
        totalCostUSD <- 0.0,
        lastActivityAt <- now,
        promptCount <- 0,
        toolCount <- 0,
        attentionReason <- Session.AttentionReason.awaitingReply.rawValue,
        sessionProvider <- Provider.codex.rawValue,
        codexIntegrationMode <- CodexIntegrationMode.direct.rawValue,
        codexThreadId <- threadId
      ))

      return Session(
        id: sessionId,
        projectPath: cwd,
        projectName: computedProjectName,
        branch: branch,
        model: model,
        transcriptPath: rolloutPath,
        status: .active,
        workStatus: .waiting,
        startedAt: Date(),
        totalTokens: 0,
        totalCostUSD: 0,
        lastActivityAt: Date(),
        promptCount: 0,
        toolCount: 0,
        attentionReason: .awaitingReply,
        provider: .codex,
        codexIntegrationMode: .direct,
        codexThreadId: threadId
      )
    } catch {
      print("Failed to create Codex direct session: \(error)")
      return nil
    }
  }

  /// Update session's transcript path
  func updateSessionTranscriptPath(sessionId: String, path: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)
    let now = formatDate(Date())

    do {
      try db.run(session.update(
        transcriptPath <- path,
        lastActivityAt <- now
      ))

    } catch {
      print("Failed to update transcript path: \(error)")
    }
  }

  /// Update Codex direct session work status
  func updateCodexDirectSessionStatus(
    sessionId: String,
    workStatus: Session.WorkStatus,
    attentionReason: Session.AttentionReason,
    pendingToolName: String? = nil,
    pendingToolInput: String? = nil,
    pendingQuestion: String? = nil,
    pendingApprovalId: String? = nil
  ) {
    guard let db else {
      CodexFileLogger.shared.log(
        .error,
        category: .session,
        message: "updateCodexDirectSessionStatus: no db",
        sessionId: sessionId
      )
      return
    }

    let session = sessions.filter(id == sessionId)
    let now = formatDate(Date())

    CodexFileLogger.shared.log(.debug, category: .session, message: "DB update starting", sessionId: sessionId, data: [
      "workStatus": workStatus.rawValue,
      "attentionReason": attentionReason.rawValue,
      "dbPath": dbPath,
    ])

    do {
      try db.run(session.update(
        self.workStatus <- workStatus.rawValue,
        self.attentionReason <- attentionReason.rawValue,
        self.pendingToolName <- pendingToolName,
        self.pendingToolInput <- pendingToolInput,
        self.pendingQuestion <- pendingQuestion,
        self.pendingApprovalId <- pendingApprovalId,
        lastActivityAt <- now
      ))

      let rowsChanged = db.changes
      CodexFileLogger.shared.log(.info, category: .session, message: "DB update complete", sessionId: sessionId, data: [
        "dbPath": dbPath,
        "rowsChanged": rowsChanged,
        "workStatusSet": workStatus.rawValue,
        "attentionReasonSet": attentionReason.rawValue,
      ])

      // Verification read
      if let row = try? db.pluck(session) {
        let actualWorkStatus = try? row.get(self.workStatus)
        let actualAttention = try? row.get(self.attentionReason)
        CodexFileLogger.shared.log(
          .debug,
          category: .session,
          message: "DB verification read",
          sessionId: sessionId,
          data: [
            "actualWorkStatus": actualWorkStatus ?? "nil",
            "actualAttention": actualAttention ?? "nil",
          ]
        )
      }

    } catch {
      CodexFileLogger.shared.log(.error, category: .session, message: "DB update failed", sessionId: sessionId, data: [
        "error": error.localizedDescription,
      ])
    }
  }

  /// Clear pending approval state for a Codex direct session
  func clearCodexPendingApproval(sessionId: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)
    let now = formatDate(Date())

    do {
      try db.run(session.update(
        workStatus <- Session.WorkStatus.working.rawValue,
        attentionReason <- Session.AttentionReason.none.rawValue,
        pendingToolName <- nil as String?,
        pendingToolInput <- nil as String?,
        pendingQuestion <- nil as String?,
        pendingApprovalId <- nil as String?,
        lastActivityAt <- now
      ))

    } catch {
      print("Failed to clear Codex pending approval: \(error)")
    }
  }

  /// Increment prompt count for Codex direct session
  func incrementCodexPromptCount(sessionId: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)

    do {
      try db.run(session.update(
        promptCount <- promptCount + 1
      ))
    } catch {
      print("Failed to increment prompt count: \(error)")
    }
  }

  /// Increment tool count for Codex direct session
  func incrementCodexToolCount(sessionId: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)

    do {
      try db.run(session.update(
        toolCount <- toolCount + 1
      ))
    } catch {
      print("Failed to increment tool count: \(error)")
    }
  }

  /// Update last tool for Codex direct session
  func updateCodexLastTool(sessionId: String, tool: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)
    let now = formatDate(Date())

    do {
      try db.run(session.update(
        lastTool <- tool,
        lastToolAt <- now,
        lastActivityAt <- now
      ))
    } catch {
      print("Failed to update last tool: \(error)")
    }
  }

  /// Update token usage for a Codex session
  func updateCodexTokenUsage(
    sessionId: String,
    inputTokens: Int?,
    outputTokens: Int?,
    cachedTokens: Int?,
    contextWindow: Int?
  ) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)

    do {
      var setters: [Setter] = []

      if let input = inputTokens {
        setters.append(codexInputTokens <- input)
      }
      if let output = outputTokens {
        setters.append(codexOutputTokens <- output)
      }
      if let cached = cachedTokens {
        setters.append(codexCachedTokens <- cached)
      }
      if let window = contextWindow {
        setters.append(codexContextWindow <- window)
      }

      guard !setters.isEmpty else { return }

      try db.run(session.update(setters))

    } catch {
      print("Failed to update Codex token usage: \(error)")
    }
  }

  /// Update the aggregated diff for the current turn
  func updateCodexDiff(sessionId: String, diff: String?) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)

    do {
      try db.run(session.update(currentDiff <- diff))

    } catch {
      print("Failed to update Codex diff: \(error)")
    }
  }

  /// Update the agent's plan for the current turn
  func updateCodexPlan(sessionId: String, plan: [Session.PlanStep]?) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)

    do {
      let planJson: String?
      if let plan {
        let data = try JSONEncoder().encode(plan)
        planJson = String(data: data, encoding: .utf8)
      } else {
        planJson = nil
      }

      try db.run(session.update(currentPlan <- planJson))

    } catch {
      print("Failed to update Codex plan: \(error)")
    }
  }

  /// Clear turn state (diff/plan) when turn completes
  func clearCodexTurnState(sessionId: String) {
    guard let db else { return }

    let session = sessions.filter(id == sessionId)

    do {
      try db.run(session.update(
        currentDiff <- nil as String?,
        currentPlan <- nil as String?
      ))
    } catch {
      print("Failed to clear turn state: \(error)")
    }
  }

  /// Fetch turn state (diff/plan) for a session
  func fetchCodexTurnState(sessionId: String) -> (diff: String?, plan: [Session.PlanStep]?) {
    guard let db else { return (nil, nil) }

    let query = sessions.filter(id == sessionId)

    do {
      guard let row = try db.pluck(query) else { return (nil, nil) }

      let diff = (try? row.get(currentDiff)) ?? nil
      let planJson = (try? row.get(currentPlan)) ?? nil

      var plan: [Session.PlanStep]?
      if let json = planJson,
         let data = json.data(using: .utf8),
         let steps = try? JSONDecoder().decode([Session.PlanStep].self, from: data)
      {
        plan = steps
      }

      return (diff, plan)
    } catch {
      print("Failed to fetch turn state: \(error)")
      return (nil, nil)
    }
  }

  /// Fetch session by Codex thread ID
  func fetchSessionByThreadId(_ threadId: String) -> Session? {
    guard let db else { return nil }

    let query = sessions.filter(codexThreadId == threadId)

    do {
      guard let row = try db.pluck(query) else { return nil }

      let providerValue = Provider(rawValue: (try? row.get(sessionProvider)) ?? "codex") ?? .codex
      let integrationModeValue: CodexIntegrationMode? = {
        if let modeStr = try? row.get(codexIntegrationMode),
           let mode = CodexIntegrationMode(rawValue: modeStr)
        {
          return mode
        }
        return nil
      }()

      return Session(
        id: row[id],
        projectPath: row[projectPath],
        projectName: row[projectName],
        branch: row[branch],
        model: row[model],
        summary: (try? row.get(sessionSummary)) ?? nil,
        customName: (try? row.get(customName)) ?? nil,
        firstPrompt: (try? row.get(firstPrompt)) ?? nil,
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
        attentionReason: Session.AttentionReason(rawValue: (try? row.get(attentionReason)) ?? "none") ?? .none,
        pendingToolName: (try? row.get(pendingToolName)) ?? nil,
        pendingToolInput: (try? row.get(pendingToolInput)) ?? nil,
        pendingQuestion: (try? row.get(pendingQuestion)) ?? nil,
        provider: providerValue,
        codexIntegrationMode: integrationModeValue,
        codexThreadId: (try? row.get(codexThreadId)) ?? nil,
        pendingApprovalId: (try? row.get(pendingApprovalId)) ?? nil,
        codexInputTokens: (try? row.get(codexInputTokens)) ?? nil,
        codexOutputTokens: (try? row.get(codexOutputTokens)) ?? nil,
        codexCachedTokens: (try? row.get(codexCachedTokens)) ?? nil,
        codexContextWindow: (try? row.get(codexContextWindow)) ?? nil
      )
    } catch {
      print("Failed to fetch session by thread ID: \(error)")
      return nil
    }
  }

  func updateCustomName(sessionId: String, name: String?) {
    guard let db else { return }

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
    guard let db else { return }

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
    guard let db else { return false }
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

  /// Ensure the database schema is up to date
  func ensureSchema() {
    guard let db else { return }

    let migrationManager = MigrationManager(db: db)

    // Check if this is a pre-migration database (has tables but no schema_versions)
    let isLegacyDatabase = tableExists("sessions") && !tableExists("schema_versions")

    if isLegacyDatabase {
      // Bootstrap: mark migration 001 as applied since schema already exists
      // Then apply any missing columns that 001 would have created
      bootstrapLegacyDatabase(migrationManager: migrationManager)
    }

    // Run any pending migrations
    let applied = migrationManager.migrate()
    if !applied.isEmpty {
      print("Applied \(applied.count) migration(s): \(applied.map(\.name).joined(separator: ", "))")
    }

    let status = migrationManager.getStatus()
    if status.pending > 0 {
      print("Warning: \(status.pending) pending migration(s) could not be applied")
    }
  }

  /// Bootstrap a legacy database that existed before the migration system
  private func bootstrapLegacyDatabase(migrationManager: MigrationManager) {
    guard let db else { return }

    print("Bootstrapping legacy database to migration system...")

    // Create the schema_versions table
    do {
      try db.execute("""
        CREATE TABLE IF NOT EXISTS schema_versions (
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          applied_at TEXT NOT NULL
        )
      """)

      // Mark migration 001 as applied (the schema already exists)
      let now = ISO8601DateFormatter().string(from: Date())
      try db.run(
        "INSERT OR IGNORE INTO schema_versions (version, name, applied_at) VALUES (?, ?, ?)",
        1, "initial", now
      )

      print("Marked migration 001_initial as applied (legacy bootstrap)")
    } catch {
      print("Failed to bootstrap legacy database: \(error)")
    }

    // Add any columns that might be missing from older versions
    // This handles databases created before certain columns were added
    addMissingColumnsForLegacy()
  }

  /// Add columns that might be missing from very old databases
  private func addMissingColumnsForLegacy() {
    guard let db else { return }

    // Sessions table columns added over time
    let sessionColumns: [(String, String)] = [
      ("summary", "TEXT"),
      ("custom_name", "TEXT"),
      ("first_prompt", "TEXT"),
      ("attention_reason", "TEXT"),
      ("pending_tool_name", "TEXT"),
      ("pending_tool_input", "TEXT"),
      ("pending_question", "TEXT"),
      ("provider", "TEXT DEFAULT 'claude'"),
      ("end_reason", "TEXT"),
      // Codex direct integration (migration 008)
      ("codex_integration_mode", "TEXT"),
      ("codex_thread_id", "TEXT"),
      ("pending_approval_id", "TEXT"),
    ]

    for (column, type) in sessionColumns {
      if !columnExists(column, in: "sessions") {
        do {
          try db.run("ALTER TABLE sessions ADD COLUMN \(column) \(type)")
        } catch {
          // Column might already exist or table doesn't exist yet
        }
      }
    }

    // Ensure dependent tables exist (for very old databases)
    createReposTable()
  }

  private func tableExists(_ tableName: String) -> Bool {
    guard let db else { return false }
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
    guard let db, !tableExists("repos") else { return }

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

  // MARK: - Activity Operations

  func fetchActivities(forSessionId sid: String, limit: Int = 50) -> [Activity] {
    guard let db else { return [] }

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
    guard let db else { return 0 }
    let query = sessions.filter(status == "active")
    return (try? db.scalar(query.count)) ?? 0
  }

  func waitingSessionCount() -> Int {
    guard let db else { return 0 }
    let query = sessions.filter(status == "active" && (workStatus == "waiting" || workStatus == "permission"))
    return (try? db.scalar(query.count)) ?? 0
  }

  func totalCostToday() -> Double {
    guard let db else { return 0 }

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
    guard let db else { return [] }

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
    guard let db else { return nil }

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

  // MARK: - Quest Operations

  func fetchQuests(status: Quest.Status? = nil) -> [Quest] {
    guard let db else { return [] }

    var query = quests.order(questUpdatedAt.desc)

    if let status {
      query = query.filter(questStatus == status.rawValue)
    }

    do {
      return try db.prepare(query).map { row in
        Quest(
          id: row[questId],
          name: row[questName],
          description: row[questDescription],
          status: Quest.Status(rawValue: row[questStatus]) ?? .active,
          color: row[questColor],
          createdAt: parseDate(row[questCreatedAt]) ?? Date(),
          updatedAt: parseDate(row[questUpdatedAt]) ?? Date(),
          completedAt: parseDate(row[questCompletedAt])
        )
      }
    } catch {
      print("Failed to fetch quests: \(error)")
      return []
    }
  }

  func fetchQuest(id questIdValue: String) -> Quest? {
    guard let db else { return nil }

    guard let row = try? db.pluck(quests.filter(questId == questIdValue)) else {
      return nil
    }

    var quest = Quest(
      id: row[questId],
      name: row[questName],
      description: row[questDescription],
      status: Quest.Status(rawValue: row[questStatus]) ?? .active,
      color: row[questColor],
      createdAt: parseDate(row[questCreatedAt]) ?? Date(),
      updatedAt: parseDate(row[questUpdatedAt]) ?? Date(),
      completedAt: parseDate(row[questCompletedAt])
    )

    // Populate relationships
    quest.links = fetchQuestLinks(questId: questIdValue)
    quest.sessions = fetchSessionsForQuest(questId: questIdValue)
    quest.inboxItems = fetchInboxItems(questId: questIdValue)
    quest.notes = fetchQuestNotes(questId: questIdValue)

    return quest
  }

  func createQuest(name: String, description: String? = nil, color: String? = nil) -> Quest? {
    guard let db else { return nil }

    let newId = UUID().uuidString.lowercased()
    let now = formatDate(Date())

    do {
      try db.run(quests.insert(
        questId <- newId,
        questName <- name,
        questDescription <- description,
        questStatus <- "active",
        questColor <- color,
        questCreatedAt <- now,
        questUpdatedAt <- now
      ))

      return Quest(
        id: newId,
        name: name,
        description: description,
        status: .active,
        color: color,
        createdAt: Date(),
        updatedAt: Date()
      )
    } catch {
      print("Failed to create quest: \(error)")
      return nil
    }
  }

  func updateQuest(
    id questIdValue: String,
    name: String? = nil,
    description: String? = nil,
    status: Quest.Status? = nil,
    color: String? = nil
  ) {
    guard let db else { return }

    let quest = quests.filter(questId == questIdValue)
    let now = formatDate(Date())

    do {
      var setters: [Setter] = [questUpdatedAt <- now]

      if let name {
        setters.append(questName <- name)
      }
      if let description {
        setters.append(questDescription <- description)
      }
      if let status {
        setters.append(questStatus <- status.rawValue)
        if status == .completed {
          setters.append(questCompletedAt <- now)
        }
      }
      if let color {
        setters.append(questColor <- color)
      }

      try db.run(quest.update(setters))

    } catch {
      print("Failed to update quest: \(error)")
    }
  }

  func deleteQuest(id questIdValue: String) {
    guard let db else { return }

    let quest = quests.filter(questId == questIdValue)

    do {
      try db.run(quest.delete())

    } catch {
      print("Failed to delete quest: \(error)")
    }
  }

  // MARK: - Inbox Operations

  func fetchInboxItems(status: InboxItem.Status? = nil, questId questIdValue: String? = nil) -> [InboxItem] {
    guard let db else { return [] }

    var query = inboxItems.order(inboxCreatedAt.desc)

    if let status {
      query = query.filter(inboxStatus == status.rawValue)
    }

    if let questIdValue {
      query = query.filter(inboxQuestId == questIdValue)
    }

    do {
      return try db.prepare(query).map { row in
        InboxItem(
          id: row[inboxId],
          content: row[inboxContent],
          source: InboxItem.Source(rawValue: row[inboxSource]) ?? .manual,
          sessionId: row[inboxSessionId],
          questId: row[inboxQuestId],
          status: InboxItem.Status(rawValue: row[inboxStatus]) ?? .pending,
          linearIssueId: row[inboxLinearIssueId],
          linearIssueUrl: row[inboxLinearIssueUrl],
          createdAt: parseDate(row[inboxCreatedAt]) ?? Date(),
          attachedAt: parseDate(row[inboxAttachedAt]),
          completedAt: parseDate(row[inboxCompletedAt])
        )
      }
    } catch {
      print("Failed to fetch inbox items: \(error)")
      return []
    }
  }

  func captureToInbox(content: String, source: InboxItem.Source = .manual, sessionId: String? = nil) -> InboxItem? {
    guard let db else { return nil }

    let newId = UUID().uuidString.lowercased()
    let now = formatDate(Date())

    do {
      try db.run(inboxItems.insert(
        inboxId <- newId,
        inboxContent <- content,
        inboxSource <- source.rawValue,
        inboxSessionId <- sessionId,
        inboxStatus <- InboxItem.Status.pending.rawValue,
        inboxCreatedAt <- now
      ))

      return InboxItem(
        id: newId,
        content: content,
        source: source,
        sessionId: sessionId,
        questId: nil,
        status: .pending,
        linearIssueId: nil,
        linearIssueUrl: nil,
        createdAt: Date(),
        attachedAt: nil,
        completedAt: nil
      )
    } catch {
      print("Failed to capture to inbox: \(error)")
      return nil
    }
  }

  func attachInboxItem(id itemId: String, toQuest questIdValue: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)
    let now = formatDate(Date())

    do {
      try db.run(item.update(
        inboxQuestId <- questIdValue,
        inboxStatus <- InboxItem.Status.attached.rawValue,
        inboxAttachedAt <- now
      ))

    } catch {
      print("Failed to attach inbox item: \(error)")
    }
  }

  func detachInboxItem(id itemId: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)

    do {
      try db.run(item.update(
        inboxQuestId <- nil as String?,
        inboxStatus <- InboxItem.Status.pending.rawValue,
        inboxAttachedAt <- nil as String?
      ))

    } catch {
      print("Failed to detach inbox item: \(error)")
    }
  }

  func markInboxItemDone(id itemId: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)
    let now = formatDate(Date())

    do {
      try db.run(item.update(
        inboxStatus <- InboxItem.Status.completed.rawValue,
        inboxCompletedAt <- now
      ))

    } catch {
      print("Failed to mark inbox item done: \(error)")
    }
  }

  func archiveInboxItem(id itemId: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)
    let now = formatDate(Date())

    do {
      try db.run(item.update(
        inboxStatus <- InboxItem.Status.archived.rawValue,
        inboxCompletedAt <- now
      ))

    } catch {
      print("Failed to archive inbox item: \(error)")
    }
  }

  func convertInboxItemToLinear(id itemId: String, issueId: String, issueUrl: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)
    let now = formatDate(Date())

    do {
      try db.run(item.update(
        inboxStatus <- InboxItem.Status.converted.rawValue,
        inboxLinearIssueId <- issueId,
        inboxLinearIssueUrl <- issueUrl,
        inboxCompletedAt <- now
      ))

    } catch {
      print("Failed to convert inbox item to Linear: \(error)")
    }
  }

  func updateInboxItem(id itemId: String, content: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)

    do {
      try db.run(item.update(
        inboxContent <- content
      ))

    } catch {
      print("Failed to update inbox item: \(error)")
    }
  }

  func deleteInboxItem(id itemId: String) {
    guard let db else { return }

    let item = inboxItems.filter(inboxId == itemId)

    do {
      try db.run(item.delete())

    } catch {
      print("Failed to delete inbox item: \(error)")
    }
  }

  // MARK: - Quest-Session Operations

  func linkSessionToQuest(sessionId sessionIdValue: String, questId questIdValue: String) {
    guard let db else { return }

    let now = formatDate(Date())

    do {
      try db.run(questSessions.insert(
        or: .ignore,
        qsQuestId <- questIdValue,
        qsSessionId <- sessionIdValue,
        qsLinkedAt <- now
      ))

    } catch {
      print("Failed to link session to quest: \(error)")
    }
  }

  func unlinkSessionFromQuest(sessionId sessionIdValue: String, questId questIdValue: String) {
    guard let db else { return }

    let link = questSessions.filter(qsQuestId == questIdValue && qsSessionId == sessionIdValue)

    do {
      try db.run(link.delete())

    } catch {
      print("Failed to unlink session from quest: \(error)")
    }
  }

  func fetchQuestsForSession(sessionId sessionIdValue: String) -> [Quest] {
    guard let db else { return [] }

    let query = quests
      .join(questSessions, on: questId == qsQuestId)
      .filter(qsSessionId == sessionIdValue)
      .order(questUpdatedAt.desc)

    do {
      return try db.prepare(query).map { row in
        Quest(
          id: row[questId],
          name: row[questName],
          description: row[questDescription],
          status: Quest.Status(rawValue: row[questStatus]) ?? .active,
          color: row[questColor],
          createdAt: parseDate(row[questCreatedAt]) ?? Date(),
          updatedAt: parseDate(row[questUpdatedAt]) ?? Date(),
          completedAt: parseDate(row[questCompletedAt])
        )
      }
    } catch {
      print("Failed to fetch quests for session: \(error)")
      return []
    }
  }

  func fetchSessionsForQuest(questId questIdValue: String) -> [Session] {
    guard let db else { return [] }

    let query = sessions
      .join(questSessions, on: id == qsSessionId)
      .filter(qsQuestId == questIdValue)
      .order(lastActivityAt.desc)

    do {
      return try db.prepare(query).map { row in
        Session(
          id: row[id],
          projectPath: row[projectPath],
          projectName: row[projectName],
          branch: row[branch],
          model: row[model],
          summary: (try? row.get(sessionSummary)) ?? nil,
          customName: (try? row.get(customName)) ?? nil,
          firstPrompt: (try? row.get(firstPrompt)) ?? nil,
          transcriptPath: row[transcriptPath],
          status: Session.SessionStatus(rawValue: row[status]) ?? .ended,
          workStatus: Session.WorkStatus(rawValue: row[workStatus] ?? "unknown") ?? .unknown,
          startedAt: parseDate(row[startedAt]),
          endedAt: parseDate(row[endedAt]),
          totalTokens: row[totalTokens],
          totalCostUSD: row[totalCostUSD],
          lastActivityAt: parseDate(row[lastActivityAt]),
          promptCount: row[promptCount] ?? 0,
          toolCount: row[toolCount] ?? 0,
          provider: Provider(rawValue: (try? row.get(sessionProvider)) ?? "claude") ?? .claude
        )
      }
    } catch {
      print("Failed to fetch sessions for quest: \(error)")
      return []
    }
  }

  // MARK: - Quest Link Operations

  func fetchQuestLinks(questId questIdValue: String) -> [QuestLink] {
    guard let db else { return [] }

    let query = questLinks
      .filter(linkQuestId == questIdValue)
      .order(linkCreatedAt.desc)

    do {
      return try db.prepare(query).map { row in
        QuestLink(
          id: row[linkId],
          questId: row[linkQuestId],
          source: QuestLink.Source(rawValue: row[linkSource]) ?? .githubPR,
          url: row[linkUrl],
          title: row[linkTitle],
          externalId: row[linkExternalId],
          detectedFrom: QuestLink.Detection(rawValue: row[linkDetectedFrom] ?? "manual") ?? .manual,
          createdAt: parseDate(row[linkCreatedAt]) ?? Date()
        )
      }
    } catch {
      print("Failed to fetch quest links: \(error)")
      return []
    }
  }

  func addQuestLink(
    questId questIdValue: String,
    source: QuestLink.Source,
    url: String,
    title: String? = nil,
    externalId: String? = nil,
    detectedFrom: QuestLink.Detection = .manual
  ) -> QuestLink? {
    guard let db else { return nil }

    let newId = UUID().uuidString.lowercased()
    let now = formatDate(Date())

    do {
      try db.run(questLinks.insert(
        or: .ignore,
        linkId <- newId,
        linkQuestId <- questIdValue,
        linkSource <- source.rawValue,
        linkUrl <- url,
        linkTitle <- title,
        linkExternalId <- externalId,
        linkDetectedFrom <- detectedFrom.rawValue,
        linkCreatedAt <- now
      ))

      return QuestLink(
        id: newId,
        questId: questIdValue,
        source: source,
        url: url,
        title: title,
        externalId: externalId,
        detectedFrom: detectedFrom,
        createdAt: Date()
      )
    } catch {
      print("Failed to add quest link: \(error)")
      return nil
    }
  }

  func removeQuestLink(id linkIdValue: String) {
    guard let db else { return }

    let link = questLinks.filter(linkId == linkIdValue)

    do {
      try db.run(link.delete())

    } catch {
      print("Failed to remove quest link: \(error)")
    }
  }

  // MARK: - Quest Note Operations

  func fetchQuestNotes(questId questIdValue: String) -> [QuestNote] {
    guard let db else { return [] }

    let query = questNotes
      .filter(noteQuestId == questIdValue)
      .order(noteUpdatedAt.desc)

    do {
      return try db.prepare(query).map { row in
        QuestNote(
          id: row[noteId],
          questId: row[noteQuestId],
          title: row[noteTitle],
          content: row[noteContent],
          createdAt: parseDate(row[noteCreatedAt]) ?? Date(),
          updatedAt: parseDate(row[noteUpdatedAt]) ?? Date()
        )
      }
    } catch {
      print("Failed to fetch quest notes: \(error)")
      return []
    }
  }

  func createQuestNote(questId questIdValue: String, title: String? = nil, content: String) -> QuestNote? {
    guard let db else { return nil }

    let newId = UUID().uuidString.lowercased()
    let now = formatDate(Date())

    do {
      try db.run(questNotes.insert(
        noteId <- newId,
        noteQuestId <- questIdValue,
        noteTitle <- title,
        noteContent <- content,
        noteCreatedAt <- now,
        noteUpdatedAt <- now
      ))

      return QuestNote(
        id: newId,
        questId: questIdValue,
        title: title,
        content: content,
        createdAt: Date(),
        updatedAt: Date()
      )
    } catch {
      print("Failed to create quest note: \(error)")
      return nil
    }
  }

  func updateQuestNote(id noteIdValue: String, title: String? = nil, content: String? = nil) {
    guard let db else { return }

    let note = questNotes.filter(noteId == noteIdValue)
    let now = formatDate(Date())

    var setters: [Setter] = [noteUpdatedAt <- now]
    if let title { setters.append(noteTitle <- title) }
    if let content { setters.append(noteContent <- content) }

    do {
      try db.run(note.update(setters))

    } catch {
      print("Failed to update quest note: \(error)")
    }
  }

  func deleteQuestNote(id noteIdValue: String) {
    guard let db else { return }

    let note = questNotes.filter(noteId == noteIdValue)

    do {
      try db.run(note.delete())

    } catch {
      print("Failed to delete quest note: \(error)")
    }
  }

  // MARK: - Helpers

  private func parseDate(_ dateString: String?) -> Date? {
    guard let str = dateString else { return nil }

    // Try ISO 8601 first (how Claude Code stores dates)
    if let date = iso8601WithFractionalSecondsFormatter.date(from: str) {
      return date
    }

    // Fallback: try without fractional seconds
    if let date = iso8601Formatter.date(from: str) {
      return date
    }

    // Legacy fallback for old format
    return storageDateFormatter.date(from: str)
  }

  private func formatDate(_ date: Date) -> String {
    storageDateFormatter.string(from: date)
  }
}
