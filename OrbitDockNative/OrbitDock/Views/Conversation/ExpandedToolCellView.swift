//
//  ExpandedToolCellView.swift
//  OrbitDock
//
//  Native cell for expanded tool cards.
//  Replaces SwiftUI HostingTableCellView for ALL expanded tool rows.
//  Deterministic height — no hosting view, no correction cycle.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

enum NativeTodoStatus: Hashable {
  case pending
  case inProgress
  case completed
  case blocked
  case canceled
  case unknown

  init(_ rawStatus: String?) {
    let normalized = rawStatus?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")

    switch normalized {
      case "pending", "queued", "todo", "open": self = .pending
      case "in_progress", "inprogress", "active", "running": self = .inProgress
      case "completed", "complete", "done", "resolved": self = .completed
      case "blocked": self = .blocked
      case "canceled", "cancelled": self = .canceled
      default: self = .unknown
    }
  }

  var label: String {
    switch self {
      case .pending: "Pending"
      case .inProgress: "In Progress"
      case .completed: "Completed"
      case .blocked: "Blocked"
      case .canceled: "Canceled"
      case .unknown: "Unknown"
    }
  }
}

struct NativeTodoItem: Hashable {
  let content: String
  let activeForm: String?
  let status: NativeTodoStatus

  var primaryText: String {
    if status == .inProgress,
       let activeForm,
       !activeForm.isEmpty
    {
      return activeForm
    }
    return content
  }

  var secondaryText: String? {
    guard status == .inProgress,
          let activeForm,
          !activeForm.isEmpty,
          activeForm != content
    else {
      return nil
    }
    return content
  }
}

// MARK: - Tool Content Enum

enum NativeToolContent {
  case bash(command: String, input: String?, output: String?)
  case edit(filename: String?, path: String?, additions: Int, deletions: Int, lines: [DiffLine], isWriteNew: Bool)
  case read(filename: String?, path: String?, language: String, lines: [String])
  case glob(pattern: String, grouped: [(dir: String, files: [String])])
  case grep(pattern: String, grouped: [(file: String, matches: [String])])
  case task(agentLabel: String, agentColor: PlatformColor, description: String, output: String?, isComplete: Bool)
  case todo(title: String, subtitle: String?, items: [NativeTodoItem], output: String?)
  case mcp(server: String, displayTool: String, subtitle: String?, input: String?, output: String?)
  case webFetch(domain: String, url: String, input: String?, output: String?)
  case webSearch(query: String, input: String?, output: String?)
  case generic(toolName: String, input: String?, output: String?)
}

// MARK: - Model

struct NativeExpandedToolModel {
  let messageID: String
  let toolColor: PlatformColor
  let iconName: String
  let hasError: Bool
  let isInProgress: Bool
  let canCancel: Bool
  let duration: String?
  let content: NativeToolContent
}

// MARK: - Cell View

// MARK: - Shared Height Calculation

enum ExpandedToolLayout {
  static let laneHorizontalInset = ConversationLayout.laneHorizontalInset
  static let accentBarWidth: CGFloat = EdgeBar.width
  static let headerHPad: CGFloat = 14
  static let headerVPad: CGFloat = 10
  static let iconSize: CGFloat = 14
  static let cornerRadius: CGFloat = Radius.lg
  static let contentLineHeight: CGFloat = 18
  static let diffLineHeight: CGFloat = 22
  static let sectionHeaderHeight: CGFloat = 24
  static let sectionPadding: CGFloat = 10
  static let contentTopPad: CGFloat = 6
  static let bottomPadding: CGFloat = 10

  // Diff/read gutter metrics
  static let diffContentTrailingPad: CGFloat = 10
  static let diffNumberLeadingInset: CGFloat = 6
  static let diffNumberColumnGap: CGFloat = 2
  static let diffPrefixGap: CGFloat = 2
  static let diffPrefixWidth: CGFloat = 10
  static let lineNumberHorizontalPadding: CGFloat = 2
  static let minLineNumberColumnWidth: CGFloat = 14

  struct DiffGutterMetrics {
    let oldLineNumberX: CGFloat?
    let oldLineNumberWidth: CGFloat
    let newLineNumberX: CGFloat?
    let newLineNumberWidth: CGFloat
    let prefixX: CGFloat
    let codeX: CGFloat
  }

  struct ReadGutterMetrics {
    let lineNumberX: CGFloat
    let lineNumberWidth: CGFloat
    let codeX: CGFloat
  }

  static func diffGutterMetrics(for lines: [DiffLine]) -> DiffGutterMetrics {
    let hasOldLineNumbers = lines.contains { $0.oldLineNum != nil }
    let hasNewLineNumbers = lines.contains { $0.newLineNum != nil }
    let maxOldLineNumber = lines.compactMap(\.oldLineNum).max() ?? 0
    let maxNewLineNumber = lines.compactMap(\.newLineNum).max() ?? 0

    let oldWidth = hasOldLineNumbers ? lineNumberColumnWidth(maxLineNumber: maxOldLineNumber) : 0
    let newWidth = hasNewLineNumbers ? lineNumberColumnWidth(maxLineNumber: maxNewLineNumber) : 0

    var cursorX = diffNumberLeadingInset

    let oldX: CGFloat? = hasOldLineNumbers ? cursorX : nil
    if hasOldLineNumbers {
      cursorX += oldWidth + diffNumberColumnGap
    }

    let newX: CGFloat? = hasNewLineNumbers ? cursorX : nil
    if hasNewLineNumbers {
      cursorX += newWidth + diffNumberColumnGap
    }

    let prefixX = cursorX
    let codeX = prefixX + diffPrefixWidth + diffPrefixGap

    return DiffGutterMetrics(
      oldLineNumberX: oldX,
      oldLineNumberWidth: oldWidth,
      newLineNumberX: newX,
      newLineNumberWidth: newWidth,
      prefixX: prefixX,
      codeX: codeX
    )
  }

  static func readGutterMetrics(lineCount: Int) -> ReadGutterMetrics {
    let maxLineNumber = max(1, lineCount)
    let lineNumberWidth = lineNumberColumnWidth(maxLineNumber: maxLineNumber)
    let lineNumberX = diffNumberLeadingInset
    let codeX = lineNumberX + lineNumberWidth + 4
    return ReadGutterMetrics(
      lineNumberX: lineNumberX,
      lineNumberWidth: lineNumberWidth,
      codeX: codeX
    )
  }

  private static func lineNumberColumnWidth(maxLineNumber: Int) -> CGFloat {
    let text = "\(max(0, maxLineNumber))"
    let measured = ceil((text as NSString).size(withAttributes: [.font: lineNumFont as Any]).width)
    return max(minLineNumberColumnWidth, measured + lineNumberHorizontalPadding)
  }

  // Card colors
  static let bgColor = PlatformColor.calibrated(red: 0.06, green: 0.06, blue: 0.08, alpha: 0.85)
  static let contentBgColor = PlatformColor.calibrated(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
  static let headerDividerColor = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.06)

  static let addedBgColor = PlatformColor.calibrated(red: 0.15, green: 0.32, blue: 0.18, alpha: 0.6)
  static let removedBgColor = PlatformColor.calibrated(red: 0.35, green: 0.14, blue: 0.14, alpha: 0.6)
  static let addedAccentColor = PlatformColor.calibrated(red: 0.4, green: 0.95, blue: 0.5, alpha: 1)
  static let removedAccentColor = PlatformColor.calibrated(red: 1.0, green: 0.5, blue: 0.5, alpha: 1)

  // Text colors
  static let textPrimary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.92)
  static let textSecondary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.65)
  static let textTertiary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.50)
  static let textQuaternary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.38)

  // Fonts
  static let codeFont = PlatformFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
  static let codeFontStrong = PlatformFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
  static let diffContentFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .regular)
  static let headerFont = PlatformFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
  static let subtitleFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
  static let lineNumFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
  static let sectionLabelFont = PlatformFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
  static let statsFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
  static let todoTitleFont = PlatformFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
  static let todoSecondaryFont = PlatformFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
  static let todoRowHorizontalPadding: CGFloat = 10
  static let todoRowVerticalPadding: CGFloat = 8
  static let todoRowSpacing: CGFloat = 6
  static let todoIconWidth: CGFloat = 16
  static let todoBadgeMinWidth: CGFloat = 80
  static let todoBadgeMaxWidth: CGFloat = 122
  static let todoBadgeSidePadding: CGFloat = 8
  static let todoBadgeHeight: CGFloat = 20

  // MARK: - Text Measurement

  /// Measure the height a text string needs when allowed to wrap at `maxWidth`.
  /// Returns at least `contentLineHeight` so empty/short lines keep consistent spacing.
  static func measuredTextHeight(_ text: String, font: PlatformFont, maxWidth: CGFloat) -> CGFloat {
    guard maxWidth > 0 else { return contentLineHeight }
    let constraintSize = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
    let rect = (text as NSString).boundingRect(
      with: constraintSize,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font],
      context: nil
    )
    return max(contentLineHeight, ceil(rect.height))
  }

  /// Available width for content text inside the card (after horizontal padding).
  static func contentTextWidth(cardWidth: CGFloat) -> CGFloat {
    cardWidth - headerHPad * 2
  }

  struct TodoStatusStyle {
    let tint: PlatformColor
    let rowBackground: PlatformColor
    let badgeBackground: PlatformColor
  }

  static func todoStatusStyle(_ status: NativeTodoStatus) -> TodoStatusStyle {
    switch status {
      case .completed:
        TodoStatusStyle(
          tint: PlatformColor.calibrated(red: 0.40, green: 0.95, blue: 0.55, alpha: 1),
          rowBackground: PlatformColor.calibrated(red: 0.13, green: 0.24, blue: 0.16, alpha: 0.95),
          badgeBackground: PlatformColor.calibrated(red: 0.22, green: 0.44, blue: 0.28, alpha: 1)
        )
      case .inProgress:
        TodoStatusStyle(
          tint: PlatformColor.calibrated(red: 0.53, green: 0.78, blue: 1.0, alpha: 1),
          rowBackground: PlatformColor.calibrated(red: 0.12, green: 0.18, blue: 0.24, alpha: 0.95),
          badgeBackground: PlatformColor.calibrated(red: 0.23, green: 0.37, blue: 0.54, alpha: 1)
        )
      case .blocked:
        TodoStatusStyle(
          tint: PlatformColor.calibrated(red: 0.98, green: 0.72, blue: 0.35, alpha: 1),
          rowBackground: PlatformColor.calibrated(red: 0.26, green: 0.18, blue: 0.08, alpha: 0.95),
          badgeBackground: PlatformColor.calibrated(red: 0.45, green: 0.31, blue: 0.11, alpha: 1)
        )
      case .canceled:
        TodoStatusStyle(
          tint: PlatformColor.calibrated(red: 1.0, green: 0.62, blue: 0.62, alpha: 1),
          rowBackground: PlatformColor.calibrated(red: 0.28, green: 0.14, blue: 0.16, alpha: 0.95),
          badgeBackground: PlatformColor.calibrated(red: 0.48, green: 0.21, blue: 0.25, alpha: 1)
        )
      case .pending, .unknown:
        TodoStatusStyle(
          tint: PlatformColor.calibrated(red: 0.86, green: 0.86, blue: 0.86, alpha: 1),
          rowBackground: PlatformColor.calibrated(red: 0.13, green: 0.13, blue: 0.16, alpha: 0.95),
          badgeBackground: PlatformColor.calibrated(red: 0.24, green: 0.24, blue: 0.29, alpha: 1)
        )
    }
  }

  // MARK: - Height Calculation

  static func headerHeight(for model: NativeExpandedToolModel?, cardWidth: CGFloat = 0) -> CGFloat {
    guard let model else { return 40 }
    switch model.content {
      case let .bash(command, _, _):
        guard cardWidth > 0 else { return 40 }
        let leftEdge: CGFloat = accentBarWidth + headerHPad + 20 + 8
        let rightEdge: CGFloat = cardWidth - headerHPad - 12 - 8 - 60
        let titleWidth = max(60, rightEdge - leftEdge)
        let bashFont = PlatformFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let titleH = measuredTextHeight("$ " + command, font: bashFont, maxWidth: titleWidth)
        return max(40, headerVPad + titleH + headerVPad)
      case .edit, .read, .glob, .grep, .mcp, .task, .todo:
        return 48
      default:
        return 40
    }
  }

  static func contentHeight(for model: NativeExpandedToolModel, cardWidth: CGFloat = 0) -> CGFloat {
    switch model.content {
      case let .bash(_, input, output):
        return genericHeight(input: input, output: output, cardWidth: cardWidth)
      case let .edit(_, _, _, _, lines, isWriteNew):
        let writeHeaderH: CGFloat = isWriteNew ? 28 : 0
        return writeHeaderH + CGFloat(lines.count) * diffLineHeight
      case let .read(_, _, _, lines):
        return readHeight(lines: lines, cardWidth: cardWidth)
      case let .glob(_, grouped):
        return globHeight(grouped: grouped, cardWidth: cardWidth)
      case let .grep(_, grouped):
        return grepHeight(grouped: grouped, cardWidth: cardWidth)
      case let .task(_, _, _, output, _):
        return textOutputHeight(output: output, cardWidth: cardWidth)
      case let .todo(_, _, items, output):
        return todoHeight(items: items, output: output, cardWidth: cardWidth)
      case let .mcp(_, _, _, input, output):
        return genericHeight(input: input, output: output, cardWidth: cardWidth)
      case let .webFetch(_, _, input, output):
        return genericHeight(input: input, output: output, cardWidth: cardWidth)
      case let .webSearch(_, input, output):
        return genericHeight(input: input, output: output, cardWidth: cardWidth)
      case let .generic(toolName, input, output):
        return genericHeight(toolName: toolName, input: input, output: output, cardWidth: cardWidth)
    }
  }

  struct StructuredPayloadEntry {
    let keyPath: String
    let value: String
  }

  struct AskUserQuestionOption {
    let label: String
    let description: String?
  }

  struct AskUserQuestionItem {
    let header: String?
    let question: String
    let options: [AskUserQuestionOption]
  }

  private static let maxStructuredPayloadEntries = 120
  private static let maxStructuredValueChars = 220

  static func structuredPayloadEntries(from text: String?) -> [StructuredPayloadEntry]? {
    guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    guard let data = raw.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data, options: [])
    else {
      return nil
    }

    var entries: [StructuredPayloadEntry] = []
    collectStructuredEntries(json, path: "", into: &entries)
    if entries.isEmpty {
      return nil
    }
    if entries.count >= maxStructuredPayloadEntries {
      entries.append(StructuredPayloadEntry(keyPath: "$", value: "…truncated"))
    }
    return entries
  }

  static func payloadDisplayLines(from text: String?) -> [String] {
    if let entries = structuredPayloadEntries(from: text) {
      return entries.map { "\($0.keyPath): \($0.value)" }
    }
    guard let text else { return [] }
    return text.components(separatedBy: "\n")
  }

  static func askUserQuestionItems(from text: String?) -> [AskUserQuestionItem]? {
    guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    guard let data = raw.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data, options: []),
          let root = json as? [String: Any],
          let questions = root["questions"] as? [[String: Any]]
    else {
      return nil
    }

    let items = questions.compactMap { question -> AskUserQuestionItem? in
      guard let prompt = question["question"] as? String, !prompt.isEmpty else {
        return nil
      }
      let header = question["header"] as? String
      let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> AskUserQuestionOption? in
        guard let label = option["label"] as? String, !label.isEmpty else {
          return nil
        }
        return AskUserQuestionOption(label: label, description: option["description"] as? String)
      }
      return AskUserQuestionItem(header: header, question: prompt, options: options)
    }

    return items.isEmpty ? nil : items
  }

  private static func collectStructuredEntries(
    _ value: Any,
    path: String,
    into entries: inout [StructuredPayloadEntry]
  ) {
    guard entries.count < maxStructuredPayloadEntries else { return }

    switch value {
      case let object as [String: Any]:
        if object.isEmpty {
          appendStructuredEntry(path: path, value: "{}", into: &entries)
          return
        }
        for key in object.keys.sorted() {
          guard let child = object[key] else { continue }
          let nextPath = path.isEmpty ? key : "\(path).\(key)"
          collectStructuredEntries(child, path: nextPath, into: &entries)
          if entries.count >= maxStructuredPayloadEntries { break }
        }
      case let array as [Any]:
        if array.isEmpty {
          appendStructuredEntry(path: path, value: "[]", into: &entries)
          return
        }
        var scalarPreview: [String] = []
        var allScalar = array.count <= 6
        if allScalar {
          for item in array {
            if isScalarJSONValue(item) {
              scalarPreview.append(formatScalarJSONValue(item))
            } else {
              allScalar = false
              break
            }
          }
        }
        if allScalar {
          let joined = scalarPreview.joined(separator: ", ")
          appendStructuredEntry(path: path, value: "[\(joined)]", into: &entries)
          return
        }
        for (idx, item) in array.enumerated() {
          let nextPath = path.isEmpty ? "[\(idx)]" : "\(path)[\(idx)]"
          collectStructuredEntries(item, path: nextPath, into: &entries)
          if entries.count >= maxStructuredPayloadEntries { break }
        }
      default:
        appendStructuredEntry(path: path, value: formatScalarJSONValue(value), into: &entries)
    }
  }

  private static func appendStructuredEntry(path: String, value: String, into entries: inout [StructuredPayloadEntry]) {
    let keyPath = path.isEmpty ? "$" : path
    let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
    let limited = normalized.count > maxStructuredValueChars
      ? String(normalized.prefix(maxStructuredValueChars)) + "…"
      : normalized
    entries.append(StructuredPayloadEntry(keyPath: keyPath, value: limited))
  }

  private static func isScalarJSONValue(_ value: Any) -> Bool {
    !(value is [String: Any]) && !(value is [Any])
  }

  private static func formatScalarJSONValue(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let number = value as? NSNumber { return number.stringValue }
    if let string = value as? String { return "\"\(string)\"" }
    return String(describing: value)
  }

  static func requiredHeight(for width: CGFloat, model: NativeExpandedToolModel) -> CGFloat {
    let cardWidth = width - laneHorizontalInset * 2
    let h = headerHeight(for: model, cardWidth: cardWidth)
    let c = contentHeight(for: model, cardWidth: cardWidth)
    return h + c + (c > 0 ? bottomPadding : 0)
  }

  static func textOutputHeight(output: String?, cardWidth: CGFloat = 0) -> CGFloat {
    guard let output, !output.isEmpty else { return 0 }
    let lines = output.components(separatedBy: "\n")
    let textWidth = contentTextWidth(cardWidth: cardWidth)

    var h: CGFloat = sectionPadding + contentTopPad
    if textWidth > 0 {
      for line in lines {
        let text = line.isEmpty ? " " : line
        h += measuredTextHeight(text, font: codeFont, maxWidth: textWidth)
      }
    } else {
      h += CGFloat(lines.count) * contentLineHeight
    }
    h += sectionPadding
    return h
  }

  static func readHeight(lines: [String], cardWidth _: CGFloat) -> CGFloat {
    sectionPadding + contentTopPad + CGFloat(lines.count) * contentLineHeight + sectionPadding
  }

  static func globHeight(grouped: [(dir: String, files: [String])], cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let fileTextWidth = textWidth > 0 ? textWidth - 28 : 0
    let dirFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
    let fileFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)

    var h: CGFloat = sectionPadding + contentTopPad
    for (dir, files) in grouped {
      let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
      if textWidth > 0 {
        h += measuredTextHeight(dirText, font: dirFont, maxWidth: textWidth - 18)
      } else {
        h += 20
      }

      for file in files {
        let filename = file.components(separatedBy: "/").last ?? file
        if fileTextWidth > 0 {
          h += measuredTextHeight(filename, font: fileFont, maxWidth: fileTextWidth)
        } else {
          h += contentLineHeight
        }
      }
      h += 6
    }
    return h
  }

  static func grepHeight(grouped: [(file: String, matches: [String])], cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let matchTextWidth = textWidth > 0 ? textWidth - 16 : 0
    let fileFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)

    var h: CGFloat = sectionPadding + contentTopPad
    for (file, matches) in grouped {
      let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
      let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
      if textWidth > 0 {
        h += measuredTextHeight(shortPath + matchSuffix, font: fileFont, maxWidth: textWidth)
        h += 2
      } else {
        h += 20
      }

      for match in matches {
        if matchTextWidth > 0 {
          h += measuredTextHeight(match, font: codeFont, maxWidth: matchTextWidth)
        } else {
          h += contentLineHeight
        }
      }
      h += 6
    }
    return h
  }

  static func genericHeight(
    toolName: String? = nil,
    input: String?,
    output: String?,
    cardWidth: CGFloat = 0
  ) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    var h: CGFloat = contentTopPad

    if let input, !input.isEmpty {
      h += sectionPadding + sectionHeaderHeight
      if toolName?.lowercased() == "question", let questions = askUserQuestionItems(from: input) {
        let titleFont = PlatformFont.systemFont(ofSize: 12.5, weight: .semibold)
        let optionFont = PlatformFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
        let detailFont = PlatformFont.systemFont(ofSize: TypeScale.meta, weight: .regular)
        let sectionSpacing: CGFloat = 8
        let rowSpacing: CGFloat = 6
        let optionSpacing: CGFloat = 5
        for (index, question) in questions.enumerated() {
          if let header = question.header, !header.isEmpty {
            h += measuredTextHeight(header, font: detailFont, maxWidth: textWidth)
            h += 3
          }
          h += measuredTextHeight(question.question, font: titleFont, maxWidth: textWidth)
          if !question.options.isEmpty {
            h += rowSpacing
            for option in question.options {
              h += measuredTextHeight(option.label, font: optionFont, maxWidth: textWidth)
              if let description = option.description, !description.isEmpty {
                h += 2 + measuredTextHeight(description, font: detailFont, maxWidth: textWidth)
              }
              h += optionSpacing
            }
            h -= optionSpacing
          }
          if index < questions.count - 1 {
            h += sectionSpacing
          }
        }
      } else {
        let inputLines = payloadDisplayLines(from: input)
        if textWidth > 0 {
          for line in inputLines {
            h += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
          }
        } else {
          h += CGFloat(inputLines.count) * contentLineHeight
        }
      }
      h += sectionPadding
    }

    if let output, !output.isEmpty {
      let outputLines = payloadDisplayLines(from: output)
      h += sectionPadding + sectionHeaderHeight
      if textWidth > 0 {
        for line in outputLines {
          h += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
        }
      } else {
        h += CGFloat(outputLines.count) * contentLineHeight
      }
      h += sectionPadding
    }
    return h
  }

  static func todoHeight(items: [NativeTodoItem], output: String?, cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let hasOutput = output?.isEmpty == false
    let hasItems = !items.isEmpty
    var h: CGFloat = contentTopPad

    if hasItems {
      h += sectionPadding + sectionHeaderHeight

      for item in items {
        let statusLabel = item.status.label.uppercased()
        let badgeTextWidth = ceil((statusLabel as NSString).size(withAttributes: [.font: statsFont as Any]).width)
        let badgeWidth = min(todoBadgeMaxWidth, max(todoBadgeMinWidth, badgeTextWidth + todoBadgeSidePadding * 2))
        let iconAndGap = todoIconWidth + 8
        let textAreaWidth = max(90, textWidth - todoRowHorizontalPadding * 2 - iconAndGap - badgeWidth - 8)
        let primaryHeight = measuredTextHeight(item.primaryText, font: todoTitleFont, maxWidth: textAreaWidth)
        let secondaryHeight = item.secondaryText.map {
          measuredTextHeight($0, font: todoSecondaryFont, maxWidth: textAreaWidth)
        } ?? 0
        let textHeight = primaryHeight + (secondaryHeight > 0 ? 2 + secondaryHeight : 0)
        let rowHeight = max(
          todoBadgeHeight + todoRowVerticalPadding * 2,
          textHeight + todoRowVerticalPadding * 2
        )
        h += rowHeight + todoRowSpacing
      }

      h += sectionPadding
    }

    if hasOutput {
      let outputLines = (output ?? "").components(separatedBy: "\n")
      h += sectionPadding + sectionHeaderHeight
      if textWidth > 0 {
        for line in outputLines {
          h += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
        }
      } else {
        h += CGFloat(outputLines.count) * contentLineHeight
      }
      h += sectionPadding
    }

    return h
  }

  static func toolTypeName(_ content: NativeToolContent) -> String {
    switch content {
      case .bash: "bash"
      case .edit: "edit"
      case .read: "read"
      case .glob: "glob"
      case .grep: "grep"
      case .task: "task"
      case .todo: "todo"
      case .mcp: "mcp"
      case .webFetch: "webFetch"
      case .webSearch: "webSearch"
      case .generic: "generic"
    }
  }
}

// MARK: - macOS Cell View

#if os(macOS)

  private final class HorizontalPanPassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
      let hasHorizontalOverflow = (documentView?.bounds.width ?? 0) > contentView.bounds.width + 1
      let horizontalDelta = abs(event.scrollingDeltaX)
      let verticalDelta = abs(event.scrollingDeltaY)
      let shouldHandleHorizontally = hasHorizontalOverflow && horizontalDelta > verticalDelta

      if shouldHandleHorizontally {
        super.scrollWheel(with: event)
      } else if let nextResponder {
        nextResponder.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
    }
  }

  final class NativeExpandedToolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeExpandedToolCell")

    private static let logger = TimelineFileLogger.shared

    // ── Layout constants (delegate to shared ExpandedToolLayout) ──

    private static let laneHorizontalInset = ExpandedToolLayout.laneHorizontalInset
    private static let accentBarWidth = ExpandedToolLayout.accentBarWidth
    private static let headerHPad = ExpandedToolLayout.headerHPad
    private static let headerVPad = ExpandedToolLayout.headerVPad
    private static let iconSize = ExpandedToolLayout.iconSize
    private static let cornerRadius = ExpandedToolLayout.cornerRadius
    private static let contentLineHeight = ExpandedToolLayout.contentLineHeight
    private static let diffLineHeight = ExpandedToolLayout.diffLineHeight
    private static let sectionHeaderHeight = ExpandedToolLayout.sectionHeaderHeight
    private static let sectionPadding = ExpandedToolLayout.sectionPadding
    private static let contentTopPad = ExpandedToolLayout.contentTopPad
    private static let bottomPadding = ExpandedToolLayout.bottomPadding

    // No line count limits — show full content for all tool types

    // Card colors — opaque dark surface with subtle depth
    private static let bgColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.85)
    private static let contentBgColor = NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)
    private static let headerDividerColor = NSColor.white.withAlphaComponent(0.06)

    private static let addedBgColor = NSColor(calibratedRed: 0.15, green: 0.32, blue: 0.18, alpha: 0.6)
    private static let removedBgColor = NSColor(calibratedRed: 0.35, green: 0.14, blue: 0.14, alpha: 0.6)
    private static let addedAccentColor = NSColor(calibratedRed: 0.4, green: 0.95, blue: 0.5, alpha: 1)
    private static let removedAccentColor = NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1)

    // Text colors — themed hierarchy (matches Color.textPrimary/Secondary/Tertiary/Quaternary)
    private static let textPrimary = NSColor.white.withAlphaComponent(0.92)
    private static let textSecondary = NSColor.white.withAlphaComponent(0.65)
    private static let textTertiary = NSColor.white.withAlphaComponent(0.50)
    private static let textQuaternary = NSColor.white.withAlphaComponent(0.38)

    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let codeFontStrong = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    private static let headerFont = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
    private static let subtitleFont = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
    private static let lineNumFont = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)
    private static let sectionLabelFont = NSFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
    private static let statsFont = NSFont.monospacedSystemFont(ofSize: TypeScale.micro, weight: .medium)

    // ── Subviews ──

    private let cardBackground = NSView()
    private let accentBar = NSView()
    private let headerDivider = NSView()
    private let contentBg = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let statsField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")
    private let collapseChevron = NSImageView()
    private let cancelButton = NSButton(title: "Stop", target: nil, action: nil)
    private let contentContainer = FlippedContentView()
    private let progressIndicator = NSProgressIndicator()

    // ── State ──

    private var model: NativeExpandedToolModel?
    var onCollapse: ((String) -> Void)?
    var onCancel: ((String) -> Void)?

    // ── Init ──

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    // ── Setup ──

    private func setup() {
      wantsLayer = true

      // Card background
      cardBackground.wantsLayer = true
      cardBackground.layer?.backgroundColor = Self.bgColor.cgColor
      cardBackground.layer?.cornerRadius = Self.cornerRadius
      cardBackground.layer?.masksToBounds = true
      cardBackground.layer?.borderWidth = 1
      addSubview(cardBackground)

      // Accent bar — full height of card
      accentBar.wantsLayer = true
      cardBackground.addSubview(accentBar)

      // Header divider — thin line separating header from content
      headerDivider.wantsLayer = true
      headerDivider.layer?.backgroundColor = Self.headerDividerColor.cgColor
      cardBackground.addSubview(headerDivider)

      // Content background — darker inset behind output
      contentBg.wantsLayer = true
      contentBg.layer?.backgroundColor = Self.contentBgColor.cgColor
      cardBackground.addSubview(contentBg)

      // Icon
      iconView.imageScaling = .scaleProportionallyUpOrDown
      iconView.contentTintColor = Self.textSecondary
      cardBackground.addSubview(iconView)

      // Title
      titleField.font = Self.headerFont
      titleField.textColor = Self.textPrimary
      titleField.lineBreakMode = .byTruncatingTail
      titleField.maximumNumberOfLines = 1
      cardBackground.addSubview(titleField)

      // Subtitle
      subtitleField.font = Self.subtitleFont
      subtitleField.textColor = Self.textTertiary
      subtitleField.lineBreakMode = .byTruncatingTail
      subtitleField.maximumNumberOfLines = 1
      cardBackground.addSubview(subtitleField)

      // Stats
      statsField.font = Self.statsFont
      statsField.textColor = Self.textTertiary
      statsField.alignment = .right
      cardBackground.addSubview(statsField)

      // Duration
      durationField.font = Self.statsFont
      durationField.textColor = Self.textQuaternary
      durationField.alignment = .right
      cardBackground.addSubview(durationField)

      // Collapse chevron
      let chevronConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      collapseChevron.image = NSImage(
        systemSymbolName: "chevron.down",
        accessibilityDescription: "Collapse"
      )?.withSymbolConfiguration(chevronConfig)
      collapseChevron.contentTintColor = Self.textQuaternary
      cardBackground.addSubview(collapseChevron)

      // Progress indicator
      progressIndicator.style = .spinning
      progressIndicator.controlSize = .small
      progressIndicator.isHidden = true
      cardBackground.addSubview(progressIndicator)

      // Cancel button (shell-only)
      cancelButton.bezelStyle = .rounded
      cancelButton.font = NSFont.systemFont(ofSize: TypeScale.meta, weight: .semibold)
      cancelButton.contentTintColor = NSColor(Color.statusError)
      cancelButton.target = self
      cancelButton.action = #selector(handleCancelTap(_:))
      cancelButton.isHidden = true
      cardBackground.addSubview(cancelButton)

      // Content container — on top of content background
      contentContainer.wantsLayer = true
      cardBackground.addSubview(contentContainer)

      // Header tap gesture
      let click = NSClickGestureRecognizer(target: self, action: #selector(handleHeaderTap(_:)))
      cardBackground.addGestureRecognizer(click)
    }

    @objc private func handleHeaderTap(_ gesture: NSClickGestureRecognizer) {
      let location = gesture.location(in: cardBackground)
      if !cancelButton.isHidden, cancelButton.frame.contains(location) {
        return
      }
      let headerHeight = Self.headerHeight(for: model)
      if location.y <= headerHeight, let messageID = model?.messageID {
        onCollapse?(messageID)
      }
    }

    @objc private func handleCancelTap(_ sender: NSButton) {
      guard let messageID = model?.messageID else { return }
      onCancel?(messageID)
    }

    // ── Configure ──

    func configure(model: NativeExpandedToolModel, width: CGFloat) {
      self.model = model

      let inset = Self.laneHorizontalInset
      let cardWidth = width - inset * 2
      let headerH = ExpandedToolLayout.headerHeight(for: model, cardWidth: cardWidth)
      let contentH = ExpandedToolLayout.contentHeight(for: model, cardWidth: cardWidth)
      let totalH = Self.requiredHeight(for: width, model: model)

      // Card background — inset from lane edges
      cardBackground.frame = NSRect(x: inset, y: 0, width: cardWidth, height: totalH)
      cardBackground.layer?.borderColor = model.toolColor.withAlphaComponent(OpacityTier.light).cgColor

      // Accent bar — full height of card
      let accentColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
      accentBar.layer?.backgroundColor = accentColor.cgColor
      accentBar.frame = NSRect(x: 0, y: 0, width: Self.accentBarWidth, height: totalH)

      // Header divider line
      let dividerX = Self.accentBarWidth
      let dividerW = cardWidth - Self.accentBarWidth
      headerDivider.frame = NSRect(x: dividerX, y: headerH, width: dividerW, height: 1)
      headerDivider.isHidden = contentH == 0

      // Content background — darker region behind output (stops before card corner radius)
      if contentH > 0 {
        contentBg.isHidden = false
        contentBg.frame = NSRect(
          x: dividerX, y: headerH + 1, width: dividerW, height: contentH
        )
      } else {
        contentBg.isHidden = true
      }

      // Icon
      let iconConfig = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
      iconView.image = NSImage(
        systemSymbolName: model.iconName,
        accessibilityDescription: nil
      )?.withSymbolConfiguration(iconConfig)
      iconView.contentTintColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
      iconView.frame = NSRect(
        x: Self.accentBarWidth + Self.headerHPad,
        y: Self.headerVPad,
        width: 20, height: 20
      )

      // Title + subtitle
      configureHeader(model: model, cardWidth: cardWidth, headerH: headerH)

      // Progress indicator
      if model.isInProgress {
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        let spinnerX = model.canCancel
          ? cardWidth - Self.headerHPad - 72
          : cardWidth - Self.headerHPad - 16
        progressIndicator.frame = NSRect(
          x: spinnerX,
          y: Self.headerVPad + 2,
          width: 16, height: 16
        )
      } else {
        progressIndicator.isHidden = true
        progressIndicator.stopAnimation(nil)
      }

      if model.canCancel {
        cancelButton.isHidden = false
        cancelButton.frame = NSRect(
          x: cardWidth - Self.headerHPad - 52,
          y: Self.headerVPad,
          width: 52,
          height: 20
        )
      } else {
        cancelButton.isHidden = true
      }

      // Collapse chevron
      if !model.isInProgress, !model.canCancel {
        collapseChevron.isHidden = false
        collapseChevron.frame = NSRect(
          x: cardWidth - Self.headerHPad - 12,
          y: Self.headerVPad + 3,
          width: 12, height: 12
        )
      } else {
        collapseChevron.isHidden = true
      }

      // Duration
      if let dur = model.duration, !model.isInProgress, !model.canCancel {
        durationField.isHidden = false
        durationField.stringValue = dur
        durationField.sizeToFit()
        let durW = durationField.frame.width
        let durX = cardWidth - Self.headerHPad - 12 - 8 - durW
        durationField.frame = NSRect(x: durX, y: Self.headerVPad + 2, width: durW, height: 16)
      } else {
        durationField.isHidden = true
      }

      // Content
      contentContainer.subviews.forEach { $0.removeFromSuperview() }
      contentContainer.frame = NSRect(
        x: 0,
        y: headerH,
        width: cardWidth,
        height: contentH
      )
      buildContent(model: model, width: cardWidth)

      // ── Diagnostic: detect content overflow ──
      let maxSubviewBottom = contentContainer.subviews
        .map(\.frame.maxY)
        .max() ?? 0
      let toolType = ExpandedToolLayout.toolTypeName(model.content)
      if maxSubviewBottom > contentH + 1 {
        // Content overflows calculated height — this causes clipping
        Self.logger.info(
          "⚠️ OVERFLOW tool-cell[\(model.messageID)] \(toolType) "
            + "contentH=\(f(contentH)) maxSubview=\(f(maxSubviewBottom)) "
            + "overflow=\(f(maxSubviewBottom - contentH)) "
            + "headerH=\(f(headerH)) totalH=\(f(totalH)) w=\(f(width))"
        )
      } else {
        Self.logger.debug(
          "tool-cell[\(model.messageID)] \(toolType) "
            + "headerH=\(f(headerH)) contentH=\(f(contentH)) totalH=\(f(totalH)) "
            + "maxSubview=\(f(maxSubviewBottom)) w=\(f(width))"
        )
      }
    }

    // ── Header Configuration ──

    private func configureHeader(model: NativeExpandedToolModel, cardWidth: CGFloat, headerH: CGFloat) {
      let leftEdge = Self.accentBarWidth + Self.headerHPad + 20 + 8 // after accent + pad + icon + gap
      let rightEdge = cardWidth - Self.headerHPad - 12 - 8 - 60 // before chevron + duration

      switch model.content {
        case let .bash(command, _, _):
          let bashColor = model.hasError ? NSColor(Color.statusError) : model.toolColor
          let bashAttr = NSMutableAttributedString()
          bashAttr.append(NSAttributedString(
            string: "$ ",
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .bold),
              .foregroundColor: bashColor,
            ]
          ))
          bashAttr.append(NSAttributedString(
            string: command,
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
              .foregroundColor: Self.textPrimary,
            ]
          ))
          titleField.attributedStringValue = bashAttr
          titleField.lineBreakMode = .byCharWrapping
          titleField.maximumNumberOfLines = 0
          subtitleField.isHidden = true
          statsField.isHidden = true

        case let .edit(filename, path, additions, deletions, _, _):
          titleField.stringValue = filename ?? "Edit"
          titleField.font = Self.headerFont
          titleField.textColor = Self.textPrimary
          subtitleField.isHidden = path == nil
          subtitleField.stringValue = path.map { ToolCardStyle.shortenPath($0) } ?? ""
          configureEditStats(additions: additions, deletions: deletions, cardWidth: cardWidth)
          return

        case let .read(filename, path, language, lines):
          titleField.stringValue = filename ?? "Read"
          titleField.font = NSFont.monospacedSystemFont(ofSize: TypeScale.caption, weight: .semibold)
          titleField.textColor = Self.textPrimary
          subtitleField.isHidden = path == nil
          subtitleField.stringValue = path.map { ToolCardStyle.shortenPath($0) } ?? ""
          statsField.isHidden = false
          statsField.stringValue = "\(lines.count) lines" + (language.isEmpty ? "" : " · \(language)")

        case let .glob(pattern, grouped):
          let fileCount = grouped.reduce(0) { $0 + $1.files.count }
          titleField.stringValue = "Glob"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = pattern
          statsField.isHidden = false
          statsField.stringValue = "\(fileCount) \(fileCount == 1 ? "file" : "files")"

        case let .grep(pattern, grouped):
          let matchCount = grouped.reduce(0) { $0 + max(1, $1.matches.count) }
          titleField.stringValue = "Grep"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = pattern
          statsField.isHidden = false
          statsField.stringValue = "\(matchCount) in \(grouped.count) \(grouped.count == 1 ? "file" : "files")"

        case let .task(agentLabel, _, description, _, isComplete):
          titleField.stringValue = agentLabel
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = description.isEmpty
          subtitleField.stringValue = description
          statsField.isHidden = false
          statsField.stringValue = isComplete ? "Complete" : "Running..."
          statsField.textColor = Self.textTertiary

        case let .todo(title, subtitle, items, _):
          let completedCount = items.filter { $0.status == .completed }.count
          let activeCount = items.filter { $0.status == .inProgress }.count
          titleField.stringValue = title
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.stringValue = subtitle ?? ""
          subtitleField.isHidden = subtitle?.isEmpty ?? true
          if !items.isEmpty {
            var statusParts = ["\(completedCount)/\(items.count) done"]
            if activeCount > 0 {
              statusParts.append("\(activeCount) active")
            }
            statsField.stringValue = statusParts.joined(separator: " · ")
            statsField.isHidden = false
          } else if model.isInProgress {
            statsField.stringValue = "Syncing..."
            statsField.isHidden = false
          } else {
            statsField.isHidden = true
          }
          statsField.textColor = Self.textTertiary

        case let .mcp(server, displayTool, subtitle, _, _):
          titleField.stringValue = displayTool
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = subtitle == nil
          subtitleField.stringValue = subtitle ?? ""
          statsField.isHidden = false
          statsField.stringValue = server

        case let .webFetch(domain, _, _, _):
          titleField.stringValue = "WebFetch"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = domain
          statsField.isHidden = true

        case let .webSearch(query, _, _):
          titleField.stringValue = "WebSearch"
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = false
          subtitleField.stringValue = query
          statsField.isHidden = true

        case let .generic(toolName, _, _):
          titleField.stringValue = toolName
          titleField.font = Self.headerFont
          titleField.textColor = model.toolColor
          subtitleField.isHidden = true
          statsField.isHidden = true
      }

      // Layout title + subtitle
      let hasSubtitle = !subtitleField.isHidden
      let titleWidth = max(60, rightEdge - leftEdge)
      if hasSubtitle {
        titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad, width: titleWidth, height: 18)
        subtitleField.frame = NSRect(x: leftEdge, y: Self.headerVPad + 18, width: titleWidth, height: 16)
      } else {
        // For bash commands, measure wrapped height
        if case .bash = model.content {
          let titleH = headerH - Self.headerVPad * 2
          titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad, width: titleWidth, height: max(18, titleH))
        } else {
          titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad + 4, width: titleWidth, height: 18)
        }
      }

      // Stats (right-aligned, after title)
      if !statsField.isHidden {
        statsField.sizeToFit()
        let statsW = statsField.frame.width
        let statsX = cardWidth - Self
          .headerHPad - 12 - 8 - (durationField.isHidden ? 0 : durationField.frame.width + 8) - statsW
        statsField.frame = NSRect(x: statsX, y: Self.headerVPad + 2, width: statsW, height: 16)
      }
    }

    private func configureEditStats(additions: Int, deletions: Int, cardWidth: CGFloat) {
      subtitleField.isHidden = subtitleField.stringValue.isEmpty

      let leftEdge = Self.accentBarWidth + Self.headerHPad + 20 + 8
      let rightEdge = cardWidth - Self.headerHPad - 60

      // Layout title + subtitle for edit
      titleField.frame = NSRect(x: leftEdge, y: Self.headerVPad, width: rightEdge - leftEdge, height: 18)
      if !subtitleField.isHidden {
        subtitleField.frame = NSRect(x: leftEdge, y: Self.headerVPad + 20, width: rightEdge - leftEdge, height: 14)
      }

      // Use statsField for combined diff stats
      var parts: [String] = []
      if deletions > 0 { parts.append("−\(deletions)") }
      if additions > 0 { parts.append("+\(additions)") }
      if !parts.isEmpty {
        statsField.isHidden = false
        statsField.stringValue = parts.joined(separator: " ")
        statsField.textColor = additions > 0 ? Self.addedAccentColor : Self.removedAccentColor
      } else {
        statsField.isHidden = true
      }
    }

    // ── Content Builders ──

    private func buildContent(model: NativeExpandedToolModel, width: CGFloat) {
      switch model.content {
        case let .bash(_, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .edit(_, _, _, _, lines, isWriteNew):
          buildEditContent(lines: lines, isWriteNew: isWriteNew, width: width)
        case let .read(_, _, language, lines):
          buildReadContent(lines: lines, language: language, width: width)
        case let .glob(_, grouped):
          buildGlobContent(grouped: grouped, width: width)
        case let .grep(_, grouped):
          buildGrepContent(grouped: grouped, width: width)
        case let .task(_, _, _, output, _):
          buildTextOutputContent(output: output, width: width)
        case let .todo(_, _, items, output):
          buildTodoContent(items: items, output: output, width: width)
        case let .mcp(_, _, _, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .webFetch(_, _, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .webSearch(_, input, output):
          buildGenericContent(input: input, output: output, width: width)
        case let .generic(toolName, input, output):
          buildGenericContent(toolName: toolName, input: input, output: output, width: width)
      }
    }

    // ── Text Output (bash, mcp, webfetch, websearch, task) ──

    private func buildTextOutputContent(output: String?, width: CGFloat) {
      guard let output, !output.isEmpty else { return }

      let lines = output.components(separatedBy: "\n")
      let textWidth = width - Self.headerHPad * 2
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for line in lines {
        let text = line.isEmpty ? " " : line
        let label = NSTextField(labelWithString: text)
        label.font = Self.codeFont
        label.textColor = Self.textSecondary
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        let labelH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: textWidth)
        label.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: labelH)
        contentContainer.addSubview(label)
        y += labelH
      }
    }

    // ── Edit (diff lines) ──

    private func buildEditContent(lines: [DiffLine], isWriteNew: Bool, width: CGFloat) {
      var y: CGFloat = 0

      // Write new file header
      if isWriteNew {
        let header = NSTextField(labelWithString: "NEW FILE (\(lines.count) lines)")
        header.font = NSFont.systemFont(ofSize: TypeScale.micro, weight: .bold)
        header.textColor = Self.addedAccentColor
        header.frame = NSRect(x: Self.headerHPad, y: y + 6, width: width - Self.headerHPad * 2, height: 16)
        contentContainer.addSubview(header)

        let headerBg = NSView(frame: NSRect(x: 0, y: y, width: width, height: 28))
        headerBg.wantsLayer = true
        headerBg.layer?.backgroundColor = Self.addedBgColor.withAlphaComponent(0.3).cgColor
        contentContainer.addSubview(headerBg, positioned: .below, relativeTo: nil)
        y += 28
      }

      let gutterMetrics = ExpandedToolLayout.diffGutterMetrics(for: lines)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - ExpandedToolLayout.diffContentTrailingPad
      let diffFont = ExpandedToolLayout.diffContentFont

      // Measure widest line for scroll content
      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.content.isEmpty ? " " : line.content
        let w = ceil((text as NSString).size(withAttributes: [.font: diffFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      // Horizontal scroll view for code content
      let totalDiffH = CGFloat(lines.count) * Self.diffLineHeight
      let scrollView = HorizontalPanPassthroughScrollView()
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.frame = NSRect(x: codeX, y: y, width: codeAvailW, height: totalDiffH)

      let docView = FlippedContentView()
      docView.frame = NSRect(x: 0, y: 0, width: scrollContentW, height: totalDiffH)
      scrollView.documentView = docView

      var rowY: CGFloat = 0
      for line in lines {
        let bgColor: NSColor
        let prefixColor: NSColor
        let contentColor: NSColor
        switch line.type {
          case .added:
            bgColor = Self.addedBgColor
            prefixColor = Self.addedAccentColor
            contentColor = Self.textPrimary
          case .removed:
            bgColor = Self.removedBgColor
            prefixColor = Self.removedAccentColor
            contentColor = Self.textPrimary
          case .context:
            bgColor = .clear
            prefixColor = Self.textQuaternary
            contentColor = Self.textTertiary
        }

        // Row background (full card width, in contentContainer)
        let rowBg = NSView(frame: NSRect(x: 0, y: y + rowY, width: width, height: Self.diffLineHeight))
        rowBg.wantsLayer = true
        rowBg.layer?.backgroundColor = bgColor.cgColor
        contentContainer.addSubview(rowBg)

        // Line numbers (in contentContainer — stay fixed)
        if let oldLineNumberX = gutterMetrics.oldLineNumberX, let num = line.oldLineNum {
          let numLabel = NSTextField(labelWithString: "\(num)")
          numLabel.font = Self.lineNumFont
          numLabel.textColor = Self.textQuaternary
          numLabel.alignment = .right
          numLabel.frame = NSRect(
            x: oldLineNumberX,
            y: y + rowY + 2,
            width: gutterMetrics.oldLineNumberWidth,
            height: 18
          )
          contentContainer.addSubview(numLabel)
        }
        if let newLineNumberX = gutterMetrics.newLineNumberX, let num = line.newLineNum {
          let numLabel = NSTextField(labelWithString: "\(num)")
          numLabel.font = Self.lineNumFont
          numLabel.textColor = Self.textQuaternary
          numLabel.alignment = .right
          numLabel.frame = NSRect(
            x: newLineNumberX,
            y: y + rowY + 2,
            width: gutterMetrics.newLineNumberWidth,
            height: 18
          )
          contentContainer.addSubview(numLabel)
        }

        // Prefix (in contentContainer — stays fixed)
        let prefixLabel = NSTextField(labelWithString: line.prefix)
        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.body, weight: .bold)
        prefixLabel.textColor = prefixColor
        prefixLabel.frame = NSRect(
          x: gutterMetrics.prefixX,
          y: y + rowY + 1,
          width: ExpandedToolLayout.diffPrefixWidth,
          height: 20
        )
        contentContainer.addSubview(prefixLabel)

        // Code content (in scroll view — scrolls horizontally)
        let text = line.content.isEmpty ? " " : line.content
        let contentLabel = NSTextField(labelWithString: text)
        contentLabel.font = diffFont
        contentLabel.textColor = contentColor
        contentLabel.lineBreakMode = .byClipping
        contentLabel.maximumNumberOfLines = 1
        contentLabel.isSelectable = true
        contentLabel.frame = NSRect(x: 0, y: rowY + 2, width: scrollContentW, height: 18)
        docView.addSubview(contentLabel)

        rowY += Self.diffLineHeight
      }

      contentContainer.addSubview(scrollView)
    }

    // ── Read (line-numbered code) ──

    private func buildReadContent(lines: [String], language: String, width: CGFloat) {
      let gutterMetrics = ExpandedToolLayout.readGutterMetrics(lineCount: lines.count)
      let codeX = gutterMetrics.codeX
      let codeAvailW = width - codeX - ExpandedToolLayout.diffContentTrailingPad
      let lang = language.isEmpty ? nil : language
      let y: CGFloat = Self.sectionPadding + Self.contentTopPad

      // Measure widest line for scroll content
      var maxTextWidth: CGFloat = 0
      for line in lines {
        let text = line.isEmpty ? " " : line
        let w = ceil((text as NSString).size(withAttributes: [.font: Self.codeFont as Any]).width)
        maxTextWidth = max(maxTextWidth, w)
      }
      let scrollContentW = max(codeAvailW, maxTextWidth + 8)

      // Horizontal scroll view for code content
      let totalH = CGFloat(lines.count) * Self.contentLineHeight
      let scrollView = HorizontalPanPassthroughScrollView()
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.frame = NSRect(x: codeX, y: y, width: codeAvailW, height: totalH)

      let docView = FlippedContentView()
      docView.frame = NSRect(x: 0, y: 0, width: scrollContentW, height: totalH)
      scrollView.documentView = docView

      var rowY: CGFloat = 0
      for (index, line) in lines.enumerated() {
        let text = line.isEmpty ? " " : line

        // Line number (in contentContainer — stays fixed)
        let numLabel = NSTextField(labelWithString: "\(index + 1)")
        numLabel.font = Self.lineNumFont
        numLabel.textColor = Self.textQuaternary
        numLabel.alignment = .right
        numLabel.frame = NSRect(
          x: gutterMetrics.lineNumberX,
          y: y + rowY,
          width: gutterMetrics.lineNumberWidth,
          height: Self.contentLineHeight
        )
        contentContainer.addSubview(numLabel)

        // Code line (in scroll view — scrolls horizontally)
        let codeLine = NSTextField(labelWithString: "")
        codeLine.attributedStringValue = SyntaxHighlighter.highlightNativeLine(text, language: lang)
        codeLine.lineBreakMode = .byClipping
        codeLine.maximumNumberOfLines = 1
        codeLine.isSelectable = true
        codeLine.frame = NSRect(x: 0, y: rowY, width: scrollContentW, height: Self.contentLineHeight)
        docView.addSubview(codeLine)

        rowY += Self.contentLineHeight
      }

      contentContainer.addSubview(scrollView)
    }

    // ── Glob (directory tree) ──

    private func buildGlobContent(grouped: [(dir: String, files: [String])], width: CGFloat) {
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for (dir, files) in grouped {
        // Directory header
        let dirIcon = NSImageView()
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        dirIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
          .withSymbolConfiguration(iconConfig)
        dirIcon.contentTintColor = NSColor(Color.toolWrite)
        dirIcon.frame = NSRect(x: Self.headerHPad, y: y + 2, width: 14, height: 14)
        contentContainer.addSubview(dirIcon)

        let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
        let dirLabel = NSTextField(labelWithString: dirText)
        dirLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
        dirLabel.textColor = Self.textSecondary
        dirLabel.lineBreakMode = .byCharWrapping
        dirLabel.maximumNumberOfLines = 0
        let dirW = width - Self.headerHPad * 2 - 18
        let dirH = ExpandedToolLayout.measuredTextHeight(dirText, font: dirLabel.font!, maxWidth: dirW)
        dirLabel.frame = NSRect(x: Self.headerHPad + 18, y: y, width: dirW, height: dirH)
        contentContainer.addSubview(dirLabel)
        y += dirH + 2

        // Files
        for file in files {
          let filename = file.components(separatedBy: "/").last ?? file
          let fileLabel = NSTextField(labelWithString: filename)
          fileLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)
          fileLabel.textColor = Self.textTertiary
          fileLabel.lineBreakMode = .byCharWrapping
          fileLabel.maximumNumberOfLines = 0
          let fileX = Self.headerHPad + 28
          let fileW = width - Self.headerHPad * 2 - 28
          let fileH = ExpandedToolLayout.measuredTextHeight(filename, font: fileLabel.font!, maxWidth: fileW)
          fileLabel.frame = NSRect(
            x: fileX, y: y, width: fileW, height: fileH
          )
          contentContainer.addSubview(fileLabel)
          y += fileH
        }

        y += 6
      }
    }

    // ── Grep (file-grouped results) ──

    private func buildGrepContent(grouped: [(file: String, matches: [String])], width: CGFloat) {
      var y: CGFloat = Self.sectionPadding + Self.contentTopPad

      for (file, matches) in grouped {
        // File header
        let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
        let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
        let fileText = shortPath + matchSuffix
        let fileLabel = NSTextField(labelWithString: fileText)
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
        fileLabel.textColor = Self.textPrimary
        fileLabel.lineBreakMode = .byCharWrapping
        fileLabel.maximumNumberOfLines = 0
        let fileLabelW = width - Self.headerHPad * 2
        let fileLabelH = ExpandedToolLayout.measuredTextHeight(fileText, font: fileLabel.font!, maxWidth: fileLabelW)
        fileLabel.frame = NSRect(x: Self.headerHPad, y: y, width: fileLabelW, height: fileLabelH)
        contentContainer.addSubview(fileLabel)
        y += fileLabelH + 2

        // Match lines
        for match in matches {
          let matchLabel = NSTextField(labelWithString: match)
          matchLabel.font = Self.codeFont
          matchLabel.textColor = Self.textTertiary
          matchLabel.lineBreakMode = .byCharWrapping
          matchLabel.maximumNumberOfLines = 0
          let matchX = Self.headerHPad + 16
          let matchW = width - Self.headerHPad * 2 - 16
          let matchH = ExpandedToolLayout.measuredTextHeight(match, font: Self.codeFont, maxWidth: matchW)
          matchLabel.frame = NSRect(
            x: matchX, y: y, width: matchW, height: matchH
          )
          contentContainer.addSubview(matchLabel)
          y += matchH
        }

        y += 6
      }
    }

    // ── Todo (structured checklist) ──

    private func buildTodoContent(items: [NativeTodoItem], output: String?, width: CGFloat) {
      var y: CGFloat = Self.contentTopPad
      let contentWidth = width - Self.headerHPad * 2

      if !items.isEmpty {
        let todoHeader = NSTextField(labelWithString: "")
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.8,
          .font: Self.sectionLabelFont as Any,
          .foregroundColor: Self.textQuaternary,
        ]
        todoHeader.attributedStringValue = NSAttributedString(string: "TODOS", attributes: attrs)
        todoHeader.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(todoHeader)
        y += Self.sectionHeaderHeight + Self.sectionPadding

        for item in items {
          let style = ExpandedToolLayout.todoStatusStyle(item.status)
          let statusText = item.status.label.uppercased()
          let badgeTextWidth = ceil((statusText as NSString).size(withAttributes: [.font: Self.statsFont as Any]).width)
          let badgeWidth = min(
            ExpandedToolLayout.todoBadgeMaxWidth,
            max(
              ExpandedToolLayout.todoBadgeMinWidth,
              badgeTextWidth + ExpandedToolLayout.todoBadgeSidePadding * 2
            )
          )

          let rowX = Self.headerHPad
          let rowW = contentWidth
          let iconAndGap = ExpandedToolLayout.todoIconWidth + 8
          let textX = rowX + ExpandedToolLayout.todoRowHorizontalPadding + iconAndGap
          let badgeX = rowX + rowW - ExpandedToolLayout.todoRowHorizontalPadding - badgeWidth
          let textW = max(90, badgeX - textX - 8)
          let primaryHeight = ExpandedToolLayout.measuredTextHeight(
            item.primaryText,
            font: ExpandedToolLayout.todoTitleFont,
            maxWidth: textW
          )
          let secondaryHeight = item.secondaryText.map {
            ExpandedToolLayout.measuredTextHeight(
              $0,
              font: ExpandedToolLayout.todoSecondaryFont,
              maxWidth: textW
            )
          } ?? 0
          let textHeight = primaryHeight + (secondaryHeight > 0 ? 2 + secondaryHeight : 0)
          let rowHeight = max(
            ExpandedToolLayout.todoBadgeHeight + ExpandedToolLayout.todoRowVerticalPadding * 2,
            textHeight + ExpandedToolLayout.todoRowVerticalPadding * 2
          )

          let rowBackground = NSView(frame: NSRect(x: rowX, y: y, width: rowW, height: rowHeight))
          rowBackground.wantsLayer = true
          rowBackground.layer?.cornerRadius = 8
          rowBackground.layer?.backgroundColor = style.rowBackground.cgColor
          contentContainer.addSubview(rowBackground)

          let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
          let iconView = NSImageView()
          iconView.image = NSImage(
            systemSymbolName: todoStatusIconName(for: item.status),
            accessibilityDescription: nil
          )?
            .withSymbolConfiguration(iconConfig)
          iconView.contentTintColor = style.tint
          iconView.frame = NSRect(
            x: rowX + ExpandedToolLayout.todoRowHorizontalPadding,
            y: y + (rowHeight - 14) / 2,
            width: 14,
            height: 14
          )
          contentContainer.addSubview(iconView)

          let primaryLabel = NSTextField(labelWithString: item.primaryText)
          primaryLabel.font = ExpandedToolLayout.todoTitleFont
          primaryLabel.textColor = Self.textPrimary
          primaryLabel.lineBreakMode = .byWordWrapping
          primaryLabel.maximumNumberOfLines = 0
          primaryLabel.isSelectable = true
          primaryLabel.frame = NSRect(
            x: textX,
            y: y + ExpandedToolLayout.todoRowVerticalPadding,
            width: textW,
            height: primaryHeight
          )
          contentContainer.addSubview(primaryLabel)

          if let secondaryText = item.secondaryText {
            let secondaryLabel = NSTextField(labelWithString: secondaryText)
            secondaryLabel.font = ExpandedToolLayout.todoSecondaryFont
            secondaryLabel.textColor = Self.textTertiary
            secondaryLabel.lineBreakMode = .byWordWrapping
            secondaryLabel.maximumNumberOfLines = 0
            secondaryLabel.isSelectable = true
            secondaryLabel.frame = NSRect(
              x: textX,
              y: primaryLabel.frame.maxY + 2,
              width: textW,
              height: secondaryHeight
            )
            contentContainer.addSubview(secondaryLabel)
          }

          let badgeHeight = ExpandedToolLayout.todoBadgeHeight
          let badgeY = y + (rowHeight - badgeHeight) / 2
          let badgeView = NSView(frame: NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight))
          badgeView.wantsLayer = true
          badgeView.layer?.cornerRadius = 6
          badgeView.layer?.backgroundColor = style.badgeBackground.cgColor
          contentContainer.addSubview(badgeView)

          let badgeLabel = NSTextField(labelWithString: statusText)
          badgeLabel.font = Self.statsFont
          badgeLabel.textColor = Self.textPrimary
          badgeLabel.alignment = .center
          badgeLabel.frame = NSRect(x: 0, y: 3, width: badgeWidth, height: 14)
          badgeView.addSubview(badgeLabel)

          y += rowHeight + ExpandedToolLayout.todoRowSpacing
        }

        y += Self.sectionPadding
      }

      if let output, !output.isEmpty {
        let outputHeader = NSTextField(labelWithString: "")
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.8,
          .font: Self.sectionLabelFont as Any,
          .foregroundColor: Self.textQuaternary,
        ]
        outputHeader.attributedStringValue = NSAttributedString(string: "RESULT", attributes: attrs)
        outputHeader.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 60, height: 14)
        contentContainer.addSubview(outputHeader)
        y += Self.sectionHeaderHeight + Self.sectionPadding

        let outputLines = output.components(separatedBy: "\n")
        let textW = width - Self.headerHPad * 2
        for line in outputLines {
          let text = line.isEmpty ? " " : line
          let label = NSTextField(labelWithString: text)
          label.font = Self.codeFont
          label.textColor = Self.textSecondary
          label.lineBreakMode = .byCharWrapping
          label.maximumNumberOfLines = 0
          label.isSelectable = true
          let lineH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: textW)
          label.frame = NSRect(x: Self.headerHPad, y: y, width: textW, height: lineH)
          contentContainer.addSubview(label)
          y += lineH
        }

        y += Self.sectionPadding
      }
    }

    private func todoStatusIconName(for status: NativeTodoStatus) -> String {
      switch status {
        case .pending: "circle"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
      }
    }

    // ── Generic (input + output) ──

    private func buildGenericContent(toolName: String? = nil, input: String?, output: String?, width: CGFloat) {
      var y: CGFloat = Self.contentTopPad

      buildPayloadSection(title: "INPUT", payload: input, toolName: toolName, width: width, y: &y)
      buildPayloadSection(title: "OUTPUT", payload: output, width: width, y: &y)
    }

    private func buildPayloadSection(
      title: String,
      payload: String?,
      toolName: String? = nil,
      width: CGFloat,
      y: inout CGFloat
    ) {
      guard let payload, !payload.isEmpty else { return }

      let header = NSTextField(labelWithString: "")
      let attrs: [NSAttributedString.Key: Any] = [
        .kern: 0.8,
        .font: Self.sectionLabelFont as Any,
        .foregroundColor: Self.textQuaternary,
      ]
      header.attributedStringValue = NSAttributedString(string: title, attributes: attrs)
      header.frame = NSRect(x: Self.headerHPad, y: y + Self.sectionPadding, width: 80, height: 14)
      contentContainer.addSubview(header)
      y += Self.sectionHeaderHeight + Self.sectionPadding

      let textWidth = width - Self.headerHPad * 2
      if toolName?.lowercased() == "question",
         let questions = ExpandedToolLayout.askUserQuestionItems(from: payload)
      {
        for (index, question) in questions.enumerated() {
          if let headerText = question.header, !headerText.isEmpty {
            let headerLabel = NSTextField(labelWithString: headerText.uppercased())
            headerLabel.font = NSFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
            headerLabel.textColor = Self.textQuaternary
            headerLabel.frame = NSRect(
              x: Self.headerHPad,
              y: y,
              width: textWidth,
              height: ExpandedToolLayout.measuredTextHeight(
                headerText,
                font: NSFont.systemFont(ofSize: TypeScale.mini, weight: .bold),
                maxWidth: textWidth
              )
            )
            contentContainer.addSubview(headerLabel)
            y += headerLabel.frame.height + 3
          }

          let promptLabel = NSTextField(labelWithString: question.question)
          promptLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
          promptLabel.textColor = Self.textPrimary
          promptLabel.lineBreakMode = .byWordWrapping
          promptLabel.maximumNumberOfLines = 0
          promptLabel.isSelectable = true
          let promptHeight = ExpandedToolLayout.measuredTextHeight(
            question.question,
            font: NSFont.systemFont(ofSize: TypeScale.body, weight: .semibold),
            maxWidth: textWidth
          )
          promptLabel.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: promptHeight)
          contentContainer.addSubview(promptLabel)
          y += promptHeight

          if !question.options.isEmpty {
            y += 6
            for option in question.options {
              let optionLabel = NSTextField(labelWithString: "• \(option.label)")
              optionLabel.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
              optionLabel.textColor = Self.textSecondary
              optionLabel.lineBreakMode = .byWordWrapping
              optionLabel.maximumNumberOfLines = 0
              optionLabel.isSelectable = true
              let optionText = "• \(option.label)"
              let optionHeight = ExpandedToolLayout.measuredTextHeight(
                optionText,
                font: NSFont.systemFont(ofSize: TypeScale.caption, weight: .medium),
                maxWidth: textWidth
              )
              optionLabel.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: optionHeight)
              contentContainer.addSubview(optionLabel)
              y += optionHeight

              if let detail = option.description, !detail.isEmpty {
                let detailLabel = NSTextField(labelWithString: detail)
                detailLabel.font = NSFont.systemFont(ofSize: TypeScale.meta, weight: .regular)
                detailLabel.textColor = Self.textTertiary
                detailLabel.lineBreakMode = .byWordWrapping
                detailLabel.maximumNumberOfLines = 0
                detailLabel.isSelectable = true
                let detailHeight = ExpandedToolLayout.measuredTextHeight(
                  detail,
                  font: NSFont.systemFont(ofSize: TypeScale.meta, weight: .regular),
                  maxWidth: textWidth
                )
                detailLabel.frame = NSRect(
                  x: Self.headerHPad + 14,
                  y: y + 2,
                  width: textWidth - 14,
                  height: detailHeight
                )
                contentContainer.addSubview(detailLabel)
                y += detailHeight + 2
              }

              y += 5
            }
            y -= 5
          }

          if index < questions.count - 1 {
            y += 8
          }
        }
      } else if let entries = ExpandedToolLayout.structuredPayloadEntries(from: payload) {
        for entry in entries {
          let label = NSTextField(labelWithAttributedString: payloadAttributedLine(
            key: entry.keyPath,
            value: entry.value
          ))
          label.lineBreakMode = .byCharWrapping
          label.maximumNumberOfLines = 0
          label.isSelectable = true
          let text = "\(entry.keyPath): \(entry.value)"
          let lineH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: textWidth)
          label.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: lineH)
          contentContainer.addSubview(label)
          y += lineH
        }
      } else {
        let lines = ExpandedToolLayout.payloadDisplayLines(from: payload)
        for line in lines {
          let text = line.isEmpty ? " " : line
          let label = NSTextField(labelWithString: text)
          label.font = Self.codeFont
          label.textColor = Self.textSecondary
          label.lineBreakMode = .byCharWrapping
          label.maximumNumberOfLines = 0
          label.isSelectable = true
          let lineH = ExpandedToolLayout.measuredTextHeight(text, font: Self.codeFont, maxWidth: textWidth)
          label.frame = NSRect(x: Self.headerHPad, y: y, width: textWidth, height: lineH)
          contentContainer.addSubview(label)
          y += lineH
        }
      }

      y += Self.sectionPadding
    }

    private func payloadAttributedLine(key: String, value: String) -> NSAttributedString {
      let attributed = NSMutableAttributedString(
        string: "\(key): ",
        attributes: [
          .font: Self.codeFontStrong as Any,
          .foregroundColor: Self.textQuaternary,
        ]
      )
      attributed.append(NSAttributedString(
        string: value,
        attributes: [
          .font: Self.codeFont as Any,
          .foregroundColor: Self.textSecondary,
        ]
      ))
      return attributed
    }

    // ── Height Calculation (delegates to shared ExpandedToolLayout) ──

    static func headerHeight(for model: NativeExpandedToolModel?) -> CGFloat {
      ExpandedToolLayout.headerHeight(for: model)
    }

    static func contentHeight(for model: NativeExpandedToolModel) -> CGFloat {
      ExpandedToolLayout.contentHeight(for: model)
    }

    static func requiredHeight(for width: CGFloat, model: NativeExpandedToolModel) -> CGFloat {
      let total = ExpandedToolLayout.requiredHeight(for: width, model: model)
      let tool = ExpandedToolLayout.toolTypeName(model.content)
      let h = ExpandedToolLayout.headerHeight(for: model)
      let c = ExpandedToolLayout.contentHeight(for: model)
      logger.debug(
        "requiredHeight[\(model.messageID)] \(tool) "
          + "header=\(f(h)) content=\(f(c)) total=\(f(total)) w=\(f(width))"
      )
      return total
    }

    private func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }

    private static func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
    }
  }

  // MARK: - Flipped Content View

  private final class FlippedContentView: NSView {
    override var isFlipped: Bool {
      true
    }
  }

#endif
