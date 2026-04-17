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
  let allowedTransitions: [OrchestrationState]
  let workStatus: String?
  let lastMessage: String?
  let prUrl: String?

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
    case allowedTransitions = "allowed_transitions"
    case workStatus = "work_status"
    case lastMessage = "last_message"
    case prUrl = "pr_url"
  }

  init(
    issueId: String,
    identifier: String,
    title: String,
    trackerState: String,
    orchestrationState: OrchestrationState,
    sessionId: String?,
    provider: String,
    attempt: UInt32,
    error: String?,
    url: String?,
    lastActivity: String?,
    startedAt: String?,
    completedAt: String?,
    allowedTransitions: [OrchestrationState],
    workStatus: String?,
    lastMessage: String?,
    prUrl: String?
  ) {
    self.issueId = issueId
    self.identifier = identifier
    self.title = title
    self.trackerState = trackerState
    self.orchestrationState = orchestrationState
    self.sessionId = sessionId
    self.provider = provider
    self.attempt = attempt
    self.error = error
    self.url = url
    self.lastActivity = lastActivity
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.allowedTransitions = allowedTransitions
    self.workStatus = workStatus
    self.lastMessage = lastMessage
    self.prUrl = prUrl
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    issueId = try container.decode(String.self, forKey: .issueId)
    identifier = try container.decode(String.self, forKey: .identifier)
    title = try container.decode(String.self, forKey: .title)
    trackerState = try container.decode(String.self, forKey: .trackerState)
    orchestrationState = try container.decode(OrchestrationState.self, forKey: .orchestrationState)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    provider = try container.decode(String.self, forKey: .provider)
    attempt = try container.decode(UInt32.self, forKey: .attempt)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    lastActivity = try container.decodeIfPresent(String.self, forKey: .lastActivity)
    startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
    completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    allowedTransitions = try container.decodeIfPresent([OrchestrationState].self, forKey: .allowedTransitions) ?? []
    workStatus = try container.decodeIfPresent(String.self, forKey: .workStatus)
    lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
    prUrl = try container.decodeIfPresent(String.self, forKey: .prUrl)
  }

  /// Extracts a short PR label like "#97" from a full GitHub PR URL.
  var prLabel: String? {
    guard let prUrl, let url = URL(string: prUrl) else { return nil }
    let parts = url.pathComponents
    // GitHub PR URLs: /owner/repo/pull/123
    if let pullIndex = parts.firstIndex(of: "pull"),
       pullIndex + 1 < parts.count
    {
      return "PR #\(parts[pullIndex + 1])"
    }
    return "PR"
  }

  /// Human-readable description of what the agent is currently doing.
  var activitySummary: String? {
    guard orchestrationState == .running || orchestrationState == .claimed else { return nil }
    if let msg = lastMessage, !msg.isEmpty {
      return msg
    }
    guard let ws = workStatus else { return nil }
    switch ws {
      case "working": return "Working..."
      case "waiting": return "Thinking..."
      case "permission": return "Awaiting approval"
      case "question": return "Has a question"
      case "reply": return "Waiting for input"
      default: return nil
    }
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

  /// Human-friendly label for transitioning TO this state.
  var transitionLabel: String {
    switch self {
      case .queued: "Reset"
      case .completed: "Mark Complete"
      case .failed: "Mark Failed"
      case .blocked: "Mark Blocked"
      case .claimed, .running, .retryQueued: displayLabel
    }
  }

  /// SF Symbol for the transition action.
  var transitionIcon: String {
    switch self {
      case .queued: "arrow.counterclockwise"
      case .completed: "checkmark.circle"
      case .failed: "xmark.circle"
      case .blocked: "hand.raised"
      case .claimed, .running: "play.circle"
      case .retryQueued: "arrow.clockwise"
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
