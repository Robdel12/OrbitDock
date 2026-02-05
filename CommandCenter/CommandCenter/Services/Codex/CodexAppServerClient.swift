//
//  CodexAppServerClient.swift
//  OrbitDock
//
//  Core JSON-RPC client managing the codex app-server process.
//  Provides bidirectional communication with request/response correlation
//  and event streaming.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "CodexAppServer")
private let fileLogger = CodexFileLogger.shared

@Observable
final class CodexAppServerClient: @unchecked Sendable {

  // MARK: - Types

  enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
      switch (lhs, rhs) {
        case (.disconnected, .disconnected): true
        case (.connecting, .connecting): true
        case (.connected, .connected): true
        case let (.error(a), .error(b)): a == b
        default: false
      }
    }
  }

  // MARK: - Properties

  private(set) var state: ConnectionState = .disconnected
  private(set) var isInitialized = false

  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?

  private var requestId: Int = 0
  private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
  private let requestLock = NSLock()

  private var eventContinuation: AsyncStream<CodexServerEvent>.Continuation?
  private(set) var events: AsyncStream<CodexServerEvent>!

  private var readBuffer = Data()
  private var readTask: Task<Void, Never>?
  private var reconnectAttempts = 0
  private let maxReconnectAttempts = 3

  // MARK: - Initialization

  init() {
    // Set up event stream
    events = AsyncStream { [weak self] continuation in
      self?.eventContinuation = continuation
    }
  }

  deinit {
    disconnect()
  }

  // MARK: - Connection Management

  func connect() async throws {
    guard state != .connected, state != .connecting else { return }

    state = .connecting
    print("[Codex] Connecting to codex app-server...")

    guard let codexPath = Self.findCodexBinary() else {
      print("[Codex] ✘ Codex binary not found")
      state = .error("Codex not installed")
      throw CodexClientError.notInstalled
    }

    print("[Codex] Found codex at: \(codexPath)")

    do {
      try await startProcess(codexPath: codexPath)
      print("[Codex] Process started, initializing...")
      try await initialize()
      state = .connected
      reconnectAttempts = 0
      print("[Codex] ✓ Connected and initialized")
    } catch {
      print("[Codex] ✘ Connection failed: \(error)")
      state = .error(error.localizedDescription)
      throw error
    }
  }

  func disconnect() {
    logger.info("Disconnecting from codex app-server")

    readTask?.cancel()
    readTask = nil

    // Cancel all pending requests
    requestLock.lock()
    for (_, continuation) in pendingRequests {
      continuation.resume(throwing: CodexClientError.processTerminated)
    }
    pendingRequests.removeAll()
    requestLock.unlock()

    // Terminate process
    if let process, process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }

    process = nil
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    isInitialized = false
    state = .disconnected

    eventContinuation?.finish()
  }

  // MARK: - Process Management

  private func startProcess(codexPath: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: codexPath)
    process.arguments = ["app-server"]
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    // Set up environment
    var env = ProcessInfo.processInfo.environment
    let nodeBinDir = (codexPath as NSString).deletingLastPathComponent
    env["PATH"] = "\(nodeBinDir):\(env["PATH"] ?? "")"
    process.environment = env

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Handle termination
    process.terminationHandler = { [weak self] proc in
      Task { @MainActor [weak self] in
        self?.handleProcessTermination(exitCode: proc.terminationStatus)
      }
    }

    do {
      try process.run()
    } catch {
      throw CodexClientError.connectionFailed(underlying: error)
    }

    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe

    // Start reading stdout
    startReadingOutput()
  }

  private func startReadingOutput() {
    guard let stdout = stdoutPipe?.fileHandleForReading else { return }

    readTask = Task.detached { [weak self] in
      while !Task.isCancelled {
        let data = stdout.availableData
        if data.isEmpty {
          // EOF - process likely terminated
          break
        }

        await self?.handleData(data)
      }
    }
  }

  private func handleData(_ data: Data) {
    readBuffer.append(data)

    // Process complete lines
    while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
      let lineData = readBuffer[..<newlineIndex]
      readBuffer = Data(readBuffer[(newlineIndex + 1)...])

      if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !line.isEmpty
      {
        processLine(line)
      }
    }
  }

  private func processLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      logger.warning("Failed to parse JSON line: \(line.prefix(100))")
      fileLogger.log(.warning, category: .decode, message: "Failed to parse JSON line", data: [
        "preview": String(line.prefix(200)),
      ])
      return
    }

    let hasId = json["id"] != nil
    let hasMethod = json["method"] != nil
    let hasResult = json["result"] != nil || json["error"] != nil

    if hasId && hasResult {
      // Response to one of our requests
      if let id = json["id"] as? Int {
        fileLogger.log(.debug, category: .connection, message: "Response received", data: ["id": id])
        handleResponse(id: id, json: json, data: data)
      }
    } else if hasId && hasMethod {
      // Server-initiated request (e.g., approval requests) - needs response
      if let id = json["id"] as? Int, let method = json["method"] as? String {
        fileLogger.log(.info, category: .connection, message: "Server request", data: ["id": id, "method": method])
        handleServerRequest(id: id, method: method, json: json)
      }
    } else if hasMethod {
      // Notification (no response needed)
      if let method = json["method"] as? String {
        handleNotification(method: method, json: json)
      }
    }
  }

  private func handleResponse(id: Int, json: [String: Any], data: Data) {
    requestLock.lock()
    let continuation = pendingRequests.removeValue(forKey: id)
    requestLock.unlock()

    guard let continuation else {
      logger.warning("Received response for unknown request ID: \(id)")
      return
    }

    if let error = json["error"] as? [String: Any] {
      let code = error["code"] as? Int ?? -1
      let message = error["message"] as? String ?? "Unknown error"
      continuation.resume(throwing: CodexClientError.requestFailed(code: code, message: message))
    } else {
      continuation.resume(returning: data)
    }
  }

  private func handleNotification(method: String, json: [String: Any]) {
    // Skip logging for high-frequency streaming events
    let isStreamingDelta = method.contains("delta") || method.contains("_delta")
    if !isStreamingDelta {
      print("[Codex] ⚡ Event: \(method)")
    }

    let params: AnyCodable? = {
      if let paramsDict = json["params"] {
        return AnyCodable(paramsDict)
      }
      return nil
    }()

    let event = CodexServerEvent.parse(method: method, params: params)

    // Don't yield ignored events to save processing
    if case .ignored = event {
      return
    }

    eventContinuation?.yield(event)
  }

  /// Handle server-initiated requests (e.g., approval requests that need a response)
  private func handleServerRequest(id: Int, method: String, json: [String: Any]) {
    print("[Codex] ⚡ Server Request: \(method) (id=\(id))")

    // Server requests may have params at root level or in "params" key
    let params: AnyCodable? = {
      if let paramsDict = json["params"] {
        return AnyCodable(paramsDict)
      }
      // Fall back to using the whole JSON (minus id/method) as params
      var rootParams = json
      rootParams.removeValue(forKey: "id")
      rootParams.removeValue(forKey: "method")
      rootParams.removeValue(forKey: "jsonrpc")
      return rootParams.isEmpty ? nil : AnyCodable(rootParams)
    }()

    // Store the request ID for later response
    // The event handler will call respondToRequest when user approves/declines
    let event = CodexServerEvent.parse(method: method, params: params)

    // For approval requests, we need to track the request ID
    // This is handled by including the id in the event params
    eventContinuation?.yield(event)
  }

  /// Respond to a server-initiated request (for approvals)
  func respondToRequest(id: Int, result: [String: Any]) throws {
    guard state == .connected else {
      throw CodexClientError.notConnected
    }

    let response: [String: Any] = ["id": id, "result": result]

    guard let data = try? JSONSerialization.data(withJSONObject: response),
          var jsonString = String(data: data, encoding: .utf8)
    else {
      throw CodexClientError.encodingFailed
    }

    jsonString += "\n"

    guard let stdin = stdinPipe?.fileHandleForWriting else {
      throw CodexClientError.notConnected
    }

    try stdin.write(contentsOf: Data(jsonString.utf8))
    print("[Codex] → Response to request \(id)")
  }

  @MainActor
  private func handleProcessTermination(exitCode: Int32) {
    logger.warning("Codex app-server terminated with exit code: \(exitCode)")

    // Cancel pending requests
    requestLock.lock()
    for (_, continuation) in pendingRequests {
      continuation.resume(throwing: CodexClientError.processTerminated)
    }
    pendingRequests.removeAll()
    requestLock.unlock()

    isInitialized = false

    // Attempt reconnection if not manually disconnected
    if state == .connected {
      Task {
        await attemptReconnect()
      }
    }
  }

  private func attemptReconnect() async {
    guard reconnectAttempts < maxReconnectAttempts else {
      state = .error("Max reconnection attempts exceeded")
      eventContinuation?.yield(.error(CodexErrorEvent(code: "reconnect_failed", message: "Failed to reconnect after \(maxReconnectAttempts) attempts", httpStatusCode: nil)))
      return
    }

    reconnectAttempts += 1
    logger.info("Reconnection attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts)")

    // Exponential backoff
    let delay = pow(2.0, Double(reconnectAttempts - 1))
    try? await Task.sleep(for: .seconds(delay))

    do {
      try await connect()
    } catch {
      logger.error("Reconnection failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Initialization

  private func initialize() async throws {
    // Send initialize request
    let clientInfo = ClientInfo(name: "orbitdock", title: "OrbitDock", version: "1.0.0")
    let params = InitializeParams(clientInfo: clientInfo)

    let _: InitializeResult = try await send("initialize", params: params)

    // Send initialized notification
    try sendNotification("initialized", params: EmptyParams())

    isInitialized = true
    logger.info("Initialization complete")
  }

  // MARK: - Request/Response

  func send<P: Encodable, R: Decodable>(_ method: String, params: P?) async throws -> R {
    guard state == .connected || state == .connecting else {
      throw CodexClientError.notConnected
    }

    let id = nextRequestId()

    let request: [String: Any] = {
      var dict: [String: Any] = ["method": method, "id": id]
      if let params {
        if let encoded = try? JSONEncoder().encode(params),
           let paramsDict = try? JSONSerialization.jsonObject(with: encoded)
        {
          dict["params"] = paramsDict
        }
      }
      return dict
    }()

    guard let data = try? JSONSerialization.data(withJSONObject: request),
          var jsonString = String(data: data, encoding: .utf8)
    else {
      throw CodexClientError.encodingFailed
    }

    jsonString += "\n"

    // Log outgoing request
    print("[Codex] → \(method) (id=\(id))")
    fileLogger.log(.debug, category: .connection, message: "Request sent", data: ["method": method, "id": id])
    if let prettyParams = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any] {
      let keys = prettyParams.keys.joined(separator: ", ")
      print("[Codex]   params: {\(keys)}")
    }

    let responseData: Data = try await withCheckedThrowingContinuation { continuation in
      requestLock.lock()
      pendingRequests[id] = continuation
      requestLock.unlock()

      guard let stdin = stdinPipe?.fileHandleForWriting else {
        requestLock.lock()
        pendingRequests.removeValue(forKey: id)
        requestLock.unlock()
        continuation.resume(throwing: CodexClientError.notConnected)
        return
      }

      do {
        try stdin.write(contentsOf: Data(jsonString.utf8))
      } catch {
        requestLock.lock()
        pendingRequests.removeValue(forKey: id)
        requestLock.unlock()
        continuation.resume(throwing: CodexClientError.connectionFailed(underlying: error))
      }
    }

    // Log incoming response
    if let responsePreview = String(data: responseData.prefix(500), encoding: .utf8) {
      print("[Codex] ← \(method) response: \(responsePreview.prefix(200))...")
    }

    // Parse response
    do {
      let response = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: responseData)

      if let error = response.error {
        print("[Codex] ✘ \(method) error: \(error.code) - \(error.message)")
        throw error
      }

      guard let result = response.result else {
        print("[Codex] ✘ \(method) error: No result in response")
        throw CodexClientError.decodingFailed(underlying: NSError(domain: "CodexClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result in response"]))
      }

      print("[Codex] ✓ \(method) success")
      return result
    } catch let error as JSONRPCError {
      print("[Codex] ✘ \(method) JSON-RPC error: \(error.code) - \(error.message)")
      throw error
    } catch let error as CodexClientError {
      print("[Codex] ✘ \(method) client error: \(error)")
      throw error
    } catch {
      print("[Codex] ✘ \(method) decoding error: \(error)")
      throw CodexClientError.decodingFailed(underlying: error)
    }
  }

  func sendNotification<P: Encodable>(_ method: String, params: P) throws {
    guard state == .connected || state == .connecting else {
      throw CodexClientError.notConnected
    }

    var request: [String: Any] = ["method": method]
    if let encoded = try? JSONEncoder().encode(params),
       let paramsDict = try? JSONSerialization.jsonObject(with: encoded)
    {
      request["params"] = paramsDict
    }

    guard let data = try? JSONSerialization.data(withJSONObject: request),
          var jsonString = String(data: data, encoding: .utf8)
    else {
      throw CodexClientError.encodingFailed
    }

    jsonString += "\n"

    guard let stdin = stdinPipe?.fileHandleForWriting else {
      throw CodexClientError.notConnected
    }

    try stdin.write(contentsOf: Data(jsonString.utf8))
  }

  // Send a submission (Op) via stdin
  func sendSubmission<S: CodexSubmission>(_ submission: S) throws {
    guard state == .connected else {
      throw CodexClientError.notConnected
    }

    guard let data = try? JSONEncoder().encode(submission),
          var jsonString = String(data: data, encoding: .utf8)
    else {
      throw CodexClientError.encodingFailed
    }

    jsonString += "\n"

    guard let stdin = stdinPipe?.fileHandleForWriting else {
      throw CodexClientError.notConnected
    }

    try stdin.write(contentsOf: Data(jsonString.utf8))
    logger.debug("Sent submission: \(submission.type)")
  }

  private func nextRequestId() -> Int {
    requestLock.lock()
    defer { requestLock.unlock() }
    requestId += 1
    return requestId
  }

  // MARK: - Convenience Methods

  /// Check if user is logged in and get account info
  func checkAuth() async throws -> AccountInfo? {
    let params = AccountReadParams(refreshToken: false)
    let result: AccountReadResult = try await send("account/read", params: params)
    return result.account
  }

  /// Get available models
  func listModels() async throws -> [CodexModel] {
    let result: ModelListResult = try await send("model/list", params: EmptyParams())
    return result.models
  }

  /// Get rate limits
  func getRateLimits() async throws -> CodexRateLimits? {
    let result: RateLimitsResult = try await send("account/rateLimits/read", params: EmptyParams())
    return result.rateLimits
  }

  // MARK: - Thread Operations

  func startThread(cwd: String, model: String? = nil, approvalPolicy: String? = "untrusted") async throws -> ThreadInfo {
    let params = ThreadStartParams(cwd: cwd, model: model, approvalPolicy: approvalPolicy)
    let result: ThreadStartResult = try await send("thread/start", params: params)
    return result.thread
  }

  func resumeThread(threadId: String, cwd: String? = nil) async throws -> ThreadInfo {
    let params = ThreadResumeParams(threadId: threadId, cwd: cwd)
    let result: ThreadResumeResult = try await send("thread/resume", params: params)
    return result.thread
  }

  func listThreads(limit: Int = 50, includeArchived: Bool = false) async throws -> [ThreadSummary] {
    let params = ThreadListParams(limit: limit, includeArchived: includeArchived)
    let result: ThreadListResult = try await send("thread/list", params: params)
    return result.threads
  }

  func readThread(threadId: String) async throws -> ThreadDetail {
    let params = ThreadReadParams(threadId: threadId)
    let result: ThreadReadResult = try await send("thread/read", params: params)
    return result.thread
  }

  // MARK: - Turn Operations

  func startTurn(threadId: String, message: String) async throws -> String {
    let input = [UserInputItem(text: message)]
    let params = TurnStartParams(threadId: threadId, input: input)
    let result: TurnStartResult = try await send("turn/start", params: params)
    return result.id
  }

  func interruptTurn(threadId: String, turnId: String? = nil) async throws {
    let params = TurnInterruptParams(threadId: threadId, turnId: turnId)
    let _: EmptyResult = try await send("turn/interrupt", params: params)
  }

  // MARK: - Approvals

  func approveExec(requestId: String, approved: Bool) throws {
    let submission = ExecApprovalSubmission(
      id: requestId,
      decision: approved ? .approve : .reject
    )
    try sendSubmission(submission)
  }

  func approvePatch(requestId: String, approved: Bool) throws {
    let submission = PatchApprovalSubmission(
      id: requestId,
      decision: approved ? .approve : .reject
    )
    try sendSubmission(submission)
  }

  func answerQuestion(requestId: String, answers: [String: String]) throws {
    let submission = UserInputAnswerSubmission(
      id: requestId,
      response: UserInputResponse(answers: answers)
    )
    try sendSubmission(submission)
  }

  // MARK: - Binary Discovery

  static func findCodexBinary() -> String? {
    let paths = [
      "/usr/local/bin/codex",
      "/opt/homebrew/bin/codex",
      "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm/versions/node/v24.12.0/bin/codex",
    ]

    for path in paths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // Try which
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    proc.arguments = ["codex"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    do {
      try proc.run()
      proc.waitUntilExit()
      if proc.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
          return path
        }
      }
    } catch {}

    return nil
  }

  static var isCodexInstalled: Bool {
    findCodexBinary() != nil
  }
}

// MARK: - Helper Types

struct EmptyParams: Codable {}

struct EmptyResult: Decodable {}
