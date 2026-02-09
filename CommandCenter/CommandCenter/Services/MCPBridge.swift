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
  private let port: UInt16 = 19384  // ORBIT on phone keypad :)

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
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
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

    // CORS preflight
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
    let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
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
    state.sendMessage(sessionId: sessionId, content: message, model: model, effort: effort)
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
      [
        "id": model.id,
        "model": model.model,
        "display_name": model.displayName,
        "description": model.description,
        "is_default": model.isDefault,
        "supported_reasoning_efforts": model.supportedReasoningEfforts,
      ] as [String: Any]
    }
    return HTTPResponse(status: 200, body: ["models": models])
  }

  private func handleApprove(sessionId: String, body: [String: Any]) -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    let requestIdFromBody = body["request_id"] as? String
    let requestId: String
    if let rid = requestIdFromBody, !rid.isEmpty, rid != "pending" {
      requestId = rid
    } else if let pending = state.sessions.first(where: { $0.id == sessionId })?.pendingApprovalId {
      requestId = pending
    } else {
      return HTTPResponse(status: 400, body: ["error": "Missing 'request_id' field and no pending approval found"])
    }

    // Support both "decision" string and legacy "approved" bool
    let decision: String
    if let d = body["decision"] as? String {
      decision = d
    } else if let approved = body["approved"] as? Bool {
      decision = approved ? "approved" : "denied"
    } else {
      return HTTPResponse(status: 400, body: ["error": "Missing 'approved' or 'decision' field"])
    }

    let approvalType = body["type"] as? String ?? "exec"

    if approvalType == "question" {
      let answer = body["answer"] as? String ?? ""
      state.answerQuestion(sessionId: sessionId, requestId: requestId, answer: answer)
    } else {
      state.approveTool(sessionId: sessionId, requestId: requestId, decision: decision)
    }

    return HTTPResponse(status: 200, body: ["status": "approved", "session_id": sessionId, "request_id": requestId])
  }

  private func handleListSessions() -> HTTPResponse {
    guard let state = serverAppState else {
      return HTTPResponse(status: 503, body: ["error": "Server state not available"])
    }

    let sessions = state.sessions.filter { $0.isActive }

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
      ]
      if let pendingApprovalId = session.pendingApprovalId {
        data["pending_approval_id"] = pendingApprovalId
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
    ]
    if let pendingApprovalId = session.pendingApprovalId {
      sessionData["pending_approval_id"] = pendingApprovalId
    }

    if let startedAt = session.startedAt {
      sessionData["started_at"] = ISO8601DateFormatter().string(from: startedAt)
    }

    if let endedAt = session.endedAt {
      sessionData["ended_at"] = ISO8601DateFormatter().string(from: endedAt)
    }

    return HTTPResponse(status: 200, body: sessionData)
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
    let statusText: String
    switch status {
      case 200: statusText = "OK"
      case 400: statusText = "Bad Request"
      case 404: statusText = "Not Found"
      case 500: statusText = "Internal Server Error"
      case 503: statusText = "Service Unavailable"
      default: statusText = "Unknown"
    }

    let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

    let response = """
      HTTP/1.1 \(status) \(statusText)\r
      Content-Type: application/json\r
      Access-Control-Allow-Origin: *\r
      Access-Control-Allow-Methods: GET, POST, OPTIONS\r
      Access-Control-Allow-Headers: Content-Type\r
      Content-Length: \(jsonData.count)\r
      Connection: close\r
      \r
      \(jsonString)
      """

    return response.data(using: .utf8) ?? Data()
  }
}
