//
//  WorkStreamEntry.swift
//  OrbitDock
//
//  Hybrid-density work stream: tools stay compact one-liners,
//  conversations render inline with full content, edits show
//  a mini diff preview. Three tiers of visual density.
//

import SwiftUI

struct WorkStreamEntry: View {
  let message: TranscriptMessage
  let provider: Provider
  let model: String?
  let sessionId: String?
  let rollbackTurns: Int?
  let nthUserMessage: Int?
  let onRollback: (() -> Void)?
  let onFork: (() -> Void)?
  let onNavigateToReviewFile: ((String, Int) -> Void)?
  var onShellSendToAI: ((String) -> Void)?
  @State private var isExpanded = false
  @State private var isEditCardCollapsed = true
  @State private var isHovering = false
  @State private var isContentExpanded = false

  // MARK: - Entry Kind

  private enum EntryKind {
    case userPrompt
    case userBash(ParsedBashContent)
    case userSlashCommand(ParsedSlashCommand)
    case userTaskNotification(ParsedTaskNotification)
    case userSystemCaveat(ParsedSystemCaveat)
    case userCodeReview
    case userSystemContext(ParsedSystemContext)
    case userShellContext(ParsedShellContext)
    case assistant
    case thinking
    case steer
    case toolBash, toolRead, toolEdit, toolGlob, toolGrep
    case toolTask, toolMcp, toolWebFetch, toolWebSearch
    case toolSkill, toolPlanMode, toolTodoTask, toolAskQuestion
    case toolStandard
    case shell
  }

  // MARK: - Render Mode

  private enum RenderMode {
    case compact // tools — one-liner, click to expand
    case inline // user/assistant/steer — always show content
    case compactPreview // edit/write — compact + mini diff below
  }

  private var renderMode: RenderMode {
    switch kind {
      case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
           .userSystemCaveat, .userCodeReview, .userSystemContext, .userShellContext,
           .assistant, .steer, .thinking, .shell:
        .inline
      case .toolEdit:
        .compactPreview
      default:
        .compact
    }
  }

  private var kind: EntryKind {
    if message.isThinking { return .thinking }
    if message.isSteer { return .steer }
    if message.isShell { return .shell }

    if message.isTool {
      guard let name = message.toolName else { return .toolStandard }
      let lowercased = name.lowercased()
      if name.hasPrefix("mcp__") { return .toolMcp }
      switch lowercased {
        case "bash": return .toolBash
        case "read": return .toolRead
        case "edit", "write", "notebookedit": return .toolEdit
        case "glob": return .toolGlob
        case "grep": return .toolGrep
        case "task": return .toolTask
        case "webfetch": return .toolWebFetch
        case "websearch": return .toolWebSearch
        case "skill": return .toolSkill
        case "enterplanmode", "exitplanmode": return .toolPlanMode
        case "taskcreate", "taskupdate", "tasklist", "taskget": return .toolTodoTask
        case "askuserquestion": return .toolAskQuestion
        default: return .toolStandard
      }
    }

    if message.isUser {
      if let bash = ParsedBashContent.parse(from: message.content) {
        return .userBash(bash)
      }
      if let cmd = ParsedSlashCommand.parse(from: message.content) {
        return .userSlashCommand(cmd)
      }
      if let notif = ParsedTaskNotification.parse(from: message.content) {
        return .userTaskNotification(notif)
      }
      if let caveat = ParsedSystemCaveat.parse(from: message.content) {
        return .userSystemCaveat(caveat)
      }
      if message.content.hasPrefix("## Code Review Feedback") {
        return .userCodeReview
      }
      if let ctx = ParsedSystemContext.parse(from: message.content) {
        return .userSystemContext(ctx)
      }
      if let shellCtx = ParsedShellContext.parse(from: message.content) {
        return .userShellContext(shellCtx)
      }
      return .userPrompt
    }

    return .assistant
  }

  // MARK: - Glyph & Color

  /// SF Symbol name for the glyph.
  private var glyphSymbol: String {
    switch kind {
      case .userPrompt: "arrow.right"
      case .userBash: "terminal"
      case .userSlashCommand: "slash.circle"
      case .userTaskNotification: "bolt.fill"
      case .userSystemCaveat: "info.circle"
      case .userCodeReview: "checkmark.message"
      case .userSystemContext: "doc.text"
      case .userShellContext: "terminal.fill"
      case .assistant: "sparkle"
      case .thinking: "brain.head.profile"
      case .steer: "arrow.turn.down.right"
      case .toolBash: "terminal"
      case .toolRead: "doc.plaintext"
      case .toolEdit: "pencil.line"
      case .toolGlob, .toolGrep: "magnifyingglass"
      case .toolTask: "bolt.fill"
      case .toolMcp: "puzzlepiece.extension"
      case .toolWebFetch, .toolWebSearch: "globe"
      case .toolSkill: "wand.and.stars"
      case .toolPlanMode: "map"
      case .toolTodoTask: "checklist"
      case .toolAskQuestion: "questionmark.bubble"
      case .toolStandard: "gearshape"
      case .shell: "terminal"
    }
  }

  private var glyphColor: Color {
    switch kind {
      case .userPrompt: .accent.opacity(0.7)
      case .userBash: .toolBash
      case .userSlashCommand: .toolSkill
      case .userTaskNotification: .toolTask
      case .userSystemCaveat: .secondary
      case .userCodeReview: .accent
      case .userSystemContext: Color.textTertiary
      case .userShellContext: .shellAccent
      case .assistant: Color.white.opacity(0.85)
      case .thinking: Color(red: 0.6, green: 0.55, blue: 0.8)
      case .steer: .accent
      case .toolBash: .toolBash
      case .toolRead: .toolRead
      case .toolEdit: .toolWrite
      case .toolGlob, .toolGrep: .toolSearch
      case .toolTask: .toolTask
      case .toolMcp: .toolMcp
      case .toolWebFetch, .toolWebSearch: .toolWeb
      case .toolSkill: .toolSkill
      case .toolPlanMode: .toolPlan
      case .toolTodoTask: .toolTodo
      case .toolAskQuestion: .toolQuestion
      case .toolStandard: .secondary
      case .shell: .shellAccent
    }
  }

  /// Compact speaker label for visual scan hierarchy.
  private var speakerLabelText: String {
    switch kind {
      case .assistant:
        return "ASSISTANT"
      case .thinking:
        return "REASONING"
      case .steer:
        return "STEER"
      case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
           .userSystemCaveat, .userCodeReview, .userSystemContext, .userShellContext, .shell:
        return "YOU"
      default:
        return "ENTRY"
    }
  }

  private var speakerLabelColor: Color {
    switch kind {
      case .assistant:
        return Color.textSecondary
      case .thinking:
        return Color(red: 0.65, green: 0.6, blue: 0.85).opacity(0.9)
      case .steer:
        return Color.accent.opacity(0.85)
      case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
           .userSystemCaveat, .userCodeReview, .userSystemContext, .userShellContext, .shell:
        return Color.accent.opacity(0.8)
      default:
        return Color.textTertiary
    }
  }

  private var speakerLabelView: some View {
    Text(speakerLabelText)
      .font(.system(size: TypeScale.chatLabel, weight: .bold, design: .rounded))
      .tracking(0.7)
      .foregroundStyle(speakerLabelColor)
      .padding(.horizontal, Spacing.xs)
  }

  // MARK: - Summary Text

  private var summaryText: String {
    switch kind {
      case .toolBash:
        return message.bashCommand ?? "bash"
      case .toolRead:
        return message.filePath.map { ToolCardStyle.shortenPath($0) } ?? "read"
      case .toolEdit:
        return message.filePath.map { ToolCardStyle.shortenPath($0) } ?? message.toolName ?? "edit"
      case .toolGlob:
        return message.globPattern ?? "glob"
      case .toolGrep:
        return message.grepPattern ?? "grep"
      case .toolTask:
        return message.taskDescription ?? message.taskPrompt ?? "task"
      case .toolMcp:
        return message.toolName?.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(
          of: "__",
          with: " · "
        ) ?? "mcp"
      case .toolWebFetch, .toolWebSearch:
        if let input = message.toolInput, let query = input["query"] as? String {
          return query
        }
        if let input = message.toolInput, let url = input["url"] as? String {
          return URL(string: url)?.host ?? url
        }
        return message.toolName ?? "web"
      case .toolSkill:
        if let input = message.toolInput, let skill = input["skill"] as? String {
          return skill
        }
        return "skill"
      case .toolPlanMode:
        return message.toolName == "EnterPlanMode" ? "Enter plan mode" : "Exit plan mode"
      case .toolTodoTask:
        if let input = message.toolInput, let subject = input["subject"] as? String {
          return subject
        }
        return message.toolName ?? "todo"
      case .toolAskQuestion:
        return "Asking question"
      case .toolStandard:
        return message.toolName ?? "tool"
      // Inline kinds still need summaryText for compactRow fallback (thinking)
      case .userPrompt:
        return firstLine(of: stripXMLTags(message.content), maxLength: 120)
      case let .userBash(bash):
        return bash.input
      case let .userSlashCommand(cmd):
        return cmd.hasArgs ? "\(cmd.name) \(cmd.args)" : cmd.name
      case let .userTaskNotification(notif):
        return notif.cleanDescription
      case let .userSystemCaveat(caveat):
        return caveat.message
      case .userCodeReview:
        return "Code review feedback"
      case let .userSystemContext(ctx):
        return ctx.label
      case let .userShellContext(ctx):
        if !ctx.userPrompt.isEmpty {
          return firstLine(of: ctx.userPrompt, maxLength: 120)
        }
        return "\(ctx.commandCount) shell command\(ctx.commandCount == 1 ? "" : "s")"
      case .assistant:
        return firstLine(of: message.content, maxLength: 100)
      case .thinking:
        return "Thinking\u{2026}"
      case .steer:
        return firstLine(of: message.content, maxLength: 100)
      case .shell:
        return message.content
    }
  }

  // MARK: - Right Metadata

  private var rightMeta: String? {
    switch kind {
      case .toolBash:
        if let dur = message.formattedDuration {
          let prefix = message.bashHasError ? "\u{2717}" : "\u{2713}"
          return "\(prefix) \(dur)"
        }
        if message.isInProgress { return "\u{2026}" }
        return nil
      case .toolRead:
        if let count = message.outputLineCount { return "\(count) lines" }
        return nil
      case .toolEdit:
        return editStats
      case .toolGlob:
        if let count = message.globMatchCount { return "\(count) files" }
        return nil
      case .toolGrep:
        if let count = message.grepMatchCount { return "\(count) matches" }
        return nil
      case .shell:
        if let dur = message.formattedDuration {
          let prefix = message.bashHasError ? "\u{2717}" : "\u{2713}"
          return "\(prefix) \(dur)"
        }
        if message.isInProgress { return "\u{2026}" }
        return nil
      case .assistant:
        if let input = message.inputTokens, input > 0 {
          return formatTokenCount(input)
        }
        return nil
      default:
        return nil
    }
  }

  private func formatTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000 {
      let k = Double(tokens) / 1_000.0
      return k >= 100 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    return "\(tokens)"
  }

  private var editStats: String? {
    if let old = message.editOldString, let new = message.editNewString {
      let oldLines = old.components(separatedBy: "\n").count
      let newLines = new.components(separatedBy: "\n").count
      let added = max(0, newLines - oldLines)
      let removed = max(0, oldLines - newLines)
      if added > 0 || removed > 0 {
        return "+\(added) -\(removed)"
      }
      return "~\(newLines) lines"
    }
    if message.hasUnifiedDiff, let diff = message.unifiedDiff {
      let lines = diff.components(separatedBy: "\n")
      let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
      let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
      return "+\(added) -\(removed)"
    }
    return nil
  }

  private var isUserKind: Bool {
    switch kind {
      case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
           .userSystemCaveat, .userCodeReview, .userShellContext, .steer, .shell:
        true
      default:
        false
    }
  }

  /// True for user-authored entries that render right-aligned.
  /// Steer and system context stay left since they're injected, not user-authored.
  private var isUserEntry: Bool {
    switch kind {
      case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
           .userSystemCaveat, .userCodeReview, .userShellContext, .shell:
        true
      default:
        false
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch renderMode {
        case .compact:
          compactRow
            .contentShape(Rectangle())
            .onTapGesture {
              withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                isExpanded.toggle()
              }
            }

          if isExpanded {
            expandedContent
              .padding(.leading, Spacing.xl)
              .padding(.trailing, Spacing.md)
              .padding(.bottom, Spacing.sm)
              .transition(.opacity.combined(with: .move(edge: .top)))
          }

        case .inline:
          if isUserEntry {
            userGlyphHeaderRow

            userInlineContent
              .padding(.leading, Spacing.md)
              .padding(.bottom, Spacing.md)
          } else {
            glyphHeaderRow

            inlineContent
              .padding(.bottom, Spacing.md)
          }

        case .compactPreview:
          compactRow
            .contentShape(Rectangle())
            .onTapGesture {
              withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                isEditCardCollapsed.toggle()
              }
            }

          if isEditCardCollapsed {
            // Collapsed: show mini 3-line diff preview
            editPreview
              .padding(.leading, Spacing.xl)
              .padding(.trailing, Spacing.md)
              .padding(.top, Spacing.xxs)
              .padding(.bottom, Spacing.xs)
          } else {
            // Default: show full diff card
            expandedContent
              .padding(.leading, Spacing.xl)
              .padding(.trailing, Spacing.md)
              .padding(.bottom, Spacing.sm)
          }
      }
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovering)
  }

  // MARK: - Glyph View (SF Symbol or text fallback)

  private var glyphView: some View {
    Image(systemName: glyphSymbol)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(glyphColor)
      .frame(width: 20, alignment: .center)
      .opacity(message.isInProgress ? pulsingOpacity : 1.0)
  }

  // MARK: - Glyph Header Row (for inline mode)

  private var glyphHeaderRow: some View {
    HStack(spacing: 0) {
      // Timestamp column (52px)
      Text(formatTime(message.timestamp))
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 52, alignment: .leading)

      // Glyph column (20px)
      glyphView

      speakerLabelView

      Spacer()
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: 26)
    .background(isHovering ? Color.surfaceHover : Color.clear)
  }

  // MARK: - User Glyph Header Row (right-aligned, for user inline entries)

  private var userGlyphHeaderRow: some View {
    HStack(spacing: 0) {
      Spacer()

      // Hover actions — inline before the glyph so they don't overlap
      if isHovering, isUserKind {
        hoverActions
          .padding(.trailing, Spacing.sm)
          .transition(.opacity)
      }

      speakerLabelView

      // Glyph column (20px)
      glyphView

      // Timestamp column (52px)
      Text(formatTime(message.timestamp))
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 52, alignment: .trailing)
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: 26)
    .background(isHovering ? Color.surfaceHover : Color.clear)
  }

  // MARK: - User Inline Content (right-aligned)

  private var userInlineContent: some View {
    HStack(spacing: 0) {
      // Left gutter — prevents user messages from spanning full width.
      // Takes ~28% of space, pushing content right-aligned.
      Color.clear
        .frame(minWidth: 80)
        .layoutPriority(-1)

      Group {
        switch kind {
          case .userPrompt:
            userPromptInlineRight

          case let .userBash(bash):
            UserBashCard(bash: bash, timestamp: message.timestamp)

          case let .userSlashCommand(cmd):
            UserSlashCommandCard(command: cmd, timestamp: message.timestamp)

          case let .userTaskNotification(notif):
            TaskNotificationCard(notification: notif, timestamp: message.timestamp)

          case let .userSystemCaveat(caveat):
            SystemCaveatView(caveat: caveat)

          case let .userShellContext(ctx):
            ShellContextCard(context: ctx, timestamp: message.timestamp)

          case .userCodeReview:
            CodeReviewFeedbackCard(
              content: message.content,
              timestamp: message.timestamp,
              onNavigateToFile: onNavigateToReviewFile
            )

          case .shell:
            shellInline

          default:
            EmptyView()
        }
      }
    }
    .padding(.trailing, Spacing.sm)
  }

  private var userPromptInlineRight: some View {
    let markdown = stripXMLTags(message.content)

    return HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .trailing, spacing: Spacing.sm) {
        if !message.images.isEmpty {
          ImageGallery(images: message.images)
        }
        if !markdown.isEmpty {
          MarkdownContentView(content: markdown)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .multilineTextAlignment(.trailing)
        }
      }
      .padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.md)

      Rectangle()
        .fill(Color.accent.opacity(OpacityTier.strong))
        .frame(width: EdgeBar.width)
    }
    .frame(maxWidth: 860, alignment: .trailing)
  }

  // MARK: - Compact Row

  private var compactRow: some View {
    HStack(spacing: 0) {
      // Timestamp column (52px)
      Text(formatTime(message.timestamp))
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 52, alignment: .leading)

      // Glyph column (20px)
      glyphView

      // Summary (flex)
      Text(summaryText)
        .font(.system(
          size: TypeScale.body,
          weight: isUserKind ? .medium : .regular,
          design: isTool ? .monospaced : .default
        ))
        .foregroundStyle(isUserKind ? Color.white.opacity(0.95) : Color.white.opacity(0.70))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, Spacing.xs)

      Spacer(minLength: Spacing.xs)

      // Right meta
      if let meta = rightMeta {
        Text(meta)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .padding(.trailing, Spacing.xs)
      }

    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: 26)
    .background(isHovering ? Color.surfaceHover : Color.clear)
  }

  @State private var isPulsing = false

  private var pulsingOpacity: Double {
    isPulsing ? 0.4 : 1.0
  }

  private var isTool: Bool {
    switch kind {
      case .toolBash, .toolRead, .toolEdit, .toolGlob, .toolGrep,
           .toolTask, .toolMcp, .toolWebFetch, .toolWebSearch,
           .toolSkill, .toolPlanMode, .toolTodoTask, .toolAskQuestion,
           .toolStandard:
        true
      default:
        false
    }
  }

  // MARK: - Hover Actions

  private var hoverActions: some View {
    HStack(spacing: Spacing.xs) {
      if let action = onRollback, rollbackTurns != nil {
        Button(action: action) {
          Image(systemName: "arrow.uturn.backward")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Roll back to here")
      }

      if let forkAction = onFork, nthUserMessage != nil {
        Button(action: forkAction) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accent.opacity(0.8))
            .frame(width: 24, height: 24)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Fork from here")
      }
    }
    .transition(.opacity)
  }

  // MARK: - Inline Content (always visible for user/assistant/steer)

  private let maxInlineLength = 4_000

  private var isLongContent: Bool {
    message.content.count > maxInlineLength
  }

  private var displayContent: String {
    if isLongContent, !isContentExpanded {
      return String(message.content.prefix(maxInlineLength))
    }
    return message.content
  }

  @ViewBuilder
  private var inlineContent: some View {
    switch kind {
      case .userPrompt:
        userPromptInline

      case let .userBash(bash):
        UserBashCard(bash: bash, timestamp: message.timestamp)
          .padding(.leading, Spacing.xl)

      case let .userSlashCommand(cmd):
        UserSlashCommandCard(command: cmd, timestamp: message.timestamp)
          .padding(.leading, Spacing.xl)

      case let .userTaskNotification(notif):
        TaskNotificationCard(notification: notif, timestamp: message.timestamp)
          .padding(.leading, Spacing.xl)

      case let .userSystemCaveat(caveat):
        SystemCaveatView(caveat: caveat)
          .padding(.leading, Spacing.xl)

      case .userCodeReview:
        CodeReviewFeedbackCard(
          content: message.content,
          timestamp: message.timestamp,
          onNavigateToFile: onNavigateToReviewFile
        )
        .padding(.leading, Spacing.xl)

      case let .userSystemContext(ctx):
        SystemContextCard(context: ctx)
          .padding(.leading, Spacing.xl)
          .padding(.trailing, Spacing.xl)

      case let .userShellContext(ctx):
        ShellContextCard(context: ctx, timestamp: message.timestamp)
          .padding(.leading, Spacing.xl)

      case .assistant:
        assistantInline

      case .steer:
        steerInline

      case .thinking:
        thinkingInline

      default:
        EmptyView()
    }
  }

  private var userPromptInline: some View {
    let markdown = stripXMLTags(message.content)

    return HStack(alignment: .top, spacing: 0) {
      Rectangle()
        .fill(Color.accent.opacity(OpacityTier.strong))
        .frame(width: EdgeBar.width)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        if !message.images.isEmpty {
          ImageGallery(images: message.images)
        }
        if !markdown.isEmpty {
          MarkdownContentView(content: markdown)
        }
      }
      .padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.md)
    }
    .frame(maxWidth: 920, alignment: .leading)
    .padding(.leading, Spacing.xl)
  }

  private var assistantInline: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if message.hasThinking {
        thinkingDisclosure
      }

      StreamingMarkdownView(content: displayContent)

      if isLongContent {
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            isContentExpanded.toggle()
          }
        } label: {
          Text(isContentExpanded ? "Show less" : "Show more\u{2026}")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.accent.opacity(0.8))
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: 920, alignment: .leading)
    .padding(.leading, Spacing.xl)
    .padding(.trailing, Spacing.xl)
  }

  private var steerInline: some View {
    Text(message.content)
      .font(.system(size: TypeScale.subhead))
      .foregroundStyle(.secondary)
      .lineSpacing(3)
      .italic()
      .textSelection(.enabled)
      .padding(.leading, Spacing.xl)
      .padding(.trailing, Spacing.xl)
  }

  // MARK: - Shell Inline

  @State private var isShellExpanded = false
  @State private var isShellHovering = false

  private var shellInline: some View {
    ShellCard(
      message: message,
      isExpanded: $isShellExpanded,
      isHovering: $isShellHovering,
      onSendToAI: onShellSendToAI
    )
    .padding(.leading, Spacing.xl)
    .padding(.trailing, Spacing.xl)
  }

  // MARK: - Thinking Inline

  private let maxThinkingPreviewLength = 600

  @State private var isThinkingContentExpanded = false

  private var thinkingInline: some View {
    let thinkingColor = Color(red: 0.65, green: 0.6, blue: 0.85)
    let content = message.content
    let isLong = content.count > maxThinkingPreviewLength
    let displayText = isLong && !isThinkingContentExpanded
      ? String(content.prefix(maxThinkingPreviewLength))
      : content

    return VStack(alignment: .leading, spacing: 0) {
      StreamingMarkdownView(content: displayText, style: .thinking)
        .frame(maxWidth: .infinity, alignment: .leading)

      if isLong {
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            isThinkingContentExpanded.toggle()
          }
        } label: {
          Text(isThinkingContentExpanded ? "Show less" : "Show more\u{2026}")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(thinkingColor.opacity(0.7))
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.xs)
      }
    }
    .frame(maxWidth: 920, alignment: .leading)
    .padding(.leading, Spacing.xl)
    .padding(.trailing, Spacing.xl)
  }

  // MARK: - Edit Preview (mini diff for compactPreview mode)

  private var editPreviewLines: [(prefix: String, text: String, isAdd: Bool)] {
    var results: [(prefix: String, text: String, isAdd: Bool)] = []

    if let old = message.editOldString, let new = message.editNewString {
      let changed = EditCard.extractChangedLines(oldString: old, newString: new)
      for line in changed.prefix(3) {
        let isAdd = line.type == .added
        results.append((isAdd ? "+" : "-", line.content, isAdd))
      }
    } else if message.hasUnifiedDiff, let diff = message.unifiedDiff {
      let lines = diff.components(separatedBy: "\n")
      for line in lines {
        if results.count >= 3 { break }
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
          results.append(("+", String(line.dropFirst()), true))
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
          results.append(("-", String(line.dropFirst()), false))
        }
      }
    }

    return results
  }

  @ViewBuilder
  private var editPreview: some View {
    let lines = editPreviewLines
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          HStack(spacing: 0) {
            Text(line.prefix)
              .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
              .foregroundStyle(line.isAdd ? Color.diffAddedAccent : Color.diffRemovedAccent)
              .frame(width: 12, alignment: .center)

            Text(line.text)
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(line.isAdd ? Color.diffAddedAccent.opacity(0.8) : Color.diffRemovedAccent.opacity(0.8))
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .padding(.vertical, 1)
          .padding(.horizontal, Spacing.xs)
          .background(line.isAdd ? Color.diffAddedBg : Color.diffRemovedBg)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    switch kind {
      case .toolBash, .toolRead, .toolEdit, .toolGlob, .toolGrep,
           .toolTask, .toolMcp, .toolWebFetch, .toolWebSearch,
           .toolSkill, .toolPlanMode, .toolTodoTask, .toolAskQuestion,
           .toolStandard:
        ToolIndicator(message: message, sessionId: sessionId, initiallyExpanded: true)

      case .thinking:
        ScrollView {
          StreamingMarkdownView(content: message.content, style: .thinking)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)

      default:
        EmptyView()
    }
  }

  // MARK: - Thinking Disclosure (for assistant messages with thinking)

  @State private var isThinkingExpanded = false

  private var thinkingDisclosure: some View {
    let thinkingColor = Color(red: 0.65, green: 0.6, blue: 0.85)

    return VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
          isThinkingExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "brain.head.profile")
            .font(.system(size: 10, weight: .semibold))
          Text("Thinking")
            .font(.system(size: 11, weight: .semibold))

          if !isThinkingExpanded {
            Text(message.thinking?.components(separatedBy: "\n").first ?? "")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
          }

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isThinkingExpanded ? 90 : 0))
        }
        .foregroundStyle(thinkingColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(thinkingColor.opacity(0.08))
        )
      }
      .buttonStyle(.plain)

      if isThinkingExpanded, let thinking = message.thinking {
        ScrollView {
          StreamingMarkdownView(content: thinking, style: .thinking)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 250)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(thinkingColor.opacity(0.04))
        )
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  // MARK: - Helpers

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private func formatTime(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }

  private func firstLine(of text: String, maxLength: Int) -> String {
    let line = text.components(separatedBy: "\n")
      .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    if line.count > maxLength {
      return String(line.prefix(maxLength - 1)) + "\u{2026}"
    }
    return line
  }

  private func stripXMLTags(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  }
}
