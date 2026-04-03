import Foundation

@MainActor
extension SessionStore {
  func routeMissionEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case .missionsList(_):
        return true
      case let .missionDelta(missionId, issues, summary):
        handleMissionDelta(missionId: missionId, issues: issues, summary: summary)
        return true
      case let .missionHeartbeat(missionId, tickStartedAt, nextTickAt):
        handleMissionHeartbeat(missionId: missionId, tickStartedAt: tickStartedAt, nextTickAt: nextTickAt)
        return true
      default:
        return false
    }
  }

  func handleMissionDelta(missionId: String, issues: [MissionIssueItem], summary: MissionSummary) {
    let observable = mission(missionId)
    observable.summary = summary
    observable.issues = issues
    observable.deltaRevision &+= 1
    observable.lastTickAt = Date()
  }

  func handleMissionHeartbeat(missionId: String, tickStartedAt: String, nextTickAt: String) {
    let observable = mission(missionId)
    observable.lastTickAt = parseServerDate(tickStartedAt)
    observable.nextTickAt = parseServerDate(nextTickAt)
    observable.heartbeatRevision &+= 1
  }

  private func parseServerDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
