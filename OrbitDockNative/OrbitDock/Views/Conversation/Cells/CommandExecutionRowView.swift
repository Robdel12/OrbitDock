//
//  CommandExecutionRowView.swift
//  OrbitDock
//
//  Structured Codex command execution row.
//

import SwiftUI

struct CommandExecutionRowView: View {
  let row: ServerConversationCommandExecutionRow
  let isExpanded: Bool
  var fetchedContent: ServerRowContent?
  var isLoadingContent: Bool = false
  var onToggle: (() -> Void)?

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isCompactLayout: Bool {
    sizeClass == .compact
  }

  private var semanticSummary: String {
    if row.commandActions.allSatisfy({ $0.type == .read }) {
      return row.commandActions.count == 1 ? "Read file" : "Read \(row.commandActions.count) files"
    }
    if row.commandActions.allSatisfy({ $0.type == .search }) {
      return row.commandActions.count == 1 ? "Search files" : "Search across files"
    }
    if row.commandActions.allSatisfy({ $0.type == .listFiles }) {
      return row.commandActions.count == 1 ? "List files" : "List file groups"
    }
    return "Run command"
  }

  private var semanticIcon: String {
    if row.commandActions.allSatisfy({ $0.type == .read }) {
      return "doc.text.fill"
    }
    if row.commandActions.allSatisfy({ $0.type == .search }) {
      return "magnifyingglass"
    }
    if row.commandActions.allSatisfy({ $0.type == .listFiles }) {
      return "folder.fill"
    }
    return "terminal"
  }

  private var semanticColor: Color {
    if row.commandActions.allSatisfy({ $0.type == .read }) {
      return .toolRead
    }
    if row.commandActions.allSatisfy({ $0.type == .search || $0.type == .listFiles }) {
      return .toolSearch
    }
    return .toolBash
  }

  private var statusColor: Color {
    switch row.status {
      case .inProgress:
        .statusWorking
      case .completed:
        .feedbackPositive
      case .failed:
        .feedbackNegative
      case .declined:
        .feedbackWarning
    }
  }

  private var statusLabel: String {
    switch row.status {
      case .inProgress:
        "Live"
      case .completed:
        "Done"
      case .failed:
        "Fail"
      case .declined:
        "Declined"
    }
  }

  private var exitLabel: String? {
    guard let exitCode = row.exitCode else { return nil }
    return exitCode == 0 ? "Exit 0" : "Exit \(exitCode)"
  }

  private var durationLabel: String? {
    guard let durationMs = row.durationMs else { return nil }
    let durationSeconds = Double(durationMs) / 1000
    if durationSeconds >= 10 {
      return String(format: "%.1fs", durationSeconds)
    }
    return String(format: "%.2fs", durationSeconds)
  }

  private var workingDirectoryLabel: String? {
    if let shortened = shortenedPath(row.cwd) {
      return shortened
    }

    let cwd = row.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cwd.isEmpty else { return nil }
    return cwd
  }

  private var supportingText: String? {
    let actions = row.commandActions

    if actions.allSatisfy({ $0.type == .search }) {
      if let query = actions
        .compactMap({ $0.query })
        .map({ normalizedInlineText($0, limit: 72) })
        .first(where: { !$0.isEmpty })
      {
        return query
      }
    }

    let pathLabels = orderedUniqueNonEmpty(actions.compactMap { action in
      if action.type == .read {
        return normalizedInlineText(action.name ?? shortenedPath(action.path) ?? action.path ?? "", limit: 72)
      }
      return normalizedInlineText(shortenedPath(action.path) ?? action.path ?? "", limit: 72)
    })

    if let firstPath = pathLabels.first {
      let hiddenCount = max(0, pathLabels.count - 1)
      return hiddenCount > 0 ? "\(firstPath) +\(hiddenCount) more" : firstPath
    }

    if let workingDirectoryLabel {
      return workingDirectoryLabel
    }

    let commandSummary = normalizedInlineText(row.command, limit: 84)
    return commandSummary.isEmpty ? nil : commandSummary
  }

  private var preview: ServerConversationCommandExecutionPreview? {
    row.preview
  }

  private var previewLines: [String] {
    if let lines = preview?.lines, !lines.isEmpty {
      return lines
    }

    let source = row.aggregatedOutput ?? row.liveOutputPreview
    guard let source else { return [] }

    return source
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .suffix(2)
      .map { normalizedInlineText($0, limit: 180) }
  }

  private var expandedOutput: String? {
    if let output = fetchedContent?.outputDisplay?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
      return output
    }
    if let output = row.aggregatedOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
      return output
    }
    if let output = row.liveOutputPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
      return output
    }
    return nil
  }

  private var previewAccent: Color {
    if row.status == .failed || row.status == .declined {
      return .feedbackNegative
    }
    return semanticColor
  }

  private var previewTextColor: Color {
    if row.status == .failed || row.status == .declined {
      return .feedbackNegative.opacity(0.92)
    }
    return .textTertiary
  }

  private var usesSearchPreviewStyle: Bool {
    preview?.kind == .searchMatches || (preview == nil && row.commandActions.allSatisfy({ $0.type == .search }))
  }

  private var usesStatusPreviewStyle: Bool {
    preview?.kind == .status
  }

  private var usesDiffPreviewStyle: Bool {
    preview?.kind == .diff
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerButton

      if !isExpanded, !previewLines.isEmpty {
        previewStrip
          .padding(.horizontal, isCompactLayout ? Spacing.sm : Spacing.md)
          .padding(.bottom, Spacing.sm_)
      }

      if isExpanded {
        expandedSection
      }
    }
    .background(
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.xl : Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(isCompactLayout ? 0.99 : 0.95))
    )
    .overlay {
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.xl : Radius.lg, style: .continuous)
        .strokeBorder(Color.white.opacity(isCompactLayout ? 0.075 : 0.055), lineWidth: 1)
    }
    .themeShadow(isCompactLayout ? Shadow.lg : Shadow.md)
    .padding(.vertical, isCompactLayout ? Spacing.sm_ : Spacing.xs)
  }

  private var headerButton: some View {
    Button(action: { onToggle?() }) {
      HStack(spacing: Spacing.sm) {
        iconCluster

        VStack(alignment: .leading, spacing: isCompactLayout ? 1 : 0) {
          Text(semanticSummary)
            .font(.system(
              size: isCompactLayout ? TypeScale.subhead : TypeScale.body,
              weight: .semibold,
              design: .rounded
            ))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(isCompactLayout ? 2 : 1)

          if let supportingText {
            Text(supportingText)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        HStack(spacing: Spacing.xs) {
          metricCapsule(text: statusLabel, tint: statusColor, emphasized: row.status != .completed)

          if let durationLabel {
            metricCapsule(text: durationLabel, tint: semanticColor)
          }

          if let exitLabel {
            metricCapsule(text: exitLabel, tint: statusColor, emphasized: true)
          }

          if onToggle != nil {
            expandChevron
          }
        }
      }
      .padding(.leading, isCompactLayout ? Spacing.md_ : Spacing.md)
      .padding(.trailing, isCompactLayout ? Spacing.md_ : Spacing.md)
      .padding(.top, isCompactLayout ? Spacing.md_ : Spacing.sm_)
      .padding(.bottom, !isExpanded && previewLines.isEmpty ? Spacing.md : Spacing.sm_)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var iconCluster: some View {
    ZStack {
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.lg : Radius.md, style: .continuous)
        .fill(semanticColor.opacity(isCompactLayout ? 0.16 : 0.11))
        .overlay(
          RoundedRectangle(cornerRadius: isCompactLayout ? Radius.lg : Radius.md, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )

      Image(systemName: semanticIcon)
        .font(.system(size: isCompactLayout ? IconScale.xl : IconScale.lg, weight: .semibold))
        .foregroundStyle(semanticColor)
    }
    .frame(width: isCompactLayout ? 28 : 22, height: isCompactLayout ? 28 : 22)
  }

  private var expandChevron: some View {
    ZStack {
      Circle()
        .fill(Color.backgroundCode.opacity(0.92))
      Circle()
        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)

      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(width: isCompactLayout ? 22 : 18, height: isCompactLayout ? 22 : 18)
  }

  private var previewStrip: some View {
    VStack(alignment: .leading, spacing: usesSearchPreviewStyle ? Spacing.xs : 2) {
      ForEach(Array(previewLines.enumerated()), id: \.offset) { index, line in
        previewLine(line, index: index)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
        .fill(Color.backgroundCode.opacity(0.96))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
            .fill(previewAccent.opacity(0.06))
        )
    )
  }

  private func previewLine(_ line: String, index: Int) -> some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      if usesStatusPreviewStyle {
        EmptyView()
      } else if usesSearchPreviewStyle {
        Text(index == 0 ? ">" : "·")
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(previewAccent)
      } else {
        Circle()
          .fill(previewAccent.opacity(0.8))
          .frame(width: 4, height: 4)
          .padding(.top, 6)
      }

      Text(line)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(diffPreviewTextColor(for: line) ?? previewTextColor)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }

  private func diffPreviewTextColor(for line: String) -> Color? {
    guard usesDiffPreviewStyle else { return nil }
    if line.hasPrefix("+"), !line.hasPrefix("+++") {
      return .diffAddedAccent
    }
    if line.hasPrefix("-"), !line.hasPrefix("---") {
      return .diffRemovedAccent
    }
    return previewTextColor
  }

  private var expandedSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle()
        .fill(Color.white.opacity(0.06))
        .frame(height: 1)

      if isLoadingContent, fetchedContent == nil {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Loading…")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
      } else {
        expandedBody
      }
    }
  }

  private var expandedBody: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      codeBlock(label: "Command", text: row.command)

      if let workingDirectoryLabel {
        codeBlock(label: "Working Directory", text: workingDirectoryLabel)
      }

      if let processId = row.processId, !processId.isEmpty {
        codeBlock(label: "Process", text: processId)
      }

      if !row.commandActions.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          sectionLabel("Actions")

          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(row.commandActions.enumerated()), id: \.offset) { _, action in
              HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(action.type.rawValue.replacingOccurrences(of: "_", with: " "))
                  .font(.system(size: TypeScale.mini, weight: .semibold))
                  .foregroundStyle(Color.textTertiary)

                Text(actionDetail(action))
                  .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
                  .lineLimit(2)
                  .textSelection(.enabled)
              }
            }
          }
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }

      if let expandedOutput {
        codeBlock(label: "Output", text: expandedOutput)
      } else if row.status == .inProgress {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          sectionLabel("Output")
          Text("Waiting for command output…")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
    .padding(Spacing.md)
  }

  private func metricCapsule(text: String, tint: Color, emphasized: Bool = false) -> some View {
    Text(text)
      .font(.system(size: TypeScale.mini, weight: emphasized ? .bold : .medium, design: .monospaced))
      .foregroundStyle(emphasized ? tint : Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(
        Capsule()
          .fill(Color.backgroundCode.opacity(0.9))
          .overlay(
            Capsule()
              .fill(tint.opacity(emphasized ? 0.08 : 0.0))
          )
          .overlay(
            Capsule()
              .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
          )
      )
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: TypeScale.caption, weight: .semibold))
      .foregroundStyle(Color.textTertiary)
  }

  private func codeBlock(label: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionLabel(label)

      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        .textSelection(.enabled)
    }
  }

  private func actionDetail(_ action: ServerConversationCommandAction) -> String {
    action.name ?? action.query ?? action.path ?? action.command
  }

  private func orderedUniqueNonEmpty(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []

    for value in values where !value.isEmpty {
      if seen.insert(value).inserted {
        ordered.append(value)
      }
    }

    return ordered
  }

  private func shortenedPath(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return ToolCardStyle.shortenPath(value)
  }

  private func normalizedInlineText(_ value: String, limit: Int = 54) -> String {
    let collapsed = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    if collapsed.count <= limit {
      return collapsed
    }

    return String(collapsed.prefix(limit - 1)) + "…"
  }
}
