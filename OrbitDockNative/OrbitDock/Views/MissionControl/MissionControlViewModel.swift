import Foundation

@MainActor
@Observable
final class MissionControlViewModel {
  var summary: MissionSummary?
  var issues: [MissionIssueItem] = []
  var settings: MissionSettings?
  var missionFileExists = true
  var missionFilePath: String?
  var workflowMigrationAvailable = false
  var isLoading = true
  var error: String?
  var selectedTab: MissionTab = .overview
  var showDeleteConfirmation = false
  var actionError: String?
  var nextTickAt: Date?
  var lastTickAt: Date?

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

  var dashboardConversationsBySessionId: [String: DashboardConversationRecord] {
    guard let runtimeRegistry, let endpointId = boundEndpointId else { return [:] }
    return runtimeRegistry.aggregatedDashboardConversations.reduce(into: [:]) { result, conversation in
      guard conversation.sessionRef.endpointId == endpointId else { return }
      result[conversation.sessionId] = conversation
    }
  }

  var missionDeltaRevision: UInt64 {
    sessionStore?.missionDeltaRevision ?? 0
  }

  var missionHeartbeatRevision: UInt64 {
    sessionStore?.missionHeartbeatRevision ?? 0
  }

  func applyDetail(_ response: MissionDetailResponse) {
    summary = response.summary
    issues = response.issues
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

  func applyLiveMissionDeltaIfNeeded() {
    guard let missionId = boundMissionId,
          let store = sessionStore,
          store.missionDeltaMissionId == missionId,
          let deltaSummary = store.missionDeltaSummary
    else { return }

    summary = deltaSummary
    issues = store.missionDeltaIssues
    lastTickAt = Date()
  }

  func applyMissionHeartbeatIfNeeded() {
    guard let missionId = boundMissionId,
          let store = sessionStore,
          store.missionDeltaMissionId == missionId
    else { return }

    nextTickAt = store.missionNextTickAt
    lastTickAt = store.missionLastTickAt
  }
}
