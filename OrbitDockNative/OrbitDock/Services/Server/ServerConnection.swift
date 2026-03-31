import Foundation

struct ServerConnectionListenerToken: Hashable, Sendable {
  fileprivate let rawValue: UUID

  fileprivate init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

/// Decoded server push event, typed and ready for consumption.
/// Reuses the existing ServerToClientMessage decode pipeline.
enum ServerEvent: Sendable {
  case hello(ServerHelloMetadata)
  case dashboardSnapshot(ServerDashboardSnapshotPayload)
  case missionsSnapshot(ServerMissionSnapshotPayload)
  case dashboardInvalidated(revision: UInt64)
  case missionsInvalidated(revision: UInt64)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)
  case sessionEnded(sessionId: String, reason: String)

  /// Messages
  case conversationRowsChanged(
    sessionId: String,
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64?
  )

  // Approvals
  case approvalRequested(sessionId: String, request: ServerApprovalRequest, approvalVersion: UInt64?)
  case approvalDecisionResult(
    sessionId: String, requestId: String, outcome: String,
    activeRequestId: String?, approvalVersion: UInt64
  )
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)

  /// Tokens
  case tokensUpdated(
    sessionId: String, usage: ServerTokenUsage, snapshotKind: ServerTokenUsageSnapshotKind
  )

  // Models / Codex account
  case modelsList([ServerCodexModelOption])
  case claudeModelsList([ServerClaudeModelOption])
  case codexAccountStatus(ServerCodexAccountStatus)
  case codexLoginChatgptStarted(loginId: String, authUrl: String)
  case codexLoginChatgptCompleted(loginId: String, success: Bool, error: String?)
  case codexLoginChatgptCanceled(loginId: String, status: ServerCodexLoginCancelStatus)
  case codexAccountUpdated(ServerCodexAccountStatus)

  // Skills
  case skillsList(sessionId: String, skills: [ServerSkillsListEntry], errors: [ServerSkillErrorInfo])
  case skillsUpdateAvailable(sessionId: String)

  /// MCP
  case mcpToolsList(
    sessionId: String, tools: [String: ServerMcpTool],
    resources: [String: [ServerMcpResource]],
    resourceTemplates: [String: [ServerMcpResourceTemplate]],
    authStatuses: [String: ServerMcpAuthStatus]
  )
  case mcpStartupUpdate(sessionId: String, server: String, status: ServerMcpStartupStatus)
  case mcpStartupComplete(
    sessionId: String, ready: [String], failed: [ServerMcpStartupFailure],
    cancelled: [String]
  )

  /// Claude capabilities
  case claudeCapabilities(
    sessionId: String, slashCommands: [String], skills: [String],
    tools: [String], models: [ServerClaudeModelOption]
  )

  // Context / undo / fork
  case contextCompacted(sessionId: String)
  case undoStarted(sessionId: String, message: String?)
  case undoCompleted(sessionId: String, success: Bool, message: String?)
  case threadRolledBack(sessionId: String, numTurns: UInt32)
  case sessionForked(sourceSessionId: String, newSessionId: String, forkedFromThreadId: String?)

  /// Turn diffs
  case turnDiffSnapshot(
    sessionId: String, turnId: String, diff: String,
    inputTokens: UInt64?, outputTokens: UInt64?, cachedTokens: UInt64?,
    contextWindow: UInt64?, snapshotKind: ServerTokenUsageSnapshotKind
  )

  // Review comments
  case reviewCommentCreated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentUpdated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentDeleted(sessionId: String, reviewRevision: UInt64, commentId: String)
  case reviewCommentsList(sessionId: String, reviewRevision: UInt64, comments: [ServerReviewComment])

  /// Subagent
  case subagentToolsList(sessionId: String, subagentId: String, tools: [ServerSubagentTool])

  // Shell
  case shellStarted(sessionId: String, requestId: String, command: String)
  case shellOutput(
    sessionId: String, requestId: String, stdout: String, stderr: String,
    exitCode: Int32?, durationMs: UInt64, outcome: ServerShellExecutionOutcome
  )

  // Worktrees
  case worktreesList(requestId: String, repoRoot: String?, worktreeRevision: UInt64, worktrees: [ServerWorktreeSummary])
  case worktreeCreated(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktree: ServerWorktreeSummary)
  case worktreeRemoved(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktreeId: String)
  case worktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String)
  case worktreeError(requestId: String, code: String, message: String)

  /// Rate limit
  case rateLimitEvent(sessionId: String, info: ServerRateLimitInfo)

  // Misc
  case promptSuggestion(sessionId: String, suggestion: String)
  case filesPersisted(sessionId: String, files: [String])
  case serverInfo(isPrimary: Bool, claims: [ServerClientPrimaryClaim])

  // Terminal sessions
  case terminalCreated(terminalId: String, sessionId: String?)
  case terminalOutput(terminalId: String, data: Data)
  case terminalExited(terminalId: String, exitCode: Int32?)

  /// Error
  case error(code: String, message: String, sessionId: String?)

  /// Permission rules
  case permissionRules(sessionId: String, rules: ServerSessionPermissionRules)

  // Mission Control
  case missionsList(missions: [MissionSummary])
  case missionDelta(missionId: String, issues: [MissionIssueItem], summary: MissionSummary)
  case missionHeartbeat(missionId: String, tickStartedAt: String, nextTickAt: String)

  /// Connection lifecycle
  case connectionStatusChanged(ConnectionStatus)

  /// Revision tracking
  case revision(sessionId: String, revision: UInt64)
}

// MARK: - ServerConnection

/// Main-actor facade for one OrbitDock server endpoint.
/// `EndpointTransport` owns raw HTTP + WebSocket mechanics; this type owns
/// app-facing state, handshake validation, and typed event fanout.
@MainActor
final class ServerConnection {
  private struct RetryHint {
    let minimumDelay: TimeInterval
    let waitingMessage: String
  }

  private struct DisconnectDiagnosis {
    let message: String
    let shouldReconnect: Bool
    let retryHint: RetryHint?
  }

  private(set) var connectionStatus: ConnectionStatus = .disconnected
  private(set) var latestSessionListItems: [ServerSessionListItem] = []
  private(set) var latestDashboardConversationItems: [ServerDashboardConversationItem] = []
  private(set) var hasReceivedInitialDashboardSnapshot = false
  private(set) var hasReceivedInitialMissionsSnapshot = false
  private(set) var hasSubscribedDashboardStream = false

  /// Event listeners. Multiple consumers can register.
  var onEvent: ((ServerEvent) -> Void)?
  private var additionalListeners: [ServerConnectionListenerToken: (ServerEvent) -> Void] = [:]

  @discardableResult
  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken {
    let token = ServerConnectionListenerToken()
    additionalListeners[token] = listener
    return token
  }

  func removeListener(_ token: ServerConnectionListenerToken) {
    additionalListeners.removeValue(forKey: token)
  }

  // MARK: - Private state

  private var serverURL: URL?
  private let authToken: String?
  private let transport: any ServerConnectionTransport
  private var connectionProbeTask: Task<Void, Never>?
  private var connectionProbeGeneration: UInt64?
  private let circuitBreaker: ConnectionCircuitBreaker
  private var stableConnectionTask: Task<Void, Never>?
  private var handshakeTimeoutTask: Task<Void, Never>?
  private var connectLaunchTask: Task<Void, Never>?
  private var lastConnectedAt: Date?
  private var reconnectTask: Task<Void, Never>?
  private var connectionGeneration: UInt64 = 0
  private var reconnectRetryHint: RetryHint?
  private var consecutiveDNSFailures: Int = 0

  private static let handshakeTimeout: TimeInterval = 10
  private static let stableConnectionThreshold: TimeInterval = 30

  var isRemote: Bool {
    guard let host = serverURL?.host else { return false }
    return host != "127.0.0.1" && host != "localhost" && host != "::1"
  }

  init(authToken: String?, transport: (any ServerConnectionTransport)? = nil) {
    self.authToken = authToken
    self.transport = transport ?? EndpointTransport(authToken: authToken)
    self.circuitBreaker = .local()
    netLog(.info, cat: .ws, "ServerConnection initialized")
  }

  // MARK: - HTTP execution

  /// Execute an HTTP request through the endpoint transport.
  /// HTTP reachability is independent from dashboard bootstrap state.
  func execute(_ request: URLRequest) async throws -> HTTPResponse {
    return try await transport.execute(request)
  }

  // MARK: - WebSocket connection

  func connect(to url: URL) {
    serverURL = url
    switch connectionStatus {
      case .disconnected, .failed:
        break
      case .connecting, .connected:
        return
    }
    reconnectTask?.cancel()
    reconnectTask = nil
    attemptConnect()
  }

  func reconnectIfNeeded() {
    guard serverURL != nil else { return }
    switch connectionStatus {
      case .connected:
        guard reconnectTask == nil else { return }
        let generation = connectionGeneration
        pruneStaleConnectionProbe(for: generation)
        guard connectionProbeTask == nil else {
          netLog(.debug, cat: .ws, "Reconnect probe already in flight", data: [
            "generation": generation,
          ])
          return
        }
        startConnectionProbe(expectedGeneration: generation)
      case .connecting:
        break // already attempting
      case .disconnected, .failed:
        guard reconnectTask == nil else { return }
        attemptConnect()
    }
  }

  func disconnect() {
    reconnectTask?.cancel()
    reconnectTask = nil
    _ = invalidateConnectionGeneration()
    teardownConnectionTasks()
    circuitBreaker.reset()
    reconnectRetryHint = nil
    consecutiveDNSFailures = 0
    lastConnectedAt = nil
    latestSessionListItems = []
    latestDashboardConversationItems = []
    hasReceivedInitialDashboardSnapshot = false
    hasReceivedInitialMissionsSnapshot = false
    hasSubscribedDashboardStream = false
    setStatus(.disconnected)
    netLog(.info, cat: .circuit, "Circuit breaker reset (explicit disconnect)")
  }

  func failCompatibility(message: String) {
    let failureGeneration = invalidateConnectionGeneration()
    pruneStaleConnectionProbe(for: failureGeneration)
    teardownConnectionTasks()
    reconnectRetryHint = nil
    consecutiveDNSFailures = 0
    lastConnectedAt = nil
    setStatus(.failed(message))
    netLog(.error, cat: .ws, "Connection marked incompatible", data: [
      "message": message,
      "url": serverURL?.absoluteString ?? "nil",
    ])
  }

  // MARK: - Outbound WS messages

  func subscribeDashboard(sinceRevision: UInt64? = nil) {
    guard !hasSubscribedDashboardStream else { return }
    hasSubscribedDashboardStream = true
    send(.subscribeDashboard(sinceRevision: sinceRevision))
  }

  func subscribeMissions(sinceRevision: UInt64? = nil) {
    send(.subscribeMissions(sinceRevision: sinceRevision))
  }

  func subscribeSessionSurface(
    _ sessionId: String,
    surface: ServerSessionSurface,
    sinceRevision: UInt64? = nil
  ) {
    send(.subscribeSessionSurface(sessionId: sessionId, surface: surface, sinceRevision: sinceRevision))
  }

  func unsubscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface) {
    send(.unsubscribeSessionSurface(sessionId: sessionId, surface: surface))
  }

  func applyDashboardSnapshot(_ snapshot: ServerDashboardSnapshotPayload) {
    latestSessionListItems = snapshot.sessions
    latestDashboardConversationItems = snapshot.conversations
    hasReceivedInitialDashboardSnapshot = true
    emit(.dashboardSnapshot(snapshot))
  }

  func applyMissionsSnapshot(_ snapshot: ServerMissionSnapshotPayload) {
    hasReceivedInitialMissionsSnapshot = true
    emit(.missionsSnapshot(snapshot))
  }

  // MARK: - Testing

  func seedDashboardSnapshotForTesting(_ snapshot: ServerDashboardSnapshotPayload) {
    latestSessionListItems = snapshot.sessions
    latestDashboardConversationItems = snapshot.conversations
    hasReceivedInitialDashboardSnapshot = true
    emit(.dashboardSnapshot(snapshot))
  }

  func emitForTesting(_ event: ServerEvent) {
    emit(event)
  }

  // MARK: - Private: Connection

  private func attemptConnect() {
    guard let serverURL else { return }
    switch connectionStatus {
      case .disconnected, .failed:
        break
      case .connecting, .connected:
        return
    }

    // If breaker is open, go straight to scheduled retry
    guard circuitBreaker.shouldAllow else {
      let reconnectGeneration = invalidateConnectionGeneration()
      scheduleReconnect(expectedGeneration: reconnectGeneration)
      return
    }

    reconnectTask?.cancel()
    reconnectTask = nil
    setStatus(.connecting)
    let generation = advanceConnectionGeneration()
    startHandshakeTimeout(expectedGeneration: generation)

    connectLaunchTask?.cancel()
    connectLaunchTask = Task { [weak self] in
      guard let self else { return }
      guard !Task.isCancelled else { return }
      await transport.connect(
        to: serverURL,
        clientVersion: OrbitDockProtocol.clientVersion,
        minimumServerVersion: OrbitDockProtocol.minimumServerVersion,
        generation: generation,
        onEvent: { [weak self] event in
          guard let self else { return }
          await self.handleTransportEvent(event)
        }
      )
      guard !Task.isCancelled else { return }
      await MainActor.run {
        if self.connectionGeneration == generation {
          self.connectLaunchTask = nil
        }
      }
    }
  }

  private func completeConnection(expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }
    guard case .connecting = connectionStatus else { return }
    connectLaunchTask?.cancel()
    connectLaunchTask = nil
    handshakeTimeoutTask?.cancel()
    handshakeTimeoutTask = nil
    lastConnectedAt = Date()
    reconnectRetryHint = nil
    consecutiveDNSFailures = 0
    netLog(.info, cat: .ws, "Connection complete", data: ["url": serverURL?.absoluteString ?? "nil"])
    setStatus(.connected)
    Task { [weak self] in
      guard let self else { return }
      await transport.activateKeepAlive(for: generation)
    }
    startStableConnectionTimer(generation: generation)
  }

  private func startStableConnectionTimer(generation: UInt64) {
    stableConnectionTask?.cancel()
    stableConnectionTask = Task {
      try? await Task.sleep(for: .seconds(Self.stableConnectionThreshold))
      guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
      circuitBreaker.recordSuccess()
      netLog(.info, cat: .circuit, "Circuit breaker reset (stable connection)")
    }
  }

  private func startHandshakeTimeout(expectedGeneration generation: UInt64) {
    handshakeTimeoutTask?.cancel()
    handshakeTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
      guard let self, !Task.isCancelled else { return }
      await self.handleHandshakeTimeout(expectedGeneration: generation)
    }
  }

  private func handleHandshakeTimeout(expectedGeneration generation: UInt64) async {
    guard isCurrentGeneration(generation) else { return }
    guard case .connecting = connectionStatus else { return }
    netLog(.warning, cat: .ws, "Server handshake timed out", data: [
      "generation": generation,
      "url": serverURL?.absoluteString ?? "nil",
    ])
    await handleDisconnect(expectedGeneration: generation)
  }

  private func handleTransportEvent(_ event: EndpointTransport.Event) async {
    switch event {
      case let .textFrame(text, generation):
        handleFrame(text, expectedGeneration: generation)
      case let .binaryFrame(data, generation):
        handleBinaryFrame(data, expectedGeneration: generation)
      case let .disconnected(generation, failure):
        await handleDisconnect(expectedGeneration: generation, failure: failure)
    }
  }

  private func stopConnectionProbe() {
    connectionProbeTask?.cancel()
    connectionProbeTask = nil
    connectionProbeGeneration = nil
  }

  private func pruneStaleConnectionProbe(for generation: UInt64) {
    guard let probeGeneration = connectionProbeGeneration else { return }
    guard probeGeneration != generation else { return }
    netLog(.debug, cat: .ws, "Cancelling stale reconnect probe", data: [
      "probeGeneration": probeGeneration,
      "currentGeneration": generation,
    ])
    stopConnectionProbe()
  }

  private func startConnectionProbe(expectedGeneration generation: UInt64) {
    connectionProbeGeneration = generation
    netLog(.debug, cat: .ws, "Reconnect probe started", data: [
      "generation": generation,
    ])
    connectionProbeTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.transport.probe(generation: generation)
        guard !Task.isCancelled else { return }
        self.finishConnectionProbe(expectedGeneration: generation, outcome: "success")
      } catch {
        guard !Task.isCancelled else { return }
        self.finishConnectionProbe(expectedGeneration: generation, outcome: "failure")
        await self.handleDisconnect(expectedGeneration: generation)
      }
    }
  }

  private func finishConnectionProbe(expectedGeneration generation: UInt64, outcome: String) {
    guard connectionProbeGeneration == generation else {
      netLog(.debug, cat: .ws, "Ignored stale reconnect probe completion", data: [
        "generation": generation,
        "currentGeneration": connectionProbeGeneration as Any,
        "outcome": outcome,
      ])
      return
    }
    connectionProbeTask = nil
    connectionProbeGeneration = nil
    netLog(.debug, cat: .ws, "Reconnect probe finished", data: [
      "generation": generation,
      "outcome": outcome,
    ])
  }

  private func handleBinaryFrame(_ data: Data, expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }
    if data.count >= 2, (data[0] == 0x01 || data[0] == 0x02) {
      handleTerminalBinaryFrame(data)
    } else if let text = String(data: data, encoding: .utf8) {
      handleFrame(text, expectedGeneration: generation)
    }
  }

  private func handleDisconnect(
    expectedGeneration generation: UInt64,
    failure: EndpointTransport.DisconnectFailure? = nil
  ) async {
    guard isCurrentGeneration(generation) else { return }

    let reconnectGeneration = invalidateConnectionGeneration()

    teardownConnectionTasks()
    lastConnectedAt = nil

    let wasConnecting: Bool
    if case .connecting = connectionStatus {
      wasConnecting = true
    } else {
      wasConnecting = false
    }

    let diagnosis = await diagnoseDisconnect(
      failure: failure,
      wasConnecting: wasConnecting,
      expectedGeneration: reconnectGeneration
    )
    guard isCurrentGeneration(reconnectGeneration) else { return }

    if let diagnosis, diagnosis.shouldReconnect == false {
      reconnectRetryHint = nil
      setStatus(.failed(diagnosis.message))
      netLog(.error, cat: .ws, "Connection failed without retry", data: [
        "message": diagnosis.message,
        "url": serverURL?.absoluteString ?? "nil",
      ])
      return
    }

    circuitBreaker.recordFailure()
    netLog(.warning, cat: .circuit, "Circuit breaker recorded failure", data: [
      "state": String(describing: circuitBreaker.state),
      "url": serverURL?.absoluteString ?? "nil",
    ])

    if let diagnosis {
      reconnectRetryHint = diagnosis.retryHint
      setStatus(.failed(diagnosis.message))
    } else {
      consecutiveDNSFailures = 0
      reconnectRetryHint = nil
      setStatus(.disconnected)
    }
    scheduleReconnect(expectedGeneration: reconnectGeneration)
  }

  private func diagnoseDisconnect(
    failure: EndpointTransport.DisconnectFailure?,
    wasConnecting: Bool,
    expectedGeneration generation: UInt64
  ) async -> DisconnectDiagnosis? {
    guard wasConnecting, let failure else { return nil }
    guard isCurrentGeneration(generation) else { return nil }

    switch failure.urlErrorCode {
      case .cannotFindHost, .dnsLookupFailed:
        consecutiveDNSFailures += 1
        let delay = min(15 * pow(2, Double(max(consecutiveDNSFailures - 1, 0))), 300)
        return DisconnectDiagnosis(
          message: "Could not resolve the server hostname. Check the endpoint URL and DNS.",
          shouldReconnect: true,
          retryHint: RetryHint(
            minimumDelay: delay,
            waitingMessage: "DNS lookup still failing"
          )
        )
      case .cannotConnectToHost:
        consecutiveDNSFailures = 0
        return DisconnectDiagnosis(
          message: "Reached the host but could not open a connection. Verify the server is running and reachable.",
          shouldReconnect: true,
          retryHint: nil
        )
      case .notConnectedToInternet:
        consecutiveDNSFailures = 0
        return DisconnectDiagnosis(
          message: "No network connection available.",
          shouldReconnect: true,
          retryHint: nil
        )
      case .badServerResponse:
        consecutiveDNSFailures = 0
        return await diagnoseHandshakeFailure(expectedGeneration: generation)
      default:
        break
    }

    consecutiveDNSFailures = 0
    switch failure.transportError {
      case .unreachable:
        return DisconnectDiagnosis(
          message: failure.transportError.errorDescription
            ?? "Server is currently unreachable.",
          shouldReconnect: true,
          retryHint: nil
        )
      case .timedOut:
        return DisconnectDiagnosis(
          message: "Connection attempt timed out while waiting for server handshake.",
          shouldReconnect: true,
          retryHint: nil
        )
      case .transport:
        return await diagnoseHandshakeFailure(expectedGeneration: generation)
      case .cancelled, .serverUnreachable, .invalidResponse:
        return nil
    }
  }

  private func diagnoseHandshakeFailure(expectedGeneration generation: UInt64) async
    -> DisconnectDiagnosis?
  {
    guard isCurrentGeneration(generation) else { return nil }
    guard let serverURL, let baseURL = makeHTTPBaseURL(from: serverURL) else {
      return nil
    }

    do {
      let request = try HTTPRequestBuilder(baseURL: baseURL, authToken: authToken).build(
        path: "/api/server/meta",
        method: "GET"
      )
      let response = try await transport.execute(request)
      guard isCurrentGeneration(generation) else { return nil }

      switch response.statusCode {
        case 200 ..< 300:
          if let meta = try? JSONDecoder().decode(ServerMetaResponse.self, from: response.body) {
            do {
              try meta.validateCompatibility()
            } catch {
              if let message = ServerContractGuard.versionMessage(
                for: error,
                surface: "WebSocket handshake"
              ) {
                return DisconnectDiagnosis(message: message, shouldReconnect: false, retryHint: nil)
              }
              return DisconnectDiagnosis(
                message: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                shouldReconnect: false,
                retryHint: nil
              )
            }
          }
          return DisconnectDiagnosis(
            message:
              "HTTP is reachable, but WebSocket upgrade failed. Check reverse-proxy support for `/ws` upgrades.",
            shouldReconnect: true,
            retryHint: nil
          )

        case 401, 403:
          return DisconnectDiagnosis(
            message: "Authentication failed while opening the realtime connection. Check the endpoint token.",
            shouldReconnect: false,
            retryHint: nil
          )

        case 426:
          let apiError = decodeAPIError(from: response.body)
          return DisconnectDiagnosis(
            message: apiError?.error
              ?? "This OrbitDock client version is incompatible with the connected server.",
            shouldReconnect: false,
            retryHint: nil
          )

        case 404:
          return DisconnectDiagnosis(
            message:
              "The server is reachable but `/api/server/meta` is unavailable. This server build may be too old for this app.",
            shouldReconnect: false,
            retryHint: nil
          )

        default:
          let apiError = decodeAPIError(from: response.body)
          let detail = apiError?.error ?? "status \(response.statusCode)"
          return DisconnectDiagnosis(
            message: "Server rejected the compatibility probe: \(detail)",
            shouldReconnect: true,
            retryHint: nil
          )
      }
    } catch {
      return nil
    }
  }

  private func decodeAPIError(from body: Data) -> APIErrorResponse? {
    try? JSONDecoder().decode(APIErrorResponse.self, from: body)
  }

  private func makeHTTPBaseURL(from webSocketURL: URL) -> URL? {
    guard var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false) else {
      return nil
    }

    switch components.scheme?.lowercased() {
      case "ws":
        components.scheme = "http"
      case "wss":
        components.scheme = "https"
      default:
        break
    }

    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private func scheduleReconnect(expectedGeneration generation: UInt64) {
    reconnectTask?.cancel()
    reconnectTask = nil

    guard serverURL != nil else { return }
    guard isCurrentGeneration(generation) else { return }

    let breakerAllows = circuitBreaker.shouldAllow
    let breakerDelay = breakerAllows ? 0 : (circuitBreaker.cooldownRemaining ?? 1)
    let hintDelay = reconnectRetryHint?.minimumDelay ?? 0
    let delay = max(breakerDelay, hintDelay)

    guard delay > 0 else {
      // Breaker is closed and no dampening hint applies — retry on next run
      // loop tick so duplicate disconnect callbacks collapse.
      reconnectTask = Task {
        await Task.yield()
        guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
        reconnectTask = nil
        attemptConnect()
      }
      return
    }

    let countdown = Int(delay.rounded(.up))
    let fallbackMessage = isRemote
      ? "Could not reach remote server — retrying in \(countdown)s"
      : "Failed to connect — retrying in \(countdown)s"
    let msg: String
    if let reconnectRetryHint {
      msg = "\(reconnectRetryHint.waitingMessage) — retrying in \(countdown)s"
    } else {
      msg = fallbackMessage
    }
    setStatus(.failed(msg))

    reconnectTask = Task {
      try? await Task.sleep(for: .seconds(max(delay, 1)))
      guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
      reconnectTask = nil
      attemptConnect()
    }
  }

  // MARK: - Private: Frame handling

  private func handleFrame(_ text: String, expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }
    guard let data = text.data(using: .utf8) else { return }

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let messageType = json?["type"] as? String
    let sessionId = json?["session_id"] as? String

    netLog(.debug, cat: .ws, "Frame received", sid: sessionId, data: [
      "type": messageType ?? "unknown",
      "bytes": text.count,
    ])

    if let json, let rev = json["revision"] as? Int, let sid = sessionId {
      emit(.revision(sessionId: sid, revision: UInt64(rev)))
    }

    do {
      let msg = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
      if case .connecting = connectionStatus {
        guard validateHandshake(message: msg, messageType: messageType, expectedGeneration: generation)
        else { return }
        completeConnection(expectedGeneration: generation)
      }
      routeMessage(msg)
    } catch {
      let preview = String(text.prefix(500))
      netLog(.error, cat: .ws, "Failed to decode frame", sid: sessionId, data: [
        "type": messageType ?? "unknown",
        "error": String(describing: error),
        "preview": preview,
      ])
    }
  }

  private func validateHandshake(
    message: ServerToClientMessage,
    messageType: String?,
    expectedGeneration generation: UInt64
  ) -> Bool {
    switch message {
      case let .hello(hello):
        do {
          try hello.validateCompatibility()
          return true
        } catch {
          failHandshake(error, expectedGeneration: generation)
          return false
        }
      default:
        failHandshake(
          ServerVersionError.missingHelloHandshake(messageType: messageType ?? "unknown"),
          expectedGeneration: generation
        )
        return false
    }
  }

  private func failHandshake(_ error: Error, expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }

    let reconnectGeneration = invalidateConnectionGeneration()
    pruneStaleConnectionProbe(for: reconnectGeneration)
    teardownConnectionTasks()
    reconnectRetryHint = nil
    consecutiveDNSFailures = 0
    lastConnectedAt = nil

    let message = (error as? LocalizedError)?.errorDescription
      ?? String(describing: error)
    netLog(.error, cat: .ws, "Server handshake failed", data: ["error": message])
    setStatus(.failed(message))
  }

  private func routeMessage(_ message: ServerToClientMessage) {
    switch message {
      case let .hello(hello): emit(.hello(hello))
      case let .dashboardInvalidated(revision): emit(.dashboardInvalidated(revision: revision))
      case let .missionsInvalidated(revision): emit(.missionsInvalidated(revision: revision))
      case let .sessionDelta(sessionId, changes):
        emit(.sessionDelta(sessionId: sessionId, changes: changes))
      case let .conversationRowsChanged(sessionId, upserted, removedRowIds, totalRowCount):
        emit(.conversationRowsChanged(
          sessionId: sessionId,
          upserted: upserted,
          removedRowIds: removedRowIds,
          totalRowCount: totalRowCount
        ))
      case let .approvalRequested(sessionId, request, approvalVersion):
        emit(.approvalRequested(sessionId: sessionId, request: request, approvalVersion: approvalVersion))
      case let .approvalDecisionResult(sessionId, requestId, outcome, activeRequestId, approvalVersion):
        emit(.approvalDecisionResult(
          sessionId: sessionId,
          requestId: requestId,
          outcome: outcome,
          activeRequestId: activeRequestId,
          approvalVersion: approvalVersion
        ))
      case let .tokensUpdated(sessionId, usage, snapshotKind):
        emit(.tokensUpdated(sessionId: sessionId, usage: usage, snapshotKind: snapshotKind))
      case let .sessionEnded(sessionId, reason): emit(.sessionEnded(sessionId: sessionId, reason: reason))
      case let .approvalsList(sessionId, approvals): emit(.approvalsList(sessionId: sessionId, approvals: approvals))
      case let .approvalDeleted(approvalId): emit(.approvalDeleted(approvalId: approvalId))
      case let .modelsList(models): emit(.modelsList(models))
      case let .codexAccountStatus(status): emit(.codexAccountStatus(status))
      case let .codexLoginChatgptStarted(loginId, authUrl):
        emit(.codexLoginChatgptStarted(loginId: loginId, authUrl: authUrl))
      case let .codexLoginChatgptCompleted(loginId, success, error):
        emit(.codexLoginChatgptCompleted(loginId: loginId, success: success, error: error))
      case let .codexLoginChatgptCanceled(loginId, status):
        emit(.codexLoginChatgptCanceled(loginId: loginId, status: status))
      case let .codexAccountUpdated(status): emit(.codexAccountUpdated(status))
      case let .skillsList(sessionId, skills, errors):
        emit(.skillsList(sessionId: sessionId, skills: skills, errors: errors))
      case let .skillsUpdateAvailable(sessionId): emit(.skillsUpdateAvailable(sessionId: sessionId))
      case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
        emit(.mcpToolsList(
          sessionId: sessionId,
          tools: tools,
          resources: resources,
          resourceTemplates: resourceTemplates,
          authStatuses: authStatuses
        ))
      case let .mcpStartupUpdate(sessionId, server, status):
        emit(.mcpStartupUpdate(sessionId: sessionId, server: server, status: status))
      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        emit(.mcpStartupComplete(sessionId: sessionId, ready: ready, failed: failed, cancelled: cancelled))
      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
        emit(.claudeCapabilities(
          sessionId: sessionId,
          slashCommands: slashCommands,
          skills: skills,
          tools: tools,
          models: models
        ))
      case let .claudeModelsList(models): emit(.claudeModelsList(models))
      case let .contextCompacted(sessionId): emit(.contextCompacted(sessionId: sessionId))
      case let .undoStarted(sessionId, message): emit(.undoStarted(sessionId: sessionId, message: message))
      case let .undoCompleted(sessionId, success, message):
        emit(.undoCompleted(sessionId: sessionId, success: success, message: message))
      case let .threadRolledBack(sessionId, numTurns):
        emit(.threadRolledBack(sessionId: sessionId, numTurns: numTurns))
      case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
        emit(.sessionForked(
          sourceSessionId: sourceSessionId,
          newSessionId: newSessionId,
          forkedFromThreadId: forkedFromThreadId
        ))
      case let .turnDiffSnapshot(
      sessionId,
      turnId,
      diff,
      inputTokens,
      outputTokens,
      cachedTokens,
      contextWindow,
      snapshotKind
    ):
        emit(.turnDiffSnapshot(
          sessionId: sessionId,
          turnId: turnId,
          diff: diff,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedTokens: cachedTokens,
          contextWindow: contextWindow,
          snapshotKind: snapshotKind
        ))
      case let .reviewCommentCreated(sessionId, reviewRevision, comment):
        emit(.reviewCommentCreated(sessionId: sessionId, reviewRevision: reviewRevision, comment: comment))
      case let .reviewCommentUpdated(sessionId, reviewRevision, comment):
        emit(.reviewCommentUpdated(sessionId: sessionId, reviewRevision: reviewRevision, comment: comment))
      case let .reviewCommentDeleted(sessionId, reviewRevision, commentId):
        emit(.reviewCommentDeleted(sessionId: sessionId, reviewRevision: reviewRevision, commentId: commentId))
      case let .reviewCommentsList(sessionId, reviewRevision, comments):
        emit(.reviewCommentsList(sessionId: sessionId, reviewRevision: reviewRevision, comments: comments))
      case let .subagentToolsList(sessionId, subagentId, tools):
        emit(.subagentToolsList(sessionId: sessionId, subagentId: subagentId, tools: tools))
      case let .shellStarted(sessionId, requestId, command):
        emit(.shellStarted(sessionId: sessionId, requestId: requestId, command: command))
      case let .shellOutput(sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome):
        emit(.shellOutput(
          sessionId: sessionId,
          requestId: requestId,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          durationMs: durationMs,
          outcome: outcome
        ))
      case let .worktreesList(requestId, repoRoot, worktreeRevision, worktrees):
        emit(.worktreesList(
          requestId: requestId,
          repoRoot: repoRoot,
          worktreeRevision: worktreeRevision,
          worktrees: worktrees
        ))
      case let .worktreeCreated(requestId, repoRoot, worktreeRevision, worktree):
        emit(.worktreeCreated(
          requestId: requestId,
          repoRoot: repoRoot,
          worktreeRevision: worktreeRevision,
          worktree: worktree
        ))
      case let .worktreeRemoved(requestId, repoRoot, worktreeRevision, worktreeId):
        emit(.worktreeRemoved(
          requestId: requestId,
          repoRoot: repoRoot,
          worktreeRevision: worktreeRevision,
          worktreeId: worktreeId
        ))
      case let .worktreeStatusChanged(worktreeId, status, repoRoot):
        emit(.worktreeStatusChanged(worktreeId: worktreeId, status: status, repoRoot: repoRoot))
      case let .worktreeError(requestId, code, message):
        emit(.worktreeError(requestId: requestId, code: code, message: message))
      case let .rateLimitEvent(sessionId, info): emit(.rateLimitEvent(sessionId: sessionId, info: info))
      case let .promptSuggestion(sessionId, suggestion):
        emit(.promptSuggestion(sessionId: sessionId, suggestion: suggestion))
      case let .filesPersisted(sessionId, files): emit(.filesPersisted(sessionId: sessionId, files: files))
      case let .serverInfo(isPrimary, claims): emit(.serverInfo(isPrimary: isPrimary, claims: claims))
      case let .permissionRules(sessionId, rules): emit(.permissionRules(sessionId: sessionId, rules: rules))
      case let .error(code, message, sessionId): emit(.error(code: code, message: message, sessionId: sessionId))
      case let .missionsList(missions):
        emit(.missionsList(missions: missions))
      case let .missionDelta(missionId, issues, summary):
        emit(.missionDelta(missionId: missionId, issues: issues, summary: summary))
      case let .missionHeartbeat(missionId, tickStartedAt, nextTickAt):
        emit(.missionHeartbeat(missionId: missionId, tickStartedAt: tickStartedAt, nextTickAt: nextTickAt))
      case let .terminalCreated(terminalId, sessionId):
        emit(.terminalCreated(terminalId: terminalId, sessionId: sessionId))
      case let .terminalExited(terminalId, exitCode):
        emit(.terminalExited(terminalId: terminalId, exitCode: exitCode))
      case .steerOutcome:
        break // Outcome is informational; steerable state flows via session_delta
      case .directoryListing, .recentProjectsList, .openAiKeyStatus,
           .codexUsageResult, .claudeUsageResult:
        break
      case .unknown:
        break // Already logged at decode time
    }
  }

  private func teardownConnectionTasks() {
    connectLaunchTask?.cancel()
    connectLaunchTask = nil
    handshakeTimeoutTask?.cancel()
    handshakeTimeoutTask = nil
    stopConnectionProbe()
    stableConnectionTask?.cancel()
    stableConnectionTask = nil
    Task { [transport] in
      await transport.disconnect()
    }
  }

  private func advanceConnectionGeneration() -> UInt64 {
    connectionGeneration &+= 1
    return connectionGeneration
  }

  private func invalidateConnectionGeneration() -> UInt64 {
    advanceConnectionGeneration()
  }

  private func isCurrentGeneration(_ generation: UInt64) -> Bool {
    connectionGeneration == generation
  }

  private func emit(_ event: ServerEvent) {
    updateRootState(for: event)
    onEvent?(event)
    let listeners = Array(additionalListeners.values)
    for listener in listeners {
      listener(event)
    }
  }

  private func setStatus(_ status: ConnectionStatus) {
    guard connectionStatus != status else { return }
    connectionStatus = status
    if status != .connected {
      // Keep the latest HTTP-backed snapshots available when WS drops so the
      // app remains navigable in degraded realtime mode.
      hasSubscribedDashboardStream = false
    }
    emit(.connectionStatusChanged(status))
  }

  private func updateRootState(for event: ServerEvent) {
    switch event {
      case let .dashboardSnapshot(snapshot):
        latestSessionListItems = snapshot.sessions
        latestDashboardConversationItems = snapshot.conversations
        hasReceivedInitialDashboardSnapshot = true
      case let .missionsSnapshot(snapshot):
        _ = snapshot
        hasReceivedInitialMissionsSnapshot = true
      case .dashboardInvalidated:
        break
      default: break
    }
  }

  // MARK: - Terminal Binary Frames

  /// Parse a binary frame from the server containing terminal PTY output or exit notification.
  /// Format: [type:1][id_len:1][id:N][payload:...]
  private func handleTerminalBinaryFrame(_ data: Data) {
    guard data.count >= 2 else { return }
    let frameType = data[0]
    let idLen = Int(data[1])
    guard data.count >= 2 + idLen else { return }

    let idData = data[2 ..< 2 + idLen]
    let terminalId = String(data: idData, encoding: .utf8) ?? ""

    switch frameType {
    case 0x01: // Terminal output
      let payload = data[(2 + idLen)...]
      emit(.terminalOutput(terminalId: terminalId, data: Data(payload)))

    case 0x02: // Terminal exited
      let payloadStart = 2 + idLen
      let exitCode: Int32?
      if data.count >= payloadStart + 4 {
        exitCode = data[payloadStart ..< payloadStart + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
      } else {
        exitCode = nil
      }
      emit(.terminalExited(terminalId: terminalId, exitCode: exitCode))

    default:
      break
    }
  }

  // MARK: - Terminal Send Methods

  func sendCreateTerminal(
    terminalId: String,
    cwd: String,
    shell: String? = nil,
    cols: UInt16,
    rows: UInt16,
    sessionId: String? = nil
  ) {
    let payload = TerminalCreatePayload(
      type: "create_terminal",
      terminalId: terminalId,
      cwd: cwd,
      shell: shell,
      cols: cols,
      rows: rows,
      sessionId: sessionId
    )
    sendJSON(payload)
  }

  func sendTerminalInput(terminalId: String, data: Data) {
    let payload = TerminalInputPayload(
      type: "terminal_input",
      terminalId: terminalId,
      data: data.base64EncodedString()
    )
    sendJSON(payload)
  }

  func sendTerminalResize(terminalId: String, cols: UInt16, rows: UInt16) {
    let payload = TerminalResizePayload(
      type: "terminal_resize",
      terminalId: terminalId,
      cols: cols,
      rows: rows
    )
    sendJSON(payload)
  }

  func sendDestroyTerminal(terminalId: String) {
    let payload = TerminalDestroyPayload(
      type: "destroy_terminal",
      terminalId: terminalId
    )
    sendJSON(payload)
  }

  /// Send an arbitrary Encodable payload as JSON text frame.
  private func sendJSON<T: Encodable>(_ payload: T) {
    guard let text = encodeOutboundText(payload) else { return }
    Task { [transport] in
      await transport.sendText(text)
    }
  }

  private func send(_ message: ClientToServerMessage) {
    guard let text = encodeOutboundText(message) else { return }
    Task { [transport] in
      await transport.sendText(text)
    }
  }

  private func encodeOutboundText<T: Encodable>(_ payload: T) -> String? {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase

    do {
      let data = try encoder.encode(payload)
      guard let text = String(data: data, encoding: .utf8) else {
        netLog(.error, cat: .ws, "Failed to encode outbound payload as UTF-8", data: [
          "payload": String(describing: T.self),
        ])
        return nil
      }
      return text
    } catch {
      netLog(.error, cat: .ws, "Failed to encode outbound payload", data: [
        "payload": String(describing: T.self),
        "error": String(describing: error),
      ])
      return nil
    }
  }
}
