//
//  ToolCardView.swift
//  OrbitDock
//
//  Every tool type has purpose-built compact + expanded rendering.
//  Expanded content fetched on demand via REST — zero truncation.
//  The toolType field from ServerToolDisplay drives rendering dispatch.
//
//  Tool types: bash, read, edit, glob, grep, task, mcp, web,
//              plan, todo, question, hook, handoff, toolSearch, generic
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
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xxs)
    .contentShape(Rectangle())
    .onChange(of: isExpanded) { _, expanded in
      if expanded, expandedContent == nil { fetchContent() }
    }
    .onAppear {
      if isExpanded, expandedContent == nil { fetchContent() }
    }
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
    .padding(.leading, Spacing.md)
    .padding(.trailing, Spacing.sm)
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

    // Live output for running bash
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

      if isLoadingContent, expandedContent == nil {
        loadingIndicator
      } else if let content = expandedContent {
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
  // MARK: - Type-Specific Expanded Bodies
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  @ViewBuilder
  private func expandedBody(_ content: ServerRowContent) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      switch toolType {
      case "bash":
        bashExpanded(content)
      case "read":
        readExpanded(content)
      case "edit":
        editExpanded(content)
      case "glob":
        globExpanded(content)
      case "grep":
        grepExpanded(content)
      case "task":
        taskExpanded(content)
      case "mcp":
        mcpExpanded(content)
      case "web":
        webExpanded(content)
      case "plan":
        planExpanded(content)
      case "todo":
        todoExpanded(content)
      case "question":
        questionExpanded(content)
      case "toolSearch":
        toolSearchExpanded(content)
      case "hook":
        hookExpanded(content)
      case "handoff":
        handoffExpanded(content)
      default:
        genericExpanded(content)
      }
    }
    .padding(Spacing.md)
  }

  // ── Bash ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func bashExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      // Terminal prompt
      HStack(alignment: .top, spacing: Spacing.xs) {
        Text("$")
          .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.toolBash)
        Text(input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    if let output = c.outputDisplay, !output.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Spacer()
          if isFailed {
            statusPill("EXIT 1", color: .feedbackNegative)
          }
        }

        Text(output)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(isFailed ? Color.feedbackNegative.opacity(0.8) : Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func readExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      // File path breadcrumb
      pathBreadcrumb(input)
    }

    if let output = c.outputDisplay, !output.isEmpty {
      let lines = output.components(separatedBy: "\n")
      let gutterChars = max(3, "\(lines.count)".count)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Content")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Spacer()
          if let lang = c.language, !lang.isEmpty { languageBadge(lang) }
          Text("\(lines.count) lines")
            .font(.system(size: TypeScale.mini, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            HStack(alignment: .top, spacing: 0) {
              Text("\(index + 1)")
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textQuaternary.opacity(0.4))
                .frame(width: CGFloat(gutterChars) * 8 + Spacing.sm, alignment: .trailing)
                .padding(.trailing, Spacing.sm)
              Rectangle().fill(Color.textQuaternary.opacity(0.08)).frame(width: 1)
              Text(line.isEmpty ? " " : line)
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .padding(.leading, Spacing.sm)
            }
            .padding(.vertical, 1)
          }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
  }

  // ── Edit / Write ─────────────────────────────────────────────────────────

  @ViewBuilder
  private func editExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      pathBreadcrumb(input)
    }

    if let diff = c.diffDisplay, !diff.isEmpty {
      let lines = diff.components(separatedBy: "\n")
      let adds = lines.filter { $0.hasPrefix("+") }.count
      let dels = lines.filter { $0.hasPrefix("-") }.count

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Changes")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Spacer()
          if let lang = c.language, !lang.isEmpty { languageBadge(lang) }
          if adds > 0 {
            Text("+\(adds)")
              .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.diffAddedAccent)
          }
          if dels > 0 {
            Text("-\(dels)")
              .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.diffRemovedAccent)
          }
        }

        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            HStack(spacing: 0) {
              Rectangle().fill(diffEdgeColor(line)).frame(width: 3)
              Text(diffPrefix(line))
                .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
                .foregroundStyle(diffLineColor(line))
                .frame(width: 16, alignment: .center)
              Text(diffContent(line))
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(diffLineColor(line))
                .padding(.trailing, Spacing.sm)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(diffLineBg(line))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
      }
    }

    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Result", text: output, language: nil)
    }
  }

  // ── Glob ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func globExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      HStack(spacing: Spacing.xs) {
        Text("Pattern:")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text(input)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.toolSearch)
      }
    }

    if let output = c.outputDisplay, !output.isEmpty {
      let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Files")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Spacer()
          Text("\(files.count) matches")
            .font(.system(size: TypeScale.mini, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(files.enumerated()), id: \.offset) { _, file in
            HStack(spacing: Spacing.sm_) {
              Image(systemName: "doc.text")
                .font(.system(size: 8))
                .foregroundStyle(Color.toolSearch.opacity(0.5))
              Text(file)
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
          }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
  }

  // ── Grep ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func grepExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      HStack(spacing: Spacing.xs) {
        Text("Pattern:")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text(input)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.toolSearch)
      }
    }

    if let output = c.outputDisplay, !output.isEmpty {
      let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Matches")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Spacer()
          Text("\(lines.count) results")
            .font(.system(size: TypeScale.mini, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(size: TypeScale.code, design: .monospaced))
              .foregroundStyle(Color.textSecondary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xxs)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
  }

  // ── Agent / Task ─────────────────────────────────────────────────────────

  @ViewBuilder
  private func taskExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Task")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.toolTask.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
              .stroke(Color.toolTask.opacity(OpacityTier.subtle), lineWidth: 1)
          )
      }
    }

    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Agent Output", text: output, language: nil)
    }
  }

  // ── MCP ──────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func mcpExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      codeBlock(label: "Input", text: input, language: "JSON")
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Output", text: output, language: "JSON")
    }
  }

  // ── Web Search / Fetch ───────────────────────────────────────────────────

  @ViewBuilder
  private func webExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "globe")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.toolWeb)
        Text(input)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.accent)
      }
    }

    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Response", text: output, language: nil)
    }
  }

  // ── Plan ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func planExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "map")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.toolPlan)
          Text("Plan")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
        }
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.toolPlan.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Result", text: output, language: nil)
    }
  }

  // ── Todo ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func todoExpanded(_ c: ServerRowContent) -> some View {
    // Show todo items from display if available
    if let display, !display.todoItems.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Tasks")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        ForEach(Array(display.todoItems.enumerated()), id: \.offset) { _, item in
          HStack(spacing: Spacing.sm) {
            Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : "circle")
              .font(.system(size: IconScale.md))
              .foregroundStyle(item.status == "completed" ? Color.feedbackPositive : Color.textQuaternary)
            Text(item.status)
              .font(.system(size: TypeScale.body))
              .foregroundStyle(item.status == "completed" ? Color.textTertiary : Color.textSecondary)
          }
        }
      }
    }

    if let input = c.inputDisplay, !input.isEmpty {
      codeBlock(label: "Input", text: input, language: nil)
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Output", text: output, language: nil)
    }
  }

  // ── Question ─────────────────────────────────────────────────────────────

  @ViewBuilder
  private func questionExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "questionmark.bubble")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.toolQuestion)
          Text("Question")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
        }
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.toolQuestion.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Response", text: output, language: nil)
    }
  }

  // ── ToolSearch ───────────────────────────────────────────────────────────

  @ViewBuilder
  private func toolSearchExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      HStack(spacing: Spacing.xs) {
        Text("Query:")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text(input)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
      }
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Tools Found", text: output, language: nil)
    }
  }

  // ── Hook ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func hookExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      codeBlock(label: "Hook Event", text: input, language: nil)
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Result", text: output, language: nil)
    }
  }

  // ── Handoff ──────────────────────────────────────────────────────────────

  @ViewBuilder
  private func handoffExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.statusReply)
          Text("Handoff")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
        }
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Result", text: output, language: nil)
    }
  }

  // ── Generic ──────────────────────────────────────────────────────────────

  @ViewBuilder
  private func genericExpanded(_ c: ServerRowContent) -> some View {
    if let input = c.inputDisplay, !input.isEmpty {
      codeBlock(label: "Input", text: input, language: nil)
    }
    if let diff = c.diffDisplay, !diff.isEmpty {
      editExpanded(c)
    }
    if let output = c.outputDisplay, !output.isEmpty {
      codeBlock(label: "Output", text: output, language: c.language)
    }
  }

  // ── Fallback (no REST content) ───────────────────────────────────────────

  @ViewBuilder
  private var fallbackBody: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let json = toolRow.invocation.jsonString, !json.isEmpty {
        codeBlock(label: "Input", text: json, language: nil)
      }
      if let json = toolRow.result?.jsonString, !json.isEmpty {
        codeBlock(label: "Output", text: json, language: nil)
      }
    }
    .padding(Spacing.md)
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
        .fixedSize(horizontal: false, vertical: true)
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

  private func pathBreadcrumb(_ path: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "folder")
        .font(.system(size: 8))
        .foregroundStyle(Color.textQuaternary)
      Text(path)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
  }

  private func statusPill(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 1)
      .background(color.opacity(OpacityTier.subtle), in: Capsule())
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Fetch
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private func fetchContent() {
    guard let clients, !isLoadingContent else { return }
    isLoadingContent = true
    Task {
      do {
        expandedContent = try await clients.conversation.fetchRowContent(
          sessionId: sessionId, rowId: toolRow.id
        )
      } catch {}
      isLoadingContent = false
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Diff Helpers
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private func diffPrefix(_ line: String) -> String {
    if line.hasPrefix("+") { return "+" }
    if line.hasPrefix("-") { return "−" }
    return " "
  }

  private func diffContent(_ line: String) -> String {
    if line.hasPrefix("+") || line.hasPrefix("-") { return String(line.dropFirst()) }
    return line
  }

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
