//
//  SessionStore.swift
//  OrbitDock
//
//  Per-endpoint session management: per-session observables, timeline row state,
//  subscription lifecycle, and event routing.
//  All mutations go via typed server clients (HTTP); events arrive from ServerConnection.
//

import Foundation

// MARK: - SessionStore

@Observable
@MainActor
final class SessionStore {
  nonisolated static func shouldAutoRefreshCodexAccount(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] == nil
      && environment["XCTestBundlePath"] == nil
      && environment["XCTestSessionIdentifier"] == nil
      && environment["ORBITDOCK_TEST_DB"] == nil
  }

  let clients: ServerClients
  let connection: ServerConnection
  let endpointId: UUID
  var endpointName: String?

  // MARK: - Observable state

  // MARK: - Mission Control live updates

  var missionListSnapshot: [MissionSummary] = []
  var missionDeltaMissionId: String?
  var missionDeltaSummary: MissionSummary?
  var missionDeltaIssues: [MissionIssueItem] = []
  var missionDeltaRevision: UInt64 = 0
  var missionNextTickAt: Date?
  var missionLastTickAt: Date?
  var missionHeartbeatRevision: UInt64 = 0

  var codexModels: [ServerCodexModelOption] = []
  var claudeModels: [ServerClaudeModelOption] = []
  var codexAccountStatus: ServerCodexAccountStatus?
  var codexAuthError: String?
  var lastServerError: (code: String, message: String)?
  var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]
  var serverIsPrimary: Bool?
  var serverPrimaryClaims: [ServerClientPrimaryClaim] = []
  let selectionRequests: AsyncStream<SessionRef>

  // MARK: - Per-session registries (not @Observable tracked)

  @ObservationIgnored var _sessionObservables: [String: SessionObservable] = [:]

  // MARK: - Private tracking

  @ObservationIgnored var lastRevision: [String: UInt64] = [:]
  @ObservationIgnored var controlStates: [String: SessionControlState] = [:]
  @ObservationIgnored var subscribedSessions: Set<String> = []
  @ObservationIgnored var autoMarkReadSessions: Set<String> = []
  @ObservationIgnored var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored var inFlightBootstraps: [String: Task<ServerConversationBootstrap?, Never>] = [:]
  @ObservationIgnored var reconnectTask: Task<Void, Never>?
  @ObservationIgnored var eventProcessingTask: Task<Void, Never>?
  @ObservationIgnored private(set) var eventProcessingStartCount = 0
  @ObservationIgnored private var connectionListenerToken: ServerConnectionListenerToken?
  @ObservationIgnored private let selectionRequestContinuation: AsyncStream<SessionRef>.Continuation

  /// Shared project file index for @ mention completions.
  let projectFileIndex = ProjectFileIndex()

  init(clients: ServerClients, connection: ServerConnection, endpointId: UUID, endpointName: String? = nil) {
    var selectionRequestContinuation: AsyncStream<SessionRef>.Continuation!
    self.selectionRequests = AsyncStream { selectionRequestContinuation = $0 }
    self.selectionRequestContinuation = selectionRequestContinuation
    self.clients = clients
    self.connection = connection
    self.endpointId = endpointId
    self.endpointName = endpointName
  }

  /// No-op instance for SwiftUI previews and tests — creates zero network connections.
  static func preview() -> SessionStore {
    let baseURL = URL(string: "http://127.0.0.1:3000")!
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: nil)
    let clients = ServerClients(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
    return SessionStore(
      clients: clients,
      connection: ServerConnection(authToken: nil),
      endpointId: UUID()
    )
  }

  deinit {
    selectionRequestContinuation.finish()
  }

  // MARK: - Per-session accessors

  func session(_ id: String) -> SessionObservable {
    if let existing = _sessionObservables[id] { return existing }
    let obs = SessionObservable(id: id)
    _sessionObservables[id] = obs
    return obs
  }

  func requestSelection(_ ref: SessionRef) {
    selectionRequestContinuation.yield(ref)
  }

  // MARK: - Event processing

  func startProcessingEvents() {
    guard connectionListenerToken == nil, eventProcessingTask == nil else { return }
    eventProcessingStartCount += 1
    netLog(.info, cat: .store, "Started event processing", data: ["endpointId": self.endpointId.uuidString])
    connectionListenerToken = connection.addListener { [weak self] event in
      self?.routeEvent(event)
    }
    // Mark as started so we don't add duplicate listeners
    eventProcessingTask = Task {}
  }

  func stopProcessingEvents() {
    eventProcessingTask?.cancel()
    eventProcessingTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    for task in inFlightBootstraps.values {
      task.cancel()
    }
    inFlightBootstraps.removeAll()
    if let connectionListenerToken {
      connection.removeListener(connectionListenerToken)
      self.connectionListenerToken = nil
    }
    netLog(.info, cat: .store, "Stopped event processing", data: ["endpointId": self.endpointId.uuidString])
  }

  // MARK: - Session subscription

  func subscribeToSession(_ sessionId: String) {
    guard subscribedSessions.insert(sessionId).inserted else {
      netLog(.debug, cat: .store, "Already subscribed, skipping", sid: sessionId)
      return
    }
    netLog(.info, cat: .store, "Subscribe: HTTP bootstrap + WS", sid: sessionId)

    Task {
      let bootstrap = await hydrateSessionFromHTTPBootstrap(sessionId: sessionId)
      let sinceRev = bootstrap?.session.revision
      netLog(.info, cat: .store, "WS subscribeSession", sid: sessionId, data: [
        "sinceRevision": sinceRev as Any,
        "bootstrapRowCount": bootstrap?.rows.count as Any,
        "connectionStatus": String(describing: connection.connectionStatus),
      ])
      connection.subscribeSession(
        sessionId,
        sinceRevision: sinceRev,
        includeSnapshot: false
      )
    }

    Task {
      do {
        let response = try await clients.approvals.listApprovals(sessionId: sessionId, limit: 200)
        session(sessionId).approvalHistory = response.approvals
      } catch {
        netLog(
          .error,
          cat: .store,
          "Load approvals failed",
          sid: sessionId,
          data: ["error": error.localizedDescription]
        )
      }
    }
  }

  @discardableResult
  func hydrateSessionFromHTTPBootstrap(
    sessionId: String
  ) async -> ServerConversationBootstrap? {
    if let existing = inFlightBootstraps[sessionId] {
      return await existing.value
    }

    let task = Task<ServerConversationBootstrap?, Never> {
      netLog(.info, cat: .conv, "Fetching bootstrap", sid: sessionId)
      do {
        let bootstrap = try await clients.conversation.fetchConversationBootstrap(sessionId, limit: 50)
        netLog(.info, cat: .conv, "Bootstrap fetched", sid: sessionId, data: ["rows": bootstrap.rows.count])

        handleConversationBootstrap(
          bootstrap.session,
          ServerConversationHistoryPage(
            rows: bootstrap.rows,
            totalRowCount: bootstrap.totalRowCount,
            hasMoreBefore: bootstrap.hasMoreBefore,
            oldestSequence: bootstrap.oldestSequence,
            newestSequence: bootstrap.newestSequence
          )
        )
        return bootstrap
      } catch {
        netLog(.error, cat: .conv, "Bootstrap fetch failed", sid: sessionId, data: ["error": error.localizedDescription])
        return nil
      }
    }

    inFlightBootstraps[sessionId] = task
    let result = await task.value
    inFlightBootstraps.removeValue(forKey: sessionId)
    return result
  }

  func unsubscribeFromSession(_ sessionId: String) {
    netLog(.info, cat: .store, "Unsubscribe", sid: sessionId)
    subscribedSessions.remove(sessionId)
    autoMarkReadSessions.remove(sessionId)
    inFlightBootstraps[sessionId]?.cancel()
    inFlightBootstraps.removeValue(forKey: sessionId)
    connection.unsubscribeSession(sessionId)
    trimInactiveSessionPayload(sessionId)
  }

  func isSessionSubscribed(_ sessionId: String) -> Bool {
    subscribedSessions.contains(sessionId)
  }

  // MARK: - Codex Account Actions

  func refreshCodexAccount() {
    guard Self.shouldAutoRefreshCodexAccount() else { return }
    Task {
      do {
        let status = try await clients.usage.readCodexAccount()
        codexAccountStatus = status
      } catch {
        netLog(.warning, cat: .store, "Refresh Codex account failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func startCodexChatgptLogin() {
    Task {
      do {
        let resp = try await clients.usage.startCodexLogin()
        if let url = URL(string: resp.authUrl) {
          _ = Platform.services.openURL(url)
        }
      } catch {
        codexAuthError = error.localizedDescription
      }
    }
  }

  func cancelCodexChatgptLogin() {
    guard let loginId = codexAccountStatus?.activeLoginId else { return }
    Task {
      do {
        try await clients.usage.cancelCodexLogin(loginId: loginId)
      } catch {
        netLog(.warning, cat: .store, "Cancel Codex login failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func logoutCodexAccount() {
    Task {
      do {
        let status = try await clients.usage.logoutCodexAccount()
        codexAccountStatus = status
      } catch {
        codexAuthError = error.localizedDescription
      }
    }
  }

  var isRemoteConnection: Bool {
    connection.isRemote
  }
}
