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

  private var outputViewportMaxHeight: CGFloat {
    #if os(iOS)
      360
    #else
      500
    #endif
  }

  private var actionCount: Int {
    row.commandActions.count
  }

  private var isFailureState: Bool {
    row.status == .failed || row.status == .declined
  }

  private var semanticSummary: String {
    if isReadOnlyActionSet {
      return actionCount == 1 ? "Read file" : "Read \(actionCount) files"
    }
    if isSearchOnlyActionSet {
      return actionCount == 1 ? "Search files" : "Search across files"
    }
    if isListFilesOnlyActionSet {
      return actionCount == 1 ? "List files" : "List file groups"
    }
    return "Run command"
  }

  private var semanticIcon: String {
    if isReadOnlyActionSet {
      return "doc.text.fill"
    }
    if isSearchOnlyActionSet {
      return "magnifyingglass"
    }
    if isListFilesOnlyActionSet {
      return "folder.fill"
    }
    return "terminal"
  }

  private var semanticColor: Color {
    if isReadOnlyActionSet {
      return .toolRead
    }
    if isSearchOnlyActionSet || isListFilesOnlyActionSet {
      return .toolSearch
    }
    return .toolBash
  }

  private func commandActionTypesMatch(_ types: [ServerConversationCommandActionType]) -> Bool {
    let allowedTypes = Set(types)
    return row.commandActions.allSatisfy { allowedTypes.contains($0.type) }
  }

  private var isReadOnlyActionSet: Bool {
    commandActionTypesMatch([.read])
  }

  private var isSearchOnlyActionSet: Bool {
    commandActionTypesMatch([.search])
  }

  private var isListFilesOnlyActionSet: Bool {
    commandActionTypesMatch([.listFiles])
  }

  private var isGenericCommandExecution: Bool {
    !(isReadOnlyActionSet || isSearchOnlyActionSet || isListFilesOnlyActionSet)
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
    shortenedPath(row.cwd) ?? trimmedOrNil(row.cwd)
  }

  private var supportingText: String? {
    let commandSummary = normalizedInlineText(row.command, limit: 84)

    if isGenericCommandExecution, !commandSummary.isEmpty {
      return commandSummary
    }

    let actions = row.commandActions

    if isSearchOnlyActionSet {
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

    return commandSummary.isEmpty ? nil : commandSummary
  }

  private var preview: ServerConversationCommandExecutionPreview? {
    row.preview
  }

  private var terminalSnapshot: ServerConversationCommandExecutionTerminalSnapshot? {
    row.terminalSnapshot
  }

  private var terminalSnapshotTranscript: String? {
    guard let transcript = terminalSnapshot?.transcript,
      !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return transcript
  }

  private var terminalSnapshotTitle: String? {
    trimmedOrNil(terminalSnapshot?.title)
  }

  private var previewLines: [String] {
    let baseLines: [String]
    if let lines = preview?.lines, !lines.isEmpty {
      baseLines = lines
    } else {
      let source = row.aggregatedOutput ?? row.liveOutputPreview
      guard let source else {
        return leadingCommandPreviewLine.map { [$0] } ?? []
      }

      baseLines = previewSourceLines(from: source)
    }

    guard let commandLine = leadingCommandPreviewLine else {
      return baseLines
    }
    if baseLines.contains(where: { normalizedInlineText($0, limit: 180) == commandLine }) {
      return baseLines
    }
    return [commandLine] + baseLines
  }

  private var leadingCommandPreviewLine: String? {
    guard isGenericCommandExecution else { return nil }
    let command = normalizedInlineText(row.command, limit: 170)
    guard !command.isEmpty else { return nil }
    return "$ \(command)"
  }

  private var expandedOutput: String? {
    if let output = fetchedContent?.outputDisplay, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return output
    }
    if let output = row.aggregatedOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return output
    }
    if let output = row.liveOutputPreview, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return output
    }
    return nil
  }

  private var terminalTitle: String {
    terminalSnapshotTitle ?? workingDirectoryLabel ?? "Terminal"
  }

  private var expandedTranscript: String? {
    if let snapshotTranscript = terminalSnapshotTranscript {
      return snapshotTranscript
    }

    return ShellTranscriptBuilder.makeSnapshot(
      command: row.command,
      output: expandedOutput,
      cwd: row.cwd
    )
  }

  private var previewAccent: Color {
    if isFailureState {
      return .feedbackNegative
    }
    return semanticColor
  }

  private var previewTextColor: Color {
    if isFailureState {
      return .feedbackNegative.opacity(0.92)
    }
    return .textTertiary
  }

  private var usesSearchPreviewStyle: Bool {
    preview?.kind == .searchMatches || (preview == nil && isSearchOnlyActionSet)
  }

  private var usesStatusPreviewStyle: Bool {
    preview?.kind == .status
  }

  private var usesDiffPreviewStyle: Bool {
    preview?.kind == .diff && !isGenericCommandExecution
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
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let expandedTranscript {
        terminalOutputBlock(expandedTranscript)
      } else if row.status == .inProgress {
        terminalWaitingState
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

  private func terminalOutputBlock(_ text: String) -> some View {
    TerminalTranscriptSurface(
      output: text,
      title: terminalTitle,
      maxHeight: outputViewportMaxHeight
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var terminalWaitingState: some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(Color.statusWorking.opacity(0.75))
        .frame(width: 5, height: 5)
      Text("Waiting for command output…")
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
      Spacer()
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
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

  private func trimmedOrNil(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func previewSourceLines(from source: String) -> [String] {
    source
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .suffix(2)
      .map { normalizedInlineText($0, limit: 180) }
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
