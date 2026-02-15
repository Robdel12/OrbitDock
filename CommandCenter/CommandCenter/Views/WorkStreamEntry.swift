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
  let transcriptPath: String?
  let rollbackTurns: Int?
  let nthUserMessage: Int?
  let onRollback: (() -> Void)?
  let onFork: (() -> Void)?
  let onNavigateToReviewFile: ((String, Int) -> Void)?
  @State private var isExpanded = false
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
    case assistant
    case thinking
    case steer
    case toolBash, toolRead, toolEdit, toolGlob, toolGrep
    case toolTask, toolMcp, toolWebFetch, toolWebSearch
    case toolSkill, toolPlanMode, toolTodoTask, toolAskQuestion
    case toolStandard
  }

  // MARK: - Render Mode

  private enum RenderMode {
    case compact        // tools — one-liner, click to expand
    case inline         // user/assistant/steer — always show content
    case compactPreview // edit/write — compact + mini diff below
  }

  private var renderMode: RenderMode {
    switch kind {
    case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
         .userSystemCaveat, .userCodeReview, .assistant, .steer:
      return .inline
    case .toolEdit:
      return .compactPreview
    default:
      return .compact
    }
  }

  private var kind: EntryKind {
    if message.isThinking { return .thinking }
    if message.isSteer { return .steer }

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
      return .userPrompt
    }

    return .assistant
  }

  // MARK: - Glyph & Color

  private var glyph: String {
    switch kind {
    case .userPrompt: return "\u{2192}"       // →
    case .userBash: return "$"
    case .userSlashCommand: return "/"
    case .userTaskNotification: return "\u{26A1}" // ⚡
    case .userSystemCaveat: return "\u{2139}"     // ℹ
    case .userCodeReview: return "\u{2714}"        // ✔
    case .assistant: return "\u{25C0}"            // ◀
    case .thinking: return "\u{25D0}"             // ◐
    case .steer: return "\u{21D2}"                // ⇒
    case .toolBash: return "$"
    case .toolRead: return "\u{25CE}"             // ◎
    case .toolEdit: return "\u{270E}"             // ✎
    case .toolGlob, .toolGrep: return "\u{2315}"  // ⌕
    case .toolTask: return "\u{26A1}"             // ⚡
    case .toolMcp, .toolStandard: return "\u{2699}" // ⚙
    case .toolWebFetch, .toolWebSearch: return "\u{2197}" // ↗
    case .toolSkill: return "\u{2726}"            // ✦
    case .toolPlanMode: return "\u{2630}"         // ☰
    case .toolTodoTask: return "\u{2611}"         // ☑
    case .toolAskQuestion: return "?"
    }
  }

  private var glyphColor: Color {
    switch kind {
    case .userPrompt: return .accent.opacity(0.7)
    case .userBash: return .toolBash
    case .userSlashCommand: return .toolSkill
    case .userTaskNotification: return .toolTask
    case .userSystemCaveat: return .secondary
    case .userCodeReview: return .accent
    case .assistant: return Color.white.opacity(0.85)
    case .thinking: return Color(red: 0.6, green: 0.55, blue: 0.8)
    case .steer: return .accent
    case .toolBash: return .toolBash
    case .toolRead: return .toolRead
    case .toolEdit: return .toolWrite
    case .toolGlob, .toolGrep: return .toolSearch
    case .toolTask: return .toolTask
    case .toolMcp: return .toolMcp
    case .toolWebFetch, .toolWebSearch: return .toolWeb
    case .toolSkill: return .toolSkill
    case .toolPlanMode: return .toolPlan
    case .toolTodoTask: return .toolTodo
    case .toolAskQuestion: return .toolQuestion
    case .toolStandard: return .secondary
    }
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
      return message.toolName?.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ") ?? "mcp"
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
    case .userBash(let bash):
      return bash.input
    case .userSlashCommand(let cmd):
      return cmd.hasArgs ? "\(cmd.name) \(cmd.args)" : cmd.name
    case .userTaskNotification(let notif):
      return notif.cleanDescription
    case .userSystemCaveat(let caveat):
      return caveat.message
    case .userCodeReview:
      return "Code review feedback"
    case .assistant:
      return firstLine(of: message.content, maxLength: 100)
    case .thinking:
      return "Thinking\u{2026}"
    case .steer:
      return firstLine(of: message.content, maxLength: 100)
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
    default:
      return nil
    }
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
         .userSystemCaveat, .userCodeReview, .steer:
      return true
    default:
      return false
    }
  }

  /// True for user-authored entries that render right-aligned.
  /// Steer stays left since it's injected guidance, not a user prompt.
  private var isUserEntry: Bool {
    switch kind {
    case .userPrompt, .userBash, .userSlashCommand, .userTaskNotification,
         .userSystemCaveat, .userCodeReview:
      return true
    default:
      return false
    }
  }

  // MARK: - Body

  var body: some View {
    ZStack(alignment: .topTrailing) {
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
              .padding(.leading, 72)
              .padding(.trailing, Spacing.md)
              .padding(.bottom, Spacing.sm)
              .transition(.opacity.combined(with: .move(edge: .top)))
          }

        case .inline:
          if isUserEntry {
            userGlyphHeaderRow

            userInlineContent
              .padding(.leading, Spacing.md)
              .padding(.top, Spacing.sm)
              .padding(.bottom, Spacing.md)
          } else {
            glyphHeaderRow

            inlineContent
              .padding(.trailing, Spacing.md)
              .padding(.top, Spacing.sm)
              .padding(.bottom, Spacing.md)
          }

        case .compactPreview:
          compactRow
            .contentShape(Rectangle())
            .onTapGesture {
              withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                isExpanded.toggle()
              }
            }

          if !isExpanded {
            editPreview
              .padding(.leading, 72)
              .padding(.trailing, Spacing.md)
              .padding(.top, Spacing.xxs)
              .padding(.bottom, Spacing.xs)
          }

          if isExpanded {
            expandedContent
              .padding(.leading, 72)
              .padding(.trailing, Spacing.md)
              .padding(.bottom, Spacing.sm)
              .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }

      // Floating hover actions
      if isHovering && isUserKind {
        hoverActions
          .padding(.top, Spacing.xs)
          .padding(.trailing, Spacing.md)
      }
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovering)
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
      Text(glyph)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(glyphColor)
        .frame(width: 20, alignment: .center)
        .opacity(message.isInProgress ? pulsingOpacity : 1.0)

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

      // Glyph column (20px)
      Text(glyph)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(glyphColor)
        .frame(width: 20, alignment: .center)
        .opacity(message.isInProgress ? pulsingOpacity : 1.0)

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

  @ViewBuilder
  private var userInlineContent: some View {
    HStack {
      Spacer(minLength: 0)

      Group {
        switch kind {
        case .userPrompt:
          userPromptInlineRight

        case .userBash(let bash):
          UserBashCard(bash: bash, timestamp: message.timestamp)

        case .userSlashCommand(let cmd):
          UserSlashCommandCard(command: cmd, timestamp: message.timestamp)

        case .userTaskNotification(let notif):
          TaskNotificationCard(notification: notif, timestamp: message.timestamp)

        case .userSystemCaveat(let caveat):
          SystemCaveatView(caveat: caveat)

        case .userCodeReview:
          CodeReviewFeedbackCard(
            content: message.content,
            timestamp: message.timestamp,
            onNavigateToFile: onNavigateToReviewFile
          )

        default:
          EmptyView()
        }
      }
      .frame(maxWidth: 600)
    }
    .padding(.trailing, Spacing.sm)
  }

  private var userPromptInlineRight: some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .trailing, spacing: Spacing.sm) {
        if !message.images.isEmpty {
          ImageGallery(images: message.images)
        }
        if !message.content.isEmpty {
          Text(stripXMLTags(message.content))
            .font(.system(size: TypeScale.title))
            .foregroundStyle(Color.white.opacity(0.92))
            .lineSpacing(4)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
      }
      .padding(.trailing, Spacing.sm)

      Rectangle()
        .fill(Color.accent.opacity(OpacityTier.strong))
        .frame(width: EdgeBar.width)
    }
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
      Text(glyph)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(glyphColor)
        .frame(width: 20, alignment: .center)
        .opacity(message.isInProgress ? pulsingOpacity : 1.0)

      // Summary (flex)
      Text(summaryText)
        .font(.system(size: TypeScale.body, weight: isUserKind ? .medium : .regular, design: isTool ? .monospaced : .default))
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
      return true
    default:
      return false
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
    if isLongContent && !isContentExpanded {
      return String(message.content.prefix(maxInlineLength))
    }
    return message.content
  }

  @ViewBuilder
  private var inlineContent: some View {
    switch kind {
    case .userPrompt:
      userPromptInline

    case .userBash(let bash):
      UserBashCard(bash: bash, timestamp: message.timestamp)
        .padding(.leading, 72)

    case .userSlashCommand(let cmd):
      UserSlashCommandCard(command: cmd, timestamp: message.timestamp)
        .padding(.leading, 72)

    case .userTaskNotification(let notif):
      TaskNotificationCard(notification: notif, timestamp: message.timestamp)
        .padding(.leading, 72)

    case .userSystemCaveat(let caveat):
      SystemCaveatView(caveat: caveat)
        .padding(.leading, 72)

    case .userCodeReview:
      CodeReviewFeedbackCard(
        content: message.content,
        timestamp: message.timestamp,
        onNavigateToFile: onNavigateToReviewFile
      )
      .padding(.leading, 72)

    case .assistant:
      assistantInline

    case .steer:
      steerInline

    default:
      EmptyView()
    }
  }

  private var userPromptInline: some View {
    HStack(alignment: .top, spacing: 0) {
      Rectangle()
        .fill(Color.accent.opacity(OpacityTier.strong))
        .frame(width: EdgeBar.width)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        if !message.images.isEmpty {
          ImageGallery(images: message.images)
        }
        if !message.content.isEmpty {
          Text(stripXMLTags(message.content))
            .font(.system(size: TypeScale.title))
            .foregroundStyle(Color.white.opacity(0.92))
            .lineSpacing(4)
            .textSelection(.enabled)
        }
      }
      .padding(.leading, Spacing.sm)
    }
    .padding(.leading, 72)
  }

  private var assistantInline: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if message.hasThinking {
        thinkingDisclosure
      }

      MarkdownView(content: displayContent)

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
    .padding(.leading, 72)
  }

  private var steerInline: some View {
    Text(message.content)
      .font(.system(size: TypeScale.subhead))
      .foregroundStyle(.secondary)
      .italic()
      .textSelection(.enabled)
      .padding(.leading, 72)
  }

  // MARK: - Edit Preview (mini diff for compactPreview mode)

  private var editPreviewLines: [(prefix: String, text: String, isAdd: Bool)] {
    var results: [(prefix: String, text: String, isAdd: Bool)] = []

    if let old = message.editOldString, let new = message.editNewString {
      let oldLines = old.components(separatedBy: "\n")
      let newLines = new.components(separatedBy: "\n")
      // Show removed then added, up to 3 total
      for line in oldLines where !newLines.contains(line) {
        if results.count >= 3 { break }
        results.append(("-", line, false))
      }
      for line in newLines where !oldLines.contains(line) {
        if results.count >= 3 { break }
        results.append(("+", line, true))
      }
    } else if message.hasUnifiedDiff, let diff = message.unifiedDiff {
      let lines = diff.components(separatedBy: "\n")
      for line in lines {
        if results.count >= 3 { break }
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
          results.append(("+", String(line.dropFirst()), true))
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
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
      ToolIndicator(message: message, transcriptPath: transcriptPath, initiallyExpanded: true)

    case .thinking:
      ScrollView {
        ThinkingMarkdownView(content: message.content)
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
          ThinkingMarkdownView(content: thinking)
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
    let line = text.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    if line.count > maxLength {
      return String(line.prefix(maxLength - 1)) + "\u{2026}"
    }
    return line
  }

  private func stripXMLTags(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  }
}
