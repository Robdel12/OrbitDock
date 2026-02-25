//
//  ApprovalPermissionPreview.swift
//  OrbitDock
//
//  Shared formatter for approval-card preview content across AppKit/UIKit.
//

import Foundation

struct ApprovalShellSegment: Hashable, Sendable {
  let command: String
  let leadingOperator: String?
}

struct ApprovalPermissionPreview: Hashable, Sendable {
  let text: String
  let showsProjectPath: Bool
  let projectPathIconName: String
}

enum ApprovalPermissionPreviewBuilder {
  static func build(for model: ApprovalCardModel) -> ApprovalPermissionPreview? {
    if let structuredPreview = buildServerBackedPreview(for: model) {
      return structuredPreview
    }

    if let manifest = trimmed(model.serverManifest) {
      return ApprovalPermissionPreview(
        text: manifest,
        showsProjectPath: model.previewType == .shellCommand,
        projectPathIconName: previewIconName(for: model)
      )
    }

    return nil
  }

  static func compactPermissionDetail(
    serverDetail: String?,
    maxLength: Int = 50
  ) -> String? {
    guard let serverDetail = trimmed(serverDetail) else { return nil }
    return compactTruncate(serverDetail, maxLength: maxLength)
  }

  private static func buildServerBackedPreview(for model: ApprovalCardModel) -> ApprovalPermissionPreview? {
    let decisionScope = trimmed(model.decisionScope) ?? "approve/deny applies to the full request payload."

    let lines = serverBackedLines(for: model, decisionScope: decisionScope)
    guard !lines.isEmpty else { return nil }

    return ApprovalPermissionPreview(
      text: lines.joined(separator: "\n"),
      showsProjectPath: model.previewType == .shellCommand,
      projectPathIconName: previewIconName(for: model)
    )
  }

  private static func serverBackedLines(for model: ApprovalCardModel, decisionScope: String) -> [String] {
    let requestId = trimmed(model.approvalId) ?? "unknown"
    let toolName = trimmed(model.toolName) ?? "unknown"
    let approvalType = approvalTypeLabel(model.approvalType)
    let riskTier = riskTierLabel(model.risk)

    var lines: [String] = [
      "APPROVAL REQUEST",
      "request_id: \(requestId)",
      "approval_type: \(approvalType)",
      "tool: \(toolName)",
      "risk_tier: \(riskTier)",
    ]

    if !model.riskFindings.isEmpty {
      lines.append("risk_signals:")
      lines.append(contentsOf: model.riskFindings.map { "- \($0)" })
    }

    lines.append("")
    lines.append("decision_scope: \(decisionScope)")
    lines.append(contentsOf: serverBackedContentLines(for: model))
    return lines
  }

  private static func serverBackedContentLines(for model: ApprovalCardModel) -> [String] {
    switch model.previewType {
      case .shellCommand:
        let segments = model.shellSegments

        var lines = [
          "command_segments: \(max(segments.count, 1))",
          "segments:",
        ]
        if segments.isEmpty {
          lines.append("[1] unavailable")
          return lines
        }

        for (index, segment) in segments.enumerated() {
          let prefix = shellOperatorPrefix(segment.leadingOperator)
          let command = compactTruncate(segment.command, maxLength: 220)
          lines.append("[\(index + 1)] \(prefix)\(command)")
        }
        return lines

      default:
        guard let value = previewValue(for: model) else { return [] }
        return ["\(previewValueLabel(for: model.previewType)): \(value)"]
    }
  }

  private static func previewValue(for model: ApprovalCardModel) -> String? {
    switch model.previewType {
      case .filePath:
        trimmed(model.filePath)
      default:
        trimmed(model.command)
    }
  }

  private static func previewValueLabel(for previewType: ApprovalPreviewType) -> String {
    switch previewType {
      case .filePath:
        "target_file"
      case .url:
        "target_url"
      case .searchQuery:
        "search_query"
      case .pattern:
        "pattern"
      case .prompt:
        "prompt"
      case .value:
        "value"
      case .action:
        "action"
      case .shellCommand:
        "command"
    }
  }

  private static func previewIconName(for model: ApprovalCardModel) -> String {
    switch model.previewType {
      case .shellCommand:
        "folder"
      case .filePath:
        filePreviewIconName(for: model.toolName)
      case .action:
        "questionmark.circle"
      default:
        "doc.text"
    }
  }

  private static func approvalTypeLabel(_ approvalType: ServerApprovalType?) -> String {
    guard let approvalType else { return "unknown" }
    return approvalType.rawValue
  }

  private static func riskTierLabel(_ risk: ApprovalRisk) -> String {
    switch risk {
      case .low:
        "low"
      case .normal:
        "normal"
      case .high:
        "high"
    }
  }

  private static func shellOperatorPrefix(_ leadingOperator: String?) -> String {
    guard let op = trimmed(leadingOperator) else { return "" }

    let meaning = switch op {
      case "||":
        "if previous fails"
      case "&&":
        "if previous succeeds"
      case "|":
        "pipe output from previous"
      default:
        "then"
    }
    return "(\(op), \(meaning)) "
  }

  private static func filePreviewIconName(for toolName: String?) -> String {
    let normalized = (toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "edit" || normalized == "notebookedit" {
      return "pencil"
    }
    if normalized == "read" {
      return "doc.text.magnifyingglass"
    }
    return "doc.badge.plus"
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func compactTruncate(_ text: String, maxLength: Int) -> String {
    guard maxLength > 3 else { return String(text.prefix(max(0, maxLength))) }
    guard text.count > maxLength else { return text }
    return String(text.prefix(maxLength - 3)) + "..."
  }
}
