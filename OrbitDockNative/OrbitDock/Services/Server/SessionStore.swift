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
  func failConnection(message: String)
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

typealias SessionSurfaceSet = Set<ServerSessionSurface>

// MARK: - SessionStore

// NOTE:
// SessionStore is a transport/recovery shell. Treat it as frozen for new
// product logic so we do not regrow a monolithic store.
// This is a legacy/dead-end integration layer: do not add new feature logic here.
// Do not add new business behavior here.
// Feature-owned projection/reducer logic belongs in the destination
// models/services (for example SessionObservable or MissionObservable), with
// SessionStore limited to wiring, bootstrap, subscription, and recovery.
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

  @ObservationIgnored var _missionObservables: [String: MissionObservable] = [:]

  var codexModels: [ServerCodexModelOption] = []
  var codexAccountStatus: ServerCodexAccountStatus?
  var codexAuthError: String?
  @ObservationIgnored lazy var codexAccountService = CodexAccountService(store: self)
  var lastServerError: (code: String, message: String)?
  var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]
  var serverIsPrimary: Bool?
  var serverPrimaryClaims: [ServerClientPrimaryClaim] = []
  let selectionRequests: AsyncStream<SessionRef>

  // MARK: - Per-session registries (not @Observable tracked)

  // MARK: - Per-session surface refresh signals

  @ObservationIgnored private var _sessionChangeContinuations: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

  /// Returns an AsyncStream that yields a value whenever a WS event arrives for this session.
  /// The stream ends when the returned task is cancelled or the caller stops iterating.
  func sessionChanges(for sessionId: String) -> (stream: AsyncStream<Void>, id: UUID) {
    let id = UUID()
    let stream = AsyncStream<Void> { continuation in
      if _sessionChangeContinuations[sessionId] == nil {
        _sessionChangeContinuations[sessionId] = [:]
      }
      _sessionChangeContinuations[sessionId]?[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?._sessionChangeContinuations[sessionId]?[id] = nil
        }
      }
    }
    return (stream, id)
  }

  /// Notify all surfaces listening for changes on this session. Called by WS event handlers.
  func notifySessionChanged(_ sessionId: String) {
    _sessionChangeContinuations[sessionId]?.values.forEach { $0.yield() }
  }

  // MARK: - Per-session conversation row delta stream

  struct ConversationRowDelta: Sendable {
    let upserted: [ServerConversationRowEntry]
    let removedIds: [String]
  }

  @ObservationIgnored private var _rowDeltaContinuations: [String: [UUID: AsyncStream<ConversationRowDelta>.Continuation]] = [:]

  /// Returns an AsyncStream that yields conversation row deltas as they arrive via WS.
  /// The conversation surface consumes this directly — rows are the one exception
  /// where WS carries data (small incremental deltas), not just a refresh signal.
  func conversationRowChanges(for sessionId: String) -> (stream: AsyncStream<ConversationRowDelta>, id: UUID) {
    let id = UUID()
    let stream = AsyncStream<ConversationRowDelta> { continuation in
      if _rowDeltaContinuations[sessionId] == nil {
        _rowDeltaContinuations[sessionId] = [:]
      }
      _rowDeltaContinuations[sessionId]?[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?._rowDeltaContinuations[sessionId]?[id] = nil
        }
      }
    }
    return (stream, id)
  }

  func notifyConversationRowDelta(_ sessionId: String, _ delta: ConversationRowDelta) {
    _rowDeltaContinuations[sessionId]?.values.forEach { $0.yield(delta) }
  }

  // MARK: - Private tracking

  @ObservationIgnored var lastRevision: [String: UInt64] = [:]
  @ObservationIgnored var lastSurfaceRevision: [String: [ServerSessionSurface: UInt64]] = [:]
  @ObservationIgnored var subscribedSessions: Set<String> = []
  @ObservationIgnored var subscribedSessionSurfaces: [String: SessionSurfaceSet] = [:]
  @ObservationIgnored var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored var connectionGeneration: UInt64 = 0
  @ObservationIgnored var inFlightBootstraps: [SessionGenerationKey: GenerationTask<SessionHTTPBootstrap?>] = [:]
  @ObservationIgnored var inFlightSessionRecoveries: [SessionGenerationKey: GenerationTask<Void>] = [:]
  @ObservationIgnored var recoveredSessionGenerations: [String: UInt64] = [:]
  @ObservationIgnored var recoveredSessionSurfaceGenerations: [String: [ServerSessionSurface: UInt64]] = [:]
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

  func subscribeToSession(
    _ sessionId: String,
    surfaces: SessionSurfaceSet = Set(ServerSessionSurface.allCases),
    forceRecovery: Bool = false
  ) {
    guard !surfaces.isEmpty else { return }
    let previousSurfaces = subscribedSessionSurfaces[sessionId] ?? []
    let requestedSurfaces = previousSurfaces.union(surfaces)
    let inserted = subscribedSessions.insert(sessionId).inserted
    if !inserted, requestedSurfaces == previousSurfaces, !forceRecovery {
      netLog(.debug, cat: .store, "Already subscribed, skipping", sid: sessionId)
      return
    }
    subscribedSessionSurfaces[sessionId] = requestedSurfaces
    if forceRecovery {
      recoveredSessionGenerations.removeValue(forKey: sessionId)
      removeRecoveredSurfaces(sessionId: sessionId, surfaces: requestedSurfaces)
    }
    netLog(.info, cat: .store, "Subscribe: HTTP bootstrap + WS", sid: sessionId, data: [
      "surfaces": requestedSurfaces.map(\.rawValue).sorted(),
      "forceRecovery": forceRecovery,
    ])

    Task {
      await ensureSessionRecovery(sessionId, generation: connectionGeneration)
    }

    if inserted {
      Task {
        do {
          _ = try await clients.approvals.listApprovals(sessionId: sessionId, limit: 200)
          notifySessionChanged(sessionId)
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

  func unsubscribeFromSession(
    _ sessionId: String,
    surfaces: SessionSurfaceSet? = nil
  ) {
    let knownSurfaces = subscribedSessionSurfaces[sessionId] ?? Set(ServerSessionSurface.allCases)
    let targetSurfaces = surfaces ?? knownSurfaces
    guard !targetSurfaces.isEmpty else { return }
    let removesEntireSubscription = targetSurfaces == knownSurfaces

    netLog(.info, cat: .store, "Unsubscribe", sid: sessionId, data: [
      "surfaces": targetSurfaces.map(\.rawValue).sorted(),
    ])

    var didClearSessionSubscription = false
    if var remainingSurfaces = subscribedSessionSurfaces[sessionId] {
      remainingSurfaces.subtract(targetSurfaces)
      if remainingSurfaces.isEmpty {
        didClearSessionSubscription = true
      } else {
        subscribedSessionSurfaces[sessionId] = remainingSurfaces
      }
    } else if removesEntireSubscription, subscribedSessions.contains(sessionId) {
      didClearSessionSubscription = true
    }

    if didClearSessionSubscription {
      subscribedSessionSurfaces.removeValue(forKey: sessionId)
      subscribedSessions.remove(sessionId)
      clearRecoveredSessionRecoveryState(sessionId: sessionId)
      lastOlderMessagesRequestBeforeSequence.removeValue(forKey: sessionId)
      cancelInFlightSessionTasks(sessionId)
      _sessionChangeContinuations.removeValue(forKey: sessionId)
      _rowDeltaContinuations.removeValue(forKey: sessionId)
    } else {
      removeRecoveredSurfaces(sessionId: sessionId, surfaces: targetSurfaces)
    }

    for surface in targetSurfaces {
      connection.unsubscribeSessionSurface(sessionId, surface: surface)
    }
  }

  func isSessionSubscribed(_ sessionId: String) -> Bool {
    subscribedSessions.contains(sessionId)
  }

  var isRemoteConnection: Bool {
    connection.isRemote
  }

  func ensureSessionRecovery(_ sessionId: String, generation: UInt64) async {
    let key = SessionGenerationKey(sessionId: sessionId, generation: generation)

    if sessionRecoveryComplete(sessionId: sessionId, generation: generation) {
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
      if let requestError = error as? ServerRequestError,
         requestError.isIncompatibleClientUpgradeRequired,
         case let .httpStatus(_, _, message) = requestError,
         let message,
         !message.isEmpty
      {
        connection.failConnection(message: message)
        netLog(
          .warning,
          cat: .conv,
          "HTTP bootstrap stopped by terminal request error",
          sid: sessionId,
          data: ["error": error.localizedDescription]
        )
        return nil
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

    guard connection.connectionStatus == .connected else {
      netLog(.debug, cat: .store, "Recovery waiting for active connection", sid: sessionId, data: [
        "generation": generation,
      ])
      return
    }

    let requestedSurfaces = requestedSurfaces(for: sessionId)
    guard !requestedSurfaces.isEmpty else { return }
    let recoveredSurfaceGenerations = recoveredSessionSurfaceGenerations[sessionId] ?? [:]
    let surfacesInOrder: [ServerSessionSurface] = [.detail, .composer, .conversation]
    let surfacesNeedingSubscribe = surfacesInOrder.filter {
      requestedSurfaces.contains($0) && recoveredSurfaceGenerations[$0] != generation
    }
    guard !surfacesNeedingSubscribe.isEmpty else {
      recoveredSessionGenerations[sessionId] = generation
      return
    }
    subscribeRecoveredSurfaces(
      sessionId: sessionId,
      generation: generation,
      bootstrap: bootstrap,
      surfaces: surfacesNeedingSubscribe
    )
  }

  private func sessionRecoveryComplete(sessionId: String, generation: UInt64) -> Bool {
    guard recoveredSessionGenerations[sessionId] == generation else { return false }
    let requestedSurfaces = requestedSurfaces(for: sessionId)
    guard !requestedSurfaces.isEmpty else { return false }
    let recoveredSurfaceGenerations = recoveredSessionSurfaceGenerations[sessionId] ?? [:]
    return requestedSurfaces.allSatisfy { recoveredSurfaceGenerations[$0] == generation }
  }

  private func requestedSurfaces(for sessionId: String) -> SessionSurfaceSet {
    subscribedSessionSurfaces[sessionId] ?? Set(ServerSessionSurface.allCases)
  }

  private func removeRecoveredSurfaces(sessionId: String, surfaces: SessionSurfaceSet) {
    guard var recoveredSurfaces = recoveredSessionSurfaceGenerations[sessionId] else { return }
    for surface in surfaces {
      recoveredSurfaces.removeValue(forKey: surface)
    }
    if recoveredSurfaces.isEmpty {
      recoveredSessionSurfaceGenerations.removeValue(forKey: sessionId)
      recoveredSessionGenerations.removeValue(forKey: sessionId)
    } else {
      recoveredSessionSurfaceGenerations[sessionId] = recoveredSurfaces
    }
  }

  private func clearRecoveredSessionRecoveryState(sessionId: String) {
    recoveredSessionGenerations.removeValue(forKey: sessionId)
    recoveredSessionSurfaceGenerations.removeValue(forKey: sessionId)
  }

  private func subscribeRecoveredSurfaces(
    sessionId: String,
    generation: UInt64,
    bootstrap: SessionHTTPBootstrap?,
    surfaces: [ServerSessionSurface]
  ) {
    let sharedRevision = bootstrap?.sharedSurfaceRevision
    var subscribeData: [String: Any] = [
      "surfaces": surfaces.map(\.rawValue).sorted(),
      "bootstrapRowCount": bootstrap?.conversation.rows.count as Any,
      "generation": generation,
      "connectionStatus": String(describing: connection.connectionStatus),
    ]
    if surfaces.contains(.detail) {
      subscribeData["detailRevision"] = sharedRevision as Any
    }
    if surfaces.contains(.composer) {
      subscribeData["composerRevision"] = sharedRevision as Any
    }
    if surfaces.contains(.conversation) {
      subscribeData["conversationRevision"] = sharedRevision as Any
    }
    netLog(.info, cat: .store, "WS subscribeSessionSurface", sid: sessionId, data: subscribeData)
    for surface in surfaces {
      connection.subscribeSessionSurface(sessionId, surface: surface, sinceRevision: sharedRevision)
    }
    var updatedRecoveredSurfaces = recoveredSessionSurfaceGenerations[sessionId] ?? [:]
    for surface in surfaces {
      updatedRecoveredSurfaces[surface] = generation
    }
    recoveredSessionSurfaceGenerations[sessionId] = updatedRecoveredSurfaces
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
