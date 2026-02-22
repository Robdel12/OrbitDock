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

// MARK: - Timeline Source + UI State

nonisolated struct ConversationSourceState {
  var messages: [TranscriptMessage]
  var turns: [TurnSummary]
  var metadata: SessionMetadata

  nonisolated struct SessionMetadata: Hashable {
    var chatViewMode: ChatViewMode
    var isSessionActive: Bool
    var workStatus: Session.WorkStatus
    var currentTool: String?
    var pendingToolName: String?
    var pendingToolInput: String?
    var currentPrompt: String?
    var messageCount: Int
    var remainingLoadCount: Int
    var hasMoreMessages: Bool

    // Approval card fields
    var needsApprovalCard: Bool
    var approvalMode: ApprovalCardMode
    var pendingQuestion: String?
    var pendingApprovalId: String?
    var isDirectSession: Bool
    var sessionId: String?
    var projectPath: String?

    var shouldShowLiveIndicator: Bool {
      isSessionActive && (workStatus == .waiting || workStatus == .permission)
    }
  }

  init(
    messages: [TranscriptMessage] = [],
    turns: [TurnSummary] = [],
    metadata: SessionMetadata = .init(
      chatViewMode: .focused,
      isSessionActive: false,
      workStatus: .unknown,
      currentTool: nil,
      pendingToolName: nil,
      pendingToolInput: nil,
      currentPrompt: nil,
      messageCount: 0,
      remainingLoadCount: 0,
      hasMoreMessages: false,
      needsApprovalCard: false,
      approvalMode: .none,
      pendingQuestion: nil,
      pendingApprovalId: nil,
      isDirectSession: false,
      sessionId: nil,
      projectPath: nil
    )
  ) {
    self.messages = messages
    self.turns = turns
    self.metadata = metadata
  }
}

nonisolated struct ConversationUIState: Hashable, Sendable {
  var expandedToolCards: Set<String>
  var expandedRollups: Set<String>
  var expandedMarkdownBlocks: Set<String>
  var isPinnedToBottom: Bool
  var widthBucket: Int
  var scrollAnchor: ScrollAnchor?

  nonisolated struct ScrollAnchor: Hashable, Sendable {
    var rowID: TimelineRowID
    var deltaFromRowTop: Double
  }

  init(
    expandedToolCards: Set<String> = [],
    expandedRollups: Set<String> = [],
    expandedMarkdownBlocks: Set<String> = [],
    isPinnedToBottom: Bool = true,
    widthBucket: Int = 1,
    scrollAnchor: ScrollAnchor? = nil
  ) {
    self.expandedToolCards = expandedToolCards
    self.expandedRollups = expandedRollups
    self.expandedMarkdownBlocks = expandedMarkdownBlocks
    self.isPinnedToBottom = isPinnedToBottom
    self.widthBucket = widthBucket
    self.scrollAnchor = scrollAnchor
  }
}

// MARK: - Timeline Projection Types

nonisolated struct TimelineRowID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  init(stringLiteral value: StringLiteralType) {
    rawValue = value
  }

  static let loadMore: Self = "timeline:load-more"
  static let messageCount: Self = "timeline:message-count"
  static let liveIndicator: Self = "timeline:live-indicator"
  static let approvalCard: Self = "timeline:approval-card"
  static let bottomSpacer: Self = "timeline:bottom-spacer"

  static func message(_ messageID: String) -> Self {
    Self(rawValue: "timeline:message:\(messageID)")
  }

  static func turnHeader(_ turnID: String) -> Self {
    Self(rawValue: "timeline:turn-header:\(turnID)")
  }

  static func tool(_ toolID: String) -> Self {
    Self(rawValue: "timeline:tool:\(toolID)")
  }

  static func rollupSummary(_ rollupID: String) -> Self {
    Self(rawValue: "timeline:rollup-summary:\(rollupID)")
  }

  static func turnRollupKey(_ turnID: String) -> String {
    "timeline:turn-rollup:\(turnID)"
  }
}

nonisolated enum TimelineRowKind: Hashable, Sendable {
  case loadMore
  case messageCount
  case turnHeader
  case message
  case tool
  case rollupSummary
  case liveIndicator
  case approvalCard
  case bottomSpacer
}

/// Tool breakdown entry for rollup summary — groups tool usage by name.
nonisolated struct ToolBreakdownEntry: Hashable, Sendable {
  let name: String
  let icon: String
  let colorKey: String
  let count: Int
}

nonisolated enum TimelineRowPayload: Hashable, Sendable {
  case none
  case message(id: String)
  case turnHeader(turnID: String)
  case tool(id: String)
  case rollupSummary(
    id: String, hiddenCount: Int, totalToolCount: Int, isExpanded: Bool,
    breakdown: [ToolBreakdownEntry]
  )
  case approvalCard(mode: ApprovalCardMode)
}

nonisolated struct TimelineRow: Hashable, Sendable {
  let id: TimelineRowID
  let kind: TimelineRowKind
  let payload: TimelineRowPayload
  let layoutHash: Int
  let renderHash: Int

}

// MARK: - Projection + Diff Contract

nonisolated struct ProjectionResult: Hashable, Sendable {
  var rows: [TimelineRow]
  var diff: ProjectionDiff
  var dirtyRowIDs: Set<TimelineRowID>

  static let empty = ProjectionResult(rows: [], diff: .empty, dirtyRowIDs: [])
}

nonisolated struct ProjectionDiff: Hashable, Sendable {
  var insertions: [Int]
  var deletions: [Int]
  var moves: [ProjectionMove]
  var reloads: [Int]

  static let empty = ProjectionDiff(insertions: [], deletions: [], moves: [], reloads: [])
}

nonisolated struct ProjectionMove: Hashable, Sendable {
  let from: Int
  let to: Int
}
