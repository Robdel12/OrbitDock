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

  /// Per-mission observable from SessionStore. NOT @ObservationIgnored so SwiftUI
  /// can track changes through this reference (e.g. liveState.deltaRevision).
  private(set) var liveState: MissionObservable?

  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private var boundMissionId: String?
  @ObservationIgnored private var boundEndpointId: UUID?

  func bind(
    missionId: String,
    endpointId: UUID,
    runtimeRegistry: ServerRuntimeRegistry
  ) {
    self.boundMissionId = missionId
    self.boundEndpointId = endpointId
    self.runtimeRegistry = runtimeRegistry
    self.liveState = sessionStore?.mission(missionId)
  }

  var missionId: String? {
    boundMissionId
  }

  var endpointId: UUID? {
    boundEndpointId
  }

  var runtime: ServerRuntime? {
    guard let runtimeRegistry, let endpointId = boundEndpointId else { return nil }
    return runtimeRegistry.runtimesByEndpointId[endpointId] ?? runtimeRegistry.primaryRuntime ?? runtimeRegistry
      .activeRuntime
  }

  var http: ServerHTTPClient? {
    runtime?.clients.http
  }

  var missionsClient: MissionsClient? {
    runtime?.clients.missions
  }

  var sessionStore: SessionStore? {
    runtime?.sessionStore
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
    guard let missionId = boundMissionId else { return }
    guard let missionsClient else {
      error = "No server connection"
      isLoading = false
      return
    }

    let isInitialLoad = summary == nil
    if isInitialLoad { isLoading = true }
    do {
      let response = try await missionsClient.getMission(missionId)
      applyDetail(response)
    } catch {
      self.error = error.localizedDescription
    }
    if isInitialLoad { isLoading = false }
  }

  func updateMission(enabled: Bool? = nil, paused: Bool? = nil) async {
    guard let missionId = boundMissionId, let missionsClient else { return }
    do {
      let response = try await missionsClient.updateMissionDetail(
        missionId,
        enabled: enabled,
        paused: paused
      )
      applyDetail(response)
    } catch {
      actionError = error.localizedDescription
    }
  }

  func transitionIssue(
    issueId: String,
    targetState: OrchestrationState,
    reason: String? = nil
  ) async {
    guard let missionId = boundMissionId, let http else { return }
    do {
      var body: [String: String] = ["target_state": targetState.rawValue]
      if let reason, !reason.isEmpty {
        body["reason"] = reason
      }
      let response: MissionDetailResponse = try await http.post(
        "/api/missions/\(missionId)/issues/\(issueId)/transition",
        body: body
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

  func applyLiveDelta() {
    guard let liveState, let deltaSummary = liveState.summary else { return }
    summary = deltaSummary
    issues = liveState.issues
    lastTickAt = liveState.lastTickAt
  }

  func applyLiveHeartbeat() {
    guard let liveState else { return }
    nextTickAt = liveState.nextTickAt
    lastTickAt = liveState.lastTickAt
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
}
