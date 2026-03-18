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

  private var previewHorizontalPad: CGFloat {
    sizeClass == .compact ? Spacing.sm : Spacing.md
  }

  private var display: ServerToolDisplay? {
    toolRow.toolDisplay
  }

  private var glyphSymbol: String {
    display?.glyphSymbol ?? "gearshape"
  }

  private var glyphColor: Color {
    Self.resolveColor(display?.glyphColor ?? "gray")
  }

  private var summary: String {
    display?.summary ?? toolRow.title
  }

  private var subtitle: String? {
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

  private var toolType: String {
    display?.toolType ?? "generic"
  }

  private var displayTier: String {
    display?.displayTier ?? "standard"
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
    .overlay(alignment: .leading) { accentEdge }
    //  horizontal padding handled by TimelineRowContent
    .padding(.vertical, sizeClass == .compact ? Spacing.sm_ : Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Card Chrome

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      .fill(Color.backgroundTertiary)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .stroke(isFailed ? Color.feedbackNegative.opacity(OpacityTier.light) : Color.clear, lineWidth: 1)
      )
  }

  private var accentEdge: some View {
    UnevenRoundedRectangle(
      topLeadingRadius: Radius.md, bottomLeadingRadius: Radius.md,
      bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
    )
    .fill(glyphColor)
    .frame(width: EdgeBar.width)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Compact Row (universal)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private var compactRow: some View {
    let isMinimal = displayTier == "minimal"
    let isProminent = displayTier == "prominent"
    let iconSize = isMinimal ? IconScale.sm : IconScale.md

    return HStack(spacing: Spacing.sm) {
      // Tool icon
      Image(systemName: glyphSymbol)
        .font(.system(size: iconSize))
        .foregroundStyle(glyphColor)
        .frame(width: 16, height: 16)

      // Primary text: summary + optional inline subtitle
      primaryText
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      // Compact metric badge (diff stats, duration, line count)
      compactMetricBadge

      // Status indicator + expand chevron
      statusAndChevron
    }
    .padding(.leading, Spacing.md + EdgeBar.width)
    .padding(.trailing, Spacing.md)
    .padding(.vertical, isMinimal ? Spacing.xs : Spacing.sm_)
    .background(
      isProminent
        ? AnyShapeStyle(glyphColor.opacity(OpacityTier.tint))
        : AnyShapeStyle(Color.clear)
    )
  }

  // MARK: - Compact Row Components

  /// Composed Text with inline styling: "Summary · filename" or just "Summary"
  private var primaryText: Text {
    let isProminent = displayTier == "prominent"
    let summaryColor = isFailed ? Color.feedbackNegative
      : isProminent ? Color.textPrimary
      : Color.textSecondary

    let summaryText = Text(summary)
      .font(display?.summaryFont == "monospace"
        ? .system(size: TypeScale.body, design: .monospaced)
        : .system(size: TypeScale.body, weight: .medium))
      .foregroundColor(summaryColor)

    guard let sub = compactDisplayName, !sub.isEmpty else {
      return summaryText
    }

    return summaryText
      + Text("  ")
      + Text(sub)
      .font(.system(size: TypeScale.caption, design: .monospaced))
      .foregroundColor(Color.textTertiary)
  }

  /// Short display name for the compact row — filename or command excerpt.
  /// Full subtitle available in the expanded view.
  private static let fileToolTypes: Set<String> = ["edit", "write", "read", "glob", "grep"]

  private var compactDisplayName: String? {
    guard let subtitle, !subtitle.isEmpty else { return nil }

    if Self.fileToolTypes.contains(toolType), subtitle.contains("/") {
      let filename = (subtitle as NSString).lastPathComponent
      guard filename.count > 22 else { return filename }
      return "…" + filename.suffix(18)
    }

    return subtitle
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
    } else if let rightMeta, !rightMeta.isEmpty {
      Text(rightMeta)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
    }
  }

  @ViewBuilder
  private var statusAndChevron: some View {
    if isRunning {
      ProgressView().controlSize(.small)
    } else if isFailed {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: IconScale.sm))
        .foregroundStyle(Color.feedbackNegative)
    }

    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
      .font(.system(size: 8, weight: .bold))
      .foregroundStyle(Color.textQuaternary)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Compact Inline Preview (type-specific)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  @ViewBuilder
  private var compactInlinePreview: some View {
    // Diff preview for edit/write
    if let preview = display?.diffPreview {
      diffPreviewStrip(preview)
    }

    // Live output for running bash (pulsing green dot)
    if isRunning, let live = display?.liveOutputPreview, !live.isEmpty {
      liveOutputStrip(live)
    }

    // Output preview for completed tools (bash, grep)
    if !isRunning, let preview = display?.outputPreview, !preview.isEmpty {
      outputPreviewStrip(preview)
    }

    // Todo items inline
    if let items = display?.todoItems, !items.isEmpty {
      todoPreviewStrip(items)
    }
  }

  private func diffPreviewStrip(_ preview: ServerToolDiffPreview) -> some View {
    HStack(spacing: Spacing.sm_) {
      Text(preview.snippetPrefix)
        .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
        .foregroundStyle(preview.isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent)
      Text(preview.snippetText)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
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
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.xs))
    .padding(.horizontal, previewHorizontalPad)
    .padding(.bottom, Spacing.sm_)
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
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.xs))
    .padding(.horizontal, previewHorizontalPad)
    .padding(.bottom, Spacing.sm_)
  }

  private func todoPreviewStrip(_ items: [ServerToolTodoItem]) -> some View {
    let completed = items.filter { $0.status == "completed" }.count
    let total = items.count
    let fraction = total > 0 ? CGFloat(completed) / CGFloat(total) : 0

    return HStack(spacing: Spacing.sm_) {
      Image(systemName: "checklist")
        .font(.system(size: 8))
        .foregroundStyle(Color.toolTodo)
      Text("\(completed)/\(total) done")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)

      // Inline micro progress bar
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
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.xs))
    .padding(.horizontal, previewHorizontalPad)
    .padding(.bottom, Spacing.sm_)
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
    Rectangle().fill(Color.textQuaternary.opacity(0.12)).frame(height: 1)
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

  // Fetch is now handled by TimelineRowStateStore.
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

// MARK: - AnyCodable JSON Helper

extension AnyCodable {
  var jsonString: String? {
    guard let data = try? JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
    ) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
