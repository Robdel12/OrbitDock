//
//  ConversationView.swift
//  OrbitDock
//

import AppKit
import SwiftUI

struct ConversationView: View {
  let sessionId: String?
  var isSessionActive: Bool = false
  var workStatus: Session.WorkStatus = .unknown
  var currentTool: String?
  var pendingToolName: String?
  var pendingToolInput: String?
  var provider: Provider = .claude
  var model: String?
  var onNavigateToReviewFile: ((String, Int) -> Void)? // (filePath, lineNumber) deep link from review card

  @Environment(ServerAppState.self) private var serverState

  @AppStorage("chatViewMode") private var chatViewMode: ChatViewMode = .focused

  @State private var messages: [TranscriptMessage] = []
  @State private var currentPrompt: String?
  @State private var isLoading = true
  @State private var loadedSessionId: String?
  @State private var displayedCount: Int = 50
  @State private var refreshTask: Task<Void, Never>?

  // Auto-follow state - controlled by parent
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  private let pageSize = 50

  /// Pre-computed per-message metadata to avoid O(n²) in ForEach
  private struct MessageMeta {
    let turnsAfter: Int?
    let nthUserMessage: Int?
  }

  var displayedMessages: [TranscriptMessage] {
    let startIndex = max(0, messages.count - displayedCount)
    return Array(messages[startIndex...])
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
    // Debounce rapid revision bumps during streaming into a single UI update
    .onChange(of: serverState.session(sessionId ?? "").messagesRevision) { _, _ in
      refreshTask?.cancel()
      refreshTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        refreshFromServerStateIfNeeded()
      }
    }
  }

  // MARK: - Main Thread View

  private var conversationThread: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .topTrailing) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            // Load more indicator
            if hasMoreMessages {
              loadMoreIndicator
            }

            // Message count (subtle)
            if messages.count > pageSize {
              messageCountIndicator
            }

            // Conditional rendering based on chat view mode
            let msgs = displayedMessages
            switch chatViewMode {
              case .verbose:
                // Existing flat ForEach — full transaction log
                let metadata = Self.computeMessageMetadata(msgs)
                ForEach(Array(msgs.enumerated()), id: \.element.id) { _, message in
                  let meta = metadata[message.id]
                  let turnsAfter = meta?.turnsAfter
                  let nthUser = meta?.nthUserMessage
                  WorkStreamEntry(
                    message: message,
                    provider: provider,
                    model: model,
                    sessionId: sessionId,
                    rollbackTurns: turnsAfter,
                    nthUserMessage: nthUser,
                    onRollback: turnsAfter != nil ? {
                      if let sid = sessionId, let turns = turnsAfter {
                        serverState.rollbackTurns(sessionId: sid, numTurns: UInt32(turns))
                      }
                    } : nil,
                    onFork: nthUser != nil ? {
                      if let sid = sessionId, let nth = nthUser {
                        serverState.forkSession(sessionId: sid, nthUserMessage: UInt32(nth))
                      }
                    } : nil,
                    onNavigateToReviewFile: onNavigateToReviewFile
                  )
                  .id(message.id)
                }

              case .focused:
                // Turn-grouped rendering with collapse logic
                let serverDiffs = sessionId.flatMap { serverState.session($0).turnDiffs } ?? []
                let turns = TurnBuilder.build(
                  from: msgs,
                  serverTurnDiffs: serverDiffs,
                  currentTurnId: isSessionActive && workStatus == .working ? "active" : nil
                )
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                  TurnGroupView(
                    turn: turn,
                    turnIndex: index,
                    provider: provider,
                    model: model,
                    sessionId: sessionId,
                    onNavigateToReviewFile: onNavigateToReviewFile
                  )
                }
            }

            // Live status indicator
            if isSessionActive, workStatus != .unknown {
              WorkStreamLiveIndicator(
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
          .padding(.horizontal, Spacing.sm)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .onAppear {
          scrollToEnd(proxy: proxy, animated: false)
        }
        .onChange(of: messages.count) { oldCount, newCount in
          if newCount > oldCount {
            if isPinned {
              // Don't animate during rapid streaming — just jump to avoid jitter
              proxy.scrollTo(
                isSessionActive && workStatus == .working ? "activity" : "bottomAnchor",
                anchor: .bottom
              )
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

        // Floating mode toggle
        chatViewModeToggle
          .padding(.top, 8)
          .padding(.trailing, 12)
      }
    }
  }

  // MARK: - Chat View Mode Toggle

  private var chatViewModeToggle: some View {
    HStack(spacing: 2) {
      ForEach(ChatViewMode.allCases, id: \.self) { mode in
        let isSelected = chatViewMode == mode

        Button {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            chatViewMode = mode
          }
        } label: {
          Image(systemName: mode.icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isSelected ? Color.accent : .secondary)
            .frame(width: 26, height: 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(mode.label)
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.9))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: 1)
    )
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

    // Fast path: nothing changed
    if messages.count == serverMessages.count,
       messages.last?.id == serverMessages.last?.id,
       messages.last == serverMessages.last
    {
      return
    }

    // Append path: server has more messages (common during streaming)
    if serverMessages.count >= messages.count,
       !messages.isEmpty,
       // Verify existing messages share the same prefix (no structural change)
       messages.first?.id == serverMessages.first?.id
    {
      // Update any changed existing messages (e.g., toolOutput filled in)
      for i in messages.indices {
        if i < serverMessages.count, messages[i] != serverMessages[i] {
          messages[i] = serverMessages[i]
        }
      }

      // Append genuinely new messages
      if serverMessages.count > messages.count {
        messages.append(contentsOf: serverMessages[messages.count...])
      }
    } else {
      // Structural change (undo/rollback/initial load) — full replace
      messages = serverMessages
    }

    displayedCount = max(displayedCount, messages.count)
    isLoading = false
  }

  /// Single-pass computation of per-message metadata (turnsAfter, nthUserMessage).
  /// Replaces O(n²) inline closures that scanned the array per message in ForEach.
  private static func computeMessageMetadata(_ msgs: [TranscriptMessage]) -> [String: MessageMeta] {
    var result: [String: MessageMeta] = [:]
    result.reserveCapacity(msgs.count)

    // First pass: assign nthUserMessage indices
    var userCount = 0
    var userIndices: [Int] = [] // indices of user messages in msgs
    for (i, msg) in msgs.enumerated() {
      if msg.isUser {
        result[msg.id] = MessageMeta(turnsAfter: 0, nthUserMessage: userCount)
        userCount += 1
        userIndices.append(i)
      } else {
        result[msg.id] = MessageMeta(turnsAfter: nil, nthUserMessage: nil)
      }
    }

    // Second pass: compute turnsAfter for each user message
    // turnsAfter = number of user messages after this one, or 1 if there's at least a response
    for (rank, msgIndex) in userIndices.enumerated() {
      let userMsgsAfter = userIndices.count - rank - 1
      let turnsAfter: Int
      if userMsgsAfter > 0 {
        turnsAfter = userMsgsAfter
      } else {
        // Last user message — check if there's any response after it
        let hasResponseAfter = msgs[(msgIndex + 1)...].contains { !$0.isUser }
        turnsAfter = hasResponseAfter ? 1 : 0
      }

      let existing = result[msgs[msgIndex].id]
      result[msgs[msgIndex].id] = MessageMeta(
        turnsAfter: turnsAfter > 0 ? turnsAfter : nil,
        nthUserMessage: existing?.nthUserMessage
      )
    }

    return result
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
