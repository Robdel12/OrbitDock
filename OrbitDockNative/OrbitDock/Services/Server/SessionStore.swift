//
//  SessionStore.swift
//  OrbitDock
//
//  Session list, per-session observables, and event routing.
//  All mutations go via typed server clients (HTTP); events arrive from EventStream.
//

import Foundation

let kConversationCacheMax = 8

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
  let eventStream: EventStream
  let endpointId: UUID
  var endpointName: String?

  // MARK: - Observable state

  var sessions: [Session] = []
  var hasReceivedInitialSessionsList = false
  var codexModels: [ServerCodexModelOption] = []
  var claudeModels: [ServerClaudeModelOption] = []
  var codexAccountStatus: ServerCodexAccountStatus?
  var codexAuthError: String?
  var lastServerError: (code: String, message: String)?
  var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]
  var serverIsPrimary: Bool?
  var serverPrimaryClaims: [ServerClientPrimaryClaim] = []
  let initialSessionsListUpdates: AsyncStream<Bool>
  let sessionListUpdates: AsyncStream<Void>
  let selectionRequests: AsyncStream<SessionRef>

  // MARK: - Per-session registries (not @Observable tracked)

  @ObservationIgnored var _sessionObservables: [String: SessionObservable] = [:]
  @ObservationIgnored var _conversationStores: [String: ConversationStore] = [:]
  @ObservationIgnored var conversationCache: [String: CachedConversation] = [:]

  // MARK: - Private tracking

  @ObservationIgnored var lastRevision: [String: UInt64] = [:]
  @ObservationIgnored var controlStates: [String: SessionControlState] = [:]
  @ObservationIgnored var subscribedSessions: Set<String> = []
  @ObservationIgnored var autoMarkReadSessions: Set<String> = []
  @ObservationIgnored var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored var eventProcessingTask: Task<Void, Never>?
  @ObservationIgnored private(set) var eventProcessingStartCount = 0
  @ObservationIgnored private let initialSessionsListContinuation: AsyncStream<Bool>.Continuation
  @ObservationIgnored private let sessionListContinuation: AsyncStream<Void>.Continuation
  @ObservationIgnored private let selectionRequestContinuation: AsyncStream<SessionRef>.Continuation

  /// Shared project file index for @ mention completions.
  let projectFileIndex = ProjectFileIndex()

  init(clients: ServerClients, eventStream: EventStream, endpointId: UUID, endpointName: String? = nil) {
    var initialSessionsListContinuation: AsyncStream<Bool>.Continuation!
    var sessionListContinuation: AsyncStream<Void>.Continuation!
    var selectionRequestContinuation: AsyncStream<SessionRef>.Continuation!
    self.initialSessionsListUpdates = AsyncStream { initialSessionsListContinuation = $0 }
    self.sessionListUpdates = AsyncStream { sessionListContinuation = $0 }
    self.selectionRequests = AsyncStream { selectionRequestContinuation = $0 }
    self.initialSessionsListContinuation = initialSessionsListContinuation
    self.sessionListContinuation = sessionListContinuation
    self.selectionRequestContinuation = selectionRequestContinuation
    self.clients = clients
    self.eventStream = eventStream
    self.endpointId = endpointId
    self.endpointName = endpointName
  }

  /// Convenience initializer for SwiftUI previews
  convenience init() {
    let url = URL(string: "http://127.0.0.1:3000")!
    self.init(
      clients: ServerClients(serverURL: url, authToken: nil),
      eventStream: EventStream(authToken: nil),
      endpointId: UUID()
    )
  }

  deinit {
    initialSessionsListContinuation.finish()
    sessionListContinuation.finish()
    selectionRequestContinuation.finish()
  }

  // MARK: - Per-session accessors

  func session(_ id: String) -> SessionObservable {
    if let existing = _sessionObservables[id] { return existing }
    let obs = SessionObservable(id: id)
    _sessionObservables[id] = obs
    return obs
  }

  func conversation(_ id: String) -> ConversationStore {
    if let existing = _conversationStores[id] { return existing }
    let store = ConversationStore(sessionId: id, endpointId: endpointId, clients: clients)
    _conversationStores[id] = store
    return store
  }

  func setHasReceivedInitialSessionsList(_ hasReceived: Bool) {
    guard hasReceivedInitialSessionsList != hasReceived else { return }
    hasReceivedInitialSessionsList = hasReceived
    initialSessionsListContinuation.yield(hasReceived)
  }

  func emitSessionListUpdate() {
    sessionListContinuation.yield()
  }

  func requestSelection(_ ref: SessionRef) {
    selectionRequestContinuation.yield(ref)
  }

  // MARK: - Event processing

  func startProcessingEvents() {
    guard eventProcessingTask == nil else { return }
    eventProcessingStartCount += 1
    netLog(.info, cat: .store, "Started event processing", data: ["endpointId": self.endpointId.uuidString])
    eventProcessingTask = Task { [weak self] in
      guard let self else { return }
      for await event in eventStream.events {
        guard !Task.isCancelled else { break }
        self.routeEvent(event)
      }
    }
  }

  func stopProcessingEvents() {
    guard eventProcessingTask != nil else { return }
    eventProcessingTask?.cancel()
    eventProcessingTask = nil
    netLog(.info, cat: .store, "Stopped event processing", data: ["endpointId": self.endpointId.uuidString])
  }

  // MARK: - Session subscription

  func subscribeToSession(
    _ sessionId: String,
    forceRefresh: Bool = false,
    recoveryGoal: ConversationRecoveryGoal = .coherentRecent
  ) {
    subscribedSessions.insert(sessionId)
    loadSessionSnapshot(sessionId)

    let conv = conversation(sessionId)

    let plan = SessionFeedPlanner.subscriptionPlan(
      forceRefresh: forceRefresh,
      hasInitialConversationData: conv.hasReceivedInitialData,
      hasCachedConversation: conversationCache[sessionId] != nil,
      recoveryGoal: recoveryGoal
    )

    switch plan.strategy {
      case .retainedSnapshot:
        netLog(.info, cat: .store, "Subscribe: Path 1 — retained snapshot, re-subscribing WS", sid: sessionId)
        if let goal = plan.deferredBootstrapGoal {
          Task {
            _ = await conv.bootstrap(goal: goal)
          }
        }
        eventStream.subscribeSession(
          sessionId,
          sinceRevision: nil,
          includeSnapshot: false
        )

      case .cachedSnapshot:
        netLog(.info, cat: .store, "Subscribe: Path 2 — restoring from cache, WS + HTTP reconcile", sid: sessionId)
        if let cached = conversationCache.removeValue(forKey: sessionId) {
          conv.restoreFromCache(cached)
        }
        eventStream.subscribeSession(
          sessionId,
          sinceRevision: lastRevision[sessionId],
          includeSnapshot: false
        )
        if let goal = plan.deferredBootstrapGoal {
          Task {
            _ = await conv.bootstrap(goal: goal)
          }
        }

      case .freshBootstrap:
        netLog(.info, cat: .store, "Subscribe: Path 3 — fresh HTTP bootstrap", sid: sessionId)
        Task {
          let revision = await conv.bootstrap(goal: recoveryGoal)
          eventStream.subscribeSession(
            sessionId,
            sinceRevision: revision,
            includeSnapshot: false
          )
        }
    }

    if plan.shouldFetchApprovals {
      Task {
        do {
          let response = try await clients.approvals.listApprovals(sessionId: sessionId, limit: 200)
          session(sessionId).approvalHistory = response.approvals
        } catch {
          netLog(.error, cat: .store, "Load approvals failed", sid: sessionId, data: ["error": error.localizedDescription])
        }
      }
    }
  }

  func unsubscribeFromSession(_ sessionId: String) {
    netLog(.info, cat: .store, "Unsubscribe", sid: sessionId)
    subscribedSessions.remove(sessionId)
    autoMarkReadSessions.remove(sessionId)
    eventStream.unsubscribeSession(sessionId)
    cacheConversationBeforeTrim(sessionId: sessionId)
    trimInactiveSessionPayload(sessionId)
  }

  func isSessionSubscribed(_ sessionId: String) -> Bool {
    subscribedSessions.contains(sessionId)
  }

  private func loadSessionSnapshot(_ sessionId: String) {
    Task {
      do {
        let snapshot = try await clients.sessions.fetchSessionSnapshot(sessionId)
        handleSessionSnapshot(snapshot)
      } catch {
        netLog(.warning, cat: .store, "Load session snapshot failed", sid: sessionId, data: ["error": error.localizedDescription])
      }
    }
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
}
