//
//  ConversationView.swift
//  OrbitDock
//

import AppKit
import SwiftUI

struct ConversationView: View {
  let transcriptPath: String?
  let sessionId: String?
  var isSessionActive: Bool = false
  var workStatus: Session.WorkStatus = .unknown
  var currentTool: String?
  var pendingToolName: String?
  var pendingToolInput: String?
  var provider: Provider = .claude
  var model: String?

  @Environment(ServerAppState.self) private var serverState

  @State private var messages: [TranscriptMessage] = []
  @State private var currentPrompt: String?
  @State private var isLoading = true
  @State private var loadedSessionId: String?
  @State private var displayedCount: Int = 50

  // Auto-follow state - controlled by parent
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  private let pageSize = 50

  var displayedMessages: [TranscriptMessage] {
    let startIndex = max(0, messages.count - displayedCount)
    let sliced = Array(messages[startIndex...])
    return combineBashMessages(sliced)
  }

  /// Combines consecutive bash input/output messages into single messages
  /// e.g., [bash-input msg, bash-stdout msg] → [combined bash msg]
  private func combineBashMessages(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
    var result: [TranscriptMessage] = []
    var i = 0

    while i < messages.count {
      let current = messages[i]

      // Check if current is bash-input-only
      if current.isUser,
         let bash = ParsedBashContent.parse(from: current.content),
         bash.hasInput, !bash.hasOutput
      {
        // Look ahead for bash-output-only
        if i + 1 < messages.count {
          let next = messages[i + 1]
          if next.isUser,
             let nextBash = ParsedBashContent.parse(from: next.content),
             !nextBash.hasInput, nextBash.hasOutput
          {
            // Combine: create merged content
            let combinedContent = current.content + next.content
            let combined = TranscriptMessage(
              id: current.id,
              type: current.type,
              content: combinedContent,
              timestamp: current.timestamp,
              toolName: nil,
              toolInput: nil,
              toolOutput: nil,
              toolDuration: nil,
              inputTokens: nil,
              outputTokens: nil
            )
            result.append(combined)
            i += 2 // Skip both messages
            continue
          }
        }
      }

      result.append(current)
      i += 1
    }

    return result
  }

  var hasMoreMessages: Bool {
    displayedCount < messages.count
  }

  var body: some View {
    ZStack {
      // Background
      Color.backgroundPrimary
        .ignoresSafeArea()

      if isLoading {
        loadingView
      } else if messages.isEmpty {
        emptyState
      } else {
        VStack(spacing: 0) {
          // Fork origin banner (persistent, above scroll)
          if let sid = sessionId, let sourceId = serverState.session(sid).forkedFrom {
            ForkOriginBanner(
              sourceSessionId: sourceId,
              sourceName: serverState.sessions.first(where: { $0.id == sourceId })?.displayName
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
          }
          conversationThread
        }
      }
    }
    .onAppear {
      loadMessagesIfNeeded()
    }
    .onChange(of: sessionId) { _, _ in
      loadMessagesIfNeeded()
    }
    // React to server message changes (appends, updates, undo, rollback) — only THIS session
    .onChange(of: serverState.session(sessionId ?? "").messagesRevision) { _, _ in
      refreshFromServerStateIfNeeded()
    }
  }

  // MARK: - Main Thread View

  private var conversationThread: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottom) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            // Load more indicator
            if hasMoreMessages {
              loadMoreIndicator
            }

            // Message count (subtle)
            if messages.count > pageSize {
              messageCountIndicator
            }

            // Messages as a thread
            let msgs = displayedMessages
            ForEach(Array(msgs.enumerated()), id: \.element.id) { index, message in
              if message.isTool {
                ToolIndicator(message: message, transcriptPath: transcriptPath)
                  .id(message.id)
              } else if message.isThinking {
                ThinkingIndicator(message: message)
                  .id(message.id)
              } else {
                let showHeader = shouldShowHeader(at: index, in: msgs)
                // turnsAfter: how many complete turns exist after this user message
                // For the last user message, if agent has responded (messages exist after it), count as 1
                let turnsAfter: Int = {
                  guard message.isUser else { return 0 }
                  let userMsgsAfter = msgs[(index + 1)...].filter(\.isUser).count
                  if userMsgsAfter > 0 {
                    return userMsgsAfter
                  }
                  // Last user message: show rollback if agent has responded after it
                  let hasResponseAfter = msgs[(index + 1)...].contains { !$0.isUser }
                  return hasResponseAfter ? 1 : 0
                }()
                // nthUserMessage: 0-based index of this user message among all user messages
                let nthUserMessage: Int? = {
                  guard message.isUser else { return nil }
                  return msgs[...index].filter(\.isUser).count - 1
                }()
                ThreadMessage(
                  message: message,
                  provider: provider,
                  model: model,
                  showHeader: showHeader,
                  rollbackTurns: turnsAfter > 0 ? turnsAfter : nil,
                  onRollback: turnsAfter > 0 ? {
                    if let sid = sessionId {
                      serverState.rollbackTurns(sessionId: sid, numTurns: UInt32(turnsAfter))
                    }
                  } : nil,
                  nthUserMessage: nthUserMessage,
                  onFork: nthUserMessage != nil ? {
                    if let sid = sessionId, let nth = nthUserMessage {
                      serverState.forkSession(sessionId: sid, nthUserMessage: UInt32(nth))
                    }
                  } : nil
                )
                .id(message.id)
              }
            }

            // Activity indicator
            if isSessionActive, workStatus != .unknown {
              ActivityBanner(
                workStatus: workStatus,
                currentTool: currentTool,
                currentPrompt: currentPrompt,
                pendingToolName: pendingToolName,
                pendingToolInput: pendingToolInput,
                provider: provider
              )
              .id("activity")
            }

            // Bottom spacer
            Color.clear
              .frame(height: 32)
              .id("bottomAnchor")
          }
          .padding(.horizontal, 32)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .onAppear {
          scrollToEnd(proxy: proxy, animated: false)
        }
        .onChange(of: messages.count) { oldCount, newCount in
          if newCount > oldCount {
            if isPinned {
              scrollToEnd(proxy: proxy, animated: true)
            } else {
              unreadCount += (newCount - oldCount)
            }
          }
        }
        .onChange(of: workStatus) {
          if isPinned {
            scrollToEnd(proxy: proxy, animated: true)
          }
        }
        .onChange(of: scrollToBottomTrigger) {
          scrollToEnd(proxy: proxy, animated: true)
        }
      }
    }
  }

  private func scrollToEnd(proxy: ScrollViewProxy, animated: Bool) {
    let targetId = if isSessionActive, workStatus == .working {
      "activity"
    } else {
      "bottomAnchor"
    }

    if animated {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(targetId, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(targetId, anchor: .bottom)
    }
  }

  // MARK: - Loading & Empty States

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.regular)
      Text("Loading conversation...")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.tertiary)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 20) {
      Image(systemName: "text.bubble")
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(.quaternary)

      VStack(spacing: 6) {
        Text("No messages yet")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
        Text("Start the conversation in your terminal")
          .font(.system(size: 13))
          .foregroundStyle(.tertiary)
      }
    }
  }

  private var loadMoreIndicator: some View {
    Button {
      displayedCount = min(displayedCount + pageSize, messages.count)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.up")
          .font(.system(size: 10, weight: .bold))
        Text("Load \(min(pageSize, messages.count - displayedCount)) earlier")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
    }
    .buttonStyle(.plain)
    .padding(.bottom, 10)
  }

  private var messageCountIndicator: some View {
    Text("\(displayedMessages.count) of \(messages.count) messages")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.quaternary)
      .frame(maxWidth: .infinity)
      .padding(.bottom, 20)
  }

  // MARK: - Subscriptions & Data Loading

  private func loadMessagesIfNeeded() {
    guard sessionId != loadedSessionId else { return }
    loadedSessionId = sessionId
    messages = []
    currentPrompt = nil
    isLoading = true
    // Note: isPinned and unreadCount are now managed by parent

    guard let sid = sessionId else {
      isLoading = false
      return
    }

    let serverMessages = serverState.session(sid).messages
    messages = serverMessages
    displayedCount = serverMessages.count
    isLoading = false
  }

  private func refreshFromServerStateIfNeeded() {
    guard let sid = sessionId else { return }
    let serverMessages = serverState.session(sid).messages
    messages = serverMessages
    displayedCount = max(displayedCount, serverMessages.count)
    isLoading = false
  }

  /// Show the header only when the sender side changes.
  /// Tool and thinking messages are transparent — we look back to the
  /// previous user or assistant message to decide.
  private func shouldShowHeader(at index: Int, in msgs: [TranscriptMessage]) -> Bool {
    guard index < msgs.count else { return true }
    let currentSide = msgs[index].isUser

    // Walk backwards past tool/thinking to find previous chat message
    var i = index - 1
    while i >= 0 {
      let prev = msgs[i]
      if prev.isTool || prev.isThinking { i -= 1; continue }
      return prev.isUser != currentSide
    }

    // First chat message — always show
    return true
  }
}

// MARK: - Thread Message (Redesigned)

struct ThreadMessage: View {
  let message: TranscriptMessage
  var provider: Provider = .claude
  var model: String?
  var showHeader: Bool = true
  var rollbackTurns: Int? = nil
  var onRollback: (() -> Void)? = nil
  var nthUserMessage: Int? = nil
  var onFork: (() -> Void)? = nil
  @State private var isContentExpanded = false
  @State private var isThinkingExpanded = false

  private let maxLength = 4_000
  private var isLongContent: Bool {
    message.content.count > maxLength
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if message.isSteer {
        steerMessage
      } else if message.isUser {
        userMessage
      } else {
        assistantMessage
      }
    }
    .padding(.top, showHeader ? 20 : 2)
    .padding(.bottom, showHeader ? 0 : 2)
  }

  // MARK: - User Message (Right-aligned, distinctive)

  /// Check if content contains bash-input tags
  private var parsedBashContent: ParsedBashContent? {
    ParsedBashContent.parse(from: message.content)
  }

  /// Check if content contains slash command tags
  private var parsedSlashCommand: ParsedSlashCommand? {
    ParsedSlashCommand.parse(from: message.content)
  }

  /// Check if content is a system caveat
  private var parsedSystemCaveat: ParsedSystemCaveat? {
    ParsedSystemCaveat.parse(from: message.content)
  }

  /// Check if content is a task notification
  private var parsedTaskNotification: ParsedTaskNotification? {
    ParsedTaskNotification.parse(from: message.content)
  }

  private var userMessage: some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(alignment: .top, spacing: 0) {
        Spacer(minLength: 100)

        // Check for special content types
        if let bash = parsedBashContent {
          UserBashCard(bash: bash, timestamp: message.timestamp)
        } else if let command = parsedSlashCommand {
          UserSlashCommandCard(command: command, timestamp: message.timestamp)
        } else if let notification = parsedTaskNotification {
          TaskNotificationCard(notification: notification, timestamp: message.timestamp)
        } else if let caveat = parsedSystemCaveat {
          SystemCaveatView(caveat: caveat)
        } else {
          standardUserMessage
        }
      }

      // Rollback pill
      if let turns = rollbackTurns, let action = onRollback {
        HStack {
          Spacer()
          Button(action: action) {
            HStack(spacing: 4) {
              Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .medium))
              Text("Roll back to here · \(turns) turn\(turns == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.surfaceHover, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.surfaceBorder, lineWidth: 1))
          }
          .buttonStyle(.plain)
        }
      }

      // Fork from here pill
      if let _ = nthUserMessage, let forkAction = onFork {
        HStack {
          Spacer()
          Button(action: forkAction) {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
              Text("Fork from here")
                .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.accent.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accent.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accent.opacity(0.2), lineWidth: 1))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var standardUserMessage: some View {
    VStack(alignment: .trailing, spacing: 12) {
      // Meta line - subtle timestamp and label (hidden for grouped messages)
      if showHeader {
        HStack(spacing: 10) {
          Text(formatTime(message.timestamp))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)

          Text("You")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
      }

      // Images (supports multiple)
      if !message.images.isEmpty {
        ImageGallery(images: message.images)
      }

      // Content - larger text for readability
      if !message.content.isEmpty {
        VStack(alignment: .trailing, spacing: 8) {
          Text(displayContent)
            .font(.system(size: 15.5))
            .foregroundStyle(.primary.opacity(0.95))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accent.opacity(0.12))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accent.opacity(0.18), lineWidth: 1)
            )

          if isLongContent {
            expandCollapseButton
          }
        }
      }
    }
  }

  // MARK: - Steer Message (Right-aligned, status-aware)

  private var steerStatus: String? {
    message.toolOutput
  }

  private var steerIcon: String {
    switch steerStatus {
      case "delivered": return "checkmark.circle"
      case "fallback": return "arrow.uturn.forward"
      case let s where s?.hasPrefix("failed") == true: return "exclamationmark.circle"
      default: return "arrow.up.circle" // nil = sending
    }
  }

  private var steerLabel: String {
    switch steerStatus {
      case "delivered": return "Steered"
      case "fallback": return "Sent as new turn"
      case let s where s?.hasPrefix("failed") == true: return "Failed"
      default: return "Sending..."
    }
  }

  private var steerHeaderColor: Color {
    switch steerStatus {
      case "delivered": return Color.accent
      case "fallback": return .secondary
      case let s where s?.hasPrefix("failed") == true: return Color.statusError
      default: return .secondary
    }
  }

  private var steerMessage: some View {
    HStack(alignment: .top, spacing: 0) {
      Spacer(minLength: 100)

      VStack(alignment: .trailing, spacing: 6) {
        // Header
        HStack(spacing: 6) {
          Text(formatTime(message.timestamp))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)

          HStack(spacing: 4) {
            Image(systemName: steerIcon)
              .font(.system(size: 9, weight: .semibold))
            Text(steerLabel)
              .font(.system(size: 12, weight: .semibold))
          }
          .foregroundStyle(steerHeaderColor)
        }

        // Content bubble — style varies by delivery status
        Text(displayContent)
          .font(.system(size: 14.5))
          .foregroundStyle(.primary.opacity(steerStatus == nil ? 0.65 : 0.85))
          .italic(steerStatus == nil)
          .lineSpacing(3)
          .textSelection(.enabled)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(steerStatus?.hasPrefix("failed") == true
                ? Color.statusError.opacity(0.08)
                : Color.accent.opacity(steerStatus == nil ? 0.04 : 0.08))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(
                steerStatus?.hasPrefix("failed") == true
                  ? Color.statusError.opacity(0.2)
                  : Color.accent.opacity(steerStatus == nil ? 0.12 : 0.15),
                style: steerStatus == nil
                  ? StrokeStyle(lineWidth: 1, dash: [6, 3])
                  : StrokeStyle(lineWidth: 1)
              )
          )
          .animation(.easeInOut(duration: 0.3), value: steerStatus)
      }
    }
  }

  // MARK: - Assistant Message (Left-aligned, clean)

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Meta line - provider branding with timestamp (hidden for grouped messages)
      if showHeader {
        HStack(spacing: 10) {
          // Provider indicator
          HStack(spacing: 5) {
            Image(systemName: provider == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right")
              .font(.system(size: 11, weight: .semibold))
            Text(provider.displayName)
              .font(.system(size: 12, weight: .semibold))
          }
          .foregroundStyle(provider.accentColor)

          // Model name (when known)
          if let model, !model.isEmpty {
            Text("·")
              .font(.system(size: 11))
              .foregroundStyle(.quaternary)
            Text(displayNameForModel(model, provider: provider))
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(colorForModel(model, provider: provider))
          }

          Text(formatTime(message.timestamp))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)
        }
      }

      // Thinking disclosure (if attached)
      if message.hasThinking {
        thinkingDisclosure
      }

      // Content - clean markdown, generous left padding for readability
      MarkdownView(content: displayContent)

      if isLongContent {
        expandCollapseButton
      }

      Spacer()
        .frame(width: 100)
    }
  }

  // MARK: - Thinking Disclosure

  private var thinkingDisclosure: some View {
    let thinkingColor = Color(red: 0.6, green: 0.55, blue: 0.8)

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

  private var expandCollapseButton: some View {
    Button {
      withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
        isContentExpanded.toggle()
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: isContentExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 9, weight: .bold))
        Text(isContentExpanded ? "Show less" : "Show more")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(Color.backgroundTertiary.opacity(0.4))
      )
    }
    .buttonStyle(.plain)
  }

  private var displayContent: String {
    if isContentExpanded || !isLongContent {
      return message.content
    }
    return String(message.content.prefix(maxLength))
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private func formatTime(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }
}

// MARK: - Thinking Indicator (Collapsed by default)

struct ThinkingIndicator: View {
  let message: TranscriptMessage
  @State private var isExpanded = false
  @State private var isHovering = false

  private let thinkingColor = Color(red: 0.6, green: 0.55, blue: 0.8) // Soft purple

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Rectangle()
          .fill(thinkingColor.opacity(0.6))
          .frame(width: 2)
          .padding(.vertical, 4)

        HStack(spacing: 10) {
          Image(systemName: "brain.head.profile")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(thinkingColor)
            .frame(width: 16)

          Text("Thinking")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(thinkingColor)

          // Preview of thinking (collapsed)
          if !isExpanded {
            Text(message.content.components(separatedBy: "\n").first ?? "")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
          }

          Spacer()

          Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
              isExpanded.toggle()
            }
          } label: {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isHovering ? thinkingColor.opacity(0.08) : Color.clear)
      )
      .contentShape(Rectangle())
      .onTapGesture {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      }
      .onHover { isHovering = $0 }

      // Expanded thinking content
      if isExpanded {
        ScrollView {
          ThinkingMarkdownView(content: message.content)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(thinkingColor.opacity(0.05))
        )
        .padding(.leading, 28)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Image Gallery (Multiple images with fullscreen + collapsible)

struct ImageGallery: View {
  let images: [MessageImage]
  @State private var selectedIndex: Int?
  @State private var isExpanded = true

  private var totalSize: String {
    let bytes = images.reduce(0) { $0 + $1.data.count }
    if bytes < 1_024 {
      return "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      // Collapsible header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 11, weight: .semibold))
          Text(images.count == 1 ? "1 image" : "\(images.count) images")
            .font(.system(size: 12, weight: .medium))
          Text("•")
            .foregroundStyle(.quaternary)
          Text(totalSize)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.5))
        )
      }
      .buttonStyle(.plain)

      // Expanded content
      if isExpanded {
        if images.count == 1 {
          // Single image - show larger
          if let nsImage = NSImage(data: images[0].data) {
            SingleImageView(nsImage: nsImage, imageData: images[0]) {
              selectedIndex = 0
            }
          }
        } else {
          // Multiple images - grid layout
          FlowLayout(spacing: 12) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
              if let nsImage = NSImage(data: image.data) {
                ImageThumbnail(
                  nsImage: nsImage,
                  imageData: image,
                  index: index,
                  totalCount: images.count
                ) {
                  selectedIndex = index
                }
              }
            }
          }
        }
      }
    }
    .sheet(item: Binding(
      get: { selectedIndex.map { ImageSelection(index: $0) } },
      set: { selectedIndex = $0?.index }
    )) { selection in
      ImageFullscreen(
        images: images,
        currentIndex: selection.index
      )
    }
  }
}

/// Helper for sheet item binding
private struct ImageSelection: Identifiable {
  let index: Int
  var id: Int {
    index
  }
}

/// Single image view - larger and more prominent
struct SingleImageView: View {
  let nsImage: NSImage
  let imageData: MessageImage
  let onTap: () -> Void

  @State private var isHovering = false

  private var imageDimensions: String {
    let w = Int(nsImage.size.width)
    let h = Int(nsImage.size.height)
    return "\(w) × \(h)"
  }

  private var imageSize: String {
    let bytes = imageData.data.count
    if bytes < 1_024 {
      return "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .trailing, spacing: 6) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 400, maxHeight: 300)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
          .overlay(alignment: .bottomTrailing) {
            // Expand icon on hover
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white)
              .padding(6)
              .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
              .padding(8)
              .opacity(isHovering ? 1 : 0)
          }

        // Image metadata
        HStack(spacing: 8) {
          Text(imageDimensions)
          Text("•")
          Text(imageSize)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.quaternary)
      }
      .scaleEffect(isHovering ? 1.01 : 1.0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

struct ImageThumbnail: View {
  let nsImage: NSImage
  let imageData: MessageImage
  let index: Int
  let totalCount: Int
  let onTap: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .topTrailing) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 200, height: 150)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.12), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)

        // Index badge
        Text("\(index + 1)")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .frame(width: 22, height: 22)
          .background(Color.accent.opacity(0.9), in: Circle())
          .padding(8)

        // Expand icon on hover
        if isHovering {
          VStack {
            Spacer()
            HStack {
              Spacer()
              Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(6)
            }
          }
        }
      }
      .scaleEffect(isHovering ? 1.03 : 1.0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

struct ImageFullscreen: View {
  let images: [MessageImage]
  @State var currentIndex: Int
  @Environment(\.dismiss) private var dismiss
  @State private var isHoveringControls = false

  private var currentImage: MessageImage {
    images[currentIndex]
  }

  private var nsImage: NSImage? {
    NSImage(data: currentImage.data)
  }

  private var imageDimensions: String {
    guard let img = nsImage else { return "" }
    return "\(Int(img.size.width)) × \(Int(img.size.height))"
  }

  private var imageSize: String {
    let bytes = currentImage.data.count
    if bytes < 1_024 {
      return "\(bytes) B"
    } else if bytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(bytes) / 1_024)
    } else {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
  }

  var body: some View {
    GeometryReader { _ in
      ZStack {
        // Background
        Color.black

        // Image - fill available space
        if let nsImage {
          Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 50)
            .padding(.bottom, images.count > 1 ? 80 : 12)
            .id(currentIndex)
        }

        // Navigation overlay
        VStack(spacing: 0) {
          // Top bar
          HStack {
            // Image counter
            if images.count > 1 {
              Text("\(currentIndex + 1) of \(images.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
            }

            Spacer()

            // Image info
            HStack(spacing: 8) {
              Text(imageDimensions)
              Text("•")
              Text(imageSize)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))

            Spacer()

            // Close button
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
          }
          .padding(12)

          Spacer()

          // Bottom navigation (for multiple images)
          if images.count > 1 {
            HStack(spacing: 16) {
              // Previous button
              Button {
                withAnimation(.easeOut(duration: 0.2)) {
                  currentIndex = (currentIndex - 1 + images.count) % images.count
                }
              } label: {
                Image(systemName: "chevron.left")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundStyle(.white)
                  .frame(width: 40, height: 40)
                  .background(.white.opacity(0.15), in: Circle())
              }
              .buttonStyle(.plain)
              .keyboardShortcut(.leftArrow, modifiers: [])

              // Thumbnail strip
              HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                  if let thumb = NSImage(data: image.data) {
                    Button {
                      withAnimation(.easeOut(duration: 0.2)) {
                        currentIndex = index
                      }
                    } label: {
                      Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                          RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(index == currentIndex ? Color.accent : Color.clear, lineWidth: 2)
                        )
                        .opacity(index == currentIndex ? 1.0 : 0.5)
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(.black.opacity(0.5), in: Capsule())

              // Next button
              Button {
                withAnimation(.easeOut(duration: 0.2)) {
                  currentIndex = (currentIndex + 1) % images.count
                }
              } label: {
                Image(systemName: "chevron.right")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundStyle(.white)
                  .frame(width: 40, height: 40)
                  .background(.white.opacity(0.15), in: Circle())
              }
              .buttonStyle(.plain)
              .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(.bottom, 16)
          }
        }
      }
    }
    .frame(minWidth: 800, idealWidth: 1_000, minHeight: 600, idealHeight: 750)
  }
}

/// Simple flow layout for images
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = layout(proposal: proposal, subviews: subviews)
    return result.size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = layout(proposal: proposal, subviews: subviews)
    for (index, position) in result.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(
          x: bounds.maxX - position.x - subviews[index].sizeThatFits(.unspecified).width,
          y: bounds.minY + position.y
        ),
        proposal: .unspecified
      )
    }
  }

  private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var lineHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)

      if currentX + size.width > maxWidth, currentX > 0 {
        currentX = 0
        currentY += lineHeight + spacing
        lineHeight = 0
      }

      positions.append(CGPoint(x: currentX, y: currentY))
      currentX += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      totalWidth = max(totalWidth, currentX - spacing)
    }

    return (CGSize(width: totalWidth, height: currentY + lineHeight), positions)
  }
}

// MARK: - Activity Banner (Redesigned)

struct ActivityBanner: View {
  let workStatus: Session.WorkStatus
  let currentTool: String?
  let currentPrompt: String?
  var pendingToolName: String?
  var pendingToolInput: String?
  var provider: Provider = .claude

  private var color: Color {
    switch workStatus {
      case .working: .modelOpus
      case .waiting: .statusWaiting
      case .permission: .statusAttention
      case .unknown: .secondary
    }
  }

  private var icon: String {
    switch workStatus {
      case .working: "sparkles"
      case .waiting: "arrow.turn.down.left"
      case .permission: "exclamationmark.triangle.fill"
      case .unknown: "circle"
    }
  }

  private var title: String {
    switch workStatus {
      case .working: "\(provider.displayName) is working"
      case .waiting: "Your turn"
      case .permission: "Permission needed"
      case .unknown: ""
    }
  }

  private var subtitle: String? {
    switch workStatus {
      case .working:
        if let tool = currentTool {
          return "Running \(tool)..."
        }
        return nil
      case .waiting:
        return provider == .codex ? "Send a message below" : "Respond in terminal"
      case .permission:
        // Use rich display if we have tool input
        return nil // We'll show rich content instead
      case .unknown:
        return nil
    }
  }

  /// Parse tool input and extract display-friendly info
  private var permissionDetail: (icon: String, text: String)? {
    guard workStatus == .permission else { return nil }

    let toolName = pendingToolName ?? "Tool"
    guard let inputJson = pendingToolInput,
          let data = inputJson.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return (toolIconFor(toolName), "Accept or reject in terminal")
    }

    switch toolName {
      case "Bash":
        if let command = input["command"] as? String {
          let truncated = command.count > 50 ? String(command.prefix(47)) + "..." : command
          return ("terminal.fill", truncated)
        }
      case "Edit":
        if let filePath = input["file_path"] as? String {
          let fileName = (filePath as NSString).lastPathComponent
          return ("pencil", fileName)
        }
      case "Write":
        if let filePath = input["file_path"] as? String {
          let fileName = (filePath as NSString).lastPathComponent
          return ("doc.badge.plus", fileName)
        }
      case "Read":
        if let filePath = input["file_path"] as? String {
          let fileName = (filePath as NSString).lastPathComponent
          return ("doc.text", fileName)
        }
      case "WebFetch":
        if let url = input["url"] as? String {
          if let urlObj = URL(string: url), let host = urlObj.host {
            return ("globe", host)
          }
          return ("globe", url.count > 40 ? String(url.prefix(37)) + "..." : url)
        }
      case "WebSearch":
        if let query = input["query"] as? String {
          return ("magnifyingglass", query.count > 40 ? String(query.prefix(37)) + "..." : query)
        }
      default:
        break
    }

    return (toolIconFor(toolName), "Accept or reject in terminal")
  }

  private func toolIconFor(_ tool: String) -> String {
    switch tool {
      case "Bash": "terminal.fill"
      case "Edit": "pencil"
      case "Write": "doc.badge.plus"
      case "Read": "doc.text"
      case "WebFetch": "globe"
      case "WebSearch": "magnifyingglass"
      case "Glob", "Grep": "magnifyingglass.circle"
      case "Task": "person.2.fill"
      default: "gearshape"
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      // Left accent
      Rectangle()
        .fill(color)
        .frame(width: 3)

      HStack(spacing: 14) {
        // Icon
        ZStack {
          if workStatus == .working {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: icon)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(color)
          }
        }
        .frame(width: 26, height: 26)

        // Text content
        if workStatus == .permission, let detail = permissionDetail {
          // Rich permission display
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)

              if let toolName = pendingToolName {
                Text(toolName)
                  .font(.system(size: 12, weight: .bold))
                  .foregroundStyle(.primary)
              }
            }

            HStack(spacing: 6) {
              Image(systemName: detail.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

              Text(detail.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        } else {
          // Standard display
          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(color)

            if let subtitle {
              Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
          }
        }

        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
    }
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(color.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(color.opacity(0.15), lineWidth: 1)
    )
    .padding(.top, 16)
  }
}

// MARK: - Fork Origin Banner

private struct ForkOriginBanner: View {
  let sourceSessionId: String
  let sourceName: String?

  var body: some View {
    Button {
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": sourceSessionId]
      )
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("Forked from")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)

        Text(sourceName ?? sourceSessionId.prefix(8).description)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accent)
          .lineLimit(1)

        Image(systemName: "arrow.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.accent.opacity(0.6))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accent.opacity(0.06))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.accent.opacity(0.15), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.bottom, 8)
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var isPinned = true
  @Previewable @State var unreadCount = 0
  @Previewable @State var scrollTrigger = 0

  ConversationView(
    transcriptPath: nil,
    sessionId: nil,
    isSessionActive: true,
    workStatus: .working,
    currentTool: "Edit",
    provider: .claude,
    model: "claude-opus-4-6",
    isPinned: $isPinned,
    unreadCount: $unreadCount,
    scrollToBottomTrigger: $scrollTrigger
  )
  .environment(ServerAppState())
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
