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

  private var display: ServerToolDisplay? { toolRow.toolDisplay }
  private var glyphSymbol: String { display?.glyphSymbol ?? "gearshape" }
  private var glyphColor: Color { Self.resolveColor(display?.glyphColor ?? "gray") }
  private var summary: String { display?.summary ?? toolRow.title }
  private var subtitle: String? { display?.subtitle ?? toolRow.subtitle }
  private var rightMeta: String? { display?.rightMeta }
  private var isRunning: Bool { toolRow.status == .running || toolRow.status == .pending }
  private var isFailed: Bool { toolRow.status == .failed }
  private var toolType: String { display?.toolType ?? "generic" }

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
    .padding(.vertical, Spacing.xxs)
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
    HStack(spacing: Spacing.sm) {
      Image(systemName: glyphSymbol)
        .font(.system(size: IconScale.md))
        .foregroundStyle(glyphColor)
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Spacing.sm_) {
          Text(summary)
            .font(display?.summaryFont == "monospace"
              ? .system(size: TypeScale.body, design: .monospaced)
              : .system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(isFailed ? Color.feedbackNegative : Color.textSecondary)

          if let subtitle, !subtitle.isEmpty, display?.subtitleAbsorbsMeta == true {
            Text(subtitle)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        }

        if let subtitle, !subtitle.isEmpty, display?.subtitleAbsorbsMeta != true {
          Text(subtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }

      Spacer(minLength: 0)

      // Micro diff stats bar for edit tools
      if toolType == "edit", let preview = display?.diffPreview {
        MicroDiffStatsBar(additions: Int(preview.additions), deletions: Int(preview.deletions))
      }

      if let rightMeta, !rightMeta.isEmpty {
        Text(rightMeta)
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      if let lang = display?.language, !lang.isEmpty, !isExpanded {
        languageBadge(lang)
      }

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
    .padding(.leading, Spacing.md + EdgeBar.width)
    .padding(.trailing, Spacing.md)
    .padding(.vertical, Spacing.sm_)
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
      Spacer(minLength: 0)
      HStack(spacing: Spacing.xs) {
        if preview.additions > 0 {
          Text("+\(preview.additions)")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.diffAddedAccent)
        }
        if preview.deletions > 0 {
          Text("-\(preview.deletions)")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.diffRemovedAccent)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
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
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.sm_)
  }

  private func outputPreviewStrip(_ preview: String) -> some View {
    let firstLine = preview.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? preview
    return Text(firstLine)
      .font(.system(size: TypeScale.meta, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .padding(.horizontal, Spacing.md)
      .padding(.bottom, Spacing.sm_)
  }

  private func todoPreviewStrip(_ items: [ServerToolTodoItem]) -> some View {
    let completed = items.filter { $0.status == "completed" }.count
    return HStack(spacing: Spacing.xs) {
      Image(systemName: "checklist")
        .font(.system(size: 8))
        .foregroundStyle(Color.toolTodo)
      Text("\(completed)/\(items.count) done")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.sm_)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Expanded Section
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  @ViewBuilder
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

  @ViewBuilder
  private func expandedBody(_ content: ServerRowContent) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      switch toolType {
      case "bash":
        BashExpandedView(content: content, isFailed: isFailed)
      case "read":
        ReadExpandedView(content: content)
      case "edit":
        EditExpandedView(content: content, toolType: toolType)
      case "glob":
        GlobExpandedView(content: content)
      case "grep":
        GrepExpandedView(content: content)
      case "task":
        TaskExpandedView(content: content, toolRow: toolRow)
      case "mcp":
        MCPExpandedView(content: content, toolRow: toolRow)
      case "web":
        webExpandedDispatch(content)
      case "plan":
        PlanExpandedView(content: content, toolRow: toolRow)
      case "todo":
        TodoExpandedView(content: content, display: display)
      case "question":
        QuestionExpandedView(content: content)
      case "toolSearch":
        ToolSearchExpandedView(content: content)
      case "hook":
        HookExpandedView(content: content, toolRow: toolRow)
      case "handoff":
        HandoffExpandedView(content: content, toolRow: toolRow)
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

  @ViewBuilder
  private var fallbackBody: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let json = toolRow.invocation.jsonString, !json.isEmpty {
        if looksLikeJSON(json) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Input")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            JSONTreeView(jsonString: json)
          }
        } else {
          codeBlock(label: "Input", text: json, language: nil)
        }
      }
      if let json = toolRow.result?.jsonString, !json.isEmpty {
        if looksLikeJSON(json) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Output")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            JSONTreeView(jsonString: json)
          }
        } else {
          codeBlock(label: "Output", text: json, language: nil)
        }
      }
    }
    .padding(Spacing.md)
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
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
    case "accent", "cyan": return .accent
    case "green", "toolBash": return .toolBash
    case "orange", "toolWrite": return .toolWrite
    case "blue", "toolRead": return .toolRead
    case "purple", "toolSearch": return .toolSearch
    case "red": return .feedbackNegative
    case "yellow", "amber", "feedbackCaution": return .feedbackCaution
    case "teal": return .accent
    case "pink", "toolSkill": return .toolSkill
    case "toolTask": return .toolTask
    case "toolWeb": return .toolWeb
    case "toolMcp": return .toolMcp
    case "toolPlan": return .toolPlan
    case "toolTodo": return .toolTodo
    case "toolQuestion": return .toolQuestion
    case "statusReply": return .statusReply
    case "gray", "grey", "secondaryLabel": return .textTertiary
    default: return .textTertiary
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
