//
//  MCPBridge.swift
//  OrbitDock
//
//  Simple HTTP server that exposes session actions to MCP clients.
//  Routes through ServerAppState which forwards to the Rust server via WebSocket.
//

import Foundation
import Network
import os.log

/// HTTP server that bridges MCP tools to OrbitDock's session management
@MainActor
final class MCPBridge {

  static let shared = MCPBridge()

  private let logger = Logger(subsystem: "com.orbitdock", category: "MCPBridge")
  private var listener: NWListener?
  private weak var serverAppState: ServerAppState?
  private let port: UInt16 = 19_384 // ORBIT on phone keypad :)

  private init() {}

  // MARK: - Lifecycle

  func start(serverAppState: ServerAppState) {
    self.serverAppState = serverAppState

    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true

      listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

      listener?.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        let portValue = self.port
        Task { @MainActor [weak self] in
          guard let self else { return }
          switch state {
            case .ready:
              self.logger.info("MCP Bridge listening on port \(portValue)")
            case let .failed(error):
              self.logger.error("MCP Bridge failed: \(error.localizedDescription)")
            case .cancelled:
              self.logger.info("MCP Bridge stopped")
            default:
              break
          }
        }
      }

      listener?.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in
          self?.handleConnection(connection)
        }
      }

      let portValue = port
      listener?.start(queue: .main)
      logger.info("MCP Bridge starting on port \(portValue)")

    } catch {
      logger.error("Failed to start MCP Bridge: \(error.localizedDescription)")
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    logger.info("MCP Bridge stopped")
  }

  // MARK: - Connection Handling

  private func handleConnection(_ connection: NWConnection) {
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch state {
          case .ready:
            self.receiveRequest(connection)
          case let .failed(error):
            self.logger.warning("Connection failed: \(error.localizedDescription)")
          default:
            break
        }
      }
    }

    connection.start(queue: .main)
  }

  private func receiveRequest(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
      guard let self, let data else {
        connection.cancel()
        return
      }

      Task { @MainActor in
        let response = await self.handleRequest(data)
        self.sendResponse(connection, response: response)
      }
    }
  }

  private func sendResponse(_ connection: NWConnection, response: HTTPResponse) {
    let responseData = response.toData()

    connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
      if let error {
        Task { @MainActor [weak self] in
          self?.logger.warning("Failed to send response: \(error.localizedDescription)")
        }
      }
      connection.cancel()
    })
  }

  // MARK: - Request Handling

  private func handleRequest(_ data: Data) async -> HTTPResponse {
    let start = CFAbsoluteTimeGetCurrent()

    guard let request = HTTPRequest.parse(data) else {
      CodexFileLogger.shared.logBridgeRequest(
        method: "UNKNOWN",
        path: "UNKNOWN",
        body: nil,
        responseStatus: 400,
        responseBody: ["error": "Invalid request"],
        durationMs: nil
      )
      return HTTPResponse(status: 400, body: ["error": "Invalid request"])
    }

    logger.debug("MCP Bridge: \(request.method) \(request.path)")

    // OPTIONS probe
    if request.method == "OPTIONS" {
      return HTTPResponse(status: 200, body: [:])
    }

    // Route requests
    let pathParts = request.path.split(separator: "/").map(String.init)

    // POST /api/sessions/:id/message
    if request.method == "POST",
       pathParts.count == 4,
       pathParts[0] == "api",
       pathParts[1] == "sessions",
       pathParts[3] == "message"
    {
      let response = handleSendMessage(sessionId: pathParts[2], body: request.body)
      logResponse(start: start, request: request, response: response)
      return response
    }

    // POST /api/sessions/:id/interrupt
    if request.method == "POST",
       pathParts.count == 4,
       pathParts[0] == "api",
       pathParts[1] == "sessions",
       pathParts[3] == "interrupt"
    {
      let response = handleInterrupt(sessionId: pathParts[2])
      logResponse(start: start, request: request, response: response)
      return response
    }

    // POST /api/sessions/:id/approve
    if request.method == "POST",
       pathParts.count == 4,
       pathParts[0] == "api",
       pathParts[1] == "sessions",
       pathParts[3] == "approve"
    {
      let response = handleApprove(sessionId: pathParts[2], body: request.body)
      logResponse(start: start, request: request, response: response)
      return response
    }

    // POST /api/sessions/:id/steer
    if request.method == "POST",
       pathParts.count == 4,
       pathParts[0] == "api",
       pathParts[1] == "sessions",
       pathParts[3] == "steer"
    {
      let response = handleSteerTurn(sessionId: pathParts[2], body: request.body)
      logResponse(start: start, request: request, response: response)
      return response
    }

    // POST /api/sessions/:id/fork
    if request.method == "POST",
       pathParts.count == 4,
       pathParts[0] == "api",
       pathParts[1] == "sessions",
       pathParts[3] == "fork"
    {
      let response = handleForkSession(sessionId: pathParts[2], body: request.body)
      logResponse(start: start, request: request, response: response)
      return response
    }

    // POST /api/sessions/:id/permission-mode
    if request.method == "POST",
       pathParts.count == 4,
       pathParts[0] == "api",
       pathParts[1] == "sessions",
       pathParts[3] == "permission-mode"
    {
      let response = handleSetPermissionMode(sessionId: pathParts[2], body: request.body)
      logResponse(start: start, request: request, response: response)
      return response
    }

    // GET /api/sessions
    if request.method == "GET",
       pathParts.count == 2,
       pathParts[0] == "api",
       pathParts[1] == "sessions"
    {
      let response = handleListSessions()
      logResponse(start: start, request: request, response: response)
      return response
    }

    // GET /api/sessions/:id
    if request.method == "GET",
       pathParts.count == 3,
       pathParts[0] == "api",
       pathParts[1] == "sessions"
    {
      let response = handleGetSession(sessionId: pathParts[2])
      logResponse(start: start, request: request, response: response)
      return response
    }

    // GET /api/health
    if request.method == "GET",
       pathParts.count == 2,
       pathParts[0] == "api",
       pathParts[1] == "health"
    {
      let response = HTTPResponse(status: 200, body: ["status": "ok", "port": port])
      logResponse(start: start, request: request, response: response)
      return response
    }

    // GET /api/models
    if request.method == "GET",
       pathParts.count == 2,
       pathParts[0] == "api",
       pathParts[1] == "models"
    {
      let response = handleListModels()
      logResponse(start: start, request: request, response: response)
      return response
    }

    let response = HTTPResponse(status: 404, body: ["error": "Not found"])
    logResponse(start: start, request: request, response: response)
    return response
  }

  private func logResponse(start: CFAbsoluteTime, request: HTTPRequest, response: HTTPResponse) {
    let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1_000
    CodexFileLogger.shared.logBridgeRequest(
      method: request.method,
      path: request.path,
      body: request.body.isEmpty ? nil : request.body,
      responseStatus: response.status,
      responseBody: response.body,
      durationMs: durationMs
    )
  }

  // MARK: - API Handlers

  private func handleSendMessage(sessionId: String, body: [String: Any]) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    guard let message = body["message"] as? String, !message.isEmpty else {
      return HTTPResponse(status: 400, body: ["error": "Missing 'message' field"])
    }

    let model = body["model"] as? String
    let effort = body["effort"] as? String

    var images: [ServerImageInput] = []
    if let rawImages = body["images"] as? [[String: Any]] {
      for raw in rawImages {
        if let inputType = raw["input_type"] as? String, let value = raw["value"] as? String {
          images.append(ServerImageInput(inputType: inputType, value: value))
        }
      }
    }

    var mentions: [ServerMentionInput] = []
    if let rawMentions = body["mentions"] as? [[String: Any]] {
      for raw in rawMentions {
        if let name = raw["name"] as? String, let path = raw["path"] as? String {
          mentions.append(ServerMentionInput(name: name, path: path))
        }
      }
    }

    state.sendMessage(
      sessionId: sessionId,
      content: message,
      model: model,
      effort: effort,
      images: images,
      mentions: mentions
    )
    return HTTPResponse(status: 200, body: ["status": "sent", "session_id": sessionId])
  }

  private func handleInterrupt(sessionId: String) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    state.interruptSession(sessionId)
    return HTTPResponse(status: 200, body: ["status": "interrupted", "session_id": sessionId])
  }

  private func handleListModels() -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    let models = state.codexModels.map { model in
      var payload: [String: Any] = [
        "id": model.id,
        "model": model.model,
        "display_name": model.displayName,
        "description": model.description,
        "is_default": model.isDefault,
        "supported_reasoning_efforts": model.supportedReasoningEfforts,
      ]
      if let supportsReasoningSummaries = model.supportsReasoningSummaries {
        payload["supports_reasoning_summaries"] = supportsReasoningSummaries
      }
      return payload
    }
    return HTTPResponse(status: 200, body: ["models": models])
  }

  private func handleSteerTurn(sessionId: String, body: [String: Any]) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    let content = (body["content"] as? String) ?? ""

    var images: [ServerImageInput] = []
    if let rawImages = body["images"] as? [[String: Any]] {
      for raw in rawImages {
        if let inputType = raw["input_type"] as? String, let value = raw["value"] as? String {
          images.append(ServerImageInput(inputType: inputType, value: value))
        }
      }
    }

    var mentions: [ServerMentionInput] = []
    if let rawMentions = body["mentions"] as? [[String: Any]] {
      for raw in rawMentions {
        if let name = raw["name"] as? String, let path = raw["path"] as? String {
          mentions.append(ServerMentionInput(name: name, path: path))
        }
      }
    }

    if content.isEmpty, images.isEmpty, mentions.isEmpty {
      return HTTPResponse(
        status: 400,
        body: ["error": "Missing steer input: provide 'content', 'images', or 'mentions'"]
      )
    }

    state.steerTurn(
      sessionId: sessionId,
      content: content,
      images: images,
      mentions: mentions
    )
    return HTTPResponse(status: 200, body: ["status": "steered", "session_id": sessionId])
  }

  private func handleForkSession(sessionId: String, body: [String: Any]) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    let nthUserMessage = (body["nth_user_message"] as? Int).map { UInt32($0) }
    state.forkSession(sessionId: sessionId, nthUserMessage: nthUserMessage)
    return HTTPResponse(status: 200, body: [
      "status": "fork_requested",
      "session_id": sessionId,
      "nth_user_message": nthUserMessage as Any,
    ])
  }

  private func handleSetPermissionMode(sessionId: String, body: [String: Any]) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    guard let modeString = body["mode"] as? String else {
      return HTTPResponse(status: 400, body: ["error": "Missing 'mode' field"])
    }

    guard let mode = ClaudePermissionMode(rawValue: modeString) else {
      let valid = ClaudePermissionMode.allCases.map(\.rawValue).joined(separator: ", ")
      return HTTPResponse(status: 400, body: ["error": "Invalid mode '\(modeString)'. Valid: \(valid)"])
    }

    guard let session = state.sessions.first(where: { $0.id == sessionId }), session.isDirectClaude else {
      return HTTPResponse(status: 400, body: ["error": "Session is not a Claude direct session"])
    }

    state.updateClaudePermissionMode(sessionId: sessionId, mode: mode)
    return HTTPResponse(status: 200, body: [
      "status": "updated",
      "session_id": sessionId,
      "permission_mode": mode.rawValue,
    ])
  }

  private func handleApprove(sessionId: String, body: [String: Any]) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    guard state.sessions.contains(where: { $0.id == sessionId }) else {
      return HTTPResponse(status: 404, body: ["error": "Session not found"])
    }

    let requestIdFromBody = body["request_id"] as? String
    let requestId: String
    if let rid = requestIdFromBody, !rid.isEmpty, rid != "pending" {
      requestId = rid
    } else if let pending = state.nextPendingApprovalRequestId(sessionId: sessionId) {
      requestId = pending
    } else {
      return HTTPResponse(status: 400, body: ["error": "Missing 'request_id' field and no pending approval found"])
    }

    let typeFromBody = (body["type"] as? String)?.lowercased()
    let typeFromState = state.pendingApprovalType(sessionId: sessionId, requestId: requestId)?.rawValue
    let approvalType = typeFromBody ?? typeFromState ?? "exec"

    guard approvalType == "exec" || approvalType == "patch" || approvalType == "question" else {
      return HTTPResponse(
        status: 400,
        body: ["error": "Invalid 'type' field '\(approvalType)'. Valid: exec, patch, question"]
      )
    }

    let denyMessage = body["message"] as? String
    let interrupt = body["interrupt"] as? Bool

    if approvalType == "question" {
      let answer = (body["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let providedAnswers = parseQuestionAnswers(from: body["answers"])
      let questionIdFromBody = (body["question_id"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let pendingApproval = state.session(sessionId).pendingApproval
      let questionId: String? = {
        if let questionIdFromBody, !questionIdFromBody.isEmpty { return questionIdFromBody }
        if let firstPromptId = pendingApproval?.questionPrompts.first?.id
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !firstPromptId.isEmpty
        {
          return firstPromptId
        }
        return nil
      }()

      var answers = providedAnswers ?? [:]
      if answers.isEmpty, !answer.isEmpty {
        answers[questionId ?? "0"] = [answer]
      }

      guard !answers.isEmpty else {
        var errorBody: [String: Any] = [
          "error": "Missing question response. Provide non-empty 'answer' or 'answers'.",
          "session_id": sessionId,
          "request_id": requestId,
        ]
        let firstPrompt = pendingApproval?.questionPrompts.first
        let promptQuestion = firstPrompt?.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let question = promptQuestion, !question.isEmpty {
          errorBody["question"] = question
        } else if let question = pendingApproval?.question {
          errorBody["question"] = question
        }
        if let promptId = firstPrompt?.id.trimmingCharacters(in: .whitespacesAndNewlines),
           !promptId.isEmpty
        {
          errorBody["question_id"] = promptId
        }
        let options = firstPrompt?.options.compactMap { option -> [String: String]? in
          let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !label.isEmpty else { return nil }
          var serialized: [String: String] = ["label": label]
          if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines),
             !description.isEmpty
          {
            serialized["description"] = description
          }
          return serialized
        } ?? []
        if !options.isEmpty {
          errorBody["options"] = options
        }
        return HTTPResponse(status: 400, body: errorBody)
      }

      let primaryAnswer: String? = {
        if let questionId,
           let preferred = answers[questionId]?.first,
           !preferred.isEmpty
        {
          return preferred
        }
        for value in answers.values {
          if let first = value.first, !first.isEmpty {
            return first
          }
        }
        return nil
      }()
      guard let primaryAnswer, !primaryAnswer.isEmpty else {
        return HTTPResponse(status: 400, body: [
          "error": "Answers payload does not contain any non-empty response values.",
          "session_id": sessionId,
          "request_id": requestId,
        ])
      }

      let result = state.answerQuestion(
        sessionId: sessionId,
        requestId: requestId,
        answer: primaryAnswer,
        questionId: questionId,
        answers: answers
      )

      guard case .dispatched = result else {
        let nextPending = state.nextPendingApprovalRequestId(sessionId: sessionId)
        let message = if let nextPending {
          "Stale approval request '\(requestId)'. Next pending request is '\(nextPending)'."
        } else {
          "Stale approval request '\(requestId)'."
        }
        return HTTPResponse(status: 409, body: [
          "error": message,
          "session_id": sessionId,
          "request_id": requestId,
          "next_pending_request_id": nextPending as Any,
        ])
      }

      return HTTPResponse(status: 200, body: [
        "status": "answered",
        "session_id": sessionId,
        "request_id": requestId,
        "question_id": questionId as Any,
        "answers": answers,
      ])
    } else {
      guard let decision = body["decision"] as? String, !decision.isEmpty else {
        return HTTPResponse(status: 400, body: ["error": "Missing 'decision' field"])
      }

      let result = state.approveTool(
        sessionId: sessionId,
        requestId: requestId,
        decision: decision,
        message: denyMessage,
        interrupt: interrupt
      )

      guard case .dispatched = result else {
        let nextPending = state.nextPendingApprovalRequestId(sessionId: sessionId)
        let message = if let nextPending {
          "Stale approval request '\(requestId)'. Next pending request is '\(nextPending)'."
        } else {
          "Stale approval request '\(requestId)'."
        }
        return HTTPResponse(status: 409, body: [
          "error": message,
          "session_id": sessionId,
          "request_id": requestId,
          "next_pending_request_id": nextPending as Any,
        ])
      }
    }

    return HTTPResponse(status: 200, body: [
      "status": "approved",
      "session_id": sessionId,
      "request_id": requestId,
      "type": approvalType,
    ])
  }

  private func handleListSessions() -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    let sessions = state.sessions.filter(\.isActive)

    let sessionData = sessions.map { session -> [String: Any] in
      var data: [String: Any] = [
        "id": session.id,
        "project_path": session.projectPath,
        "branch": session.branch ?? "",
        "model": session.model ?? "",
        "provider": session.provider.rawValue,
        "work_status": session.workStatus.rawValue,
        "attention_reason": session.attentionReason.rawValue,
        "is_direct_codex": session.isDirectCodex,
        "is_direct_claude": session.isDirectClaude,
        "is_direct": session.isDirect,
      ]
      if let pendingApprovalId = state.nextPendingApprovalRequestId(sessionId: session.id) {
        data["pending_approval_id"] = pendingApprovalId
      }
      let pendingApproval = state.session(session.id).pendingApproval
      if let pendingApproval {
        data["pending_approval_type"] = pendingApproval.type.rawValue
      }
      if let pendingQuestion = pendingApproval?.questionPrompts.first?.question ?? pendingApproval?.question {
        data["pending_question"] = pendingQuestion
      }
      if let pendingToolInput = pendingApproval?.toolInput {
        data["pending_tool_input"] = pendingToolInput
      }
      if let firstPrompt = pendingApproval?.questionPrompts.first {
        let questionId = firstPrompt.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !questionId.isEmpty {
          data["pending_question_id"] = questionId
        }
        let options = firstPrompt.options.compactMap { option -> [String: String]? in
          let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !label.isEmpty else { return nil }
          var serialized: [String: String] = ["label": label]
          if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines),
             !description.isEmpty
          {
            serialized["description"] = description
          }
          return serialized
        }
        if !options.isEmpty {
          data["pending_question_options"] = options
        }
      }
      if session.isDirectClaude {
        data["permission_mode"] = state.session(session.id).permissionMode.rawValue
      }
      return data
    }

    return HTTPResponse(status: 200, body: ["sessions": sessionData])
  }

  private func handleGetSession(sessionId: String) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    guard let session = state.sessions.first(where: { $0.id == sessionId }) else {
      return HTTPResponse(status: 404, body: ["error": "Session not found"])
    }

    var sessionData: [String: Any] = [
      "id": session.id,
      "project_path": session.projectPath,
      "branch": session.branch ?? "",
      "model": session.model ?? "",
      "provider": session.provider.rawValue,
      "work_status": session.workStatus.rawValue,
      "attention_reason": session.attentionReason.rawValue,
      "is_direct_codex": session.isDirectCodex,
      "is_direct_claude": session.isDirectClaude,
      "is_direct": session.isDirect,
    ]
    if let pendingApprovalId = state.nextPendingApprovalRequestId(sessionId: session.id) {
      sessionData["pending_approval_id"] = pendingApprovalId
    }

    let pendingApproval = state.session(session.id).pendingApproval
    if let pendingApproval {
      sessionData["pending_approval_type"] = pendingApproval.type.rawValue
    }
    if let pendingQuestion = pendingApproval?.questionPrompts.first?.question ?? pendingApproval?.question {
      sessionData["pending_question"] = pendingQuestion
    }
    if let pendingToolInput = pendingApproval?.toolInput {
      sessionData["pending_tool_input"] = pendingToolInput
    }
    if let firstPrompt = pendingApproval?.questionPrompts.first {
      let questionId = firstPrompt.id.trimmingCharacters(in: .whitespacesAndNewlines)
      if !questionId.isEmpty {
        sessionData["pending_question_id"] = questionId
      }
      let options = firstPrompt.options.compactMap { option -> [String: String]? in
        let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        var serialized: [String: String] = ["label": label]
        if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
          serialized["description"] = description
        }
        return serialized
      }
      if !options.isEmpty {
        sessionData["pending_question_options"] = options
      }
    }

    if session.isDirectClaude {
      sessionData["permission_mode"] = state.session(session.id).permissionMode.rawValue
    }

    if let startedAt = session.startedAt {
      sessionData["started_at"] = ISO8601DateFormatter().string(from: startedAt)
    }

    if let endedAt = session.endedAt {
      sessionData["ended_at"] = ISO8601DateFormatter().string(from: endedAt)
    }

    return HTTPResponse(status: 200, body: sessionData)
  }

  private func parseQuestionAnswers(from rawAnswers: Any?) -> [String: [String]]? {
    guard let rawAnswers = rawAnswers as? [String: Any] else { return nil }
    var parsed: [String: [String]] = [:]

    for (rawQuestionId, rawValue) in rawAnswers {
      let questionId = rawQuestionId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !questionId.isEmpty else { continue }

      let values: [String]
      if let rawArray = rawValue as? [Any] {
        values = rawArray.compactMap { value in
          guard let answer = value as? String else { return nil }
          let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
      } else if let answer = rawValue as? String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        values = trimmed.isEmpty ? [] : [trimmed]
      } else {
        values = []
      }

      guard !values.isEmpty else { continue }
      parsed[questionId] = values
    }

    return parsed.isEmpty ? nil : parsed
  }
}

// MARK: - HTTP Types

private struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: [String: Any]

  static func parse(_ data: Data) -> HTTPRequest? {
    guard let string = String(data: data, encoding: .utf8) else { return nil }

    let lines = string.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }

    let method = String(parts[0])
    let path = String(parts[1])

    // Parse headers
    var headers: [String: String] = [:]
    var bodyStartIndex = 1

    for (index, line) in lines.dropFirst().enumerated() {
      if line.isEmpty {
        bodyStartIndex = index + 2
        break
      }
      let headerParts = line.split(separator: ":", maxSplits: 1)
      if headerParts.count == 2 {
        headers[String(headerParts[0]).lowercased()] = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
      }
    }

    // Parse JSON body
    var body: [String: Any] = [:]
    if bodyStartIndex < lines.count {
      let bodyString = lines[bodyStartIndex...].joined(separator: "\r\n")
      if let bodyData = bodyString.data(using: .utf8),
         let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
      {
        body = json
      }
    }

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
  }
}

private struct HTTPResponse {
  let status: Int
  let body: [String: Any]

  func toData() -> Data {
    let statusText = switch status {
      case 200: "OK"
      case 400: "Bad Request"
      case 404: "Not Found"
      case 500: "Internal Server Error"
      case 503: "Service Unavailable"
      default: "Unknown"
    }

    let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

    let response = """
    HTTP/1.1 \(status) \(statusText)\r
    Content-Type: application/json\r
    Content-Length: \(jsonData.count)\r
    Connection: close\r
    \r
    \(jsonString)
    """

    return response.data(using: .utf8) ?? Data()
  }
}
