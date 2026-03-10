//
//  ConversationUtilityRowModels.swift
//  OrbitDock
//
//  Shared presentation builders for utility rows rendered on both macOS and iOS.
//  Keeps formatting and semantic state in one place so the platform cells stay
//  as thin view renderers instead of growing separate display logic.
//

import Foundation
import SwiftUI

nonisolated enum ConversationUtilityRowModels {
  nonisolated enum ColorKey: Hashable, Sendable {
    case accent
    case textPrimary
    case textSecondary
    case textTertiary
    case textQuaternary
    case search
    case write
    case bash
    case task
    case web
    case todo
    case plan
    case working
    case steer
    case reply
    case permission
  }

  nonisolated enum BarStyle: Hashable, Sendable {
    case none
    case orbiting(ColorKey, secondary: ColorKey? = nil)
    case holding(ColorKey)
    case parked(ColorKey)
  }

  nonisolated enum DetailStyle: Hashable, Sendable {
    case none
    case regular
    case monospaced
    case emphasis
  }

  nonisolated struct TurnHeaderModel: Hashable, Sendable {
    let labelText: String?
    let toolsText: String?

    var isHidden: Bool { labelText == nil }
  }

  nonisolated struct RollupSummaryModel: Hashable, Sendable {
    let summaryText: String
    let symbolName: String
    let colorKey: ColorKey
    let durationText: String?
    let chevronName: String
    let isExpanded: Bool
  }

  nonisolated struct LiveIndicatorModel: Hashable, Sendable {
    let barStyle: BarStyle
    let iconName: String?
    let iconColorKey: ColorKey?
    let primaryText: String
    let primaryColorKey: ColorKey
    let detailText: String?
    let detailStyle: DetailStyle
    let detailColorKey: ColorKey
  }

  nonisolated struct CollapsedTurnModel: Hashable, Sendable {
    let userPreview: String
    let assistantPreview: String
    let statsText: String
  }

  nonisolated struct LiveProgressModel: Hashable, Sendable {
    let operationText: String
    let statsText: String
  }

  @MainActor
  static func color(for key: ColorKey) -> Color {
    switch key {
      case .accent: .accent
      case .textPrimary: .textPrimary
      case .textSecondary: .textSecondary
      case .textTertiary: .textTertiary
      case .textQuaternary: .textQuaternary
      case .search: .toolSearch
      case .write: .toolWrite
      case .bash: .toolBash
      case .task: .toolTask
      case .web: .toolWeb
      case .todo: .toolTodo
      case .plan: .toolPlan
      case .working: .statusWorking
      case .steer: .composerSteer
      case .reply: .statusReply
      case .permission: .statusPermission
    }
  }

  static func turnHeader(for turn: TurnSummary) -> TurnHeaderModel {
    guard turn.turnNumber > 1 else {
      return TurnHeaderModel(labelText: nil, toolsText: nil)
    }

    var labelText = "TURN \(turn.turnNumber)"
    if let relativeTime = relativeTimeText(from: turn.startTimestamp) {
      labelText += " · \(relativeTime)"
    }

    let toolsText: String? = if turn.toolsUsed.isEmpty {
      nil
    } else {
      "\(turn.toolsUsed.count) " + (turn.toolsUsed.count == 1 ? "tool" : "tools")
    }

    return TurnHeaderModel(labelText: labelText, toolsText: toolsText)
  }

  @MainActor static func rollupSummary(
    hiddenCount: Int,
    totalToolCount: Int,
    isExpanded: Bool,
    breakdown: [ToolBreakdownEntry],
    messages: [TranscriptMessage]
  ) -> RollupSummaryModel {
    if isExpanded {
      let countText = totalToolCount == 1 ? "1 operation" : "\(totalToolCount) operations"
      return RollupSummaryModel(
        summaryText: countText,
        symbolName: "arrow.up.left.and.arrow.down.right",
        colorKey: .textTertiary,
        durationText: nil,
        chevronName: "chevron.down",
        isExpanded: true
      )
    }

    if !messages.isEmpty {
      let summary = ActivitySummarizer.summarize(messages)
      return RollupSummaryModel(
        summaryText: summary.text,
        symbolName: summary.icon,
        colorKey: colorKey(forActivityKey: summary.colorKey),
        durationText: summary.formattedDuration,
        chevronName: "chevron.right",
        isExpanded: false
      )
    }

    let fallbackText = if !breakdown.isEmpty {
      breakdown.prefix(6)
        .map { "\($0.count) \(CompactToolHelpers.displayName(for: $0.name))" }
        .joined(separator: ", ")
    } else if hiddenCount == 1 {
      "1 hidden operation"
    } else {
      "\(hiddenCount) hidden operations"
    }

    return RollupSummaryModel(
      summaryText: fallbackText,
      symbolName: "gearshape",
      colorKey: .textTertiary,
      durationText: nil,
      chevronName: "chevron.right",
      isExpanded: false
    )
  }

  static func liveIndicator(
    workStatus: Session.WorkStatus,
    currentTool: String?,
    pendingToolName: String?
  ) -> LiveIndicatorModel {
    switch workStatus {
      case .working:
        let detailText: String? = if let currentTool, !currentTool.isEmpty {
          currentTool
        } else {
          nil
        }
        return LiveIndicatorModel(
          barStyle: .orbiting(.working, secondary: .steer),
          iconName: nil,
          iconColorKey: nil,
          primaryText: orbitPhrases.randomElement() ?? "In orbit",
          primaryColorKey: .working,
          detailText: detailText,
          detailStyle: detailText == nil ? .none : .monospaced,
          detailColorKey: .textTertiary
        )

      case .waiting:
        return LiveIndicatorModel(
          barStyle: .parked(.reply),
          iconName: nil,
          iconColorKey: nil,
          primaryText: "Docked",
          primaryColorKey: .reply,
          detailText: nil,
          detailStyle: .none,
          detailColorKey: .textTertiary
        )

      case .permission:
        let detailText: String? = if let pendingToolName, !pendingToolName.isEmpty {
          pendingToolName
        } else {
          nil
        }
        return LiveIndicatorModel(
          barStyle: .holding(.permission),
          iconName: "exclamationmark.triangle.fill",
          iconColorKey: .permission,
          primaryText: "Holding pattern",
          primaryColorKey: .permission,
          detailText: detailText,
          detailStyle: detailText == nil ? .none : .emphasis,
          detailColorKey: .textPrimary
        )

      case .unknown:
        return LiveIndicatorModel(
          barStyle: .none,
          iconName: nil,
          iconColorKey: nil,
          primaryText: "",
          primaryColorKey: .textTertiary,
          detailText: nil,
          detailStyle: .none,
          detailColorKey: .textTertiary
        )
    }
  }

  static func collapsedTurn(
    userPreview: String,
    assistantPreview: String,
    toolCount: Int,
    totalDuration: TimeInterval?
  ) -> CollapsedTurnModel {
    CollapsedTurnModel(
      userPreview: userPreview.isEmpty ? "..." : userPreview,
      assistantPreview: assistantPreview.isEmpty ? "..." : assistantPreview,
      statsText: operationStats(toolCount: toolCount, duration: totalDuration)
    )
  }

  private static let orbitPhrases = [
    "In orbit",
    "On approach",
    "Maneuvering",
    "Plotting course",
    "Engaging thrusters",
    "Locking on",
    "Running trajectory",
  ]

  static func liveProgress(
    currentTool: String,
    completedCount: Int,
    elapsedTime: TimeInterval
  ) -> LiveProgressModel {
    let fallback = orbitPhrases.randomElement() ?? "In orbit"
    return LiveProgressModel(
      operationText: currentTool.isEmpty ? fallback : currentTool,
      statsText: operationStats(toolCount: completedCount, duration: elapsedTime)
    )
  }

  private static func relativeTimeText(from timestamp: Date?) -> String? {
    guard let timestamp else { return nil }

    let elapsed = Date().timeIntervalSince(timestamp)
    if elapsed < 60 {
      return "just now"
    }
    if elapsed < 3_600 {
      return "\(Int(elapsed / 60))m ago"
    }
    if elapsed < 86_400 {
      return "\(Int(elapsed / 3_600))h ago"
    }
    return "\(Int(elapsed / 86_400))d ago"
  }

  private static func operationStats(toolCount: Int, duration: TimeInterval?) -> String {
    var parts: [String] = []

    if toolCount > 0 {
      parts.append("\(toolCount) ops")
    }

    if let duration = duration, duration > 0 {
      parts.append(formattedDuration(duration))
    }

    return parts.joined(separator: " · ")
  }

  private static func formattedDuration(_ duration: TimeInterval) -> String {
    if duration < 1.0 {
      return "\(Int(duration * 1000))ms"
    }
    if duration < 60 {
      return String(format: "%.1fs", duration)
    }
    let minutes = Int(duration / 60)
    let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
    return "\(minutes)m \(seconds)s"
  }

  private static func colorKey(forActivityKey key: String) -> ColorKey {
    switch key {
      case "search": .search
      case "write": .write
      case "bash": .bash
      case "task": .task
      case "web": .web
      case "todo": .todo
      case "plan": .plan
      default: .textTertiary
    }
  }
}
