import Foundation

@MainActor
@Observable
final class MissionControlViewModel {
  var summary: MissionSummary?
  var issues: [MissionIssueItem] = []
  var cleanupPrompt: MissionCleanupPrompt?
  var settings: MissionSettings?
  var missionFileExists = true
  var missionFilePath: String?
  var workflowMigrationAvailable = false
  var isLoading = true
  var error: String?
  var showDeleteConfirmation = false
  var showWorktreeCleanup = false
  var missionWorktrees: [MissionWorktreeItem] = []
  var isLoadingWorktrees = false
  var isCleaningWorktrees = false
  var actionError: String?
  var nextTickAt: Date?
  var lastTickAt: Date?

  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private var boundMissionId: String?
  @ObservationIgnored private var boundEndpointId: UUID?
  @ObservationIgnored private var realtimeSubscription: MissionRealtimeSubscription?
  @ObservationIgnored private let refreshDetailRunner = CoalescedRefreshRunner()
  @ObservationIgnored private static let serverDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  @ObservationIgnored private static let serverDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  func activate(
    missionId: String,
    endpointId: UUID,
    runtimeRegistry: ServerRuntimeRegistry
  ) async {
    bind(missionId: missionId, endpointId: endpointId, runtimeRegistry: runtimeRegistry)
    await refreshDetail()
  }

  func deactivate() {
    unbind()
  }

  func bind(
    missionId: String,
    endpointId: UUID,
    runtimeRegistry: ServerRuntimeRegistry
  ) {
    let didChangeMission = self.boundMissionId != missionId
    let didChangeEndpoint = self.boundEndpointId != endpointId
    let didChangeRuntimeRegistry = self.runtimeRegistry !== runtimeRegistry
    self.boundMissionId = missionId
    self.boundEndpointId = endpointId
    self.runtimeRegistry = runtimeRegistry
    if didChangeMission || didChangeEndpoint || didChangeRuntimeRegistry {
      refreshDetailRunner.cancel()
    }
    if didChangeEndpoint || didChangeRuntimeRegistry {
      detachRealtimeListener()
    }
    attachRealtimeListenerIfNeeded()
  }

  func unbind() {
    refreshDetailRunner.cancel()
    detachRealtimeListener()
    runtimeRegistry = nil
    boundMissionId = nil
    boundEndpointId = nil
  }

  var missionId: String? {
    boundMissionId
  }

  var endpointId: UUID? {
    boundEndpointId
  }

  var runtime: ServerRuntime? {
    guard let runtimeRegistry, let endpointId = boundEndpointId else { return nil }
    return runtimeRegistry.runtimesByEndpointId[endpointId]
  }

  var missionsClient: MissionsClient? {
    runtime?.clients.missions
  }

  var sessionsClient: SessionsClient? {
    runtime?.clients.sessions
  }

  func applyDetail(_ response: MissionDetailResponse) {
    summary = response.summary
    issues = response.issues
    cleanupPrompt = response.cleanupPrompt
    settings = response.settings
    missionFileExists = response.missionFileExists
    missionFilePath = response.missionFilePath
    workflowMigrationAvailable = response.workflowMigrationAvailable
    error = nil
  }

  func refreshDetail() async {
    requestDetailRefresh()
    await refreshDetailRunner.waitForCurrentRefresh()
  }

  private func requestDetailRefresh() {
    refreshDetailRunner.schedule { [weak self] in
      await self?.performDetailRefresh()
    }
  }

  private func performDetailRefresh() async {
    guard let missionId = boundMissionId else { return }
    guard let missionsClient else {
      error = "No server connection"
      isLoading = false
      return
    }

    let isInitialLoad = summary == nil
    let currentMissionId = missionId
    let currentEndpointId = boundEndpointId
    if isInitialLoad { isLoading = true }
    defer {
      if isInitialLoad,
         boundMissionId == currentMissionId,
         boundEndpointId == currentEndpointId
      {
        isLoading = false
      }
    }

    do {
      let response = try await missionsClient.getMission(currentMissionId)
      guard boundMissionId == currentMissionId, boundEndpointId == currentEndpointId else {
        return
      }
      applyDetail(response)
    } catch {
      guard boundMissionId == currentMissionId, boundEndpointId == currentEndpointId else {
        return
      }
      self.error = error.localizedDescription
    }
  }

  func updateMission(enabled: Bool? = nil, paused: Bool? = nil) async {
    guard let missionId = boundMissionId, let missionsClient else { return }
    do {
      let response = try await missionsClient.updateMission(
        missionId,
        enabled: enabled,
        paused: paused
      )
      applyDetail(response)
    } catch {
      actionError = error.localizedDescription
    }
  }

  func startOrchestrator() async {
    guard let missionId = boundMissionId, let missionsClient else { return }
    do {
      try await missionsClient.startOrchestrator(missionId)
      await refreshDetail()
    } catch {
      actionError = error.localizedDescription
    }
  }

  func triggerPoll() async {
    guard let missionId = boundMissionId, let missionsClient else { return }
    do {
      try await missionsClient.triggerPoll(missionId)
    } catch {
      actionError = error.localizedDescription
    }
  }

  func transitionIssue(
    issueId: String,
    targetState: OrchestrationState,
    reason: String? = nil
  ) async {
    guard let missionId = boundMissionId, let missionsClient else { return }
    do {
      let response = try await missionsClient.transitionIssue(
        missionId: missionId,
        issueId: issueId,
        targetState: targetState,
        reason: reason
      )
      applyDetail(response)
    } catch {
      actionError = error.localizedDescription
    }
  }

  func deleteMission() async -> Bool {
    guard let missionId = boundMissionId, let missionsClient else { return false }
    do {
      _ = try await missionsClient.deleteMission(missionId)
      return true
    } catch {
      actionError = error.localizedDescription
      return false
    }
  }

  private func attachRealtimeListenerIfNeeded() {
    guard let connection = runtime?.connection, let missionId = boundMissionId else { return }
    if let realtimeSubscription, realtimeSubscription.connection === connection {
      return
    }

    detachRealtimeListener()

    let token = connection.addListener { [weak self] event in
      guard let self else { return }
      self.handleRealtimeEvent(event)
    }
    realtimeSubscription = MissionRealtimeSubscription(connection: connection, token: token)

    if connection.connectionStatus == .connected {
      connection.subscribeMission(missionId)
    }
  }

  private func detachRealtimeListener() {
    if let missionId = boundMissionId {
      realtimeSubscription?.connection.unsubscribeMission(missionId)
    }
    guard let realtimeSubscription else { return }
    realtimeSubscription.connection.removeListener(realtimeSubscription.token)
    self.realtimeSubscription = nil
  }

  private func handleRealtimeEvent(_ event: ServerEvent) {
    guard let missionId = boundMissionId else { return }
    switch event {
      case let .missionHeartbeat(eventMissionId, tickStartedAt, nextTickAt) where eventMissionId == missionId:
        self.lastTickAt = parseServerDate(tickStartedAt)
        self.nextTickAt = parseServerDate(nextTickAt)

      case let .missionInvalidated(eventMissionId, _) where eventMissionId == missionId:
        scheduleDetailRefresh()

      case let .connectionStatusChanged(status):
        guard status == .connected else { return }
        runtime?.connection.resubscribeMission(missionId)
        scheduleDetailRefresh()

      default:
        break
    }
  }

  private func scheduleDetailRefresh() {
    requestDetailRefresh()
  }

  // MARK: - Worktree Cleanup

  func loadMissionWorktrees() async {
    guard let missionId = boundMissionId, let missionsClient else { return }
    isLoadingWorktrees = true
    do {
      missionWorktrees = try await missionsClient.listMissionWorktrees(missionId)
    } catch {
      actionError = error.localizedDescription
    }
    isLoadingWorktrees = false
  }

  func cleanupWorktrees(ids: Set<String>) async {
    guard let runtime else { return }
    isCleaningWorktrees = true
    let worktreesClient = runtime.clients.worktrees
    var errors: [String] = []
    for id in ids {
      do {
        try await worktreesClient.removeWorktree(
          worktreeId: id,
          force: true,
          deleteBranch: true
        )
      } catch {
        errors.append(error.localizedDescription)
      }
    }
    isCleaningWorktrees = false
    if !errors.isEmpty {
      actionError = errors.joined(separator: "\n")
    }
    await loadMissionWorktrees()
    await refreshDetail()
  }

  func presentWorktreeCleanup() async {
    showWorktreeCleanup = true
    await loadMissionWorktrees()
  }

  func confirmWorktreeCleanup(ids: Set<String>) async {
    await cleanupWorktrees(ids: ids)
    if missionWorktrees.isEmpty {
      showWorktreeCleanup = false
    }
  }

  private func parseServerDate(_ value: String) -> Date? {
    if let date = Self.serverDateFormatterWithFractionalSeconds.date(from: value) {
      return date
    }
    return Self.serverDateFormatter.date(from: value)
  }
}

private struct MissionRealtimeSubscription {
  let connection: any ServerEndpointRuntimeConnection
  let token: ServerConnectionListenerToken
}
