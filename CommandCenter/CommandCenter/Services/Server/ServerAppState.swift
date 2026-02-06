//
//  ServerAppState.swift
//  OrbitDock
//
//  WebSocket-backed state store for server-managed sessions.
//  Listens to ServerConnection callbacks and maintains Session/TranscriptMessage
//  state that views can observe. Equivalent to SessionStore but for Codex sessions
//  flowing through the Rust server.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "server-app-state")

@Observable
@MainActor
final class ServerAppState {
  // MARK: - Observable State

  /// Sessions managed by the server (converted to Session model for view compatibility)
  private(set) var sessions: [Session] = []

  /// Messages per session (converted to TranscriptMessage for view compatibility)
  private(set) var sessionMessages: [String: [TranscriptMessage]] = [:]

  /// Pending approval requests per session
  private(set) var pendingApprovals: [String: ServerApprovalRequest] = [:]

  /// Token usage per session
  private(set) var tokenUsage: [String: ServerTokenUsage] = [:]

  /// Diff per session (aggregated turn diff)
  private(set) var sessionDiffs: [String: String] = [:]

  /// Plan per session (JSON string)
  private(set) var sessionPlans: [String: String] = [:]

  /// Revision counter per session - incremented on message append/update for change tracking
  private(set) var messageRevisions: [String: Int] = [:]

  // MARK: - Internal State

  /// Full session state cache (from snapshots)
  private var sessionStates: [String: ServerSessionState] = [:]

  /// Track which sessions we're subscribed to
  private var subscribedSessions: Set<String> = []

  // MARK: - Setup

  /// Wire up ServerConnection callbacks. Call after connection is established.
  func setup() {
    let conn = ServerConnection.shared

    conn.onSessionsList = { [weak self] summaries in
      Task { @MainActor in
        self?.handleSessionsList(summaries)
      }
    }

    conn.onSessionSnapshot = { [weak self] state in
      Task { @MainActor in
        self?.handleSessionSnapshot(state)
      }
    }

    conn.onSessionDelta = { [weak self] sessionId, changes in
      Task { @MainActor in
        self?.handleSessionDelta(sessionId, changes)
      }
    }

    conn.onMessageAppended = { [weak self] sessionId, message in
      Task { @MainActor in
        self?.handleMessageAppended(sessionId, message)
      }
    }

    conn.onMessageUpdated = { [weak self] sessionId, messageId, changes in
      Task { @MainActor in
        self?.handleMessageUpdated(sessionId, messageId, changes)
      }
    }

    conn.onApprovalRequested = { [weak self] sessionId, request in
      Task { @MainActor in
        self?.handleApprovalRequested(sessionId, request)
      }
    }

    conn.onTokensUpdated = { [weak self] sessionId, usage in
      Task { @MainActor in
        self?.handleTokensUpdated(sessionId, usage)
      }
    }

    conn.onSessionCreated = { [weak self] summary in
      Task { @MainActor in
        self?.handleSessionCreated(summary)
      }
    }

    conn.onSessionEnded = { [weak self] sessionId, reason in
      Task { @MainActor in
        self?.handleSessionEnded(sessionId, reason)
      }
    }

    conn.onError = { [weak self] code, message, sessionId in
      Task { @MainActor in
        self?.handleError(code, message, sessionId)
      }
    }

    conn.onConnected = { [weak self] in
      Task { @MainActor in
        self?.resubscribeAll()
      }
    }

    logger.info("ServerAppState callbacks wired")
  }

  // MARK: - Actions

  /// Create a new Codex session
  func createSession(cwd: String, model: String? = nil) {
    logger.info("Creating Codex session in \(cwd)")
    ServerConnection.shared.createSession(provider: .codex, cwd: cwd, model: model)
  }

  /// Send a message to a session
  func sendMessage(sessionId: String, content: String) {
    logger.info("Sending message to \(sessionId)")
    ServerConnection.shared.sendMessage(sessionId: sessionId, content: content)
  }

  /// Approve or reject a tool
  func approveTool(sessionId: String, requestId: String, approved: Bool) {
    logger.info("Approving tool \(requestId) in \(sessionId): \(approved)")
    ServerConnection.shared.approveTool(sessionId: sessionId, requestId: requestId, approved: approved)
  }

  /// Answer a question
  func answerQuestion(sessionId: String, requestId: String, answer: String) {
    logger.info("Answering question \(requestId) in \(sessionId)")
    ServerConnection.shared.answerQuestion(sessionId: sessionId, requestId: requestId, answer: answer)
  }

  /// Interrupt a session
  func interruptSession(_ sessionId: String) {
    logger.info("Interrupting session \(sessionId)")
    ServerConnection.shared.interruptSession(sessionId)
  }

  /// End a session
  func endSession(_ sessionId: String) {
    logger.info("Ending session \(sessionId)")
    ServerConnection.shared.endSession(sessionId)
  }

  /// Subscribe to a session's updates (called when viewing a session)
  func subscribeToSession(_ sessionId: String) {
    guard !subscribedSessions.contains(sessionId) else { return }
    subscribedSessions.insert(sessionId)
    ServerConnection.shared.subscribeSession(sessionId)
    logger.debug("Subscribed to session \(sessionId)")
  }

  /// Unsubscribe from a session (called when navigating away)
  func unsubscribeFromSession(_ sessionId: String) {
    subscribedSessions.remove(sessionId)
    ServerConnection.shared.unsubscribeSession(sessionId)
    logger.debug("Unsubscribed from session \(sessionId)")
  }

  /// Check if a session ID belongs to a server-managed session
  func isServerSession(_ sessionId: String) -> Bool {
    sessions.contains { $0.id == sessionId }
  }

  // MARK: - Reconnection

  /// Re-subscribe to all previously subscribed sessions after reconnect
  private func resubscribeAll() {
    let sessions = subscribedSessions
    subscribedSessions.removeAll()
    logger.info("Re-subscribing to \(sessions.count) session(s) after reconnect")
    for sessionId in sessions {
      subscribeToSession(sessionId)
    }
  }

  // MARK: - Message Handlers

  private func handleSessionsList(_ summaries: [ServerSessionSummary]) {
    logger.info("Received sessions list: \(summaries.count) sessions")
    sessions = summaries.map { $0.toSession() }
  }

  private func handleSessionSnapshot(_ state: ServerSessionState) {
    logger.info("Received snapshot for \(state.id): \(state.messages.count) messages")
    sessionStates[state.id] = state

    // Mark as subscribed (server pre-subscribes creator on CreateSession)
    subscribedSessions.insert(state.id)

    // Update session in list
    updateSessionInList(state.toSession())

    // Store messages
    sessionMessages[state.id] = state.messages.map { $0.toTranscriptMessage() }
    messageRevisions[state.id, default: 0] += 1

    // Store approval if present
    if let approval = state.pendingApproval {
      pendingApprovals[state.id] = approval
    } else {
      pendingApprovals.removeValue(forKey: state.id)
    }

    // Store token usage
    tokenUsage[state.id] = state.tokenUsage

    // Store diff/plan
    if let diff = state.currentDiff {
      sessionDiffs[state.id] = diff
    }
    if let plan = state.currentPlan {
      sessionPlans[state.id] = plan
    }
  }

  private func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    logger.debug("Session delta for \(sessionId)")

    // Find and update the session
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var session = sessions[idx]

    if let status = changes.status {
      session.status = status == .active ? .active : .ended
    }
    if let workStatus = changes.workStatus {
      session.workStatus = workStatus.toSessionWorkStatus()
      session.attentionReason = workStatus.toAttentionReason()
    }
    // Handle optional-optional for pendingApproval (nil = unchanged, .some(nil) = cleared)
    if let approvalOuter = changes.pendingApproval {
      if let approval = approvalOuter {
        pendingApprovals[sessionId] = approval
        session.pendingApprovalId = approval.id
        session.pendingToolName = approval.toolNameForDisplay
        session.pendingToolInput = approval.toolInputForDisplay
        session.pendingQuestion = approval.question
      } else {
        pendingApprovals.removeValue(forKey: sessionId)
        session.pendingApprovalId = nil
        session.pendingToolName = nil
        session.pendingToolInput = nil
        session.pendingQuestion = nil
      }
    }
    if let usage = changes.tokenUsage {
      tokenUsage[sessionId] = usage
      session.codexInputTokens = Int(usage.inputTokens)
      session.codexOutputTokens = Int(usage.outputTokens)
      session.codexCachedTokens = Int(usage.cachedTokens)
      session.codexContextWindow = Int(usage.contextWindow)
    }
    // Handle optional-optional for diff
    if let diffOuter = changes.currentDiff {
      if let diff = diffOuter {
        sessionDiffs[sessionId] = diff
        session.currentDiff = diff
      } else {
        sessionDiffs.removeValue(forKey: sessionId)
        session.currentDiff = nil
      }
    }
    // Handle optional-optional for plan
    if let planOuter = changes.currentPlan {
      if let plan = planOuter {
        sessionPlans[sessionId] = plan
      } else {
        sessionPlans.removeValue(forKey: sessionId)
      }
    }
    if let lastActivity = changes.lastActivityAt {
      // Parse and update
      let stripped = lastActivity.hasSuffix("Z") ? String(lastActivity.dropLast()) : lastActivity
      if let secs = TimeInterval(stripped) {
        session.lastActivityAt = Date(timeIntervalSince1970: secs)
      }
    }

    sessions[idx] = session
  }

  private func handleMessageAppended(_ sessionId: String, _ message: ServerMessage) {
    logger.debug("Message appended to \(sessionId): \(message.type.rawValue)")
    let transcriptMsg = message.toTranscriptMessage()

    if sessionMessages[sessionId] != nil {
      sessionMessages[sessionId]!.append(transcriptMsg)
    } else {
      sessionMessages[sessionId] = [transcriptMsg]
    }
    messageRevisions[sessionId, default: 0] += 1
  }

  private func handleMessageUpdated(_ sessionId: String, _ messageId: String, _ changes: ServerMessageChanges) {
    logger.debug("Message updated in \(sessionId): \(messageId)")

    guard var messages = sessionMessages[sessionId],
          let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }

    var msg = messages[idx]
    if let content = changes.content {
      // TranscriptMessage.content is let, so we need to create a new one
      msg = TranscriptMessage(
        id: msg.id,
        type: msg.type,
        content: content,
        timestamp: msg.timestamp,
        toolName: msg.toolName,
        toolInput: msg.toolInput,
        toolOutput: changes.toolOutput ?? msg.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1000.0 } ?? msg.toolDuration,
        inputTokens: msg.inputTokens,
        outputTokens: msg.outputTokens,
        isInProgress: false
      )
    } else {
      // Only updating mutable fields
      if let output = changes.toolOutput {
        msg.toolOutput = output
      }
      msg.isInProgress = false
    }
    messages[idx] = msg
    sessionMessages[sessionId] = messages
    messageRevisions[sessionId, default: 0] += 1
  }

  private func handleApprovalRequested(_ sessionId: String, _ request: ServerApprovalRequest) {
    logger.info("Approval requested in \(sessionId): \(request.type.rawValue)")
    pendingApprovals[sessionId] = request

    // Update session state
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      var session = sessions[idx]
      session.pendingApprovalId = request.id
      session.pendingToolName = request.toolNameForDisplay
      session.pendingToolInput = request.toolInputForDisplay
      session.pendingQuestion = request.question
      session.attentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission
      session.workStatus = .permission
      sessions[idx] = session
    }
  }

  private func handleTokensUpdated(_ sessionId: String, _ usage: ServerTokenUsage) {
    tokenUsage[sessionId] = usage

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].codexInputTokens = Int(usage.inputTokens)
      sessions[idx].codexOutputTokens = Int(usage.outputTokens)
      sessions[idx].codexCachedTokens = Int(usage.cachedTokens)
      sessions[idx].codexContextWindow = Int(usage.contextWindow)
    }
  }

  private func handleSessionCreated(_ summary: ServerSessionSummary) {
    logger.info("Session created: \(summary.id)")
    let session = summary.toSession()

    // Add if not already present
    if !sessions.contains(where: { $0.id == session.id }) {
      sessions.append(session)
    }

    // Auto-subscribe to get detailed updates
    subscribeToSession(summary.id)
  }

  private func handleSessionEnded(_ sessionId: String, _ reason: String) {
    logger.info("Session ended: \(sessionId) (\(reason))")

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].workStatus = .waiting
      sessions[idx].attentionReason = .none
    }

    pendingApprovals.removeValue(forKey: sessionId)
    subscribedSessions.remove(sessionId)
  }

  private func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    logger.error("Server error [\(code)]: \(message)")
  }

  // MARK: - Helpers

  private func updateSessionInList(_ session: Session) {
    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[idx] = session
    } else {
      sessions.append(session)
    }
  }

  /// Parse plan JSON string into PlanStep array for UI
  func getPlanSteps(sessionId: String) -> [Session.PlanStep]? {
    guard let json = sessionPlans[sessionId],
          let data = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    let steps = array.compactMap { dict -> Session.PlanStep? in
      guard let step = dict["step"] as? String else { return nil }
      let status = dict["status"] as? String ?? "pending"
      return Session.PlanStep(step: step, status: status)
    }
    return steps.isEmpty ? nil : steps
  }

  /// Get diff for a session
  func getDiff(sessionId: String) -> String? {
    sessionDiffs[sessionId]
  }
}
