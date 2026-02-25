//
//  ApprovalPermissionPreview.swift
//  OrbitDock
//
//  Shared types and helpers for approval-card rendering across AppKit/UIKit.
//

import Foundation

struct ApprovalShellSegment: Hashable, Sendable {
  let command: String
  let leadingOperator: String?
}

// MARK: - Shared Helpers

enum ApprovalPermissionPreviewHelpers {
  static func compactPermissionDetail(
    serverDetail: String?,
    maxLength: Int = 50
  ) -> String? {
    guard let serverDetail = trimmed(serverDetail) else { return nil }
    return compactTruncate(serverDetail, maxLength: maxLength)
  }

  /// Resolve the preview value to display (command text or file path).
  static func previewValue(for model: ApprovalCardModel) -> String? {
    switch model.previewType {
      case .filePath:
        trimmed(model.filePath)
      default:
        trimmed(model.command)
    }
  }

  /// Icon name appropriate for the preview type.
  static func previewIconName(for model: ApprovalCardModel) -> String {
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

  /// Human-readable label for a shell pipe/chain operator.
  static func operatorLabel(_ op: String?) -> String? {
    guard let op = trimmed(op) else { return nil }
    return switch op {
      case "||": "if previous fails"
      case "&&": "then"
      case "|": "pipe"
      default: "then"
    }
  }

  /// Whether the model has any displayable preview content.
  static func hasPreviewContent(_ model: ApprovalCardModel) -> Bool {
    if !model.shellSegments.isEmpty { return true }
    if trimmed(model.command) != nil { return true }
    if trimmed(model.filePath) != nil { return true }
    if trimmed(model.serverManifest) != nil { return true }
    return false
  }

  /// Whether to show the project path row below the preview.
  static func showsProjectPath(_ model: ApprovalCardModel) -> Bool {
    model.previewType == .shellCommand && hasPreviewContent(model)
  }

  // MARK: - Private

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

  static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func compactTruncate(_ text: String, maxLength: Int) -> String {
    guard maxLength > 3 else { return String(text.prefix(max(0, maxLength))) }
    guard text.count > maxLength else { return text }
    return String(text.prefix(maxLength - 3)) + "..."
  }
}

// MARK: - Legacy Compatibility

enum ApprovalPermissionPreviewBuilder {
  static func compactPermissionDetail(
    serverDetail: String?,
    maxLength: Int = 50
  ) -> String? {
    ApprovalPermissionPreviewHelpers.compactPermissionDetail(
      serverDetail: serverDetail,
      maxLength: maxLength
    )
  }
}
