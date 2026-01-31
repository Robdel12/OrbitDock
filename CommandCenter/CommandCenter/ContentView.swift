//
//  ContentView.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI
import Combine

struct ContentView: View {
    @Environment(DatabaseManager.self) private var database
    @State private var sessions: [Session] = []
    @State private var selectedSessionId: String?
    @State private var eventSubscription: AnyCancellable?

    // Panel state
    @State private var showAgentPanel = false
    @State private var showQuickSwitcher = false

    // Resolve ID to fresh session object from current sessions array
    private var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var workingSessions: [Session] {
        sessions.filter { $0.isActive && $0.workStatus == .working }
    }

    var waitingSessions: [Session] {
        sessions.filter { $0.needsAttention }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content (conversation-first)
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Left panel overlay
            if showAgentPanel {
                HStack(spacing: 0) {
                    AgentListPanel(
                        sessions: sessions,
                        selectedSessionId: selectedSessionId,
                        onSelectSession: { id in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                selectedSessionId = id
                            }
                        },
                        onClose: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showAgentPanel = false
                            }
                        }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    // Click-away area
                    Color.black.opacity(0.3)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showAgentPanel = false
                            }
                        }
                }
                .transition(.opacity)
            }

            // Quick switcher overlay
            if showQuickSwitcher {
                quickSwitcherOverlay
            }
        }
        .background(Color.backgroundPrimary)
        .onAppear {
            loadSessions()
            setupEventSubscription()
            // Dashboard is now the home view - no auto-select needed
        }
        .onDisappear {
            eventSubscription?.cancel()
            eventSubscription = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSession)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                selectedSessionId = sessionId
            }
        }
        // Keyboard shortcuts via focusable + onKeyPress
        .focusable()
        .onKeyPress(keys: [.escape]) { _ in
            if showQuickSwitcher {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    showQuickSwitcher = false
                }
                return .handled
            }
            if showAgentPanel {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showAgentPanel = false
                }
                return .handled
            }
            return .ignored
        }
        // Use toolbar buttons with keyboard shortcuts
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        selectedSessionId = nil
                    }
                } label: {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showAgentPanel.toggle()
                    }
                } label: {
                    Label("Agents", systemImage: "sidebar.left")
                }
                .keyboardShortcut("1", modifiers: .command)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        showQuickSwitcher = true
                    }
                } label: {
                    Label("Quick Switch", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        Group {
            if let session = selectedSession {
                SessionDetailViewNew(
                    session: session,
                    onTogglePanel: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showAgentPanel.toggle()
                        }
                    },
                    onOpenSwitcher: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            showQuickSwitcher = true
                        }
                    },
                    onGoToDashboard: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            selectedSessionId = nil
                        }
                    }
                )
            } else {
                // Dashboard view when no session selected
                DashboardView(
                    sessions: sessions,
                    onSelectSession: { id in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            selectedSessionId = id
                        }
                    },
                    onOpenQuickSwitcher: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            showQuickSwitcher = true
                        }
                    },
                    onOpenPanel: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showAgentPanel = true
                        }
                    }
                )
            }
        }
    }

    // MARK: - Quick Switcher Overlay

    private var quickSwitcherOverlay: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        showQuickSwitcher = false
                    }
                }

            // Quick Switcher
            QuickSwitcher(
                sessions: sessions,
                onSelect: { id in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        selectedSessionId = id
                        showQuickSwitcher = false
                    }
                },
                onGoToDashboard: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        selectedSessionId = nil
                        showQuickSwitcher = false
                    }
                },
                onClose: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        showQuickSwitcher = false
                    }
                }
            )
        }
        .transition(.opacity)
    }

    // MARK: - Setup

    private func setupEventSubscription() {
        eventSubscription = EventBus.shared.sessionUpdated
            .receive(on: DispatchQueue.main)
            .sink { _ in
                loadSessions()
            }

        database.onDatabaseChanged = {
            EventBus.shared.notifyDatabaseChanged()
        }
    }

    private func loadSessions() {
        let oldWaitingIds = Set(waitingSessions.map { $0.id })
        sessions = database.fetchSessions()

        // Check for new sessions needing attention
        for session in waitingSessions {
            if !oldWaitingIds.contains(session.id) {
                NotificationManager.shared.notifyNeedsAttention(session: session)
            }
        }

        // Clear notifications for sessions no longer needing attention
        for oldId in oldWaitingIds {
            if !waitingSessions.contains(where: { $0.id == oldId }) {
                NotificationManager.shared.resetNotificationState(for: oldId)
            }
        }
    }
}

// MARK: - New Session Detail View (Conversation-First)

struct SessionDetailViewNew: View {
    @Environment(DatabaseManager.self) private var database
    let session: Session
    let onTogglePanel: () -> Void
    let onOpenSwitcher: () -> Void
    let onGoToDashboard: () -> Void

    @State private var usageStats = TranscriptUsageStats()
    @State private var currentTool: String?
    @State private var transcriptSubscription: AnyCancellable?
    @State private var terminalActionFailed = false

    var body: some View {
        VStack(spacing: 0) {
            // Compact header
            HeaderView(
                session: session,
                usageStats: usageStats,
                currentTool: currentTool,
                onTogglePanel: onTogglePanel,
                onOpenSwitcher: onOpenSwitcher,
                onFocusTerminal: { openInITerm() },
                onGoToDashboard: onGoToDashboard
            )

            Divider()
                .foregroundStyle(Color.panelBorder)

            // Conversation (hero)
            ConversationView(
                transcriptPath: session.transcriptPath,
                sessionId: session.id,
                isSessionActive: session.isActive,
                workStatus: session.workStatus,
                currentTool: currentTool
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Action bar
            actionBar
        }
        .background(Color.backgroundPrimary)
        .onAppear {
            loadUsageStats()
            setupSubscription()
        }
        .onDisappear {
            transcriptSubscription?.cancel()
        }
        .onChange(of: session.id) { _, _ in
            transcriptSubscription?.cancel()
            loadUsageStats()
            setupSubscription()
        }
        .alert("Terminal Not Found", isPresented: $terminalActionFailed) {
            Button("Open New") { openNewITermWithResume() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Couldn't find the terminal. Open a new iTerm window to resume?")
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            // Primary action
            Button {
                openInITerm()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: session.isActive ? "arrow.up.forward.app" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                    Text(session.isActive ? "Focus" : "Resume")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                copyResumeCommand()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                    Text("Copy cmd")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(.primary.opacity(0.7))
            }
            .buttonStyle(.plain)

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.backgroundSecondary)
    }

    // MARK: - Helpers

    private func setupSubscription() {
        guard let path = session.transcriptPath else { return }
        let targetSession = session

        transcriptSubscription = EventBus.shared.transcriptUpdated
            .filter { $0 == path }
            .receive(on: DispatchQueue.main)
            .sink { [targetSession] _ in
                guard session.id == targetSession.id else { return }
                loadUsageStats()
            }
    }

    private func loadUsageStats() {
        let targetId = session.id

        DispatchQueue.global(qos: .userInitiated).async {
            if let stats = MessageStore.shared.readStats(sessionId: targetId) {
                let info = MessageStore.shared.readSessionInfo(sessionId: targetId)

                DispatchQueue.main.async {
                    guard session.id == targetId else { return }
                    usageStats = stats
                    currentTool = info.lastTool
                }
            }
        }
    }

    private func copyResumeCommand() {
        let command = "claude --resume \(session.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func openInITerm() {
        if session.isActive {
            focusExistingTerminal()
        } else {
            openNewITermWithResume()
        }
    }

    private func focusExistingTerminal() {
        if let terminalId = session.terminalSessionId, !terminalId.isEmpty,
           session.terminalApp == "iTerm.app" {
            focusITermBySessionId(terminalId)
            return
        }
        focusExistingTerminalByPath()
    }

    private func focusITermBySessionId(_ sessionId: String) {
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
                completion(result?.stringValue)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(DatabaseManager.shared)
        .frame(width: 1000, height: 700)
}

// MARK: - Supporting Views

struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(isActive ? 1 : 0.4)

            Text("\(value) \(label)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? color : .secondary)
        }
    }
}

struct FilterPill: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accent)
                    : AnyShapeStyle(Color.backgroundTertiary),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

struct AttentionRow: View {
    let session: Session
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.workStatus == .permission ? Color.yellow : Color.orange)
                    .frame(width: 5, height: 5)

                Text(session.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(session.workStatus == .permission ? "Permission" : "Waiting")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(session.workStatus == .permission ? .yellow : .orange)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.backgroundSecondary)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environment(DatabaseManager.shared)
        .frame(width: 1000, height: 700)
}
