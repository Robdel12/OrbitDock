//
//  SessionDetailView.swift
//  CommandCenter
//

import SwiftUI
import Combine

struct SessionDetailView: View {
    @Environment(DatabaseManager.self) private var database
    let session: Session

    // UI state - cleared on session change
    @State private var editingName = false
    @State private var nameText = ""
    @State private var isHoveringPath = false
    @State private var copiedResume = false
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var terminalActionFailed = false
    @State private var transcriptSubscription: AnyCancellable?

    // Session-specific data - direct state (not dictionary cache)
    @State private var usageStats = TranscriptUsageStats()
    @State private var currentTool: String?


    var body: some View {
        VStack(spacing: 0) {
            // Compact header with essential info
            headerSection
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Stats row
            statsSection
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider().opacity(0.3)

            // Conversation
            ConversationView(
                transcriptPath: session.transcriptPath,
                sessionId: session.id,
                isSessionActive: session.isActive,
                workStatus: session.workStatus,
                currentTool: currentTool
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Minimal action bar
            actionBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.backgroundSecondary)
        }
        .background(Color.backgroundPrimary)
        .onAppear {
            resetStateForSession()
            loadUsageStats(for: session)
            setupSubscription()
        }
        .onDisappear {
            cleanupSubscription()
        }
        .onChange(of: session.id) { oldId, newId in
            // CRITICAL: Clean up old subscription before setting up new one
            cleanupSubscription()
            resetStateForSession()
            loadUsageStats(for: session)
            setupSubscription()
        }
    }

    /// Set up EventBus subscription for current session's transcript
    private func setupSubscription() {
        guard let path = session.transcriptPath else { return }
        let targetSession = session  // Capture current session

        transcriptSubscription = EventBus.shared.transcriptUpdated
            .filter { $0 == path }
            .receive(on: DispatchQueue.main)
            .sink { [targetSession] _ in
                // Only update if still viewing the same session
                guard session.id == targetSession.id else { return }
                loadUsageStats(for: targetSession)
            }
    }

    /// Clean up subscription
    private func cleanupSubscription() {
        transcriptSubscription?.cancel()
        transcriptSubscription = nil
    }

    /// Reset all session-specific state to defaults
    private func resetStateForSession() {
        currentTool = nil
        usageStats = TranscriptUsageStats()
        nameText = session.customName ?? ""
        editingName = false
        copiedResetTask?.cancel()
        copiedResume = false
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: Status + Title + Model
            HStack(alignment: .center, spacing: 12) {
                // Minimal status dot
                Circle()
                    .fill(session.isActive ? workStatusColor : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
                    .overlay {
                        if session.isActive && session.workStatus == .working {
                            Circle()
                                .stroke(workStatusColor.opacity(0.4), lineWidth: 2)
                                .frame(width: 18, height: 18)
                        }
                    }

                Text(session.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)

                if session.isActive {
                    StatusPill(workStatus: session.workStatus, currentTool: currentTool)
                }

                Spacer()

                ModelBadge(model: session.model)
            }

            // Second row: Path + Branch + Label
            HStack(spacing: 12) {
                // Path button
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                        Text(shortenPath(session.projectPath))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(isHoveringPath ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringPath = $0 }

                if let branch = session.branch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                        Text(branch)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.orange)
                }

                Spacer()

                // Inline label
                sessionNameView
            }
        }
    }

    private var workStatusColor: Color {
        switch session.workStatus {
        case .working: return .green
        case .waiting: return .orange
        case .permission: return .yellow
        case .unknown: return .green.opacity(0.6)
        }
    }

    private func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 4 {
            return "~/.../" + components.suffix(2).joined(separator: "/")
        }
        return path.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
    }

    private var sessionNameView: some View {
        Group {
            if editingName {
                HStack(spacing: 6) {
                    TextField("Custom name...", text: $nameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .frame(width: 160)

                    Button {
                        database.updateCustomName(sessionId: session.id, name: nameText.isEmpty ? nil : nameText)
                        editingName = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)

                    Button {
                        nameText = session.customName ?? ""
                        editingName = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    editingName = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: session.customName == nil ? "pencil" : "pencil.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                        Text(session.customName ?? "Rename")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(session.customName == nil ? Color.secondary : Color.primary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 16) {
            StatChip(value: session.formattedDuration, label: "duration", icon: "clock")
            StatChip(value: "\(session.promptCount)", label: "prompts", icon: "text.bubble")
            StatChip(value: "\(session.toolCount)", label: "tools", icon: "wrench.and.screwdriver")
            StatChip(value: usageStats.formattedCost, label: "cost", icon: "dollarsign")

            // Context window usage
            ContextGauge(stats: usageStats)

            Spacer()
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            // Primary action: Open in iTerm
            Button {
                openInITerm()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: session.isActive ? "arrow.up.forward.app" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                    Text(session.isActive ? "Focus" : "Resume")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(session.isActive ? "Focus the terminal running this session" : "Open iTerm and resume this session")

            Button {
                copyResumeCommand()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedResume ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                    Text(copiedResume ? "Copied" : "Copy cmd")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(.primary.opacity(0.7))
            }
            .buttonStyle(.plain)

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(.primary.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()

            if let lastActivity = session.lastActivityAt {
                Text(lastActivity, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Terminal Not Found", isPresented: $terminalActionFailed) {
            Button("Open New") {
                openNewITermWithResume()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Couldn't find the terminal for this session. It might be in a different app. Open a new iTerm window to resume?")
        }
    }

    private func copyResumeCommand() {
        let command = "claude --resume \(session.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedResume = true

        // Cancel any existing reset task
        copiedResetTask?.cancel()

        // Schedule reset using Task (cancellable, no timer)
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedResume = false
        }
    }

    private func openInITerm() {
        if session.isActive {
            // Try to find and focus the existing terminal
            focusExistingTerminal()
        } else {
            // Open new window with resume command
            openNewITermWithResume()
        }
    }

    private func focusExistingTerminal() {
        // If we have the iTerm session ID, use it directly
        if let terminalId = session.terminalSessionId, !terminalId.isEmpty,
           session.terminalApp == "iTerm.app" {
            focusITermBySessionId(terminalId)
            return
        }

        // Fallback: search by working directory
        let escapedPath = session.projectPath.replacingOccurrences(of: "'", with: "'\\''")

        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            set sessionPath to path of aSession
                            if sessionPath contains "\(escapedPath)" then
                                select aTab
                                select aSession
                                set index of aWindow to 1
                                activate
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """

        runAppleScript(script) { result in
            if result == "not_found" || result == nil {
                // Couldn't find it - show alert offering to open new
                DispatchQueue.main.async {
                    terminalActionFailed = true
                }
            }
        }
    }

    private func focusITermBySessionId(_ sessionId: String) {
        // iTerm session IDs look like "w0t0p0:GUID" - we can match by the unique ID part
        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            if unique ID of aSession contains "\(sessionId)" then
                                select aTab
                                select aSession
                                set index of aWindow to 1
                                activate
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """

        runAppleScript(script) { result in
            if result == "not_found" || result == nil {
                // Fall back to path-based search
                focusExistingTerminalByPath()
            }
        }
    }

    private func focusExistingTerminalByPath() {
        let escapedPath = session.projectPath.replacingOccurrences(of: "'", with: "'\\''")

        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        try
                            set sessionPath to path of aSession
                            if sessionPath contains "\(escapedPath)" then
                                select aTab
                                select aSession
                                set index of aWindow to 1
                                activate
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "not_found"
        end tell
        """

        runAppleScript(script) { result in
            if result == "not_found" || result == nil {
                DispatchQueue.main.async {
                    terminalActionFailed = true
                }
            }
        }
    }

    private func openNewITermWithResume() {
        let escapedPath = session.projectPath.replacingOccurrences(of: "'", with: "'\\''")
        let command = "cd '\(escapedPath)' && claude --resume \(session.id)"

        let script = """
        tell application "iTerm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(command)"
            end tell
        end tell
        """

        runAppleScript(script) { _ in }
    }

    private func runAppleScript(_ source: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)

            DispatchQueue.main.async {
                if let error = error {
                    print("AppleScript error: \(error)")
                    completion(nil)
                } else {
                    completion(result?.stringValue)
                }
            }
        }
    }

    private func loadUsageStats(for targetSession: Session) {
        let targetId = targetSession.id

        DispatchQueue.global(qos: .userInitiated).async {
            // Read-only from SQLite - ConversationView handles syncing
            if let stats = MessageStore.shared.readStats(sessionId: targetId) {
                let info = MessageStore.shared.readSessionInfo(sessionId: targetId)

                DispatchQueue.main.async {
                    // Only update if still viewing the same session
                    guard session.id == targetId else { return }
                    usageStats = stats
                    currentTool = info.lastTool
                }
            }
            // If no SQLite data yet, ConversationView will sync it - we'll get updated via EventBus
        }
    }
}

// MARK: - Supporting Components

struct StatusPill: View {
    let workStatus: Session.WorkStatus
    let currentTool: String?

    private var color: Color {
        switch workStatus {
        case .working: return .green
        case .waiting: return .orange
        case .permission: return .yellow
        case .unknown: return .secondary
        }
    }

    private var icon: String {
        switch workStatus {
        case .working: return "bolt.fill"
        case .waiting: return "clock"
        case .permission: return "lock.fill"
        case .unknown: return "circle"
        }
    }

    private var label: String {
        switch workStatus {
        case .working:
            if let tool = currentTool {
                return tool
            }
            return "Working"
        case .waiting: return "Waiting"
        case .permission: return "Permission"
        case .unknown: return ""
        }
    }

    var body: some View {
        if workStatus != .unknown {
            HStack(spacing: 4) {
                if workStatus == .working {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
        }
    }
}

struct StatChip: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

struct ContextGauge: View {
    let stats: TranscriptUsageStats

    private var progressColor: Color {
        if stats.contextPercentage > 0.9 { return .red }
        if stats.contextPercentage > 0.7 { return .orange }
        return .blue
    }

    var body: some View {
        HStack(spacing: 6) {
            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.1))

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(progressColor)
                        .frame(width: geo.size.width * stats.contextPercentage)
                }
            }
            .frame(width: 40, height: 4)

            Text(stats.formattedContext)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)

            Text("context")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

