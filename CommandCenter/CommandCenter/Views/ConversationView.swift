//
//  ConversationView.swift
//  CommandCenter
//

import SwiftUI

struct ConversationView: View {
    let transcriptPath: String?
    var isSessionActive: Bool = false
    var workStatus: Session.WorkStatus = .unknown
    var currentTool: String? = nil

    // Use a dictionary keyed by path to prevent state bleeding between sessions
    @State private var messagesCache: [String: [TranscriptMessage]] = [:]
    @State private var isLoading = true
    @State private var loadedPath: String?
    @State private var displayedCount: Int = 50
    @State private var isLoadingMore = false
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var refreshTimer: Timer?

    private let pageSize = 50

    // Get messages for the current path only
    private var messages: [TranscriptMessage] {
        guard let path = transcriptPath else { return [] }
        return messagesCache[path] ?? []
    }

    var displayedMessages: [TranscriptMessage] {
        let startIndex = max(0, messages.count - displayedCount)
        return Array(messages[startIndex...])
    }

    var hasMoreMessages: Bool {
        displayedCount < messages.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                loadingView
            } else if messages.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .onAppear {
            loadMessagesIfNeeded()
            startWatchingFile()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                reloadMessages()
            }
        }
        .onDisappear {
            stopWatchingFile()
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: transcriptPath) { oldPath, newPath in
            // Reset display count for new path
            displayedCount = pageSize
            stopWatchingFile()
            loadMessagesIfNeeded()
            startWatchingFile()
        }
    }

    // MARK: - File Watching

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

        source.setEventHandler { [self] in
            reloadMessages()
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

    private func reloadMessages() {
        guard let path = transcriptPath else { return }
        let targetPath = path  // Capture for async

        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = TranscriptParser.parse(transcriptPath: targetPath)
            DispatchQueue.main.async {
                // Only update if we're still viewing the same path
                guard transcriptPath == targetPath else { return }

                let currentMessages = messagesCache[targetPath] ?? []
                if parsed.count != currentMessages.count {
                    let wasAtBottom = displayedCount >= currentMessages.count
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        messagesCache[targetPath] = parsed
                        if wasAtBottom {
                            displayedCount = min(pageSize, parsed.count)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if hasMoreMessages {
                        loadMoreButton
                            .id("load-more")
                    }

                    if messages.count > pageSize {
                        Text("\(displayedMessages.count) of \(messages.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }

                    ForEach(displayedMessages, id: \.id) { message in
                        if message.isTool {
                            ToolRow(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .leading)),
                                    removal: .opacity
                                ))
                        } else {
                            MessageRow(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: message.isUser ? .trailing : .leading)),
                                    removal: .opacity
                                ))
                        }
                    }

                    // Activity indicator when Claude is working
                    if isSessionActive && workStatus == .working {
                        ActivityIndicator(currentTool: currentTool)
                            .id("activity-indicator")
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: messages.count)
                .animation(.easeInOut(duration: 0.2), value: workStatus)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onAppear {
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: messages.count) {
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: workStatus) {
                scrollToBottom(proxy: proxy, animated: true)
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            loadMoreMessages()
        } label: {
            HStack(spacing: 6) {
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text("Load \(min(pageSize, messages.count - displayedCount)) more")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMore)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        // Scroll to activity indicator if showing, otherwise last message
        let targetId: String? = if isSessionActive && workStatus == .working {
            "activity-indicator"
        } else {
            displayedMessages.last?.id
        }

        guard let id = targetId else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func loadMoreMessages() {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            displayedCount = min(displayedCount + pageSize, messages.count)
            isLoadingMore = false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("No messages yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadMessagesIfNeeded() {
        guard transcriptPath != loadedPath else { return }
        loadedPath = transcriptPath

        isLoading = true
        guard let path = transcriptPath else {
            isLoading = false
            return
        }

        let targetPath = path  // Capture for async

        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = TranscriptParser.parse(transcriptPath: targetPath)
            DispatchQueue.main.async {
                // Only update if we're still viewing the same path
                guard transcriptPath == targetPath else { return }

                messagesCache[targetPath] = parsed
                displayedCount = min(pageSize, parsed.count)
                isLoading = false
            }
        }
    }
}

// MARK: - Tool Row

struct ToolRow: View {
    let message: TranscriptMessage
    @State private var isExpanded = false
    @State private var isHovering = false

    private var toolColor: Color {
        switch message.toolColor {
        case "blue": return .blue
        case "orange": return .orange
        case "green": return .green
        case "purple": return .purple
        case "indigo": return .indigo
        case "teal": return .teal
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                // Compact icon
                Image(systemName: message.toolIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(toolColor)
                    .frame(width: 20, height: 20)
                    .background(toolColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                // Tool name
                Text(message.toolName ?? "Tool")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(toolColor)

                // Summary
                Text(message.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(isExpanded ? nil : 1)

                Spacer()

                // Actions
                HStack(spacing: 4) {
                    if let path = message.filePath {
                        Button {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovering ? 1 : 0)
                    }

                    if message.toolInput != nil {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(toolColor.opacity(isHovering ? 0.12 : 0.08))
            )
            .onHover { isHovering = $0 }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let command = message.bashCommand {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .textSelection(.enabled)
                    }

                    if let path = message.filePath {
                        HStack(spacing: 4) {
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.7))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .padding(.leading, 28)
            }
        }
    }
}

// MARK: - Message Row

struct MessageRow: View {
    let message: TranscriptMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser {
                Spacer(minLength: 60)
                userMessage
            } else {
                assistantMessage
                Spacer(minLength: 60)
            }
        }
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Minimal header
            HStack(spacing: 6) {
                Text(formatTime(message.timestamp))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("You")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
            }

            // Message content
            Text(truncatedContent)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with tokens
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.purple)

                Text("Claude")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.purple)

                Text(formatTime(message.timestamp))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                if let tokens = message.outputTokens, tokens > 0 {
                    Text("\(tokens)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Message content
            MarkdownText(content: truncatedContent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var truncatedContent: String {
        let maxLength = 3000
        if message.content.count > maxLength {
            return String(message.content.prefix(maxLength)) + "\n\n[Truncated...]"
        }
        return message.content
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Markdown Text View

struct MarkdownText: View {
    let content: String

    var body: some View {
        Text(attributedContent)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineSpacing(2)
    }

    private var attributedContent: AttributedString {
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(content)
    }
}

// MARK: - Activity Indicator

struct ActivityIndicator: View {
    let currentTool: String?
    @State private var dotCount = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.purple)

                    Text("Claude")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.purple)
                }

                // Typing bubble
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    if let tool = currentTool {
                        Text(tool)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        TypingDots()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer(minLength: 60)
        }
    }
}

struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

#Preview {
    ConversationView(transcriptPath: nil)
        .frame(width: 600, height: 700)
}
