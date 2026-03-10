//
//  SessionStore.swift
//  OrbitDock
//
//  Session list, per-session observables, and event routing.
//  All mutations go via APIClient (HTTP); events arrive from EventStream.
//

import Foundation

let kConversationCacheMax = 8

// MARK: - SessionStore

@Observable
@MainActor
final class SessionStore {
  let apiClient: APIClient
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

  // MARK: - Per-session registries (not @Observable tracked)

  @ObservationIgnored var _sessionObservables: [String: SessionObservable] = [:]
  @ObservationIgnored var _conversationStores: [String: ConversationStore] = [:]
  @ObservationIgnored var conversationCache: [String: CachedConversation] = [:]

  // MARK: - Private tracking

  @ObservationIgnored var lastRevision: [String: UInt64] = [:]
  @ObservationIgnored var approvalPolicies: [String: String] = [:]
  @ObservationIgnored var sandboxModes: [String: String] = [:]
  @ObservationIgnored var permissionModes: [String: String] = [:]
  @ObservationIgnored var subscribedSessions: Set<String> = []
  @ObservationIgnored var autoMarkReadSessions: Set<String> = []
  @ObservationIgnored var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored var eventProcessingTask: Task<Void, Never>?

  /// Shared project file index for @ mention completions.
  let projectFileIndex = ProjectFileIndex()

  init(apiClient: APIClient, eventStream: EventStream, endpointId: UUID, endpointName: String? = nil) {
    self.apiClient = apiClient
    self.eventStream = eventStream
    self.endpointId = endpointId
    self.endpointName = endpointName
  }

  /// Convenience initializer for SwiftUI previews
  convenience init() {
    let url = URL(string: "http://127.0.0.1:3000")!
    self.init(
      apiClient: APIClient(serverURL: url, authToken: nil),
      eventStream: EventStream(authToken: nil),
      endpointId: UUID()
    )
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
    let store = ConversationStore(sessionId: id, apiClient: apiClient)
    _conversationStores[id] = store
    return store
  }

  // MARK: - Event processing

  func startProcessingEvents() {
    eventProcessingTask?.cancel()
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

    let conv = conversation(sessionId)

    if !forceRefresh, conv.hasReceivedInitialData {
      // Path 1: Retained snapshot — already have messages, just re-subscribe WS
      netLog(.info, cat: .store, "Subscribe: Path 1 — retained snapshot, re-subscribing WS", sid: sessionId)
      if recoveryGoal == .completeHistory {
        Task {
          _ = await conv.bootstrap(goal: recoveryGoal)
        }
      }
      eventStream.subscribeSession(
        sessionId,
        sinceRevision: nil,
        includeSnapshot: true
      )
    } else if !forceRefresh, let cached = conversationCache.removeValue(forKey: sessionId) {
      // Path 2: Cached messages — restore for instant display, subscribe for delta
      netLog(.info, cat: .store, "Subscribe: Path 2 — restoring from cache, WS + HTTP reconcile", sid: sessionId)
      conv.restoreFromCache(cached)
      eventStream.subscribeSession(
        sessionId,
        sinceRevision: lastRevision[sessionId],
        includeSnapshot: false
      )
      // Background reconcile via HTTP bootstrap
      Task {
        _ = await conv.bootstrap(goal: recoveryGoal)
      }
    } else {
      // Path 3: Bootstrap — fresh HTTP load, then subscribe
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

    // Fetch approval history
    Task {
      do {
        let response = try await apiClient.listApprovals(sessionId: sessionId, limit: 200)
        session(sessionId).approvalHistory = response.approvals
      } catch {
        netLog(.error, cat: .store, "Load approvals failed", sid: sessionId, data: ["error": error.localizedDescription])
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

  // MARK: - Codex Account Actions

  func refreshCodexAccount() {
    Task {
      do {
        let status = try await apiClient.readCodexAccount()
        codexAccountStatus = status
      } catch {
        netLog(.warning, cat: .store, "Refresh Codex account failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func startCodexChatgptLogin() {
    Task {
      do {
        let resp = try await apiClient.startCodexLogin()
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
        try await apiClient.cancelCodexLogin(loginId: loginId)
      } catch {
        netLog(.warning, cat: .store, "Cancel Codex login failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func logoutCodexAccount() {
    Task {
      do {
        let status = try await apiClient.logoutCodexAccount()
        codexAccountStatus = status
      } catch {
        codexAuthError = error.localizedDescription
      }
    }
  }
}
