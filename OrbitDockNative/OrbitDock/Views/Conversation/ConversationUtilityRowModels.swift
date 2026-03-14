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
    case positive
    case caution
    case negative
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

  nonisolated struct WorkerChipModel: Hashable, Sendable {
    let id: String
    let title: String
    let statusText: String
    let statusColorKey: ColorKey
    let isActive: Bool
  }

  nonisolated struct WorkerOrchestrationModel: Hashable, Sendable {
    let titleText: String
    let subtitleText: String
    let spotlightText: String?
    let workers: [WorkerChipModel]
  }

  nonisolated struct ActivitySummaryModel: Hashable, Sendable {
    let titleText: String
    let subtitleText: String
    let iconName: String
    let accentColorKey: ColorKey
    let badgeText: String?
    let isExpanded: Bool
    let childCount: Int
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
      case .positive: .feedbackPositive
      case .caution: .feedbackCaution
      case .negative: .feedbackNegative
    }
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

  private static let orbitPhrases = [
    "In orbit",
    "On approach",
    "Maneuvering",
    "Plotting course",
    "Engaging thrusters",
    "Locking on",
    "Running trajectory",
  ]

  static func workerOrchestration(
    workerIDs: [String],
    subagentsByID: [String: ServerSubagentInfo]
  ) -> WorkerOrchestrationModel {
    let workers = workerIDs.prefix(4).map { workerID in
      let worker = subagentsByID[workerID]
      let title = trimmed(worker?.label)
        ?? trimmed(worker?.taskSummary)
        ?? trimmed(worker?.resultSummary)
        ?? "Worker"
      let status = workerStatusPresentation(worker?.status)
      return WorkerChipModel(
        id: workerID,
        title: title,
        statusText: status.label,
        statusColorKey: status.colorKey,
        isActive: status.isActive
      )
    }

    let activeCount = workerIDs.reduce(into: 0) { count, workerID in
      if workerStatusPresentation(subagentsByID[workerID]?.status).isActive {
        count += 1
      }
    }
    let completedCount = workerIDs.count - activeCount
    let hasActiveWorkers = activeCount > 0

    let extraCount = max(0, workerIDs.count - workers.count)
    let subtitle = if activeCount > 0 {
      extraCount > 0
        ? "\(activeCount) active · +\(extraCount) more in this turn"
        : "\(activeCount) active in this turn"
    } else if completedCount > 0 && extraCount > 0 {
      "\(completedCount) finished · +\(extraCount) more"
    } else if completedCount > 0 {
      "\(completedCount) finished in this turn"
    } else {
      "Worker activity in this turn"
    }

    let spotlightWorker = workers.first(where: \.isActive) ?? workers.first
    let spotlightText: String?
    if let worker = spotlightWorker {
      let details = subagentsByID[worker.id]
      let summary = trimmed(details?.taskSummary)
        ?? trimmed(details?.resultSummary)
        ?? trimmed(details?.label)
      if let summary {
        let statusLead = worker.isActive ? "\(worker.title) is on it" : "\(worker.title) reported back"
        spotlightText = truncateLine("\(statusLead): \(summary)", limit: 120)
      } else {
        spotlightText = nil
      }
    } else {
      spotlightText = nil
    }

    return WorkerOrchestrationModel(
      titleText: workerOrchestrationTitle(workerCount: workerIDs.count, hasActiveWorkers: hasActiveWorkers),
      subtitleText: subtitle,
      spotlightText: spotlightText,
      workers: Array(workers)
    )
  }

  @MainActor
  static func activitySummary(messages: [TranscriptMessage], isExpanded: Bool) -> ActivitySummaryModel {
    let summary = ActivitySummarizer.summarize(messages)
    let count = messages.count
    let subtitle = count == 1 ? "1 tool event in this block" : "\(count) tool events in this block"
    return ActivitySummaryModel(
      titleText: summary.text,
      subtitleText: subtitle,
      iconName: summary.icon,
      accentColorKey: colorKey(forActivityColor: summary.colorKey),
      badgeText: summary.formattedDuration,
      isExpanded: isExpanded,
      childCount: count
    )
  }

  private static func truncateLine(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let end = text.index(text.startIndex, offsetBy: limit - 1)
    return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static func workerStatusPresentation(_ status: ServerSubagentStatus?) -> (
    label: String, colorKey: ColorKey, isActive: Bool
  ) {
    switch status {
      case .pending:
        ("Pending", .caution, true)
      case .running:
        ("Running", .working, true)
      case .completed:
        ("Complete", .positive, false)
      case .failed:
        ("Failed", .negative, false)
      case .cancelled:
        ("Cancelled", .permission, false)
      case .shutdown:
        ("Stopped", .textTertiary, false)
      case .notFound:
        ("Unavailable", .negative, false)
      case nil:
        ("Worker", .textTertiary, false)
    }
  }

  private static func workerOrchestrationTitle(
    workerCount: Int,
    hasActiveWorkers: Bool
  ) -> String {
    if hasActiveWorkers {
      return workerCount == 1 ? "Worker in play" : "Workers in play"
    }
    return "Worker activity"
  }

  private static func colorKey(forActivityColor rawValue: String) -> ColorKey {
    switch rawValue {
      case "search":
        .search
      case "write":
        .write
      case "bash":
        .bash
      case "task":
        .task
      case "web":
        .web
      case "todo":
        .todo
      case "plan":
        .plan
      default:
        .accent
    }
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
