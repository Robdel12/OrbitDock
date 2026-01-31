//
//  ConversationViewNew.swift
//  CommandCenter
//
//  Radically redesigned conversation view
//  Linear/Raycast polish + VS Code utility
//

import SwiftUI
import Combine
import AppKit

struct ConversationViewNew: View {
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
                        .frame(height: 20)
                }
                .padding(.horizontal, 24)
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
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading conversation...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.quaternary)

            VStack(spacing: 4) {
                Text("No messages yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Start the conversation in your terminal")
                    .font(.system(size: 12))
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
                    .font(.system(size: 10, weight: .semibold))
                Text("Load \(min(pageSize, messages.count - displayedCount)) earlier")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private var messageCountIndicator: some View {
        Text("\(displayedMessages.count) of \(messages.count) messages")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
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
        .padding(.vertical, 16)
    }

    // MARK: - User Message (Right-aligned, distinctive)

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 8) {
                // Meta line
                HStack(spacing: 8) {
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)

                    Text("You")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // Images (supports multiple)
                if !message.images.isEmpty {
                    ImageGallery(images: message.images)
                }

                // Content
                if !message.content.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(displayContent)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 8) {
            // Meta line
            HStack(spacing: 8) {
                // Claude indicator
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Claude")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.modelOpus)

                Text(formatTime(message.timestamp))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)

                if let tokens = message.outputTokens, tokens > 0 {
                    Text("\(tokens) tokens")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }

            // Content - clean, no bubble for assistant
            MarkdownView(content: displayContent)
                .padding(.leading, 2)

            if isLongContent {
                expandCollapseButton
                    .padding(.leading, 2)
            }

            Spacer()
                .frame(width: 80)
        }
    }

    private var expandCollapseButton: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                isContentExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isContentExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isContentExpanded ? "Show less" : "Show more")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.backgroundTertiary.opacity(0.5))
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

// MARK: - Tool Indicator (Redesigned - Code edits are first-class)

struct ToolIndicator: View {
    let message: TranscriptMessage
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isCodeEdit: Bool {
        let tool = message.toolName?.lowercased() ?? ""
        return tool == "edit" || tool == "write" || tool == "notebookedit"
    }

    private var isBash: Bool {
        message.toolName?.lowercased() == "bash"
    }

    private var isRead: Bool {
        message.toolName?.lowercased() == "read"
    }

    private var toolColor: Color {
        switch message.toolColor {
        case "blue": return Color(red: 0.4, green: 0.6, blue: 1.0)      // Read - soft blue
        case "orange": return Color(red: 1.0, green: 0.55, blue: 0.25) // Edit - warm orange
        case "green": return Color(red: 0.35, green: 0.8, blue: 0.5)   // Bash - soft green
        case "purple": return Color(red: 0.65, green: 0.45, blue: 0.9) // Search - purple
        case "indigo": return Color(red: 0.45, green: 0.45, blue: 0.95) // Task - indigo
        case "teal": return Color(red: 0.3, green: 0.75, blue: 0.75)   // Web - teal
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCodeEdit {
                codeEditCard
            } else if isBash {
                bashCard
            } else {
                standardToolCard
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Code Edit Card (First-class, prominent diff view)

    private var codeEditCard: some View {
        let oldString = message.editOldString ?? ""
        let newString = message.editNewString ?? ""
        let writeContent = message.writeContent
        let oldLines = oldString.components(separatedBy: "\n").filter { !$0.isEmpty }
        let newLines = newString.components(separatedBy: "\n").filter { !$0.isEmpty }
        let isTruncated = oldLines.count > 25 || newLines.count > 25

        return VStack(alignment: .leading, spacing: 0) {
            // File header bar
            HStack(spacing: 0) {
                // Left accent bar
                Rectangle()
                    .fill(toolColor)
                    .frame(width: 4)

                HStack(spacing: 12) {
                    // File icon + name
                    if let path = message.filePath {
                        let filename = path.components(separatedBy: "/").last ?? path

                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(toolColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(filename)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)

                                Text(shortenPath(path))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        // Diff stats
                        HStack(spacing: 12) {
                            if !oldLines.isEmpty {
                                HStack(spacing: 4) {
                                    Text("−\(oldLines.count)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                                }
                            }
                            if !newLines.isEmpty {
                                HStack(spacing: 4) {
                                    Text("+\(newLines.count)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                                }
                            }
                        }

                        // Expand toggle if truncated
                        if isTruncated {
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    isExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(isExpanded ? "Collapse" : "Expand")
                                        .font(.system(size: 10, weight: .medium))
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        // Open in editor
                        Button {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Open in Finder")
                    } else {
                        Text(message.toolName ?? "Edit")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(toolColor)
                        Spacer()
                    }

                    // Status indicator
                    if message.isInProgress {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Editing...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(toolColor)
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.statusWorking)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.backgroundTertiary.opacity(0.7))

            // Code diff content
            codeDiffView(
                oldString: oldString,
                newString: newString,
                writeContent: writeContent,
                language: detectLanguage(from: message.filePath),
                isExpanded: isExpanded || !isTruncated
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.backgroundTertiary.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(toolColor.opacity(0.25), lineWidth: 1)
        )
    }

    // Diff view - NO nested scroll, just truncated with expand
    @ViewBuilder
    private func codeDiffView(
        oldString: String,
        newString: String,
        writeContent: String?,
        language: String,
        isExpanded: Bool
    ) -> some View {
        let maxLines = isExpanded ? 200 : 30

        VStack(alignment: .leading, spacing: 0) {
            // For Write tool, show full content as addition
            if let content = writeContent {
                let lines = content.components(separatedBy: "\n")
                let displayLines = lines.count > maxLines
                    ? Array(lines.prefix(maxLines))
                    : lines
                DiffSection(
                    lines: displayLines,
                    isAddition: true,
                    language: language
                )
            }
            // For Edit tool, show unified diff (GitHub-style)
            else if !oldString.isEmpty || !newString.isEmpty {
                UnifiedDiffView(
                    oldString: oldString,
                    newString: newString,
                    language: language,
                    maxLines: maxLines
                )
            }
            // Fallback - no diff data
            else if let input = message.formattedToolInput {
                Text(input)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(14)
            } else {
                Text("No content")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(14)
            }
        }
    }

    // Detect language from file extension
    private func detectLanguage(from path: String?) -> String {
        guard let path = path else { return "" }
        let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""

        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "typescript"
        case "js", "jsx": return "javascript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt": return "kotlin"
        case "css", "scss": return "css"
        case "html": return "html"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        default: return ""
        }
    }

    // MARK: - Bash Card

    private var bashCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(toolColor)
                    .frame(width: 3)

                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(toolColor)

                    Text("$")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(toolColor)

                    Text(message.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer()

                    if message.isInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    } else if message.toolOutput != nil {
                        Button {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(toolColor.opacity(isHovering ? 0.10 : 0.06))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if message.toolOutput != nil {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                        isExpanded.toggle()
                    }
                }
            }
            .onHover { isHovering = $0 }

            // Output
            if isExpanded, let output = message.toolOutput, !output.isEmpty {
                ScrollView {
                    Text(output.count > 2000 ? String(output.prefix(2000)) + "\n[...]" : output)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 6)
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Standard Tool Card (Read, Search, etc.)

    private var standardToolCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(toolColor)
                    .frame(width: 2)
                    .padding(.vertical, 4)

                HStack(spacing: 10) {
                    Image(systemName: message.toolIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(toolColor)
                        .frame(width: 16)

                    Text(message.toolName ?? "Tool")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(toolColor)

                    if message.isInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Text(message.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if message.toolInput != nil || message.toolOutput != nil {
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if message.toolInput != nil || message.toolOutput != nil {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                        isExpanded.toggle()
                    }
                }
            }
            .onHover { isHovering = $0 }

            if isExpanded {
                standardExpandedContent
                    .padding(.leading, 28)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var standardExpandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let input = message.formattedToolInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INPUT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.backgroundTertiary)
                    )
                }
            }

            if let output = message.toolOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OUTPUT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    ScrollView {
                        Text(output.count > 1500 ? String(output.prefix(1500)) + "\n[...]" : output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.backgroundTertiary)
                    )
                }
            }

            if let path = message.filePath {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 9))
                        Text(path.components(separatedBy: "/").suffix(3).joined(separator: "/"))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}

// MARK: - Unified Diff View (GitHub-style interleaved diff)

struct UnifiedDiffView: View {
    let oldString: String
    let newString: String
    let language: String
    var maxLines: Int = 100

    // Colors
    private let addedBg = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
    private let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
    private let contextBg = Color.clear
    private let addedGutter = Color(red: 0.2, green: 0.45, blue: 0.25).opacity(0.5)
    private let removedGutter = Color(red: 0.45, green: 0.18, blue: 0.18).opacity(0.5)
    private let addedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
    private let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

    var body: some View {
        let diffLines = computeUnifiedDiff()
        let displayLines = diffLines.count > maxLines ? Array(diffLines.prefix(maxLines)) : diffLines
        let isTruncated = diffLines.count > maxLines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                diffLineView(line)
            }

            if isTruncated {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(diffLines.count - maxLines) more lines")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.backgroundTertiary.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private func diffLineView(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Old line number
            Text(line.oldLineNum.map { String($0) } ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 4)

            // New line number
            Text(line.newLineNum.map { String($0) } ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)

            // Change indicator
            Text(line.prefix)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(prefixColor(for: line.type))
                .frame(width: 16)

            // Code content with syntax highlighting
            Text(SyntaxHighlighter.highlightLine(line.content.isEmpty ? " " : line.content, language: language.isEmpty ? nil : language))
                .font(.system(size: 13, design: .monospaced))
                .opacity(line.type == .context ? 0.7 : 1.0)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .background(backgroundColor(for: line.type))
    }

    private func backgroundColor(for type: DiffLineType) -> Color {
        switch type {
        case .added: return addedBg
        case .removed: return removedBg
        case .context: return contextBg
        }
    }

    private func prefixColor(for type: DiffLineType) -> Color {
        switch type {
        case .added: return addedAccent
        case .removed: return removedAccent
        case .context: return .clear
        }
    }

    // Simple line-by-line diff computation
    private func computeUnifiedDiff() -> [DiffLine] {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")

        // Use LCS-based diff for proper interleaving
        return computeLCSDiff(oldLines: oldLines, newLines: newLines)
    }

    // LCS-based diff algorithm for proper unified diff
    private func computeLCSDiff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let m = oldLines.count
        let n = newLines.count

        // Build LCS table
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to build diff
        var i = m, j = n
        var tempResult: [DiffLine] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                // Context line (unchanged)
                tempResult.append(DiffLine(
                    type: .context,
                    content: oldLines[i - 1],
                    oldLineNum: i,
                    newLineNum: j,
                    prefix: " "
                ))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                // Added line
                tempResult.append(DiffLine(
                    type: .added,
                    content: newLines[j - 1],
                    oldLineNum: nil,
                    newLineNum: j,
                    prefix: "+"
                ))
                j -= 1
            } else if i > 0 {
                // Removed line
                tempResult.append(DiffLine(
                    type: .removed,
                    content: oldLines[i - 1],
                    oldLineNum: i,
                    newLineNum: nil,
                    prefix: "−"
                ))
                i -= 1
            }
        }

        return tempResult.reversed()
    }
}

enum DiffLineType {
    case added
    case removed
    case context
}

struct DiffLine {
    let type: DiffLineType
    let content: String
    let oldLineNum: Int?
    let newLineNum: Int?
    let prefix: String
}

// MARK: - Legacy DiffSection (for Write tool - all additions)

struct DiffSection: View {
    let lines: [String]
    let isAddition: Bool
    let language: String
    var showHeader: Bool = true

    private var backgroundColor: Color {
        isAddition
            ? Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
            : Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
    }

    private var accentColor: Color {
        isAddition
            ? Color(red: 0.4, green: 0.95, blue: 0.5)
            : Color(red: 1.0, green: 0.5, blue: 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HStack(spacing: 6) {
                    Image(systemName: isAddition ? "plus.circle.fill" : "minus.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(isAddition ? "NEW FILE" : "REMOVED")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.5)
                    Text("(\(lines.count) lines)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(backgroundColor.opacity(0.5))
            }

            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 36, alignment: .trailing)
                        .padding(.trailing, 8)

                    Text(isAddition ? "+" : "−")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(accentColor)
                        .frame(width: 16)

                    Text(SyntaxHighlighter.highlightLine(line.isEmpty ? " " : line, language: language.isEmpty ? nil : language))
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .background(backgroundColor)
            }
        }
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

            HStack(spacing: 12) {
                // Icon
                ZStack {
                    if workStatus == .working {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: 24, height: 24)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
        .padding(.top, 12)
    }
}

// MARK: - Preview

#Preview {
    ConversationViewNew(
        transcriptPath: nil,
        sessionId: nil,
        isSessionActive: true,
        workStatus: .working,
        currentTool: "Edit"
    )
    .frame(width: 700, height: 600)
    .background(Color.backgroundPrimary)
}
