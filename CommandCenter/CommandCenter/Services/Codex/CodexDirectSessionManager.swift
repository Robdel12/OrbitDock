//
//  CodexDirectSessionManager.swift
//  OrbitDock
//
//  Orchestrates direct Codex sessions via the app-server JSON-RPC API.
//  Handles session lifecycle, message sending, and approval workflows.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "CodexDirectSession")

@Observable
@MainActor
final class CodexDirectSessionManager {

  // MARK: - Properties

  let client: CodexAppServerClient
  private let db: DatabaseManager
  private let messageStore: MessageStore
  private let eventHandler: CodexEventHandler

  /// Thread ID → Session ID mapping for active sessions
  private var threadSessionMap: [String: String] = [:]

  /// Whether the manager has started event processing
  private var isListening = false

  /// Event processing task
  private var eventTask: Task<Void, Never>?

  // MARK: - Initialization

  init(
    client: CodexAppServerClient? = nil,
    db: DatabaseManager? = nil,
    messageStore: MessageStore? = nil
  ) {
    self.client = client ?? CodexAppServerClient()
    self.db = db ?? DatabaseManager.shared
    self.messageStore = messageStore ?? MessageStore.shared
    self.eventHandler = CodexEventHandler(db: self.db, messageStore: self.messageStore)
  }

  func cleanup() {
    eventTask?.cancel()
  }

  // MARK: - Connection Management

  /// Connect to app-server and start listening for events
  func connect() async throws {
    try await client.connect()
    startListening()
    logger.info("Connected and listening for events")
  }

  /// Disconnect and stop listening
  func disconnect() {
    eventTask?.cancel()
    eventTask = nil
    isListening = false
    client.disconnect()
    logger.info("Disconnected")
  }

  /// Start listening for events from the app-server
  private func startListening() {
    guard !isListening else { return }
    isListening = true

    eventTask = Task { [weak self] in
      guard let self else { return }

      for await event in client.events {
        await self.handleEvent(event)
      }
    }
  }

  /// Handle an incoming event from the app-server
  private func handleEvent(_ event: CodexServerEvent) async {
    // Find the session ID for this event (from thread ID in event or global state)
    let sessionId = extractSessionId(from: event)

    guard let sessionId else {
      logger.warning("Received event without session context: \(String(describing: event))")
      return
    }

    // Delegate to event handler
    await eventHandler.handle(event, sessionId: sessionId)
  }

  /// Extract session ID from an event
  private func extractSessionId(from event: CodexServerEvent) -> String? {
    switch event {
      case let .turnStarted(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case let .turnCompleted(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case let .turnAborted(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case let .itemCreated(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case let .itemUpdated(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case let .threadNameUpdated(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case let .tokenUsageUpdated(e):
        if let threadId = e.threadId {
          return threadSessionMap[threadId]
        }
      case .rateLimitsUpdated:
        // Rate limits are account-wide, not per-thread
        // Use first session as fallback (could be improved to update all sessions)
        return threadSessionMap.values.first
      case .mcpStartupUpdate, .mcpStartupComplete:
        // MCP events are global, use first session
        return threadSessionMap.values.first
      default:
        // For events without thread ID, use the most recent active session
        // This is a fallback for approval requests and similar events
        return threadSessionMap.values.first
    }
    return nil
  }

  // MARK: - Session Lifecycle

  /// Create a new Codex direct session
  func createSession(cwd: String, model: String? = nil) async throws -> Session {
    // Ensure connected
    if client.state != .connected {
      try await connect()
    }

    // Start thread via app-server
    let threadInfo = try await client.startThread(cwd: cwd, model: model)
    logger.info("Created thread: \(threadInfo.id)")

    // Resolve git info for branch
    let branch = resolveGitBranch(cwd: cwd)

    // Create session in database with rollout path for transcript
    guard let session = db.createCodexDirectSession(
      threadId: threadInfo.id,
      cwd: cwd,
      model: model,
      branch: branch,
      transcriptPath: threadInfo.path
    ) else {
      throw CodexClientError.requestFailed(code: -1, message: "Failed to create session in database")
    }

    // Update mapping
    threadSessionMap[threadInfo.id] = session.id

    logger.info("Created session: \(session.id) for thread: \(threadInfo.id)")
    return session
  }

  /// Resume an existing Codex direct session
  func resumeSession(_ session: Session) async throws {
    guard let threadId = session.codexThreadId else {
      throw CodexClientError.requestFailed(code: -1, message: "Session has no thread ID")
    }

    try await resumeSessionById(session.id, threadId: threadId, cwd: session.projectPath)
  }

  /// Resume a session by its IDs (internal helper)
  private func resumeSessionById(_ sessionId: String, threadId: String, cwd: String) async throws {
    // Ensure connected
    if client.state != .connected {
      try await connect()
    }

    // Resume thread via app-server
    _ = try await client.resumeThread(threadId: threadId, cwd: cwd)

    // Update mapping
    threadSessionMap[threadId] = sessionId

    logger.info("Resumed session: \(sessionId) for thread: \(threadId)")
  }

  /// End a Codex direct session
  func endSession(_ sessionId: String) async throws {
    // Find thread ID
    guard let threadId = threadSessionMap.first(where: { $0.value == sessionId })?.key else {
      // Just end in database
      db.endSession(sessionId: sessionId)
      return
    }

    // Try to interrupt any running turn
    do {
      try await client.interruptTurn(threadId: threadId)
    } catch {
      logger.warning("Failed to interrupt turn when ending session: \(error.localizedDescription)")
    }

    // Remove from mapping
    threadSessionMap.removeValue(forKey: threadId)

    // End in database
    db.endSession(sessionId: sessionId)

    logger.info("Ended session: \(sessionId)")
  }

  // MARK: - Turn Operations

  /// Send a user message to start a new turn
  func sendMessage(_ sessionId: String, message: String) async throws {
    // Try to get thread ID from active sessions
    var threadId = threadIdForSession(sessionId)

    // If not in active map, try to resume the session
    if threadId == nil {
      // Look up session from database to get thread ID
      if let session = db.fetchSession(id: sessionId),
         let storedThreadId = session.codexThreadId
      {
        // Resume the thread with app-server
        try await resumeSessionById(sessionId, threadId: storedThreadId, cwd: session.projectPath)
        threadId = storedThreadId

        // Reactivate session in database
        db.reactivateSession(sessionId: sessionId)
        logger.info("Auto-resumed session: \(sessionId) for thread: \(storedThreadId)")
      }
    }

    guard let threadId else {
      throw CodexClientError.requestFailed(code: -1, message: "Session not found or has no thread ID")
    }

    // Update session to working state
    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .working,
      attentionReason: .none
    )

    // Increment prompt count
    db.incrementCodexPromptCount(sessionId: sessionId)

    // Store user message
    let userMessage = TranscriptMessage(
      id: UUID().uuidString,
      type: .user,
      content: message,
      timestamp: Date(),
      toolName: nil,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )
    messageStore.appendCodexMessage(userMessage, sessionId: sessionId)

    // Start turn via app-server
    let turnId = try await client.startTurn(threadId: threadId, message: message)
    logger.info("Started turn: \(turnId) for session: \(sessionId)")
  }

  /// Interrupt the current turn
  func interruptTurn(_ sessionId: String) async throws {
    guard let threadId = threadIdForSession(sessionId) else {
      throw CodexClientError.requestFailed(code: -1, message: "Session not found or not active")
    }

    try await client.interruptTurn(threadId: threadId)

    // Update session to waiting state
    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingReply
    )

    logger.info("Interrupted turn for session: \(sessionId)")
  }

  // MARK: - Approvals

  /// Approve or reject an exec command
  func approveExec(_ sessionId: String, requestId: String, approved: Bool) throws {
    try client.approveExec(requestId: requestId, approved: approved)

    // Clear pending state
    db.clearCodexPendingApproval(sessionId: sessionId)

    logger.info("Exec approval sent for session: \(sessionId), approved: \(approved)")
  }

  /// Approve or reject a patch
  func approvePatch(_ sessionId: String, requestId: String, approved: Bool) throws {
    try client.approvePatch(requestId: requestId, approved: approved)

    // Clear pending state
    db.clearCodexPendingApproval(sessionId: sessionId)

    logger.info("Patch approval sent for session: \(sessionId), approved: \(approved)")
  }

  /// Answer a question prompt
  func answerQuestion(_ sessionId: String, requestId: String, answers: [String: String]) throws {
    try client.answerQuestion(requestId: requestId, answers: answers)

    // Clear pending state
    db.clearCodexPendingApproval(sessionId: sessionId)

    logger.info("Question answered for session: \(sessionId)")
  }

  // MARK: - Helpers

  /// Get thread ID for a session
  private func threadIdForSession(_ sessionId: String) -> String? {
    threadSessionMap.first(where: { $0.value == sessionId })?.key
  }

  /// Resolve git branch for a directory
  private func resolveGitBranch(cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()

      guard process.terminationStatus == 0 else { return nil }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return branch?.isEmpty == true ? nil : branch
    } catch {
      return nil
    }
  }

  // MARK: - State Recovery

  /// Recover session mappings on app restart
  func recoverActiveSessions() async {
    let sessions = db.fetchSessions(statusFilter: .active)
    let directSessions = sessions.filter { $0.isDirectCodex && $0.codexThreadId != nil }

    guard !directSessions.isEmpty else { return }

    logger.info("Found \(directSessions.count) active direct Codex session(s) to recover")

    // Ensure connected
    do {
      if client.state != .connected {
        try await connect()
      }
    } catch {
      logger.error("Failed to connect for session recovery: \(error.localizedDescription)")
      return
    }

    // Resume each thread with app-server and rebuild mappings
    for session in directSessions {
      guard let threadId = session.codexThreadId else { continue }

      do {
        // Resume the thread with the app-server so it knows about it
        let threadInfo = try await client.resumeThread(threadId: threadId, cwd: session.projectPath)

        threadSessionMap[threadId] = session.id
        logger.info("Recovered mapping: thread \(threadId) → session \(session.id)")

        // Update transcript path if we didn't have it
        if session.transcriptPath == nil, let path = threadInfo.path {
          db.updateSessionTranscriptPath(sessionId: session.id, path: path)
        }

        // Reset status to waiting since no turn is active
        db.updateCodexDirectSessionStatus(
          sessionId: session.id,
          workStatus: .waiting,
          attentionReason: .awaitingReply
        )
      } catch {
        // Thread may no longer exist - mark session as ended
        logger.warning("Failed to resume thread \(threadId): \(error.localizedDescription)")
        db.endSession(sessionId: session.id)
      }
    }
  }
}
