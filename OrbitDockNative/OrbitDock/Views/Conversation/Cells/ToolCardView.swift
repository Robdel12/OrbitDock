//
//  ToolCardView.swift
//  OrbitDock
//
//  SwiftUI view for tool calls. Reads ServerToolDisplay directly.
//  Compact: accent bar + glyph + summary + subtitle + inline preview.
//  Expanded: fetches full content on demand via REST.
//

import SwiftUI

struct ToolCardView: View {
  let toolRow: ServerConversationToolRow
  let isExpanded: Bool
  let sessionId: String
  let clients: ServerClients?

  @State private var expandedContent: ServerRowContent?
  @State private var isLoadingContent = false

  private var display: ServerToolDisplay? { toolRow.toolDisplay }
  private var glyphSymbol: String { display?.glyphSymbol ?? "gearshape" }
  private var glyphColor: Color { Self.resolveColor(display?.glyphColor ?? "gray") }
  private var summary: String { display?.summary ?? toolRow.title }
  private var subtitle: String? { display?.subtitle ?? toolRow.subtitle }
  private var rightMeta: String? { display?.rightMeta }
  private var isRunning: Bool { toolRow.status == .running || toolRow.status == .pending }
  private var isFailed: Bool { toolRow.status == .failed }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      compactRow

      // Inline diff preview (compact, not expanded)
      if !isExpanded, let preview = display?.diffPreview {
        diffPreviewStrip(preview)
      }

      // Inline live output (compact, streaming)
      if !isExpanded, isRunning,
         let liveOutput = display?.liveOutputPreview, !liveOutput.isEmpty
      {
        liveOutputStrip(liveOutput)
      }

      if isExpanded {
        expandedSection
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .stroke(isFailed ? Color.feedbackNegative.opacity(OpacityTier.light) : Color.clear, lineWidth: 1)
        )
    )
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(
        topLeadingRadius: Radius.md,
        bottomLeadingRadius: Radius.md,
        bottomTrailingRadius: 0,
        topTrailingRadius: 0,
        style: .continuous
      )
      .fill(glyphColor)
      .frame(width: EdgeBar.width)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xxs)
    .contentShape(Rectangle())
    .onChange(of: isExpanded) { _, expanded in
      if expanded, expandedContent == nil {
        fetchContent()
      }
    }
    .onAppear {
      if isExpanded, expandedContent == nil {
        fetchContent()
      }
    }
  }

  // MARK: - Compact Row

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

          if let subtitle, !subtitle.isEmpty,
             display?.subtitleAbsorbsMeta == true
          {
            Text(subtitle)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        }

        if let subtitle, !subtitle.isEmpty,
           display?.subtitleAbsorbsMeta != true
        {
          Text(subtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }

      Spacer(minLength: 0)

      if let rightMeta, !rightMeta.isEmpty {
        Text(rightMeta)
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      if isRunning {
        ProgressView()
          .controlSize(.small)
      } else if isFailed {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.feedbackNegative)
      }

      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.leading, Spacing.md)
    .padding(.trailing, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
  }

  // MARK: - Inline Previews (Compact)

  private func diffPreviewStrip(_ preview: ServerToolDiffPreview) -> some View {
    HStack(spacing: Spacing.sm_) {
      if let context = preview.contextLine, !context.isEmpty {
        Text(context)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      Text(preview.snippetPrefix)
        .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
        .foregroundStyle(preview.isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent)

      Text(preview.snippetText)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(preview.isAddition ? Color.diffAddedAccent.opacity(0.8) : Color.diffRemovedAccent.opacity(0.8))

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
    .padding(.top, Spacing.xxs)
  }

  private func liveOutputStrip(_ output: String) -> some View {
    let lastLine = output.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? output
    return HStack(spacing: Spacing.xs) {
      Circle()
        .fill(Color.feedbackPositive)
        .frame(width: 5, height: 5)

      Text(lastLine)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.sm_)
  }

  // MARK: - Expanded Content (fetched on demand)

  @ViewBuilder
  private var expandedSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle()
        .fill(Color.textQuaternary.opacity(0.15))
        .frame(height: 1)

      if isLoadingContent, expandedContent == nil {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Loading…")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
        .padding(Spacing.md)
      } else if let content = expandedContent {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if let input = content.inputDisplay, !input.isEmpty {
            codeSection(title: "Input", text: input, language: nil)
          }
          if let diff = content.diffDisplay, !diff.isEmpty {
            diffSection(text: diff)
          }
          if let output = content.outputDisplay, !output.isEmpty {
            codeSection(title: "Output", text: output, language: content.language)
          }
        }
        .padding(Spacing.md)
      } else {
        // Fallback: show raw invocation/result from the row data
        VStack(alignment: .leading, spacing: Spacing.md) {
          if let json = toolRow.invocation.jsonString, !json.isEmpty {
            codeSection(title: "Input", text: json, language: nil)
          }
          if let json = toolRow.result?.jsonString, !json.isEmpty {
            codeSection(title: "Output", text: json, language: nil)
          }
        }
        .padding(Spacing.md)
      }
    }
  }

  // MARK: - Fetch

  private func fetchContent() {
    guard let clients, !isLoadingContent else { return }
    isLoadingContent = true
    Task {
      do {
        let content = try await clients.conversation.fetchRowContent(
          sessionId: sessionId, rowId: toolRow.id
        )
        expandedContent = content
      } catch {
        // Fallback to inline data — already handled in expandedSection
      }
      isLoadingContent = false
    }
  }

  // MARK: - Section Views

  private func codeSection(title: String, text: String, language: String?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack {
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        Spacer()

        if let language, !language.isEmpty {
          Text(language)
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.backgroundSecondary, in: Capsule())
        }
      }

      ScrollView(.vertical, showsIndicators: true) {
        ScrollView(.horizontal, showsIndicators: false) {
          Text(text)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .fixedSize(horizontal: true, vertical: true)
        }
      }
      .frame(maxHeight: 400)
      .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  private func diffSection(text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Changes")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
            diffLine(line)
          }
        }
      }
      .frame(maxHeight: 500)
      .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  private func diffLine(_ line: String) -> some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(diffEdgeColor(line))
        .frame(width: 3)

      Text(line)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(diffLineColor(line))
        .padding(.leading, Spacing.sm)
        .padding(.trailing, Spacing.sm)
        .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(diffLineBg(line))
  }

  // MARK: - Diff Helpers

  private func diffLineColor(_ line: String) -> Color {
    if line.hasPrefix("+") { return .diffAddedAccent }
    if line.hasPrefix("-") { return .diffRemovedAccent }
    return .textTertiary
  }

  private func diffLineBg(_ line: String) -> Color {
    if line.hasPrefix("+") { return .diffAddedBg }
    if line.hasPrefix("-") { return .diffRemovedBg }
    return .clear
  }

  private func diffEdgeColor(_ line: String) -> Color {
    if line.hasPrefix("+") { return .diffAddedEdge }
    if line.hasPrefix("-") { return .diffRemovedEdge }
    return .clear
  }

  // MARK: - Color Resolution

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
