//
//  ConversationView.swift
//  CommandCenter
//

import SwiftUI
import Combine
import AppKit

struct ConversationView: View {
    let transcriptPath: String?
    let sessionId: String?  // For SQLite lookups
    var isSessionActive: Bool = false
    var workStatus: Session.WorkStatus = .unknown
    var currentTool: String? = nil

    // Direct state for current session (not computed - ensures SwiftUI updates)
    @State private var messages: [TranscriptMessage] = []
    @State private var currentPrompt: String?
    @State private var transcriptSubscription: AnyCancellable?

    @State private var isLoading = true
    @State private var loadedSessionId: String?
    @State private var displayedCount: Int = 50
    @State private var isLoadingMore = false
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var refreshTimer: Timer?

    private let pageSize = 50

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

            // Subscribe to EventBus for this transcript
            if let path = transcriptPath {
                transcriptSubscription = EventBus.shared.transcriptUpdated
                    .filter { $0 == path }
                    .receive(on: DispatchQueue.main)
                    .sink { _ in
                        syncAndReload()
                    }
            }

            // Long fallback timer (30s) in case events are missed
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
                syncAndReload()
            }
        }
        .onDisappear {
            stopWatchingFile()
            refreshTimer?.invalidate()
            refreshTimer = nil
            transcriptSubscription?.cancel()
            transcriptSubscription = nil
        }
        .onChange(of: sessionId) { oldId, newId in
            // Reset state for new session
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

        let capturedPath = path
        source.setEventHandler {
            // Push to EventBus which handles debouncing
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

    /// Sync JSONL to SQLite, then read from SQLite
    private func syncAndReload() {
        guard let path = transcriptPath, let sid = sessionId else { return }
        let targetPath = path
        let targetSid = sid

        DispatchQueue.global(qos: .utility).async {
            // Parse JSONL (source of truth)
            let result = TranscriptParser.parseAll(transcriptPath: targetPath)

            // Store in SQLite for fast future reads
            MessageStore.shared.syncFromParseResult(result, sessionId: targetSid)

            // Read back from SQLite (validates the sync worked)
            let newMessages = MessageStore.shared.readMessages(sessionId: targetSid)

            DispatchQueue.main.async {
                guard sessionId == targetSid else { return }

                // Update state directly (ensures SwiftUI view update)
                currentPrompt = result.lastUserPrompt

                let oldCount = messages.count
                let wasAtBottom = displayedCount >= oldCount

                messages = newMessages

                // Expand displayedCount to show new messages if user was at bottom
                if wasAtBottom && newMessages.count > oldCount {
                    displayedCount = newMessages.count
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
                        } else {
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }

                    // Activity indicator when Claude is working or needs attention
                    if isSessionActive && workStatus != .unknown {
                        SessionActivityIndicator(
                            workStatus: workStatus,
                            currentTool: currentTool,
                            currentPrompt: currentPrompt
                        )
                        .id("activity-indicator")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
            withAnimation(.easeOut(duration: 0.2)) {
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
        guard sessionId != loadedSessionId else { return }
        loadedSessionId = sessionId

        // Clear state immediately when switching sessions
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
            // Check if SQLite has data (fast ~5ms)
            let hasData = MessageStore.shared.hasData(sessionId: targetSid)

            if hasData {
                // Fast path: read from SQLite immediately
                let loadedMessages = MessageStore.shared.readMessages(sessionId: targetSid)
                let info = MessageStore.shared.readSessionInfo(sessionId: targetSid)

                DispatchQueue.main.async {
                    guard sessionId == targetSid else { return }

                    messages = loadedMessages
                    currentPrompt = info.lastPrompt
                    displayedCount = loadedMessages.count  // Show all messages
                    isLoading = false
                }

                // Background sync to catch any new messages
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
                // Cold start: parse JSONL, store in SQLite
                let result = TranscriptParser.parseAll(transcriptPath: targetPath)
                MessageStore.shared.syncFromParseResult(result, sessionId: targetSid)
                let loadedMessages = MessageStore.shared.readMessages(sessionId: targetSid)

                DispatchQueue.main.async {
                    guard sessionId == targetSid else { return }

                    messages = loadedMessages
                    currentPrompt = result.lastUserPrompt
                    displayedCount = loadedMessages.count  // Show all messages
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Tool Row

struct ToolRow: View {
    let message: TranscriptMessage
    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var showOutput = false

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
                // Compact icon with in-progress indicator
                Image(systemName: message.toolIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(toolColor)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(toolColor.opacity(message.isInProgress ? 0.25 : 0.15))
                    )

                // Tool name
                Text(message.toolName ?? "Tool")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(toolColor)

                if message.isInProgress {
                    ProgressView()
                        .controlSize(.mini)
                }

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

                    if message.toolInput != nil || message.toolOutput != nil {
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
                    .fill(message.isInProgress ? toolColor.opacity(0.15) : toolColor.opacity(isHovering ? 0.12 : 0.08))
            )
            .contentShape(Rectangle())  // Make entire row clickable
            .onTapGesture {
                if message.toolInput != nil || message.toolOutput != nil {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        isExpanded.toggle()
                    }
                }
            }
            .onHover { isHovering = $0 }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Input section
                    if let formattedInput = message.formattedToolInput {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(formattedInput)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }

                    // Output section
                    if let output = message.toolOutput, !output.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Output")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    showOutput.toggle()
                                } label: {
                                    Text(showOutput ? "Hide" : "Show")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            if showOutput {
                                ScrollView {
                                    Text(output.count > 2000 ? String(output.prefix(2000)) + "\n\n[Truncated...]" : output)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.8))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 200)
                                .padding(10)
                                .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }

                    // File path
                    if let path = message.filePath {
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
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

            // Image if present
            if let imageData = message.imageData,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }

            // Message content (if not empty)
            if !message.content.isEmpty {
                MarkdownView(content: truncatedContent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
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
            MessageText(content: truncatedContent)
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - Message Text View (with markdown support)

struct MessageText: View {
    let content: String

    var body: some View {
        MarkdownView(content: content)
    }
}

// MARK: - Session Activity Indicator

struct SessionActivityIndicator: View {
    let workStatus: Session.WorkStatus
    let currentTool: String?
    let currentPrompt: String?

    private var statusColor: Color {
        switch workStatus {
        case .working: return .purple
        case .waiting: return .orange
        case .permission: return .yellow
        case .unknown: return .secondary
        }
    }

    private var statusIcon: String {
        switch workStatus {
        case .working: return "sparkle"
        case .waiting: return "hand.raised.fill"
        case .permission: return "lock.fill"
        case .unknown: return "circle"
        }
    }

    private var statusLabel: String {
        switch workStatus {
        case .working: return "Claude is working"
        case .waiting: return "Waiting for you"
        case .permission: return "Needs permission"
        case .unknown: return ""
        }
    }

    private var truncatedPrompt: String? {
        guard let prompt = currentPrompt else { return nil }
        let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > 100 {
            return String(cleaned.prefix(100)) + "..."
        }
        return cleaned
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(statusColor)

                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor)

                    if let tool = currentTool, workStatus == .working {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(tool)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                // Status bubble with prompt context
                VStack(alignment: .leading, spacing: 6) {
                    if workStatus == .working {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            TypingDots()
                        }

                        // Show what prompt triggered this work
                        if let prompt = truncatedPrompt {
                            Text("Working on: \(prompt)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else if workStatus == .permission {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.yellow)

                            Text("Accept or reject in terminal")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.8))
                        }
                    } else if workStatus == .waiting {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.orange)

                            Text("Your turn to respond")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(statusColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer(minLength: 60)
        }
    }
}

struct TypingDots: View {
    var body: some View {
        // Simple static dots - no animation to save battery
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

#Preview {
    ConversationView(transcriptPath: nil, sessionId: nil)
        .frame(width: 600, height: 700)
}
