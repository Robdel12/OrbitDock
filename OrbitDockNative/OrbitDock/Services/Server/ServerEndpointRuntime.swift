import Foundation

@MainActor
protocol ServerEndpointRuntimeConnection: AnyObject {
  var connectionStatus: ConnectionStatus { get }
  var isRemote: Bool { get }

  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken
  func removeListener(_ token: ServerConnectionListenerToken)
  func subscribeMissions(sinceRevision: UInt64?)
  func unsubscribeMissions()
  func subscribeMission(_ missionId: String)
  func unsubscribeMission(_ missionId: String)
  func resubscribeMission(_ missionId: String)
  func subscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface, sinceRevision: UInt64?)
  func unsubscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface)
  func failConnection(message: String)
}

extension ServerConnection: ServerEndpointRuntimeConnection {}

@Observable
@MainActor
final class ServerEndpointRuntime {
  @MainActor
  private final class SessionContextRef {
    weak var value: ServerSessionContext?

    init(_ value: ServerSessionContext) {
      self.value = value
    }
  }

  nonisolated static func shouldAutoRefreshCodexAccount(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] == nil
      && environment["XCTestBundlePath"] == nil
      && environment["XCTestSessionIdentifier"] == nil
      && environment["ORBITDOCK_TEST_DB"] == nil
  }

  let clients: ServerClients
  let connection: any ServerEndpointRuntimeConnection
  let endpointId: UUID
  var endpointName: String?

  var codexModels: [ServerCodexModelOption] = []
  var codexAccountStatus: ServerCodexAccountStatus?
  var codexAuthError: String?
  @ObservationIgnored lazy var codexAccountService = CodexAccountService(endpointStore: self)
  var lastServerError: (code: String, message: String)?
  var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]
  var serverInstanceId: String?
  var serverIsPrimary: Bool?
  var serverPrimaryClaims: [ServerClientPrimaryClaim] = []
  let selectionRequests: AsyncStream<SessionRef>
  var isRemoteConnection: Bool { connection.isRemote }

  @ObservationIgnored private var sessionsByID: [String: SessionContextRef] = [:]
  @ObservationIgnored private var connectionListenerToken: ServerConnectionListenerToken?
  @ObservationIgnored private var eventProcessingTask: Task<Void, Never>?
  @ObservationIgnored private(set) var eventProcessingStartCount = 0
  @ObservationIgnored private let selectionRequestContinuation: AsyncStream<SessionRef>.Continuation

  let projectFileIndex = ProjectFileIndex()

  init(
    clients: ServerClients,
    connection: any ServerEndpointRuntimeConnection,
    endpointId: UUID,
    endpointName: String? = nil
  ) {
    var selectionRequestContinuation: AsyncStream<SessionRef>.Continuation!
    self.selectionRequests = AsyncStream { selectionRequestContinuation = $0 }
    self.selectionRequestContinuation = selectionRequestContinuation
    self.clients = clients
    self.connection = connection
    self.endpointId = endpointId
    self.endpointName = endpointName
  }

  static func preview() -> ServerEndpointRuntime {
    let baseURL = URL(string: "http://127.0.0.1:3000")!
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: nil)
    let clients = ServerClients(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
    return ServerEndpointRuntime(
      clients: clients,
      connection: ServerConnection(authToken: nil),
      endpointId: UUID()
    )
  }

  deinit {
    selectionRequestContinuation.finish()
  }

  func session(_ sessionId: String) -> ServerSessionContext {
    if let existing = sessionsByID[sessionId]?.value {
      return existing
    }
    let context = ServerSessionContext(sessionId: sessionId, endpointRuntime: self)
    sessionsByID[sessionId] = SessionContextRef(context)
    return context
  }

  func removeSession(_ sessionId: String) {
    sessionsByID.removeValue(forKey: sessionId)
  }

  func requestSelection(_ ref: SessionRef) {
    selectionRequestContinuation.yield(ref)
  }

  func worktrees(for repoRoot: String) -> [ServerWorktreeSummary] {
    worktreesByRepo[repoRoot] ?? []
  }

  func clearServerError() {
    lastServerError = nil
  }

  func refreshCodexModels() {
    Task { codexModels = await (try? clients.usage.listCodexModels()) ?? codexModels }
  }

  func createSession(
    _ request: SessionsClient.CreateSessionRequest
  ) async throws -> SessionsClient.CreateSessionResponse {
    netLog(.info, cat: .store, "Create session", data: ["provider": request.provider, "cwd": request.cwd])
    return try await clients.sessions.createSession(request)
  }

  func startProcessingEvents() {
    guard connectionListenerToken == nil, eventProcessingTask == nil else { return }
    eventProcessingStartCount += 1
    netLog(.info, cat: .store, "Started endpoint event processing", data: ["endpointId": endpointId.uuidString])
    connectionListenerToken = connection.addListener { [weak self] event in
      self?.routeEvent(event)
    }
    eventProcessingTask = Task {}
  }

  func stopProcessingEvents() {
    eventProcessingTask?.cancel()
    eventProcessingTask = nil
    for session in activeSessions {
      session.transport.stopProcessingEvents()
    }
    if let connectionListenerToken {
      connection.removeListener(connectionListenerToken)
      self.connectionListenerToken = nil
    }
    netLog(.info, cat: .store, "Stopped endpoint event processing", data: ["endpointId": endpointId.uuidString])
  }

  func routeEvent(_ event: ServerEvent) {
    if routeCodexAccountEvent(event) || routeWorktreeEvent(event) {
      return
    }

    switch event {
      case let .modelsList(models):
        codexModels = models

      case let .serverInfo(isPrimary, claims):
        serverIsPrimary = isPrimary
        serverPrimaryClaims = claims

      case let .error(code, message, sessionId):
        if let sessionId, let session = sessionContext(for: sessionId) {
          session.transport.handleError(code, message)
        } else {
          handleEndpointError(code, message)
        }

      case let .connectionStatusChanged(status):
        handleConnectionStatusChanged(status)

      case let .sessionForked(sourceSessionId, _, _):
        sessionContext(for: sourceSessionId)?.transport.handleEvent(event)

      case let .sessionSurfaceInvalidated(sessionId, _, _),
           let .conversationRowsChanged(sessionId, _, _, _),
           let .revision(sessionId, _):
        sessionContext(for: sessionId)?.transport.handleEvent(event)

      default:
        break
    }
  }

  func applyCodexAccountStatus(_ status: ServerCodexAccountStatus) {
    codexAccountStatus = status
  }

  func applyCodexAuthError(_ message: String) {
    codexAuthError = message
  }

  private func routeCodexAccountEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case let .codexAccountStatus(status):
        applyCodexAccountStatus(status)
        return true
      case let .codexAccountUpdated(status):
        applyCodexAccountStatus(status)
        return true
      case .codexLoginChatgptStarted(_, _),
           .codexLoginChatgptCompleted(_, _, _),
           .codexLoginChatgptCanceled(_, _):
        return true
      default:
        return false
    }
  }

  private func routeWorktreeEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case let .worktreesList(_, repoRoot, _, worktrees):
        guard let repoRoot else { return true }
        worktreesByRepo[repoRoot] = worktrees
        return true
      case let .worktreeCreated(_, _, _, worktree):
        worktreesByRepo[worktree.repoRoot, default: []].append(worktree)
        return true
      case let .worktreeRemoved(_, repoRoot, _, worktreeId):
        worktreesByRepo[repoRoot]?.removeAll { $0.id == worktreeId }
        return true
      case let .worktreeStatusChanged(worktreeId, status, repoRoot):
        if var worktrees = worktreesByRepo[repoRoot],
           let index = worktrees.firstIndex(where: { $0.id == worktreeId })
        {
          worktrees[index].status = status
          worktreesByRepo[repoRoot] = worktrees
        }
        return true
      case .worktreeError(_, _, _):
        return true
      default:
        return false
    }
  }

  private func handleEndpointError(_ code: String, _ message: String) {
    netLog(.error, cat: .store, "Server error", data: ["code": code, "message": message])
    if code == "codex_auth_error" {
      applyCodexAuthError(message)
      return
    }
    lastServerError = (code: code, message: message)
  }

  private func handleConnectionStatusChanged(_ status: ConnectionStatus) {
    guard status == .connected else { return }
    for session in activeSessions {
      session.transport.handleConnectionStatusChanged(status)
    }
  }

  private var activeSessions: [ServerSessionContext] {
    sessionsByID = sessionsByID.filter { $0.value.value != nil }
    return sessionsByID.values.compactMap(\.value)
  }

  private func sessionContext(for sessionId: String) -> ServerSessionContext? {
    guard let reference = sessionsByID[sessionId] else { return nil }
    guard let session = reference.value else {
      sessionsByID.removeValue(forKey: sessionId)
      return nil
    }
    return session
  }
}
