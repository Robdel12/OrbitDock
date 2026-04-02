//
//  ToolCardView.swift
//  OrbitDock
//
//  Compact row + inline preview + dispatch to type-specific expanded views.
//  Expanded content fetched on demand via REST — zero truncation.
//  The toolType field from ServerToolDisplay drives rendering dispatch.
//
//  Expanded views live in Views/ToolCards/Expanded/*.swift
//

import SwiftUI

struct ToolCardView: View {
  let toolRow: ServerConversationToolRow
  let isExpanded: Bool
  let sessionId: String
  let clients: ServerClients?
  var fetchedContent: ServerRowContent?
  var isLoadingContent: Bool = false
  var onToggle: (() -> Void)?

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isCompactLayout: Bool {
    sizeClass == .compact
  }

  private var previewHorizontalPad: CGFloat {
    isCompactLayout ? Spacing.sm : Spacing.md
  }

  private var cardCornerRadius: CGFloat {
    isCompactLayout ? Radius.xl : Radius.lg
  }

  private var display: ServerToolDisplay? {
    toolRow.toolDisplay
  }

  private var rawSummary: String {
    display?.summary ?? toolRow.summary ?? toolRow.title
  }

  private var glyphSymbol: String {
    display?.glyphSymbol ?? "gearshape"
  }

  private var glyphColor: Color {
    Self.resolveColor(display?.glyphColor ?? "gray")
  }

  private var rawSubtitle: String? {
    display?.subtitle ?? toolRow.subtitle
  }

  private var rightMeta: String? {
    display?.rightMeta
  }

  private var isRunning: Bool {
    toolRow.status == .running || toolRow.status == .pending
  }

  private var isFailed: Bool {
    toolRow.status == .failed
  }

  private var isSuccessful: Bool {
    toolRow.status == .completed
  }

  private var toolType: String {
    display?.toolType ?? "generic"
  }

  private var isFileChangeCard: Bool {
    toolType == "edit" || toolType == "write"
  }

  private var usesCustomOutputPreview: Bool {
    [
      "read",
      "grep",
      "glob",
      "toolSearch",
      "webSearch",
      "task",
      "mcp",
      "question",
      "plan",
      "hook",
      "handoff",
      "guardianAssessment",
    ].contains(toolType)
  }

  private var displayTier: String {
    display?.displayTier ?? "standard"
  }

  private var chromeTint: Color {
    isFailed ? Color.feedbackNegative : glyphColor
  }

  private var summary: String {
    if isFileChangeCard, let fileName = compactFileName {
      return fileName
    }

    return rawSummary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      compactRow

      if !isExpanded {
        compactInlinePreview
      }

      if isExpanded {
        expandedSection
      }
    }
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    .overlay { cardBorderOverlay }
    .themeShadow(isCompactLayout ? Shadow.lg : Shadow.md)
    //  horizontal padding handled by TimelineRowContent
    .padding(.vertical, isCompactLayout ? Spacing.sm_ : Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Card Chrome

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
      .fill(Color.backgroundTertiary.opacity(isCompactLayout ? 0.99 : 0.95))
  }

  private var cardBorderOverlay: some View {
    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
      .strokeBorder(
        cardBorderColor,
        lineWidth: 1
      )
  }

  private var cardBorderColor: Color {
    if isFailed {
      return Color.feedbackNegative.opacity(0.24)
    }

    return Color.white.opacity(isCompactLayout ? 0.075 : 0.055)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Compact Row (universal)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private var compactRow: some View {
    let isMinimal = displayTier == "minimal"
    let isProminent = displayTier == "prominent"
    let iconSize = isMinimal ? IconScale.md : (isCompactLayout ? IconScale.xl : IconScale.lg)

    return HStack(spacing: Spacing.sm) {
      iconCluster(iconSize: iconSize)

      primaryText
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      trailingControlCluster
    }
    .padding(.leading, isCompactLayout ? Spacing.md_ : Spacing.md)
    .padding(.trailing, isCompactLayout ? Spacing.md_ : Spacing.md)
    .padding(.top, isCompactLayout ? (isMinimal ? Spacing.sm_ : Spacing.md_) : (isMinimal ? Spacing.xs : Spacing.sm_))
    .padding(.bottom, isCompactLayout ? Spacing.sm : (isMinimal ? Spacing.xs : Spacing.sm_))
    .background(
      isProminent
        ? AnyShapeStyle(glyphColor.opacity(OpacityTier.tint))
        : AnyShapeStyle(Color.clear)
    )
  }

  private func iconCluster(iconSize: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: isCompactLayout ? Radius.lg : Radius.md, style: .continuous)
        .fill(chromeTint.opacity(isCompactLayout ? 0.16 : 0.11))
        .overlay(
          RoundedRectangle(cornerRadius: isCompactLayout ? Radius.lg : Radius.md, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )

      Image(systemName: glyphSymbol)
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(chromeTint)
    }
    .frame(width: isCompactLayout ? 28 : 22, height: isCompactLayout ? 28 : 22)
  }

  // MARK: - Compact Row Components

  /// Composed Text with inline styling: "Summary · filename" or just "Summary"
  private var primaryText: some View {
    let isProminent = displayTier == "prominent"
    let summaryColor = isFailed ? Color.feedbackNegative
      : isProminent ? Color.textPrimary
      : Color.textSecondary

    return VStack(alignment: .leading, spacing: isCompactLayout ? 1 : 0) {
      Text(summary)
        .font((display?.summaryFont == "mono" || display?.summaryFont == "monospace")
          ? .system(size: isCompactLayout ? TypeScale.subhead : TypeScale.body, weight: .medium, design: .monospaced)
          : .system(size: isCompactLayout ? TypeScale.subhead : TypeScale.body, weight: .semibold, design: .rounded))
        .foregroundStyle(summaryColor)
        .lineLimit(isCompactLayout ? 2 : 1)

      if let sub = compactDisplayName, !sub.isEmpty {
        Text(sub)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      }
    }
  }

  /// Short display name for the compact row — filename or command excerpt.
  /// Full subtitle available in the expanded view.
  private static let fileToolTypes: Set<String> = ["edit", "write", "read", "glob", "grep"]

  private var compactFileName: String? {
    guard let rawSubtitle, !rawSubtitle.isEmpty else {
      guard !toolRow.title.isEmpty else { return nil }
      if toolRow.title.contains("/") {
        return (toolRow.title as NSString).lastPathComponent
      }
      return toolRow.title
    }

    if rawSubtitle.contains("/") {
      return (rawSubtitle as NSString).lastPathComponent
    }

    return rawSubtitle
  }

  private var compactResultSummary: String? {
    let lines = rawSummary
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !lines.isEmpty else { return nil }

    if let resultLine = lines.first(where: { $0.lowercased().hasPrefix("result:") }) {
      let value = resultLine.dropFirst("result:".count).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return nil }
      return value.prefix(1).uppercased() + value.dropFirst()
    }

    let meaningful = lines.first(where: { !$0.lowercased().hasPrefix("status:") })
    guard let meaningful, meaningful != rawSummary else { return nil }
    return meaningful
  }

  private var compactDisplayName: String? {
    if isFileChangeCard {
      guard let rawSubtitle, !rawSubtitle.isEmpty else { return nil }
      return ToolCardStyle.shortenPath(rawSubtitle)
    }

    guard let rawSubtitle, !rawSubtitle.isEmpty else { return nil }

    if Self.fileToolTypes.contains(toolType), rawSubtitle.contains("/") {
      let filename = (rawSubtitle as NSString).lastPathComponent
      guard filename.count > 22 else { return filename }
      return "…" + filename.suffix(18)
    }

    return rawSubtitle
  }

  /// Compact badge showing the single most important metric for this tool.
  @ViewBuilder
  private var compactMetricBadge: some View {
    if toolType == "edit" || toolType == "write", let preview = display?.diffPreview,
       preview.additions > 0 || preview.deletions > 0
    {
      HStack(spacing: Spacing.xxs) {
        if preview.additions > 0 {
          Text("+\(preview.additions)")
            .foregroundStyle(Color.diffAddedAccent)
        }
        if preview.deletions > 0 {
          Text("-\(preview.deletions)")
            .foregroundStyle(Color.diffRemovedAccent)
        }
      }
      .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(
        Capsule()
          .fill(Color.backgroundCode.opacity(0.9))
          .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
      )
    } else if let rightMeta, !rightMeta.isEmpty {
      Text(rightMeta)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, Spacing.xxs)
        .background(
          Capsule()
            .fill(Color.backgroundCode.opacity(0.86))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.04), lineWidth: 1))
        )
    }
  }

  private var trailingControlCluster: some View {
    HStack(spacing: Spacing.xs) {
      compactMetricBadge
      statusPill
      expandChevronButton
    }
  }

  @ViewBuilder
  private var statusPill: some View {
    if isRunning || isFailed || (isSuccessful && !isFileChangeCard) {
      HStack(spacing: Spacing.xxs) {
        if isRunning {
          ProgressView()
            .controlSize(.mini)
            .tint(chromeTint)
        } else {
          Circle()
            .fill(isFailed ? Color.feedbackNegative : chromeTint)
            .frame(width: 6, height: 6)
        }

        Text(statusLabel)
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(isFailed ? Color.feedbackNegative : chromeTint)
      }
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(
        Capsule()
          .fill(Color.backgroundCode.opacity(0.88))
          .overlay(
            Capsule()
              .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
          )
      )
    }
  }

  private var statusLabel: String {
    if isFailed { return "Fail" }
    if isRunning { return "Live" }
    return "Done"
  }

  private var expandChevronButton: some View {
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

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Compact Inline Preview (type-specific)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  @ViewBuilder
  private var compactInlinePreview: some View {
    // Diff preview for edit/write
    if let preview = display?.diffPreview {
      diffPreviewStrip(preview)
    } else if let preview = fetchedContentDiffPreview {
      diffPreviewStrip(preview)
    } else if let preview = fallbackFileChangePreview {
      diffPreviewStrip(preview)
    }

    if toolType == "read", let preview = display?.outputPreview, !preview.isEmpty {
      readPreviewStrip(preview)
    }

    if toolType == "grep" || toolType == "glob" || toolType == "toolSearch",
       let preview = searchPreviewText, !preview.isEmpty
    {
      searchPreviewStrip(preview)
    }

    if toolType == "webSearch", !webPreviewLines.isEmpty {
      let preview = webPreviewLines
      webSearchPreviewStrip(preview)
    }

    if toolType == "task", !taskPreviewLines.isEmpty {
      let preview = taskPreviewLines
      taskPreviewStrip(preview)
    }

    if toolType == "mcp", !mcpPreviewLines.isEmpty {
      let preview = mcpPreviewLines
      mcpPreviewStrip(preview)
    }

    if toolType == "question", let preview = questionPreviewText, !preview.isEmpty {
      questionPreviewStrip(preview)
    }

    if toolType == "plan", !planPreviewLines.isEmpty {
      let preview = planPreviewLines
      planPreviewStrip(preview)
    }

    if toolType == "hook", !hookPreviewLines.isEmpty {
      let preview = hookPreviewLines
      hookPreviewStrip(preview)
    }

    if toolType == "handoff", !handoffPreviewLines.isEmpty {
      let preview = handoffPreviewLines
      handoffPreviewStrip(preview)
    }

    if toolType == "guardianAssessment", let preview = display?.outputPreview, !preview.isEmpty {
      guardianPreviewStrip(preview)
    }

    // Live output for running bash (pulsing green dot)
    if isRunning, let live = display?.liveOutputPreview, !live.isEmpty {
      liveOutputStrip(live)
    }

    // Output preview for completed tools (bash, grep)
    if !isRunning, let preview = display?.outputPreview, !preview.isEmpty, !usesCustomOutputPreview {
      outputPreviewStrip(preview)
    }

    // Todo items inline
    if let items = display?.todoItems, !items.isEmpty {
      todoPreviewStrip(items)
    }
  }

  @ViewBuilder
  private func diffPreviewStrip(_ preview: ServerToolDiffPreview) -> some View {
    if isFileChangeCard {
      fileChangePreview(preview)
    } else {
      HStack(spacing: Spacing.sm_) {
        Text(preview.snippetPrefix)
          .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
          .foregroundStyle(preview.isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent)
        Text(preview.snippetText)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
      .previewStripChrome(
        tint: preview.isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent,
        horizontalPad: previewHorizontalPad,
        bottomPad: Spacing.sm_
      )
    }
  }

  private var fallbackFileChangePreview: ServerToolDiffPreview? {
    guard isFileChangeCard else { return nil }

    if case let .diff(additions, deletions, snippet)? = toolRow.preview {
      let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let isAddition = additions > 0 || deletions == 0
      return ServerToolDiffPreview(
        contextLine: compactResultSummary,
        snippetText: trimmed,
        previewLines: trimmed
          .components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty },
        snippetPrefix: isAddition ? "+" : "-",
        isAddition: isAddition,
        additions: additions,
        deletions: deletions
      )
    }

    return nil
  }

  private var fetchedContentDiffPreview: ServerToolDiffPreview? {
    guard isFileChangeCard, let diffLines = fetchedContent?.diffDisplay, !diffLines.isEmpty else { return nil }

    let additions = diffLines.filter { $0.type == .addition }.count
    let deletions = diffLines.filter { $0.type == .deletion }.count

    guard let firstChanged = diffLines.first(where: { $0.type != .context }) else { return nil }

    let isAddition = firstChanged.type == .addition
    let prefix = isAddition ? "+" : "-"

    return ServerToolDiffPreview(
      contextLine: compactResultSummary,
      snippetText: firstChanged.content,
      previewLines: diffLines
        .filter { $0.type != .context }
        .prefix(4)
        .map(\.content),
      snippetPrefix: prefix,
      isAddition: isAddition,
      additions: UInt32(additions),
      deletions: UInt32(deletions)
    )
  }

  private func fileChangePreview(_ preview: ServerToolDiffPreview) -> some View {
    let tint = preview.isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent
    let previewLines = preview.previewLines.isEmpty
      ? preview.snippetText.components(separatedBy: .newlines)
      : preview.previewLines
    let headerTitle: String = {
      if let contextLine = preview.contextLine, !contextLine.isEmpty {
        return contextLine
      }
      return compactResultSummary ?? "Edited"
    }()

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      previewStripHeader(
        title: headerTitle,
        tint: tint,
        titleStyle: .mono,
        trailing: {
          DiffStatsBar(
            additions: Int(preview.additions),
            deletions: Int(preview.deletions),
            maxWidth: isCompactLayout ? 44 : 56
          )
        }
      )

      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(previewLines.prefix(isCompactLayout ? 5 : 4).enumerated()), id: \.offset) { index, line in
          previewCodeLine(
            line,
            prefix: index == 0 ? preview.snippetPrefix : " ",
            tint: tint
          )
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundCode.opacity(0.98))
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(tint.opacity(0.9))
            .frame(width: 2)
            .padding(.vertical, Spacing.sm_)
            .padding(.leading, 1)
        }
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
        )
    )
    .padding(.horizontal, previewHorizontalPad)
    .padding(.bottom, Spacing.sm_)
  }

  private func liveOutputStrip(_ output: String) -> some View {
    let lastLine = output.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? output
    return HStack(spacing: Spacing.xs) {
      Circle().fill(Color.toolBash).frame(width: 5, height: 5)
      Text(lastLine)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
    .previewStripChrome(tint: Color.toolBash, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private func outputPreviewStrip(_ preview: String) -> some View {
    let firstLine = preview.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? preview
    let isBash = toolType == "bash"

    return HStack(spacing: Spacing.xs) {
      if isBash {
        Text("$")
          .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.toolBash.opacity(0.3))
      }
      Text(firstLine)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(isBash ? Color.textTertiary : Color.textQuaternary)
    }
    .previewStripChrome(
      tint: isBash ? Color.toolBash : chromeTint,
      horizontalPad: previewHorizontalPad,
      bottomPad: Spacing.sm_
    )
  }

  private func todoPreviewStrip(_ items: [ServerToolTodoItem]) -> some View {
    let completed = items.filter { $0.status == "completed" }.count
    let total = items.count
    let fraction = total > 0 ? CGFloat(completed) / CGFloat(total) : 0
    let previewItems = Array(items.prefix(isCompactLayout ? 2 : 3))

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      previewStripHeader(
        title: "\(completed)/\(total) done",
        tint: Color.toolTodo,
        titleStyle: .compact,
        symbol: "checklist",
        trailing: {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color.feedbackPositive.opacity(OpacityTier.subtle))
                .frame(height: 3)
              RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color.feedbackPositive)
                .frame(width: geo.size.width * fraction, height: 3)
            }
          }
          .frame(width: 40, height: 3)
        }
      )

      ForEach(Array(previewItems.enumerated()), id: \.offset) { _, item in
        previewBulletLine(
          item.activeForm ?? item.content ?? item.status.capitalized,
          bullet: todoItemColor(item.status),
          font: .system(size: TypeScale.caption)
        )
      }
    }
    .previewStripChrome(tint: Color.toolTodo, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private func readPreviewStrip(_ preview: String) -> some View {
    let lines = compactPreviewLines(from: preview, limit: isCompactLayout ? 4 : 3)
    return VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        previewCodeLine(line, tint: Color.toolRead)
      }
    }
    .previewStripChrome(tint: Color.toolRead, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var searchPreviewText: String? {
    if let preview = display?.outputPreview, !preview.isEmpty {
      return preview
    }
    if case let .search(matches, summary)? = toolRow.preview {
      if let summary, !summary.isEmpty {
        return summary
      }
      return matches > 0 ? "\(matches) matches" : nil
    }
    return nil
  }

  private func searchPreviewStrip(_ preview: String) -> some View {
    let lines = compactPreviewLines(from: preview, limit: isCompactLayout ? 3 : 2)
    return VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        previewCodeLine(
          line,
          prefix: index == 0 ? ">" : "·",
          tint: Color.toolSearch,
          font: .system(size: TypeScale.caption, design: .monospaced)
        )
      }
    }
    .previewStripChrome(tint: Color.toolSearch, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var webPreviewLines: [String] {
    guard let preview = display?.outputPreview, !preview.isEmpty else { return [] }
    return compactPreviewLines(from: preview, limit: isCompactLayout ? 3 : 2)
  }

  private func webSearchPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        previewCodeLine(
          line,
          prefix: "\(index + 1).",
          tint: Color.toolWeb,
          font: .system(size: TypeScale.caption),
          lineLimit: 2
        )
      }
    }
    .previewStripChrome(tint: Color.toolWeb, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var taskPreviewLines: [String] {
    let lines = compactPreviewLines(from: rawSummary, limit: isCompactLayout ? 3 : 2)
    if !lines.isEmpty { return lines }
    if let subtitle = rawSubtitle, !subtitle.isEmpty {
      return compactPreviewLines(from: subtitle, limit: 2)
    }
    return []
  }

  private func taskPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        previewIconLine(
          line,
          icon: index == 0 ? "bolt.fill" : "arrow.turn.down.right",
          tint: Color.toolTask.opacity(index == 0 ? 1 : 0.7),
          iconSize: index == 0 ? IconScale.xs : 7
        )
      }
    }
    .previewStripChrome(tint: Color.toolTask, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var mcpPreviewLines: [String] {
    if let preview = display?.outputPreview, !preview.isEmpty {
      return compactPreviewLines(from: preview, limit: isCompactLayout ? 3 : 2)
    }
    return compactPreviewLines(from: rawSummary, limit: 2)
  }

  private func mcpPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if let server = rawSubtitle, !server.isEmpty {
        previewStripHeader(
          title: server,
          tint: Color.toolMcp,
          titleStyle: .compact
        )
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        previewCodeLine(line, tint: Color.toolMcp, font: .system(size: TypeScale.caption, design: .monospaced))
      }
    }
    .previewStripChrome(tint: Color.toolMcp, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var questionPreviewText: String? {
    nonEmpty(rawSubtitle) ?? nonEmpty(display?.outputPreview) ?? nonEmpty(rawSummary)
  }

  private func questionPreviewStrip(_ text: String) -> some View {
    Text(text)
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textSecondary)
      .lineLimit(isCompactLayout ? 3 : 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .previewStripChrome(tint: Color.toolQuestion, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var planPreviewLines: [String] {
    compactPreviewLines(from: rawSummary, limit: isCompactLayout ? 3 : 2)
  }

  private func planPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        previewCodeLine(
          line,
          prefix: "\(index + 1)",
          tint: Color.toolPlan,
          font: .system(size: TypeScale.caption),
          prefixWidth: 12
        )
      }
    }
    .previewStripChrome(tint: Color.toolPlan, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var hookPreviewLines: [String] {
    compactPreviewLines(from: rawSummary, limit: isCompactLayout ? 2 : 2)
  }

  private func hookPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if let subtitle = rawSubtitle, !subtitle.isEmpty {
        previewStripHeader(
          title: subtitle,
          tint: Color.feedbackCaution,
          titleStyle: .mono
        )
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        previewCodeLine(line, tint: Color.feedbackCaution, font: .system(size: TypeScale.caption, design: .monospaced))
      }
    }
    .previewStripChrome(tint: Color.feedbackCaution, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var handoffPreviewLines: [String] {
    compactPreviewLines(from: rawSummary, limit: isCompactLayout ? 2 : 2)
  }

  private func handoffPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if let subtitle = rawSubtitle, !subtitle.isEmpty {
        previewStripHeader(
          title: subtitle,
          tint: Color.statusReply,
          titleStyle: .compact
        )
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        previewCodeLine(line, tint: Color.statusReply, font: .system(size: TypeScale.caption), lineLimit: 2)
      }
    }
    .previewStripChrome(tint: Color.statusReply, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private func guardianPreviewStrip(_ text: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "shield.lefthalf.filled")
        .font(.system(size: IconScale.xs, weight: .semibold))
        .foregroundStyle(Color.feedbackCaution)
      Text(text)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.feedbackCaution)
        .lineLimit(2)
    }
    .previewStripChrome(tint: Color.feedbackCaution, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private func compactPreviewLines(from text: String, limit: Int) -> [String] {
    text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("status:") }
      .prefix(limit)
      .map { String($0.prefix(120)) }
  }

  private func nonEmpty(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func todoItemColor(_ status: String) -> Color {
    switch status {
      case "completed": .feedbackPositive
      case "in_progress": .toolTodo
      case "cancelled": .feedbackNegative
      default: .textQuaternary
    }
  }

  private enum PreviewHeaderStyle {
    case compact
    case mono
  }

  private func previewStripHeader(
    title: String,
    tint: Color,
    titleStyle: PreviewHeaderStyle,
    symbol: String? = nil,
    @ViewBuilder trailing: () -> some View = { EmptyView() }
  ) -> some View {
    HStack(alignment: .center, spacing: Spacing.sm_) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: IconScale.xs, weight: .semibold))
          .foregroundStyle(tint)
      }

      Text(title)
        .font(previewHeaderFont(titleStyle))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      trailing()
    }
  }

  private func previewHeaderFont(_ style: PreviewHeaderStyle) -> Font {
    switch style {
      case .compact:
        .system(size: TypeScale.mini, weight: .semibold, design: .rounded)
      case .mono:
        .system(size: TypeScale.mini, weight: .medium, design: .monospaced)
    }
  }

  private func previewCodeLine(
    _ text: String,
    prefix: String? = nil,
    tint: Color,
    font: Font = .system(size: TypeScale.code, design: .monospaced),
    lineLimit: Int = 1,
    prefixWidth: CGFloat = 10
  ) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm_) {
      if let prefix {
        Text(prefix)
          .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
          .foregroundStyle(tint)
          .frame(width: prefixWidth, alignment: .leading)
      }

      Text(text)
        .font(font)
        .foregroundStyle(Color.textSecondary)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func previewBulletLine(_ text: String, bullet: Color, font: Font) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm_) {
      Circle()
        .fill(bullet)
        .frame(width: 6, height: 6)
        .padding(.top, 4)

      Text(text)
        .font(font)
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func previewIconLine(
    _ text: String,
    icon: String,
    tint: Color,
    iconSize: CGFloat
  ) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: iconSize, weight: .bold))
        .foregroundStyle(tint)
        .frame(width: 10, alignment: .leading)

      Text(text)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Expanded Section

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private var expandedSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      divider

      if isLoadingContent, fetchedContent == nil {
        loadingIndicator
      } else if let content = fetchedContent {
        expandedBody(content)
      } else {
        fallbackBody
      }
    }
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.06))
      .frame(height: 1)
  }

  private var loadingIndicator: some View {
    HStack(spacing: Spacing.sm) {
      ProgressView().controlSize(.small)
      Text("Loading…")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Expanded Body Dispatch

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private func expandedBody(_ content: ServerRowContent) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      switch toolType {
        case "bash":
          BashExpandedView(content: content, isFailed: isFailed)
        case "read":
          ReadExpandedView(content: content)
        case "edit":
          EditExpandedView(content: content, toolType: toolType)
        case "write":
          WriteExpandedView(content: content)
        case "glob":
          GlobExpandedView(content: content)
        case "grep":
          GrepExpandedView(content: content)
        case "task":
          TaskExpandedView(content: content, toolRow: toolRow)
        case "mcp":
          MCPExpandedView(content: content, toolRow: toolRow)
        case "webSearch":
          WebSearchExpandedView(content: content)
        case "webFetch":
          WebFetchExpandedView(content: content)
        case "web":
          webExpandedDispatch(content)
        case "plan":
          PlanExpandedView(content: content, toolRow: toolRow)
        case "todo":
          TodoExpandedView(content: content, display: display)
        case "question":
          QuestionExpandedView(content: content, toolRow: toolRow)
        case "toolSearch":
          ToolSearchExpandedView(content: content)
        case "hook":
          HookExpandedView(content: content, toolRow: toolRow)
        case "handoff":
          HandoffExpandedView(content: content, toolRow: toolRow)
        case "image":
          ImageExpandedView(content: content)
        case "compactContext":
          CompactContextExpandedView(content: content)
        case "config":
          ConfigExpandedView(content: content)
        case "worktree":
          WorktreeExpandedView(content: content)
        case "guardianAssessment":
          GuardianExpandedView(content: content, toolRow: toolRow)
        default:
          GenericExpandedView(content: content)
      }
    }
    .padding(Spacing.md)
  }

  /// Split web tools into search vs fetch based on input content
  @ViewBuilder
  private func webExpandedDispatch(_ content: ServerRowContent) -> some View {
    let input = content.inputDisplay ?? ""
    let looksLikeURL = input.hasPrefix("http://") || input.hasPrefix("https://") || input.contains("://")

    if looksLikeURL {
      WebFetchExpandedView(content: content)
    } else {
      WebSearchExpandedView(content: content)
    }
  }

  // ── Fallback (no REST content) ───────────────────────────────────────────

  private var fallbackBody: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = toolRow.toolDisplay.inputDisplay, !input.isEmpty {
        codeBlock(label: "Input", text: input, language: nil)
      }
      if let output = toolRow.toolDisplay.outputDisplay, !output.isEmpty {
        codeBlock(label: "Output", text: output, language: toolRow.toolDisplay.language)
      }
    }
    .padding(Spacing.md)
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    ToolCardStyle.looksLikeJSON(text)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Shared Components

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private func codeBlock(label: String, text: String, language: String?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack {
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Spacer()
        if let language, !language.isEmpty { languageBadge(language) }
      }

      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        // text wraps naturally — no fixedSize (causes infinity height in NSHostingController.sizeThatFits)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  private func languageBadge(_ lang: String) -> some View {
    Text(lang)
      .font(.system(size: TypeScale.mini, weight: .semibold))
      .foregroundStyle(Color.textQuaternary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(Color.backgroundSecondary, in: Capsule())
  }

  // Fetch is handled by the conversation timeline view model.
  // ToolCardView is a pure function of its inputs.

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Color Resolution

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static func resolveColor(_ name: String) -> Color {
    switch name {
      case "accent", "cyan": .accent
      case "green", "toolBash": .toolBash
      case "orange", "toolWrite": .toolWrite
      case "blue", "toolRead": .toolRead
      case "purple", "toolSearch": .toolSearch
      case "red": .feedbackNegative
      case "yellow", "amber", "feedbackCaution": .feedbackCaution
      case "teal": .accent
      case "pink", "toolSkill": .toolSkill
      case "toolTask": .toolTask
      case "toolWeb": .toolWeb
      case "toolMcp": .toolMcp
      case "toolPlan": .toolPlan
      case "toolTodo": .toolTodo
      case "toolQuestion": .toolQuestion
      case "statusReply": .statusReply
      case "gray", "grey", "secondaryLabel": .textTertiary
      default: .textTertiary
    }
  }
}

private struct ToolCardPreviewStripChrome: ViewModifier {
  let tint: Color
  let horizontalPad: CGFloat
  let bottomPad: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
          .fill(Color.backgroundCode.opacity(0.96))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
              .fill(tint.opacity(0.06))
          )
      )
      .padding(.horizontal, horizontalPad)
      .padding(.bottom, bottomPad)
  }
}

private extension View {
  func previewStripChrome(tint: Color, horizontalPad: CGFloat, bottomPad: CGFloat) -> some View {
    modifier(
      ToolCardPreviewStripChrome(
        tint: tint,
        horizontalPad: horizontalPad,
        bottomPad: bottomPad
      )
    )
  }
}

// MARK: - AnyCodable JSON Helper

extension AnyCodable {
  var jsonString: String? {
    guard let data = try? JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
    ) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
