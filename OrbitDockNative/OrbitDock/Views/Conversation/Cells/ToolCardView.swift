import SwiftUI

struct ToolCardView: View {
  let toolRow: ServerConversationToolRow
  let isExpanded: Bool
  let sessionId: String
  let endpointId: UUID?
  let clients: ServerClients?
  var fetchedContent: ServerRowContent?
  var isLoadingContent: Bool = false
  var onToggle: (() -> Void)?

  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

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

  private var shellExecution: ServerShellExecutionPayload? {
    toolRow.shellExecution
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

  private var isReadCard: Bool {
    toolType == "read"
  }

  private var isBashCard: Bool {
    toolType == "bash"
  }

  private var isSearchCard: Bool {
    toolType == "grep" || toolType == "glob" || toolType == "toolSearch"
  }

  private var isWebSearchCard: Bool {
    toolType == "webSearch" || toolType == "webFetch"
  }

  private var isTaskCard: Bool {
    toolType == "task"
  }

  private var isQuestionCard: Bool {
    toolType == "question"
  }

  private var isMcpCard: Bool {
    toolType == "mcp" || toolType == "dynamicTool"
  }

  private var isGuardianCard: Bool {
    toolType == "guardianAssessment"
  }

  private var isHandoffCard: Bool {
    toolType == "handoff"
  }

  private var isImageCard: Bool {
    toolType == "image"
  }

  private var isPlanCard: Bool {
    toolType == "plan"
  }

  private var isTodoCard: Bool {
    toolType == "todo"
  }

  private var isHookCard: Bool {
    toolType == "hook"
  }

  private var isCompactContextCard: Bool {
    toolType == "compactContext"
  }

  private var isConfigCard: Bool {
    toolType == "config"
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
      "dynamicTool",
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

  // MARK: - Tool PTY Support

  private var runtime: ServerRuntime? {
    guard let endpointId else { return nil }
    return runtimeRegistry.runtimesByEndpointId[endpointId]
  }

  private var toolPtyManager: ToolPtySessionManager? {
    runtime?.toolPtyManager
  }

  /// PTY session for bash tools — available for both running and completed commands
  /// if the session was established during execution.
  private var toolPtySession: TerminalSessionController? {
    guard toolType == "bash" else { return nil }
    guard let manager = toolPtyManager else { return nil }
    return manager.existingSession(for: toolRow.id)
  }

  /// Subscribe to PTY for all running bash tools, not just expanded ones.
  /// This ensures we capture full terminal history for Ghostty rendering
  /// when the user eventually expands the card.
  private var shouldSubscribeToolPty: Bool {
    toolType == "bash" && isRunning
  }

  var body: some View {
    if isFileChangeCard {
      fileChangeBody
    } else if isReadCard {
      readCardBody
    } else if isBashCard {
      bashCardBody
    } else if isSearchCard {
      searchCardBody
    } else if isWebSearchCard {
      webSearchCardBody
    } else if isQuestionCard {
      questionCardBody
    } else if isTaskCard {
      taskCardBody
    } else if isMcpCard {
      mcpCardBody
    } else if isGuardianCard {
      guardianCardBody
    } else if isHandoffCard {
      handoffCardBody
    } else if isImageCard {
      imageCardBody
    } else if isPlanCard {
      planCardBody
    } else if isTodoCard {
      todoCardBody
    } else if isHookCard {
      hookCardBody
    } else if isCompactContextCard {
      compactContextCardBody
    } else if isConfigCard {
      configCardBody
    } else {
      standardToolBody
    }
  }

  /// Standard tool card layout (non-file-change tools)
  private var standardToolBody: some View {
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
    .padding(.vertical, isCompactLayout ? Spacing.sm_ : Spacing.xs)
    .overlay { toolPtySubscriptionBridge }
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  /// File change layout — code-review-first, diff is the content
  private var fileChangeBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      fileChangeHeader

      fileChangeDiffContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .overlay { toolPtySubscriptionBridge }
    .contentShape(Rectangle())
  }

  // MARK: - Read Card Layout

  /// Read card layout — file content is the content
  private var readCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      readCardHeader

      readCardContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .overlay { toolPtySubscriptionBridge }
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  /// Minimal header for read cards — filename + line count
  private var readCardHeader: some View {
    let lineCount = readContentLines.count

    return HStack(spacing: Spacing.sm) {
      // File icon — blue tint for read operations
      Image(systemName: "doc.text")
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(Color.toolRead.opacity(0.8))

      // Filename in mono
      Text(compactFileName ?? "File")
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      // Line count badge
      if lineCount > 0 {
        Text("\(lineCount) lines")
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.toolRead)
      }

      statusIndicator(tint: Color.toolRead)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
    .contentShape(Rectangle())
  }

  /// Lines from the read content
  private var readContentLines: [String] {
    let output = fetchedContent?.outputDisplay ?? display?.outputPreview ?? ""
    return output.components(separatedBy: "\n")
  }

  /// Read card content — shows file content preview or full
  @ViewBuilder
  private var readCardContent: some View {
    let lines = readContentLines
    let maxPreviewLines = isCompactLayout ? 10 : 12

    if isExpanded {
      // Full content in scrollable view
      expandedReadContent(lines: lines)
    } else if !lines.isEmpty && lines.first?.isEmpty == false {
      // Preview first N lines
      readContentPreview(lines: lines, maxLines: maxPreviewLines)
    } else if isLoadingContent {
      loadingState
    }
  }

  /// Preview of file content with line numbers
  private func readContentPreview(lines: [String], maxLines: Int) -> some View {
    let displayLines = Array(lines.prefix(maxLines))
    let hasMore = lines.count > maxLines
    let startLine = fetchedContent?.startLine ?? 1

    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
        readCodeLine(line, lineNumber: startLine + index)
      }

      if hasMore {
        expandPrompt(remaining: lines.count - maxLines)
      }
    }
  }

  /// Full scrollable read content
  private func expandedReadContent(lines: [String]) -> some View {
    let maxHeight: CGFloat = isCompactLayout ? 400 : 500
    let startLine = fetchedContent?.startLine ?? 1

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
          readCodeLine(line, lineNumber: startLine + index)
        }
      }
    }
    .frame(maxHeight: maxHeight)
  }

  /// Single line of read content with line number
  private func readCodeLine(_ content: String, lineNumber: Int) -> some View {
    HStack(alignment: .top, spacing: 0) {
      // Line number gutter
      Text("\(lineNumber)")
        .font(.system(size: TypeScale.mini, design: .monospaced))
        .foregroundStyle(Color.toolRead.opacity(0.4))
        .frame(width: 32, alignment: .trailing)
        .padding(.trailing, Spacing.xs)

      // Code content
      Text(content.isEmpty ? " " : content)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Bash Card Layout

  /// Bash card layout — different structure for collapsed vs expanded
  private var bashCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isExpanded {
        // Expanded: full terminal chrome
        bashExpandedHeader
        bashCommandStrip
        bashCardContent
      } else {
        // Collapsed: compact scannable card
        bashCollapsedHeader
        bashCardContent
      }
    }
    .background(isExpanded ? Color.backgroundCode.opacity(0.95) : Color.backgroundTertiary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .overlay { toolPtySubscriptionBridge }
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  /// Collapsed header — compact single row with command inline
  private var bashCollapsedHeader: some View {
    HStack(spacing: Spacing.sm_) {
      // Terminal icon
      Image(systemName: "terminal")
        .font(.system(size: IconScale.sm, weight: .semibold))
        .foregroundStyle(Color.toolBash)

      // Command with $ prefix
      HStack(spacing: Spacing.xs) {
        Text("$")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.toolBash)

        Text(bashCommandText)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: Spacing.sm)

      // Status + duration + chevron
      statusIndicatorWithSuccess(tint: Color.toolBash)
      expandChevron
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .contentShape(Rectangle())
  }

  /// Expanded header — full terminal chrome with traffic lights and cwd
  private var bashExpandedHeader: some View {
    HStack(spacing: Spacing.sm) {
      #if os(macOS)
        HStack(spacing: Spacing.xs) {
          Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35)).frame(width: 6, height: 6)
          Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.2)).frame(width: 6, height: 6)
          Circle().fill(Color(red: 0.3, green: 0.8, blue: 0.35)).frame(width: 6, height: 6)
        }
      #else
        Image(systemName: "terminal")
          .font(.system(size: IconScale.xs, weight: .semibold))
          .foregroundStyle(Color.toolBash)
      #endif

      Spacer(minLength: Spacing.sm)

      Text(bashTerminalTitle)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      statusIndicatorWithSuccess(tint: Color.toolBash)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
    .contentShape(Rectangle())
  }

  /// Extract command from bash input
  private var bashCommandText: String {
    [
      shellExecution?.command,
      toolRow.title,
      display?.inputDisplay,
    ]
    .compactMap(normalizedBashCommandCandidate)
    .first ?? "Shell command"
  }

  private func normalizedBashCommandCandidate(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let command = trimmed.hasPrefix("$ ")
      ? String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
      : trimmed
    let lower = command.lowercased()
    guard !["$", "bash", "shell", "terminal"].contains(lower) else { return nil }
    guard !lower.hasPrefix("bash completed") else { return nil }
    guard !lower.hasPrefix("command completed") else { return nil }
    return command
  }

  /// Bash card content — shows terminal output
  @ViewBuilder
  private var bashCardContent: some View {
    if isExpanded {
      // Full Ghostty terminal for expanded
      if let content = fetchedContent {
        bashExpandedView(content)
      } else if isLoadingContent {
        loadingState
      } else {
        bashExpandedFallback
      }
    } else {
      // Compact output preview
      bashOutputPreview
    }
  }

  private func bashExpandedView(_ content: ServerRowContent) -> some View {
    BashExpandedView(
      content: content,
      isFailed: isFailed,
      liveOutputPreview: shellExecution?.liveOutputPreview ?? display?.liveOutputPreview ?? display?.outputPreview,
      isRunning: isRunning,
      commandOverride: shellExecution?.command,
      cwd: shellExecution?.cwd,
      terminalTitle: shellExecution?.terminalSnapshot?.title,
      toolPtySession: toolPtySession
    )
  }

  private var bashCommandStrip: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
      Text("$")
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.toolBash)

      Text(bashCommandText)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundCode.opacity(0.98))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.white.opacity(0.06))
        .frame(height: 1)
    }
  }

  @ViewBuilder
  private var bashExpandedFallback: some View {
    let transcript = bashPreviewTranscript(output: bashPreviewOutput)

    bashTerminalSurface(
      transcript: transcript,
      maxHeight: isCompactLayout ? 360 : 500,
      captureScrollWithoutFocus: true,
      title: bashTerminalTitle
    )
  }

  /// Preview of bash output without mounting the full terminal renderer.
  @ViewBuilder
  private var bashOutputPreview: some View {
    let previewLines = bashCompactPreviewLines

    if !previewLines.isEmpty {
      bashCompactOutputPreview(lines: previewLines)
    } else if isRunning {
      HStack(spacing: Spacing.sm_) {
        Circle()
          .fill(Color.toolBash)
          .frame(width: 6, height: 6)
        Text("Running...")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
  }

  private var bashCompactPreviewLines: [String] {
    compactPreviewLines(from: bashPreviewOutput ?? "", limit: isCompactLayout ? 4 : 3)
  }

  private func bashCompactOutputPreview(lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        previewCodeLine(
          line,
          prefix: index == 0 ? ">" : nil,
          tint: Color.toolBash,
          font: .system(size: TypeScale.caption, design: .monospaced),
          lineLimit: 1,
          prefixWidth: 10
        )
      }
    }
    .previewStripChrome(tint: Color.toolBash, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
  }

  private var bashPreviewOutput: String? {
    shellExecution?.liveOutputPreview
      ?? display?.liveOutputPreview
      ?? display?.outputPreview
  }

  private func bashPreviewTranscript(output: String?) -> String? {
    if let snapshot = shellExecution?.terminalSnapshot?.transcript,
       !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return snapshot
    }

    return ShellTranscriptBuilder.makeSnapshot(
      command: bashCommandText,
      output: output,
      cwd: shellExecution?.cwd
    )
  }

  @ViewBuilder
  private func bashTerminalSurface(
    transcript: String?,
    maxHeight: CGFloat,
    captureScrollWithoutFocus: Bool,
    cursorBlinkEnabled: Bool = true,
    minRows: Int = 6,
    title: String
  ) -> some View {
    if let session = toolPtySession, session.hasOutput {
      TerminalContainerView(
        session: session,
        shouldAutoFocusOnFirstAttachment: false,
        captureScrollWithoutFocus: captureScrollWithoutFocus,
        cursorBlinkEnabled: cursorBlinkEnabled,
        allowsInput: false,
        titleOverride: title,
        showsTitleBar: false
      )
      .frame(maxHeight: maxHeight)
    } else if let transcript {
      TerminalTranscriptSurface(
        output: transcript,
        title: title,
        maxHeight: maxHeight,
        minRows: minRows,
        showsTitleBar: false,
        captureScrollWithoutFocus: captureScrollWithoutFocus
      )
    }
  }

  private var bashTerminalTitle: String {
    if let title = shellExecution?.terminalSnapshot?.title {
      return title
    }
    if let cwd = shellExecution?.cwd {
      return ToolCardStyle.shortenPath(cwd)
    }
    return "Terminal"
  }

  // MARK: - Search Card Layout

  /// Search card layout — pattern + results is the content
  private var searchCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      searchCardHeader

      searchCardContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .overlay { toolPtySubscriptionBridge }
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  /// Header for search cards — shows pattern + result count
  private var searchCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Search icon — purple tint
      Image(systemName: "magnifyingglass")
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(Color.toolSearch.opacity(0.8))

      // Pattern in mono
      Text(searchPattern)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      // Result count badge
      if let count = searchResultCount, count > 0 {
        Text("\(count) results")
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.toolSearch)
      }

      statusIndicator(tint: Color.toolSearch)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
    .contentShape(Rectangle())
  }

  private var searchPattern: String {
    if let sub = rawSubtitle, !sub.isEmpty {
      return sub
    }
    return rawSummary
  }

  private var searchResultCount: Int? {
    guard let meta = rightMeta else { return nil }
    let digits = meta.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    return Int(digits)
  }

  /// Search results lines
  private var searchResultLines: [String] {
    let output = fetchedContent?.outputDisplay ?? display?.outputPreview ?? ""
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  /// Search card content — shows result list
  @ViewBuilder
  private var searchCardContent: some View {
    let lines = searchResultLines

    if isExpanded {
      // Full results in scrollable view
      expandedSearchResults(lines: lines)
    } else if !lines.isEmpty {
      // Preview first N results
      searchResultsPreview(lines: lines)
    } else if isRunning {
      HStack {
        Circle()
          .fill(Color.toolSearch)
          .frame(width: 6, height: 6)
        Text("Searching...")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm)
    } else if isLoadingContent {
      loadingState
    }
  }

  /// Preview of search results
  private func searchResultsPreview(lines: [String]) -> some View {
    let maxPreviewLines = isCompactLayout ? 5 : 7
    let displayLines = Array(lines.prefix(maxPreviewLines))
    let hasMore = lines.count > maxPreviewLines

    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
        searchResultLine(line)
      }

      if hasMore {
        expandPrompt(remaining: lines.count - maxPreviewLines)
      }
    }
  }

  /// Full scrollable search results
  private func expandedSearchResults(lines: [String]) -> some View {
    let maxHeight: CGFloat = isCompactLayout ? 400 : 500

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          searchResultLine(line)
        }
      }
    }
    .frame(maxHeight: maxHeight)
  }

  /// Single search result line — handles file paths and matches
  private func searchResultLine(_ content: String) -> some View {
    // Check if this line is a file path (for glob) or a match line (for grep)
    let isFilePath = content.hasPrefix("/") || content.hasPrefix("./")
    let trimmed = content.trimmingCharacters(in: .whitespaces)

    return HStack(alignment: .top, spacing: 0) {
      if isFilePath {
        // File icon for paths
        Image(systemName: "doc")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(Color.toolSearch.opacity(0.5))
          .frame(width: 14, alignment: .center)
      } else {
        // Dot for match lines
        Circle()
          .fill(Color.toolSearch.opacity(0.4))
          .frame(width: 4, height: 4)
          .frame(width: 14, alignment: .center)
          .padding(.top, 6)
      }

      Text(trimmed)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(isFilePath ? Color.textSecondary : Color.textTertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isFilePath ? Color.toolSearch.opacity(0.04) : Color.clear)
  }

  // MARK: - Web Search Card Layout

  /// Web search card — query + result titles
  private var webSearchCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      webSearchCardHeader
      webSearchCardContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  private var webSearchCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Globe icon — teal/cyan for web
      Image(systemName: "globe")
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(Color.toolWeb.opacity(0.8))

      // Query in regular font (not mono — differentiates from code search)
      Text(webSearchQuery)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      statusIndicator(tint: Color.toolWeb)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
  }

  private var webSearchQuery: String {
    rawSubtitle ?? rawSummary
  }

  private var webSearchResults: [String] {
    let output = display?.outputPreview ?? ""
    return output.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  @ViewBuilder
  private var webSearchCardContent: some View {
    let results = webSearchResults

    if isExpanded, let content = fetchedContent {
      expandedWebSearchResults(content: content)
    } else if !results.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(results.prefix(4).enumerated()), id: \.offset) { index, title in
          HStack(spacing: Spacing.sm) {
            Text("\(index + 1)")
              .font(.system(size: TypeScale.mini, design: .monospaced))
              .foregroundStyle(Color.toolWeb.opacity(0.5))
              .frame(width: 16, alignment: .trailing)

            Text(title)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, 4)
        }

        if results.count > 4 {
          expandPrompt(remaining: results.count - 4)
        }
      }
    } else if isRunning {
      HStack {
        Circle().fill(Color.toolWeb).frame(width: 6, height: 6)
        Text("Searching...")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm)
    }
  }

  private func expandedWebSearchResults(content: ServerRowContent) -> some View {
    let output = content.outputDisplay ?? ""
    let results = output.components(separatedBy: "\n").filter { !$0.isEmpty }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.offset) { index, title in
          HStack(spacing: Spacing.sm) {
            Text("\(index + 1)")
              .font(.system(size: TypeScale.mini, design: .monospaced))
              .foregroundStyle(Color.toolWeb.opacity(0.5))
              .frame(width: 16, alignment: .trailing)

            Text(title)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(2)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, 4)
        }
      }
    }
    .frame(maxHeight: isCompactLayout ? 300 : 400)
  }

  // MARK: - Question Card Layout

  /// Question card — prominent, demands user attention
  private var questionCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      questionCardHeader
      questionCardContent
    }
    .background(Color.accent.opacity(OpacityTier.subtle))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.accent.opacity(OpacityTier.medium), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  private var questionCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Question icon — larger for prominence
      Image(systemName: "questionmark.circle.fill")
        .font(.system(size: IconScale.lg, weight: .medium))
        .foregroundStyle(Color.accent)

      Text("Question")
        .font(.system(size: TypeScale.subhead, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Spacer(minLength: Spacing.sm)

      statusIndicator(tint: Color.accent)
      expandChevron
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var questionText: String {
    display?.outputPreview ?? rawSummary
  }

  @ViewBuilder
  private var questionCardContent: some View {
    Text(questionText)
      .font(.system(size: TypeScale.body))
      .foregroundStyle(Color.textPrimary)
      .padding(.horizontal, Spacing.md)
      .padding(.bottom, Spacing.md)
  }

  // MARK: - Task Card Layout

  /// Task/Agent card — mission status forward
  private var taskCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      taskCardHeader
      taskCardContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  private var taskCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Bolt icon — mission/task
      Image(systemName: "bolt.fill")
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(Color.toolTask.opacity(0.8))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      statusIndicatorWithSuccess(tint: Color.toolTask)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
  }

  private var taskPreviewText: String? {
    display?.outputPreview
  }

  @ViewBuilder
  private var taskCardContent: some View {
    if isExpanded, let content = fetchedContent {
      expandedTaskContent(content: content)
    } else if let preview = taskPreviewText, !preview.isEmpty {
      let lines = preview.components(separatedBy: "\n").filter { !$0.isEmpty }

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
        }

        if lines.count > 3 {
          expandPrompt(remaining: lines.count - 3)
        }
      }
    } else if isRunning {
      HStack {
        ProgressView().controlSize(.small)
        Text("Task in progress...")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm)
    }
  }

  private func expandedTaskContent(content: ServerRowContent) -> some View {
    let output = content.outputDisplay ?? ""
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
        }
      }
    }
    .frame(maxHeight: isCompactLayout ? 300 : 400)
  }

  // MARK: - MCP Card Layout

  /// MCP/Dynamic tool card — structured output
  private var mcpCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      mcpCardHeader
      mcpCardContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  private var mcpCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Puzzle piece — external integration
      Image(systemName: "puzzlepiece.extension")
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(Color.toolMcp.opacity(0.8))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      statusIndicatorWithSuccess(tint: Color.toolMcp)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
  }

  private var mcpPreviewText: String? {
    display?.outputPreview
  }

  @ViewBuilder
  private var mcpCardContent: some View {
    if isExpanded, let content = fetchedContent {
      expandedMcpContent(content: content)
    } else if let preview = mcpPreviewText, !preview.isEmpty {
      let lines = preview.components(separatedBy: "\n").filter { !$0.isEmpty }

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
          mcpOutputLine(line)
        }

        if lines.count > 3 {
          expandPrompt(remaining: lines.count - 3)
        }
      }
    } else if isRunning {
      HStack {
        ProgressView().controlSize(.small)
        Text("Running tool...")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm)
    }
  }

  private func mcpOutputLine(_ line: String) -> some View {
    // Parse "key: value" format
    let parts = line.split(separator: ":", maxSplits: 1)
    let hasKey = parts.count == 2

    return HStack(alignment: .top, spacing: Spacing.xs) {
      if hasKey {
        Text(String(parts[0]))
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.toolMcp.opacity(0.7))

        Text(String(parts[1]).trimmingCharacters(in: .whitespaces))
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      } else {
        Text(line)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func expandedMcpContent(content: ServerRowContent) -> some View {
    let output = content.outputDisplay ?? ""
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          mcpOutputLine(line)
        }
      }
    }
    .frame(maxHeight: isCompactLayout ? 300 : 400)
  }

  // MARK: - Auto-review Assessment Card Layout

  /// Auto-review/security review card — prominent, security-focused
  private var guardianCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      guardianCardHeader
      guardianCardContent
    }
    .background(Color.feedbackCaution.opacity(OpacityTier.subtle))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.feedbackCaution.opacity(OpacityTier.medium), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  private var guardianCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Shield icon — security-focused
      Image(systemName: "shield.lefthalf.filled")
        .font(.system(size: IconScale.lg, weight: .medium))
        .foregroundStyle(Color.feedbackCaution)

      Text("Security Review")
        .font(.system(size: TypeScale.subhead, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Spacer(minLength: Spacing.sm)

      statusIndicator(tint: Color.feedbackCaution)
      expandChevron
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var guardianPreviewText: String? {
    display?.outputPreview
  }

  @ViewBuilder
  private var guardianCardContent: some View {
    if let preview = guardianPreviewText, !preview.isEmpty {
      Text(preview)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
    }
  }

  // MARK: - Handoff Card Layout

  /// Handoff card — agent transfer
  private var handoffCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      handoffCardHeader
      handoffCardContent
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  private var handoffCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Branch arrow — transfer/handoff metaphor
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(Color.statusReply.opacity(0.8))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      statusIndicatorWithSuccess(tint: Color.statusReply)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
  }

  @ViewBuilder
  private var handoffCardContent: some View {
    if let preview = display?.outputPreview, !preview.isEmpty {
      Text(preview)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
    }
  }

  // MARK: - Image Card Layout

  /// Image card — view/generate images
  private var imageCardBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      imageCardHeader
      if isExpanded {
        expandedSection
      } else {
        imageCardContent
      }
    }
    .background(Color.backgroundCode.opacity(0.95))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
  }

  private var imageCardHeader: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: glyphSymbol)
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(glyphColor.opacity(0.8))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      statusIndicator(tint: glyphColor)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  @ViewBuilder
  private var imageCardContent: some View {
    if let content = fetchedContent, !content.images.isEmpty {
      imageArtifactPreview(content)
    } else if isLoadingContent {
      loadingIndicator
    } else if let subtitle = rawSubtitle, !subtitle.isEmpty {
      imagePathLine(subtitle, icon: "photo")
    }
  }

  private func imageArtifactPreview(_ content: ServerRowContent) -> some View {
    let imageCount = content.images.count
    let messageImages = content.images.enumerated().compactMap { index, image in
      image.toMessageImage(index: index, endpointId: endpointId, sessionId: sessionId)
    }

    return VStack(alignment: .leading, spacing: Spacing.sm) {
      if let imageLoader = clients?.imageLoader, !messageImages.isEmpty {
        MessageImageView(
          images: messageImages,
          imageLoader: imageLoader,
          maxWidth: isCompactLayout ? 300 : 420
        )
      }

      HStack(spacing: Spacing.sm) {
        Image(systemName: imageCount == 1 ? "photo" : "photo.stack")
          .font(.system(size: IconScale.sm, weight: .semibold))
          .foregroundStyle(glyphColor.opacity(0.85))

        Text(imageArtifactLabel(for: content))
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: Spacing.sm)

        if imageCount > 1 {
          Text("\(imageCount) images")
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(glyphColor.opacity(0.85))
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
  }

  private func imageArtifactLabel(for content: ServerRowContent) -> String {
    if let displayName = content.images.first?.displayName, !displayName.isEmpty {
      return displayName
    }
    if let value = content.images.first?.value, !value.isEmpty {
      return URL(fileURLWithPath: value).lastPathComponent
    }
    return rawSubtitle ?? "Generated image"
  }

  private func imagePathLine(_ text: String, icon: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.sm, weight: .semibold))
        .foregroundStyle(glyphColor.opacity(0.75))

      Text(text)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Plan Card Layout

  /// Plan card — minimal, mode entry/exit
  private var planCardBody: some View {
    HStack(spacing: Spacing.sm) {
      // Map icon — very muted
      Image(systemName: "map")
        .font(.system(size: IconScale.sm, weight: .medium))
        .foregroundStyle(Color.toolPlan.opacity(0.5))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      if isRunning {
        ProgressView()
          .controlSize(.mini)
          .tint(Color.toolPlan)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundTertiary.opacity(OpacityTier.light))
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - Todo Card Layout

  /// Todo card — minimal, task tracking
  private var todoCardBody: some View {
    HStack(spacing: Spacing.sm) {
      // Checklist icon — very muted
      Image(systemName: "checklist")
        .font(.system(size: IconScale.sm, weight: .medium))
        .foregroundStyle(Color.toolTodo.opacity(0.5))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      if isRunning {
        ProgressView()
          .controlSize(.mini)
          .tint(Color.toolTodo)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundTertiary.opacity(OpacityTier.light))
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - Hook Card Layout

  /// Hook notification card — system event from hooks
  private var hookCardBody: some View {
    HStack(spacing: Spacing.sm) {
      // Bolt+clock icon — subtle warning
      Image(systemName: "bolt.badge.clock")
        .font(.system(size: IconScale.sm, weight: .medium))
        .foregroundStyle(Color.feedbackCaution.opacity(0.5))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      if isRunning {
        ProgressView()
          .controlSize(.mini)
          .tint(Color.feedbackCaution)
      } else if isFailed {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: IconScale.xs))
          .foregroundStyle(Color.feedbackNegative)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.feedbackCaution.opacity(OpacityTier.tint))
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .strokeBorder(Color.feedbackCaution.opacity(OpacityTier.subtle), lineWidth: 1)
    }
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - Compact Context Card Layout

  /// Compact context card — context window management
  private var compactContextCardBody: some View {
    HStack(spacing: Spacing.sm) {
      // Circular arrows — system maintenance
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: IconScale.sm, weight: .medium))
        .foregroundStyle(Color.accent.opacity(0.4))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      if isRunning {
        ProgressView()
          .controlSize(.mini)
          .tint(Color.accent)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundTertiary.opacity(OpacityTier.light))
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - Config Card Layout

  /// Config card — configuration changes, lowest priority
  private var configCardBody: some View {
    HStack(spacing: Spacing.sm) {
      // Gear icon — very muted
      Image(systemName: "gearshape")
        .font(.system(size: IconScale.sm, weight: .medium))
        .foregroundStyle(Color.textQuaternary.opacity(0.5))

      Text(rawSummary)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      if isRunning {
        ProgressView()
          .controlSize(.mini)
          .tint(Color.textTertiary)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundTertiary.opacity(OpacityTier.light))
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - File Change Card Layout

  /// Minimal header for file changes — filename + stats, tappable to expand
  private var fileChangeHeader: some View {
    HStack(spacing: Spacing.sm) {
      // File icon
      Image(systemName: glyphSymbol)
        .font(.system(size: IconScale.md, weight: .medium))
        .foregroundStyle(chromeTint.opacity(0.8))

      // Filename in mono
      Text(compactFileName ?? "File")
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: Spacing.sm)

      // Diff stats
      if let preview = display?.diffPreview, preview.additions > 0 || preview.deletions > 0 {
        HStack(spacing: Spacing.xs) {
          if preview.additions > 0 {
            Text("+\(preview.additions)")
              .foregroundStyle(Color.diffAddedAccent)
          }
          if preview.deletions > 0 {
            Text("-\(preview.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
        }
        .font(.system(size: TypeScale.meta, weight: .bold, design: .monospaced))
      }

      statusIndicator(tint: chromeTint)
      expandChevron
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium))
    .contentShape(Rectangle())
    .onTapGesture { onToggle?() }
  }

  /// Diff content — shows inline preview or full diff based on size
  @ViewBuilder
  private var fileChangeDiffContent: some View {
    let diffLines = fetchedContent?.diffDisplay ?? display?.diffDisplay ?? []
    let previewLines = display?.diffPreview?.previewLines ?? []
    let totalChanges = (display?.diffPreview?.additions ?? 0) + (display?.diffPreview?.deletions ?? 0)

    if isExpanded {
      // Full expanded diff — same style, just scrollable
      if !diffLines.isEmpty {
        expandedDiffView(lines: diffLines)
      } else if let content = fetchedContent, let lines = content.diffDisplay, !lines.isEmpty {
        expandedDiffView(lines: lines)
      } else if isLoadingContent {
        loadingState
      } else {
        if let content = fetchedContent {
          expandedBody(content)
        }
      }
    } else if !diffLines.isEmpty {
      // Show inline diff from fetched content
      inlineDiffView(lines: diffLines, showFull: false)
    } else if !previewLines.isEmpty {
      // Show preview lines with expand option
      inlinePreviewDiff(lines: previewLines, totalChanges: Int(totalChanges))
    } else if let snippet = display?.diffPreview?.snippetText, !snippet.isEmpty {
      // Minimal snippet preview
      singleLineDiffPreview(snippet: snippet, isAddition: display?.diffPreview?.isAddition ?? true)
    } else if isLoadingContent {
      loadingState
    }
  }

  private var loadingState: some View {
    HStack {
      ProgressView().controlSize(.small)
      Text("Loading diff…")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
    }
    .padding(Spacing.md)
  }

  /// Full expanded diff — scrollable, same visual style as preview
  private func expandedDiffView(lines: [ServerDiffLine]) -> some View {
    let maxHeight: CGFloat = isCompactLayout ? 400 : 500

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          diffLineRow(line)
        }
      }
    }
    .frame(maxHeight: maxHeight)
  }

  /// Inline diff view — shows actual diff lines, smartly picking the first meaningful hunk
  private func inlineDiffView(lines: [ServerDiffLine], showFull: Bool) -> some View {
    // For preview, find the first hunk with changes and show context around it
    let displayLines: [ServerDiffLine]
    let hasMore: Bool

    if showFull {
      displayLines = lines
      hasMore = false
    } else {
      // Find first change and show context around it
      let previewLines = smartPreviewLines(from: lines, maxLines: isCompactLayout ? 8 : 10)
      displayLines = previewLines
      hasMore = lines.count > previewLines.count
    }

    return VStack(alignment: .leading, spacing: 0) {
      // Show context line header if available
      if !showFull, let contextLine = display?.diffPreview?.contextLine, !contextLine.isEmpty {
        HStack(spacing: Spacing.xs) {
          Text("@")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.accent.opacity(0.6))
          Text(contextLine)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.accent.opacity(0.05))
      }

      ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
        diffLineRow(line)
      }

      if hasMore {
        expandPrompt(remaining: lines.count - displayLines.count)
      }
    }
  }

  /// Smart preview: find first hunk with actual changes and include surrounding context
  private func smartPreviewLines(from lines: [ServerDiffLine], maxLines: Int) -> [ServerDiffLine] {
    // Find the index of the first actual change (not context)
    guard let firstChangeIndex = lines.firstIndex(where: { $0.type != .context }) else {
      // No changes? Just show first few lines
      return Array(lines.prefix(maxLines))
    }

    // Start a few lines before the first change for context
    let contextBefore = 2
    let startIndex = max(0, firstChangeIndex - contextBefore)

    // Take maxLines from that point
    let endIndex = min(lines.count, startIndex + maxLines)

    return Array(lines[startIndex..<endIndex])
  }

  /// Single diff line row
  private func diffLineRow(_ line: ServerDiffLine) -> some View {
    let bgColor: Color = switch line.type {
      case .addition: Color.diffAddedBg
      case .deletion: Color.diffRemovedBg
      case .context: Color.clear
    }

    let textColor: Color = switch line.type {
      case .addition: Color.diffAddedAccent
      case .deletion: Color.diffRemovedAccent
      case .context: Color.textTertiary
    }

    let prefix: String = switch line.type {
      case .addition: "+"
      case .deletion: "-"
      case .context: " "
    }

    return HStack(alignment: .top, spacing: 0) {
      // Line number gutter (optional on mobile)
      if !isCompactLayout, let lineNum = line.newLine ?? line.oldLine {
        Text("\(lineNum)")
          .font(.system(size: TypeScale.mini, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 32, alignment: .trailing)
          .padding(.trailing, Spacing.xs)
      }

      // Prefix (+/-/ )
      Text(prefix)
        .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
        .foregroundStyle(textColor)
        .frame(width: 14, alignment: .leading)

      // Code content
      Text(line.content)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(line.type == .context ? Color.textTertiary : Color.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(bgColor)
  }

  /// Preview diff from previewLines when full diff content is not available.
  private func inlinePreviewDiff(lines: [String], totalChanges: Int) -> some View {
    let isAddition = display?.diffPreview?.isAddition ?? true
    let maxPreviewLines = isCompactLayout ? 6 : 8

    return VStack(alignment: .leading, spacing: 0) {
      // Show context line header if available
      if let contextLine = display?.diffPreview?.contextLine, !contextLine.isEmpty {
        HStack(spacing: Spacing.xs) {
          Text("@")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.accent.opacity(0.6))
          Text(contextLine)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.accent.opacity(0.05))
      }

      ForEach(Array(lines.prefix(maxPreviewLines).enumerated()), id: \.offset) { _, line in
        HStack(alignment: .top, spacing: 0) {
          Text(isAddition ? "+" : "-")
            .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
            .foregroundStyle(isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent)
            .frame(width: 14, alignment: .leading)

          Text(line)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isAddition ? Color.diffAddedBg : Color.diffRemovedBg)
      }

      if lines.count > maxPreviewLines || totalChanges > maxPreviewLines {
        expandPrompt(remaining: max(totalChanges - maxPreviewLines, lines.count - maxPreviewLines))
      }
    }
  }

  /// Single line snippet preview
  private func singleLineDiffPreview(snippet: String, isAddition: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      Text(isAddition ? "+" : "-")
        .font(.system(size: TypeScale.code, weight: .bold, design: .monospaced))
        .foregroundStyle(isAddition ? Color.diffAddedAccent : Color.diffRemovedAccent)
        .frame(width: 14, alignment: .leading)

      Text(snippet)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(2)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isAddition ? Color.diffAddedBg : Color.diffRemovedBg)
    .onTapGesture { onToggle?() }
  }

  /// "See more" prompt
  private func expandPrompt(remaining: Int) -> some View {
    HStack {
      Spacer()
      Text("▼ \(remaining) more lines")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.accent)
      Spacer()
    }
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundTertiary.opacity(0.3))
    .onTapGesture { onToggle?() }
  }

  @ViewBuilder
  private var toolPtySubscriptionBridge: some View {
    if shouldSubscribeToolPty,
       let manager = toolPtyManager,
       let connection = runtime?.connection
    {
      ToolPtySubscriptionBridge(
        toolId: toolRow.id,
        sessionId: sessionId,
        manager: manager,
        connection: connection
      )
    }
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

  // MARK: - Unified Status Indicator

  /// Unified status indicator for all card types
  /// Shows: running spinner, failed X, or nothing (completion implied by presence)
  @ViewBuilder
  private func statusIndicator(tint: Color) -> some View {
    if isRunning {
      ProgressView()
        .controlSize(.mini)
        .tint(tint)
    } else if isFailed {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: IconScale.sm))
        .foregroundStyle(Color.feedbackNegative)
    }
    // No indicator for completed — implied by presence
  }

  /// Status indicator with success checkmark (for tools where completion matters)
  @ViewBuilder
  private func statusIndicatorWithSuccess(tint: Color) -> some View {
    if isRunning {
      ProgressView()
        .controlSize(.mini)
        .tint(tint)
    } else if isFailed {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: IconScale.sm))
        .foregroundStyle(Color.feedbackNegative)
    } else if isSuccessful {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: IconScale.sm))
        .foregroundStyle(Color.feedbackPositive)
    }
  }

  /// Expand/collapse chevron
  private var expandChevron: some View {
    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(Color.textQuaternary)
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
      Text(rawSummary)
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
      // Prominent diff stats for file changes — key visual identifier
      HStack(spacing: Spacing.xs) {
        if preview.additions > 0 {
          Text("+\(preview.additions)")
            .foregroundStyle(Color.diffAddedAccent)
        }
        if preview.deletions > 0 {
          Text("-\(preview.deletions)")
            .foregroundStyle(Color.diffRemovedAccent)
        }
      }
      .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        Capsule()
          .fill(Color.backgroundCode.opacity(0.95))
          .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
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

    if toolType == "dynamicTool", !dynamicToolPreviewLines.isEmpty {
      let preview = dynamicToolPreviewLines
      dynamicToolPreviewStrip(preview)
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
    if isRunning, let live = shellExecution?.liveOutputPreview ?? display?.liveOutputPreview, !live.isEmpty {
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

  private var dynamicToolPreviewLines: [String] {
    if let preview = display?.outputPreview, !preview.isEmpty {
      return compactPreviewLines(from: preview, limit: isCompactLayout ? 3 : 2)
    }
    if let output = display?.outputDisplay, !output.isEmpty {
      return compactPreviewLines(from: output, limit: isCompactLayout ? 3 : 2)
    }
    return compactPreviewLines(from: rawSummary, limit: 2)
  }

  private func dynamicToolPreviewStrip(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      previewStripHeader(
        title: "Dynamic Tool",
        tint: Color.toolTask,
        titleStyle: .compact,
        symbol: "wrench.and.screwdriver"
      ) {
        if let scope = rawSubtitle, !scope.isEmpty {
          Text(scope)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
        }
      }

      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        previewCodeLine(
          line,
          tint: Color.toolTask,
          font: .system(size: TypeScale.caption, design: .monospaced)
        )
      }
    }
    .previewStripChrome(tint: Color.toolTask, horizontalPad: previewHorizontalPad, bottomPad: Spacing.sm_)
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
          bashExpandedView(content)
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
        case "dynamicTool":
          dynamicToolExpandedView(content)
        case "webSearch":
          WebSearchExpandedView(content: content)
        case "webFetch":
          WebFetchExpandedView(content: content)
        case "web":
          webExpandedDispatch(content)
        case "plan":
          PlanExpandedView(content: content, toolRow: toolRow, display: display)
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
          ImageExpandedView(
            content: content,
            toolKind: toolRow.kind,
            imageLoader: clients?.imageLoader,
            sessionId: sessionId,
            endpointId: endpointId
          )
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

  @ViewBuilder
  private func dynamicToolExpandedView(_ content: ServerRowContent) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "wrench.and.screwdriver")
          .font(.system(size: IconScale.sm, weight: .semibold))
          .foregroundStyle(Color.toolTask)

        Text("Dynamic Tool")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.toolTask)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(Color.toolTask.opacity(OpacityTier.subtle), in: Capsule())

        if let name = nonEmpty(toolRow.title) {
          Text(name)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if let meta = nonEmpty(display?.rightMeta) {
          Text(meta)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if let subtitle = nonEmpty(rawSubtitle) {
        HStack(spacing: Spacing.xs) {
          Text("Scope")
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .textCase(.uppercase)
            .tracking(0.8)
          Text(subtitle)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
        }
      }

      if let input = nonEmpty(content.inputDisplay ?? display?.inputDisplay) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Input")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          SmartJSONView(jsonString: input)
        }
      }

      if let output = nonEmpty(content.outputDisplay ?? display?.outputDisplay ?? display?.outputPreview) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          SmartJSONView(jsonString: output)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.backgroundCode)
                .overlay(
                  RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
                )
            )
        }
      }
    }
  }

  // ── Compact Display Body ─────────────────────────────────────────────────

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

private struct ToolPtySubscriptionBridge: View {
  let toolId: String
  let sessionId: String
  let manager: ToolPtySessionManager
  let connection: ServerConnection

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear {
        manager.attach(toolId: toolId, sessionId: sessionId, connection: connection)
      }
      .onDisappear {
        manager.detach(toolId: toolId, connection: connection)
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
