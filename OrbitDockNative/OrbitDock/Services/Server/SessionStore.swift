//
//  SessionStore.swift
//  OrbitDock
//
//  Per-endpoint session management: per-session observables, timeline row state,
//  subscription lifecycle, and event routing.
//  All mutations go via typed server clients (HTTP); events arrive from ServerConnection.
//

import Foundation

@MainActor
protocol SessionStoreConnection: AnyObject {
  var connectionStatus: ConnectionStatus { get }
  var isRemote: Bool { get }

  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken
  func removeListener(_ token: ServerConnectionListenerToken)
  func subscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface, sinceRevision: UInt64?)
  func unsubscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface)
  func failCompatibility(message: String)
}

extension ServerConnection: SessionStoreConnection {}

struct SessionGenerationKey: Hashable {
  let sessionId: String
  let generation: UInt64
}

struct GenerationTask<Value> {
  let generation: UInt64
  let task: Task<Value, Never>
}

struct SessionHTTPBootstrap {
  let conversation: ServerConversationBootstrap

  var sharedSurfaceRevision: UInt64? {
    conversation.session.revision
  }
}

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
  let connection: any SessionStoreConnection
  let endpointId: UUID
  var endpointName: String?

  // MARK: - Observable state

  // MARK: - Mission Control live updates

  var missionListSnapshot: [MissionSummary] = []
  @ObservationIgnored var _missionObservables: [String: MissionObservable] = [:]

  var codexModels: [ServerCodexModelOption] = []
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
  @ObservationIgnored var lastSurfaceRevision: [String: [ServerSessionSurface: UInt64]] = [:]
  @ObservationIgnored var controlStates: [String: SessionControlState] = [:]
  @ObservationIgnored var subscribedSessions: Set<String> = []
  @ObservationIgnored var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored var connectionGeneration: UInt64 = 0
  @ObservationIgnored var inFlightBootstraps: [SessionGenerationKey: GenerationTask<SessionHTTPBootstrap?>] = [:]
  @ObservationIgnored var inFlightSessionRecoveries: [SessionGenerationKey: GenerationTask<Void>] = [:]
  @ObservationIgnored var recoveredSessionGenerations: [String: UInt64] = [:]
  @ObservationIgnored var lastOlderMessagesRequestBeforeSequence: [String: UInt64] = [:]
  @ObservationIgnored var _localNamingClaimedSessions: Set<String> = []
  @ObservationIgnored var connectionRecoveryTask: GenerationTask<Void>?
  @ObservationIgnored var eventProcessingTask: Task<Void, Never>?
  @ObservationIgnored private(set) var eventProcessingStartCount = 0
  @ObservationIgnored private var connectionListenerToken: ServerConnectionListenerToken?
  @ObservationIgnored private let selectionRequestContinuation: AsyncStream<SessionRef>.Continuation

  /// Shared project file index for @ mention completions.
  let projectFileIndex = ProjectFileIndex()

  init(clients: ServerClients, connection: any SessionStoreConnection, endpointId: UUID, endpointName: String? = nil) {
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

  func mission(_ id: String) -> MissionObservable {
    if let existing = _missionObservables[id] { return existing }
    let obs = MissionObservable(missionId: id)
    _missionObservables[id] = obs
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
    connectionRecoveryTask?.task.cancel()
    connectionRecoveryTask = nil
    for task in inFlightBootstraps.values {
      task.task.cancel()
    }
    inFlightBootstraps.removeAll()
    for task in inFlightSessionRecoveries.values {
      task.task.cancel()
    }
    inFlightSessionRecoveries.removeAll()
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
      await ensureSessionRecovery(sessionId, generation: connectionGeneration)
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
    sessionId: String,
    generation: UInt64? = nil
  ) async -> SessionHTTPBootstrap? {
    let targetGeneration = generation ?? connectionGeneration
    let key = SessionGenerationKey(sessionId: sessionId, generation: targetGeneration)

    if let existing = inFlightBootstraps[key] {
      return await existing.task.value
    }

    let task = Task<SessionHTTPBootstrap?, Never> { [weak self] in
      guard let self else { return nil }
      return await self.loadSessionBootstrap(sessionId: sessionId, generation: targetGeneration)
    }

    inFlightBootstraps[key] = GenerationTask(generation: targetGeneration, task: task)
    let result = await task.value
    inFlightBootstraps.removeValue(forKey: key)
    return result
  }

  func unsubscribeFromSession(_ sessionId: String) {
    netLog(.info, cat: .store, "Unsubscribe", sid: sessionId)
    subscribedSessions.remove(sessionId)
    recoveredSessionGenerations.removeValue(forKey: sessionId)
    lastOlderMessagesRequestBeforeSequence.removeValue(forKey: sessionId)
    cancelInFlightSessionTasks(sessionId)
    connection.unsubscribeSessionSurface(sessionId, surface: .detail)
    connection.unsubscribeSessionSurface(sessionId, surface: .composer)
    connection.unsubscribeSessionSurface(sessionId, surface: .conversation)
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

  func ensureSessionRecovery(_ sessionId: String, generation: UInt64) async {
    let key = SessionGenerationKey(sessionId: sessionId, generation: generation)

    if recoveredSessionGenerations[sessionId] == generation {
      netLog(.debug, cat: .store, "Session already recovered for generation", sid: sessionId, data: [
        "generation": generation,
      ])
      return
    }

    if let existing = inFlightSessionRecoveries[key] {
      await existing.task.value
      return
    }

    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.performSessionRecovery(sessionId: sessionId, generation: generation)
    }

    inFlightSessionRecoveries[key] = GenerationTask(generation: generation, task: task)
    await task.value
    inFlightSessionRecoveries.removeValue(forKey: key)
  }

  private func loadSessionBootstrap(sessionId: String, generation: UInt64) async -> SessionHTTPBootstrap? {
    netLog(.info, cat: .conv, "Fetching HTTP session bootstrap", sid: sessionId, data: [
      "generation": generation,
    ])
    do {
      let conversationBootstrap = try await clients.conversation.fetchConversationBootstrap(
        sessionId,
        limit: 50
      )
      let bootstrap = SessionHTTPBootstrap(
        conversation: conversationBootstrap
      )
      guard subscribedSessions.contains(sessionId), connectionGeneration == generation else {
        netLog(.debug, cat: .conv, "HTTP bootstrap became stale before apply", sid: sessionId, data: [
          "generation": generation,
          "currentGeneration": connectionGeneration,
          "subscribed": subscribedSessions.contains(sessionId),
          "rows": bootstrap.conversation.rows.count,
        ])
        return nil
      }

      netLog(.info, cat: .conv, "HTTP bootstrap fetched", sid: sessionId, data: [
        "sharedRevision": bootstrap.sharedSurfaceRevision as Any,
        "rows": bootstrap.conversation.rows.count,
        "generation": generation,
      ])

      let snapshotRevision = bootstrap.sharedSurfaceRevision ?? 0
      let snapshot = ServerSessionDetailSnapshotPayload(
        revision: snapshotRevision,
        session: bootstrap.conversation.session
      )
      handleSessionDetailSnapshot(snapshot)
      handleSessionComposerSnapshot(
        ServerSessionComposerSnapshotPayload(
          revision: snapshotRevision,
          session: bootstrap.conversation.session
        )
      )
      handleConversationBootstrap(
        bootstrap.conversation.session,
        ServerConversationHistoryPage(
          rows: bootstrap.conversation.rows,
          totalRowCount: bootstrap.conversation.totalRowCount,
          hasMoreBefore: bootstrap.conversation.hasMoreBefore,
          oldestSequence: bootstrap.conversation.oldestSequence,
          newestSequence: bootstrap.conversation.newestSequence
        )
      )
      return bootstrap
    } catch {
      if let message = ServerContractGuard.compatibilityMessage(
        for: error,
        surface: "session bootstrap"
      ) {
        connection.failCompatibility(message: message)
      }
      netLog(
        .error,
        cat: .conv,
        "HTTP bootstrap fetch failed",
        sid: sessionId,
        data: ["error": error.localizedDescription]
      )
      return nil
    }
  }

  private func performSessionRecovery(sessionId: String, generation: UInt64) async {
    guard subscribedSessions.contains(sessionId) else { return }

    let bootstrap = await hydrateSessionFromHTTPBootstrap(sessionId: sessionId, generation: generation)
    guard subscribedSessions.contains(sessionId), connectionGeneration == generation else {
      netLog(.debug, cat: .store, "Recovery became stale before subscribe", sid: sessionId, data: [
        "generation": generation,
        "currentGeneration": connectionGeneration,
        "subscribed": subscribedSessions.contains(sessionId),
      ])
      return
    }

    guard recoveredSessionGenerations[sessionId] != generation else { return }
    guard connection.connectionStatus == .connected else {
      netLog(.debug, cat: .store, "Recovery waiting for active connection", sid: sessionId, data: [
        "generation": generation,
      ])
      return
    }

    let detailRevision = bootstrap?.sharedSurfaceRevision
    let composerRevision = bootstrap?.sharedSurfaceRevision
    let conversationRevision = bootstrap?.sharedSurfaceRevision
    netLog(.info, cat: .store, "WS subscribeSessionSurface", sid: sessionId, data: [
      "detailRevision": detailRevision as Any,
      "composerRevision": composerRevision as Any,
      "conversationRevision": conversationRevision as Any,
      "bootstrapRowCount": bootstrap?.conversation.rows.count as Any,
      "generation": generation,
      "connectionStatus": String(describing: connection.connectionStatus),
    ])
    connection.subscribeSessionSurface(sessionId, surface: .detail, sinceRevision: detailRevision)
    connection.subscribeSessionSurface(sessionId, surface: .composer, sinceRevision: composerRevision)
    connection.subscribeSessionSurface(sessionId, surface: .conversation, sinceRevision: conversationRevision)
    recoveredSessionGenerations[sessionId] = generation
  }

  private func cancelInFlightSessionTasks(_ sessionId: String) {
    let bootstrapKeys = inFlightBootstraps.keys.filter { $0.sessionId == sessionId }
    for key in bootstrapKeys {
      inFlightBootstraps[key]?.task.cancel()
      inFlightBootstraps.removeValue(forKey: key)
    }

    let recoveryKeys = inFlightSessionRecoveries.keys.filter { $0.sessionId == sessionId }
    for key in recoveryKeys {
      inFlightSessionRecoveries[key]?.task.cancel()
      inFlightSessionRecoveries.removeValue(forKey: key)
    }
  }
}
