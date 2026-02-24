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
    if let command = trimmed(model.command) {
      return buildCommandPreview(
        command: command,
        previewType: model.previewType,
        shellSegments: model.shellSegments
      )
    }

    if let filePath = trimmed(model.filePath) {
      let title = ApprovalPreviewType.filePath.title
      let iconName = filePreviewIconName(for: model.toolName)
      return ApprovalPermissionPreview(
        text: "\(title)\n\(filePath)",
        showsProjectPath: false,
        projectPathIconName: iconName
      )
    }

    if let toolName = trimmed(model.toolName) {
      return ApprovalPermissionPreview(
        text: "\(ApprovalPreviewType.action.title)\nApprove \(toolName) action?",
        showsProjectPath: false,
        projectPathIconName: "questionmark.circle"
      )
    }

    return nil
  }

  static func compactPermissionDetail(
    serverDetail: String?,
    toolName: String?,
    toolInput: String?,
    maxLength: Int = 50
  ) -> String? {
    if let serverDetail = trimmed(serverDetail) {
      return compactTruncate(serverDetail, maxLength: maxLength)
    }
    return compactPermissionDetail(toolName: toolName, toolInput: toolInput, maxLength: maxLength)
  }

  static func compactPermissionDetail(
    toolName: String?,
    toolInput: String?,
    maxLength: Int = 50
  ) -> String? {
    guard let toolInput,
          let data = toolInput.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let normalizedTool = (toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["edit", "write", "read", "notebookedit"].contains(normalizedTool),
       let filePath = trimmed((input["file_path"] as? String) ?? (input["path"] as? String))
    {
      let fileName = (filePath as NSString).lastPathComponent
      return compactTruncate(fileName, maxLength: maxLength)
    }

    if let command = String.shellCommandDisplay(from: input["command"])
      ?? String.shellCommandDisplay(from: input["cmd"])
    {
      let segments = shellSegments(for: command)
      let summary: String
      if segments.count > 1 {
        let first = segments[0].command
        let remaining = segments.count - 1
        let segmentWord = remaining == 1 ? "segment" : "segments"
        summary = "\(first) +\(remaining) \(segmentWord)"
      } else {
        summary = command
      }
      return compactTruncate(summary, maxLength: maxLength)
    }

    if let url = trimmed(input["url"] as? String) {
      return compactTruncate("url: \(url)", maxLength: maxLength)
    }

    if let query = trimmed(input["query"] as? String) {
      return compactTruncate("query: \(query)", maxLength: maxLength)
    }

    if let pattern = trimmed(input["pattern"] as? String) {
      return compactTruncate("pattern: \(pattern)", maxLength: maxLength)
    }

    if let prompt = trimmed(input["prompt"] as? String) {
      return compactTruncate("prompt: \(prompt)", maxLength: maxLength)
    }

    let fallback = input.keys.sorted().compactMap { key -> String? in
      guard let value = input[key] as? String else { return nil }
      let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedValue.isEmpty else { return nil }
      return trimmedValue
    }.first

    guard let fallback else { return nil }
    return compactTruncate(fallback, maxLength: maxLength)
  }

  static func shellSegments(for command: String) -> [ApprovalShellSegment] {
    let characters = Array(command)
    var segments: [ApprovalShellSegment] = []
    var buffer = ""
    var pendingOperator: String?

    var inSingleQuote = false
    var inDoubleQuote = false
    var inBacktick = false
    var escaped = false
    var parenDepth = 0

    func flushSegment() {
      let trimmedSegment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
      defer { buffer = "" }
      guard !trimmedSegment.isEmpty else { return }

      let leadingOperator = segments.isEmpty ? nil : pendingOperator
      segments.append(
        ApprovalShellSegment(
          command: trimmedSegment,
          leadingOperator: leadingOperator
        )
      )
      pendingOperator = nil
    }

    var index = 0
    while index < characters.count {
      let character = characters[index]

      if escaped {
        buffer.append(character)
        escaped = false
        index += 1
        continue
      }

      if character == "\\" {
        if !inSingleQuote {
          escaped = true
        }
        buffer.append(character)
        index += 1
        continue
      }

      if !inDoubleQuote, !inBacktick, character == "'" {
        inSingleQuote.toggle()
        buffer.append(character)
        index += 1
        continue
      }

      if !inSingleQuote, !inBacktick, character == "\"" {
        inDoubleQuote.toggle()
        buffer.append(character)
        index += 1
        continue
      }

      if !inSingleQuote, !inDoubleQuote, character == "`" {
        inBacktick.toggle()
        buffer.append(character)
        index += 1
        continue
      }

      let canSplit = !inSingleQuote && !inDoubleQuote && !inBacktick && parenDepth == 0

      if !inSingleQuote, !inDoubleQuote, !inBacktick {
        if character == "(" {
          parenDepth += 1
        } else if character == ")" {
          parenDepth = max(0, parenDepth - 1)
        }
      }

      if canSplit {
        if character == "|" {
          let isDouble = (index + 1) < characters.count && characters[index + 1] == "|"
          flushSegment()
          pendingOperator = isDouble ? "||" : "|"
          index += isDouble ? 2 : 1
          continue
        }

        if character == "&", (index + 1) < characters.count, characters[index + 1] == "&" {
          flushSegment()
          pendingOperator = "&&"
          index += 2
          continue
        }

        if character == ";" || character == "\n" {
          flushSegment()
          pendingOperator = character == "\n" ? ";" : String(character)
          index += 1
          continue
        }
      }

      buffer.append(character)
      index += 1
    }

    flushSegment()
    return segments
  }

  private static func buildCommandPreview(
    command: String,
    previewType: ApprovalPreviewType,
    shellSegments: [ApprovalShellSegment]
  ) -> ApprovalPermissionPreview {
    switch previewType {
      case .shellCommand:
        let segments = shellSegments.isEmpty ? Self.shellSegments(for: command) : shellSegments
        if segments.count > 1 {
          let title = "\(previewType.title) (\(segments.count) segments)"
          let lines = segments.enumerated().map { index, segment in
            if let op = segment.leadingOperator, !op.isEmpty {
              return "[\(index + 1)] (\(op)) \(segment.command)"
            }
            return "[\(index + 1)] \(segment.command)"
          }
          return ApprovalPermissionPreview(
            text: ([title] + lines).joined(separator: "\n"),
            showsProjectPath: true,
            projectPathIconName: "folder"
          )
        }

        return ApprovalPermissionPreview(
          text: "\(previewType.title)\n\(command)",
          showsProjectPath: true,
          projectPathIconName: "folder"
        )

      case .filePath:
        return ApprovalPermissionPreview(
          text: "\(ApprovalPreviewType.filePath.title)\n\(command)",
          showsProjectPath: false,
          projectPathIconName: "doc"
        )

      case .action:
        return ApprovalPermissionPreview(
          text: "\(ApprovalPreviewType.action.title)\n\(command)",
          showsProjectPath: false,
          projectPathIconName: "questionmark.circle"
        )

      default:
        return ApprovalPermissionPreview(
          text: "\(previewType.title)\n\(command)",
          showsProjectPath: false,
          projectPathIconName: "doc.text"
        )
    }
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
