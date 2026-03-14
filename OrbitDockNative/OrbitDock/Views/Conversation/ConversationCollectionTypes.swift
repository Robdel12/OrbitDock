//
//  ConversationCollectionTypes.swift
//  OrbitDock
//
//  Shared timeline domain and identifier types for ConversationCollectionView.
//  Keep these `nonisolated` so they can remain Hashable/Sendable under the
//  project's default @MainActor isolation.
//

import Foundation

// MARK: - Diffable Data Source Section

nonisolated enum ConversationSection: Hashable, Sendable {
  case main
}

// MARK: - Approval Card Mode

nonisolated enum ApprovalCardMode: Hashable, Sendable {
  case permission // Direct session needing tool approval
  case question // Direct session with pending question
  case takeover // Passive session with pending approval
  case none // No approval needed
}

// MARK: - Card Position

/// Position of a row within a turn card — determines corner rounding.
nonisolated enum CardPosition: Hashable, Sendable {
  case none    // Not part of a card
  case top     // Top of card (top corners rounded)
  case middle  // Middle of card (no rounding)
  case bottom  // Bottom of card (bottom corners rounded)
  case solo    // Single-row card (all corners rounded)
}

nonisolated struct TimelineRowID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  init(stringLiteral value: StringLiteralType) {
    rawValue = value
  }

  static let loadMore: Self = "timeline:load-more"
  static let liveIndicator: Self = "timeline:live-indicator"
  static let approvalCard: Self = "timeline:approval-card"
  static let bottomSpacer: Self = "timeline:bottom-spacer"
  static func workerOrchestration(_ turnID: String) -> Self {
    Self(rawValue: "timeline:workers:\(turnID)")
  }

  static func message(_ messageID: String) -> Self {
    Self(rawValue: "timeline:message:\(messageID)")
  }

  static func tool(_ toolID: String) -> Self {
    Self(rawValue: "timeline:tool:\(toolID)")
  }

  static func workerEvent(_ messageID: String) -> Self {
    Self(rawValue: "timeline:worker-event:\(messageID)")
  }

  static func activitySummary(_ anchorID: String) -> Self {
    Self(rawValue: "timeline:activity:\(anchorID)")
  }

}

nonisolated struct ConversationJumpTarget: Equatable, Sendable {
  let messageID: String
  let nonce: Int
}

nonisolated enum TimelineRowKind: Hashable, Sendable {
  case loadMore
  case message
  case tool
  case workerEvent
  case activitySummary
  case liveIndicator
  case approvalCard
  case workerOrchestration
  case bottomSpacer
}

nonisolated enum TimelineRowPayload: Hashable, Sendable {
  case none
  case message(id: String, showHeader: Bool)
  case tool(id: String)
  case workerEvent(id: String)
  case activitySummary(anchorID: String, messageIDs: [String], isExpanded: Bool)
  case approvalCard(mode: ApprovalCardMode)
  case workerOrchestration(turnID: String, workerIDs: [String])
}

nonisolated struct ConversationTimelineExpansionState: Hashable, Sendable {
  var expandedActivityGroupIDs: Set<String> = []
}

nonisolated struct TimelineRow: Hashable, Sendable {
  let id: TimelineRowID
  let kind: TimelineRowKind
  let payload: TimelineRowPayload
  let layoutHash: Int
  let renderHash: Int
}
