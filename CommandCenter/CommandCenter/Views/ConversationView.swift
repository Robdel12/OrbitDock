//
//  ConversationView.swift
//  CommandCenter
//

import SwiftUI
import Combine
import AppKit

struct ConversationView: View {
    let transcriptPath: String?
    let sessionId: String?
    var isSessionActive: Bool = false
    var workStatus: Session.WorkStatus = .unknown
    var currentTool: String? = nil

    @State private var messages: [TranscriptMessage] = []
    @State private var currentPrompt: String?
    @State private var transcriptSubscription: AnyCancellable?
    @State private var isLoading = true
    @State private var loadedSessionId: String?
    @State private var displayedCount: Int = 50
    @State private var fileMonitor: DispatchSourceFileSystemObject?

    private let pageSize = 50

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
                conversationThread
            }
        }
        .onAppear {
            loadMessagesIfNeeded()
            setupSubscriptions()
        }
        .onDisappear {
            cleanupSubscriptions()
        }
        .onChange(of: sessionId) { _, _ in
            cleanupSubscriptions()
            loadMessagesIfNeeded()
            setupSubscriptions()
        }
    }

    // MARK: - Main Thread View

    private var conversationThread: some View {
        ScrollViewReader { proxy in
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
                    ForEach(displayedMessages, id: \.id) { message in
                        if message.isTool {
                            ToolIndicator(message: message)
                                .id(message.id)
                        } else if message.isThinking {
                            ThinkingIndicator(message: message)
                                .id(message.id)
                        } else {
                            ThreadMessage(message: message)
                                .id(message.id)
                        }
                    }

                    // Activity indicator
                    if isSessionActive && workStatus != .unknown {
                        ActivityBanner(
                            workStatus: workStatus,
                            currentTool: currentTool,
                            currentPrompt: currentPrompt
                        )
                        .id("activity")
                    }

                    // Bottom padding
                    Spacer()
                        .frame(height: 32)
                }
                .padding(.horizontal, 32)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onAppear {
                scrollToEnd(proxy: proxy, animated: false)
            }
            .onChange(of: messages.count) {
                scrollToEnd(proxy: proxy, animated: true)
            }
            .onChange(of: workStatus) {
                scrollToEnd(proxy: proxy, animated: true)
            }
        }
    }

    private func scrollToEnd(proxy: ScrollViewProxy, animated: Bool) {
        let targetId: String? = if isSessionActive && workStatus == .working {
            "activity"
        } else {
            displayedMessages.last?.id
        }

        guard let id = targetId else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
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
    // (Same as original - keeping the proven data layer)

    private func setupSubscriptions() {
        startWatchingFile()
        if let path = transcriptPath {
            transcriptSubscription = EventBus.shared.transcriptUpdated
                .filter { $0 == path }
                .receive(on: DispatchQueue.main)
                .sink { _ in syncAndReload() }
        }
    }

    private func cleanupSubscriptions() {
        stopWatchingFile()
        transcriptSubscription?.cancel()
        transcriptSubscription = nil
    }

    private func startWatchingFile() {
        guard let path = transcriptPath else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: .main
        )

        let capturedPath = path
        source.setEventHandler {
            EventBus.shared.notifyTranscriptChanged(path: capturedPath)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileMonitor = source
    }

    private func stopWatchingFile() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func syncAndReload() {
        guard let path = transcriptPath, let sid = sessionId else { return }
        let targetPath = path
        let targetSid = sid

        // Invalidate cache to ensure fresh parse
        TranscriptParser.invalidateCache(for: targetPath)

        DispatchQueue.global(qos: .utility).async {
            let result = TranscriptParser.parseAll(transcriptPath: targetPath)
            MessageStore.shared.syncFromParseResult(result, sessionId: targetSid)
            let newMessages = MessageStore.shared.readMessages(sessionId: targetSid)

            DispatchQueue.main.async {
                guard sessionId == targetSid else { return }
                currentPrompt = result.lastUserPrompt
                let oldCount = messages.count
                let wasAtBottom = displayedCount >= oldCount
                messages = newMessages
                if wasAtBottom && newMessages.count > oldCount {
                    displayedCount = newMessages.count
                }
            }
        }
    }

    private func loadMessagesIfNeeded() {
        guard sessionId != loadedSessionId else { return }
        loadedSessionId = sessionId
        messages = []
        currentPrompt = nil
        isLoading = true

        guard let path = transcriptPath, let sid = sessionId else {
            isLoading = false
            return
        }

        let targetPath = path
        let targetSid = sid

        DispatchQueue.global(qos: .userInitiated).async {
            let hasData = MessageStore.shared.hasData(sessionId: targetSid)

            if hasData {
                let loadedMessages = MessageStore.shared.readMessages(sessionId: targetSid)
                let info = MessageStore.shared.readSessionInfo(sessionId: targetSid)

                DispatchQueue.main.async {
                    guard sessionId == targetSid else { return }
                    messages = loadedMessages
                    currentPrompt = info.lastPrompt
                    displayedCount = loadedMessages.count
                    isLoading = false
                }

                DispatchQueue.global(qos: .utility).async {
                    let result = TranscriptParser.parseAll(transcriptPath: targetPath)
                    MessageStore.shared.syncFromParseResult(result, sessionId: targetSid)
                    let updatedMessages = MessageStore.shared.readMessages(sessionId: targetSid)
                    if updatedMessages.count != loadedMessages.count {
                        DispatchQueue.main.async {
                            guard sessionId == targetSid else { return }
                            messages = updatedMessages
                            displayedCount = updatedMessages.count
                        }
                    }
                }
            } else {
                let result = TranscriptParser.parseAll(transcriptPath: targetPath)
                MessageStore.shared.syncFromParseResult(result, sessionId: targetSid)
                let loadedMessages = MessageStore.shared.readMessages(sessionId: targetSid)

                DispatchQueue.main.async {
                    guard sessionId == targetSid else { return }
                    messages = loadedMessages
                    currentPrompt = result.lastUserPrompt
                    displayedCount = loadedMessages.count
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Thread Message (Redesigned)

struct ThreadMessage: View {
    let message: TranscriptMessage
    @State private var isContentExpanded = false
    @State private var isThinkingExpanded = false

    private let maxLength = 4000
    private var isLongContent: Bool { message.content.count > maxLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.isUser {
                userMessage
            } else {
                assistantMessage
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: - User Message (Right-aligned, distinctive)

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 100)

            VStack(alignment: .trailing, spacing: 12) {
                // Meta line - subtle timestamp and label
                HStack(spacing: 10) {
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)

                    Text("You")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
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
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                            )

                        if isLongContent {
                            expandCollapseButton
                        }
                    }
                }
            }
        }
    }

    // MARK: - Assistant Message (Left-aligned, clean)

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Meta line - Claude branding with timestamp
            HStack(spacing: 10) {
                // Claude indicator
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Claude")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.modelOpus)

                Text(formatTime(message.timestamp))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)

                if let tokens = message.outputTokens, tokens > 0 {
                    Text("\(tokens) tokens")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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

    private let thinkingColor = Color(red: 0.6, green: 0.55, blue: 0.8)  // Soft purple

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

// MARK: - Image Gallery (Multiple images with fullscreen)

struct ImageGallery: View {
    let images: [MessageImage]
    @State private var selectedImage: MessageImage?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Show images in a flow layout
            FlowLayout(spacing: 8) {
                ForEach(images) { image in
                    if let nsImage = NSImage(data: image.data) {
                        ImageThumbnail(nsImage: nsImage) {
                            selectedImage = image
                        }
                    }
                }
            }

            // Image count badge if multiple
            if images.count > 1 {
                Text("\(images.count) images")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .sheet(item: $selectedImage) { image in
            ImageFullscreen(image: image)
        }
    }
}

struct ImageThumbnail: View {
    let nsImage: NSImage
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovering ? 0.3 : 0.1), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(6)
                        .opacity(isHovering ? 1 : 0)
                }
                .scaleEffect(isHovering ? 1.02 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct ImageFullscreen: View {
    let image: MessageImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let nsImage = NSImage(data: image.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(40)
            }

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                }
                Spacer()
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

// Simple flow layout for images
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.maxX - position.x - subviews[index].sizeThatFits(.unspecified).width,
                                               y: bounds.minY + position.y),
                                   proposal: .unspecified)
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

            if currentX + size.width > maxWidth && currentX > 0 {
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

    private var color: Color {
        switch workStatus {
        case .working: return .modelOpus  // Purple for Claude
        case .waiting: return .statusWaiting
        case .permission: return .statusPermission
        case .unknown: return .secondary
        }
    }

    private var icon: String {
        switch workStatus {
        case .working: return "sparkles"
        case .waiting: return "arrow.turn.down.left"
        case .permission: return "exclamationmark.triangle.fill"
        case .unknown: return "circle"
        }
    }

    private var title: String {
        switch workStatus {
        case .working: return "Claude is working"
        case .waiting: return "Your turn"
        case .permission: return "Permission needed"
        case .unknown: return ""
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
            return "Respond in terminal"
        case .permission:
            return "Accept or reject in terminal"
        case .unknown:
            return nil
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

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
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

// MARK: - Preview

#Preview {
    ConversationView(
        transcriptPath: nil,
        sessionId: nil,
        isSessionActive: true,
        workStatus: .working,
        currentTool: "Edit"
    )
    .frame(width: 700, height: 600)
    .background(Color.backgroundPrimary)
}
