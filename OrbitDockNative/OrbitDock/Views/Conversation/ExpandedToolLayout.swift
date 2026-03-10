//
//  ExpandedToolLayout.swift
//  OrbitDock
//
//  Shared layout math and payload parsing for expanded tool cards.
//

import SwiftUI

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
    return ReadGutterMetrics(lineNumberX: lineNumberX, lineNumberWidth: lineNumberWidth, codeX: codeX)
  }

  private static func lineNumberColumnWidth(maxLineNumber: Int) -> CGFloat {
    let text = "\(max(0, maxLineNumber))"
    let measured = ceil((text as NSString).size(withAttributes: [.font: lineNumFont as Any]).width)
    return max(minLineNumberColumnWidth, measured + lineNumberHorizontalPadding)
  }

  static let bgColor = PlatformColor.calibrated(red: 0.06, green: 0.06, blue: 0.08, alpha: 0.85)
  static let contentBgColor = PlatformColor.calibrated(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
  static let headerDividerColor = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.06)

  static let addedBgColor = PlatformColor.calibrated(red: 0.15, green: 0.32, blue: 0.18, alpha: 0.6)
  static let removedBgColor = PlatformColor.calibrated(red: 0.35, green: 0.14, blue: 0.14, alpha: 0.6)
  static let addedAccentColor = PlatformColor.calibrated(red: 0.4, green: 0.95, blue: 0.5, alpha: 1)
  static let removedAccentColor = PlatformColor.calibrated(red: 1.0, green: 0.5, blue: 0.5, alpha: 1)

  static let textPrimary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.92)
  static let textSecondary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.65)
  static let textTertiary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.50)
  static let textQuaternary = PlatformColor.calibrated(red: 1, green: 1, blue: 1, alpha: 0.38)

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
        return (isWriteNew ? 28 : 0) + CGFloat(lines.count) * diffLineHeight
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

  struct StructuredPayloadEntry: Equatable {
    let keyPath: String
    let value: String
  }

  struct AskUserQuestionOption: Equatable {
    let label: String
    let description: String?
  }

  struct AskUserQuestionItem: Equatable {
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
          appendStructuredEntry(path: path, value: "[\(scalarPreview.joined(separator: ", "))]", into: &entries)
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
    let header = headerHeight(for: model, cardWidth: cardWidth)
    let content = contentHeight(for: model, cardWidth: cardWidth)
    return header + content + (content > 0 ? bottomPadding : 0)
  }

  static func textOutputHeight(output: String?, cardWidth: CGFloat = 0) -> CGFloat {
    guard let output, !output.isEmpty else { return 0 }
    let lines = output.components(separatedBy: "\n")
    let textWidth = contentTextWidth(cardWidth: cardWidth)

    var height: CGFloat = sectionPadding + contentTopPad
    if textWidth > 0 {
      for line in lines {
        height += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
      }
    } else {
      height += CGFloat(lines.count) * contentLineHeight
    }
    return height + sectionPadding
  }

  static func readHeight(lines: [String], cardWidth _: CGFloat) -> CGFloat {
    sectionPadding + contentTopPad + CGFloat(lines.count) * contentLineHeight + sectionPadding
  }

  static func globHeight(grouped: [(dir: String, files: [String])], cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let fileTextWidth = textWidth > 0 ? textWidth - 28 : 0
    let dirFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)
    let fileFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .regular)

    var height: CGFloat = sectionPadding + contentTopPad
    for (dir, files) in grouped {
      let dirText = "\(dir == "." ? "(root)" : dir) (\(files.count))"
      height += textWidth > 0
        ? measuredTextHeight(dirText, font: dirFont, maxWidth: textWidth - 18)
        : 20

      for file in files {
        let filename = file.components(separatedBy: "/").last ?? file
        height += fileTextWidth > 0
          ? measuredTextHeight(filename, font: fileFont, maxWidth: fileTextWidth)
          : contentLineHeight
      }
      height += 6
    }
    return height
  }

  static func grepHeight(grouped: [(file: String, matches: [String])], cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let matchTextWidth = textWidth > 0 ? textWidth - 16 : 0
    let fileFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.meta, weight: .medium)

    var height: CGFloat = sectionPadding + contentTopPad
    for (file, matches) in grouped {
      let shortPath = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
      let matchSuffix = matches.isEmpty ? "" : " (\(matches.count))"
      height += textWidth > 0
        ? measuredTextHeight(shortPath + matchSuffix, font: fileFont, maxWidth: textWidth) + 2
        : 20

      for match in matches {
        height += matchTextWidth > 0
          ? measuredTextHeight(match, font: codeFont, maxWidth: matchTextWidth)
          : contentLineHeight
      }
      height += 6
    }
    return height
  }

  static func genericHeight(toolName: String? = nil, input: String?, output: String?, cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    var height: CGFloat = contentTopPad

    if let input, !input.isEmpty {
      height += sectionPadding + sectionHeaderHeight
      if toolName?.lowercased() == "question", let questions = askUserQuestionItems(from: input) {
        let titleFont = PlatformFont.systemFont(ofSize: 12.5, weight: .semibold)
        let optionFont = PlatformFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
        let detailFont = PlatformFont.systemFont(ofSize: TypeScale.meta, weight: .regular)

        for (index, question) in questions.enumerated() {
          if let header = question.header, !header.isEmpty {
            height += measuredTextHeight(header, font: detailFont, maxWidth: textWidth) + 3
          }
          height += measuredTextHeight(question.question, font: titleFont, maxWidth: textWidth)

          if !question.options.isEmpty {
            height += 6
            for option in question.options {
              height += measuredTextHeight(option.label, font: optionFont, maxWidth: textWidth)
              if let description = option.description, !description.isEmpty {
                height += 2 + measuredTextHeight(description, font: detailFont, maxWidth: textWidth)
              }
              height += 5
            }
            height -= 5
          }

          if index < questions.count - 1 {
            height += 8
          }
        }
      } else {
        let lines = payloadDisplayLines(from: input)
        if textWidth > 0 {
          for line in lines {
            height += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
          }
        } else {
          height += CGFloat(lines.count) * contentLineHeight
        }
      }
      height += sectionPadding
    }

    if let output, !output.isEmpty {
      let lines = payloadDisplayLines(from: output)
      height += sectionPadding + sectionHeaderHeight
      if textWidth > 0 {
        for line in lines {
          height += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
        }
      } else {
        height += CGFloat(lines.count) * contentLineHeight
      }
      height += sectionPadding
    }

    return height
  }

  static func todoHeight(items: [NativeTodoItem], output: String?, cardWidth: CGFloat = 0) -> CGFloat {
    let textWidth = contentTextWidth(cardWidth: cardWidth)
    let hasOutput = output?.isEmpty == false
    let hasItems = !items.isEmpty
    var height: CGFloat = contentTopPad

    if hasItems {
      height += sectionPadding + sectionHeaderHeight

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
        let rowHeight = max(todoBadgeHeight + todoRowVerticalPadding * 2, textHeight + todoRowVerticalPadding * 2)
        height += rowHeight + todoRowSpacing
      }

      height += sectionPadding
    }

    if hasOutput {
      let lines = (output ?? "").components(separatedBy: "\n")
      height += sectionPadding + sectionHeaderHeight
      if textWidth > 0 {
        for line in lines {
          height += measuredTextHeight(line.isEmpty ? " " : line, font: codeFont, maxWidth: textWidth)
        }
      } else {
        height += CGFloat(lines.count) * contentLineHeight
      }
      height += sectionPadding
    }

    return height
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
