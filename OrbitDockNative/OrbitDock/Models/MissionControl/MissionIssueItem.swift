import Foundation

struct MissionIssueItem: Codable, Identifiable, Equatable {
  var id: String {
    issueId
  }

  let issueId: String
  let identifier: String
  let title: String
  let trackerState: String
  let orchestrationState: OrchestrationState
  let sessionId: String?
  let provider: String
  let attempt: UInt32
  let error: String?
  let url: String?
  let lastActivity: String?
  let startedAt: String?
  let completedAt: String?

  enum CodingKeys: String, CodingKey {
    case issueId = "issue_id"
    case identifier
    case title
    case trackerState = "tracker_state"
    case orchestrationState = "orchestration_state"
    case sessionId = "session_id"
    case provider
    case attempt
    case error
    case url
    case lastActivity = "last_activity"
    case startedAt = "started_at"
    case completedAt = "completed_at"
  }
}

enum OrchestrationState: String, Codable {
  case queued
  case claimed
  case running
  case retryQueued = "retry_queued"
  case completed
  case failed
  case blocked

  var displayLabel: String {
    switch self {
      case .queued: "Queued"
      case .claimed: "Claimed"
      case .running: "Running"
      case .retryQueued: "Retry Queued"
      case .completed: "Completed"
      case .failed: "Failed"
      case .blocked: "Blocked"
    }
  }
}

import SwiftUI

extension MissionIssueItem {
  var providerColor: Color {
    provider == "codex" ? Color.feedbackPositive : Color.accent
  }
}

extension OrchestrationState {
  var color: Color {
    switch self {
      case .queued, .retryQueued: Color.feedbackCaution
      case .claimed, .running: Color.statusWorking
      case .completed: Color.feedbackPositive
      case .failed: Color.feedbackNegative
      case .blocked: Color.feedbackWarning
    }
  }
}
