//
//  QuickSwitcher.swift
//  OrbitDock
//
//  Command palette for switching agents and executing actions (⌘K)
//  - No prefix: Search sessions
//  - ">" prefix: Search commands
//

import SwiftUI

// MARK: - Command Definition

struct QuickCommand: Identifiable {
    let id: String
    let name: String
    let icon: String
    let shortcut: String?
    let requiresSession: Bool
    let action: (Session?) -> Void

    static func sessionCommands(
        onRename: @escaping (Session) -> Void,
        onFocus: @escaping (Session) -> Void,
        onOpenFinder: @escaping (Session) -> Void,
        onCopyResume: @escaping (Session) -> Void
    ) -> [QuickCommand] {
        [
            QuickCommand(
                id: "rename",
                name: "Rename Session",
                icon: "pencil",
                shortcut: "⌘R",
                requiresSession: true,
                action: { session in if let s = session { onRename(s) } }
            ),
            QuickCommand(
                id: "focus",
                name: "Focus Terminal",
                icon: "terminal",
                shortcut: nil,
                requiresSession: true,
                action: { session in if let s = session { onFocus(s) } }
            ),
            QuickCommand(
                id: "finder",
                name: "Open in Finder",
                icon: "folder",
                shortcut: nil,
                requiresSession: true,
                action: { session in if let s = session { onOpenFinder(s) } }
            ),
            QuickCommand(
                id: "copy",
                name: "Copy Resume Command",
                icon: "doc.on.doc",
                shortcut: nil,
                requiresSession: true,
                action: { session in if let s = session { onCopyResume(s) } }
            )
        ]
    }
}

// MARK: - Quick Switcher

struct QuickSwitcher: View {
    @Environment(DatabaseManager.self) private var database
    let sessions: [Session]
    let onSelect: (String) -> Void
    let onGoToDashboard: () -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var renamingSession: Session?
    @State private var renameText = ""
    @State private var contextSession: Session?  // Session selected when entering command mode
    @FocusState private var isSearchFocused: Bool

    // MARK: - Search Mode Detection

    private var isCommandMode: Bool {
        searchText.hasPrefix(">")
    }

    private var commandSearchText: String {
        guard isCommandMode else { return "" }
        return String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private var sessionSearchText: String {
        guard !isCommandMode else { return "" }
        return searchText
    }

    // MARK: - Commands

    private var commands: [QuickCommand] {
        // Global commands (no session required)
        var allCommands: [QuickCommand] = [
            QuickCommand(
                id: "dashboard",
                name: "Go to Dashboard",
                icon: "square.grid.2x2",
                shortcut: "⌘0",
                requiresSession: false,
                action: { _ in
                    onGoToDashboard()
                    onClose()
                }
            )
        ]

        // Session-specific commands
        allCommands += QuickCommand.sessionCommands(
            onRename: { session in
                renameText = session.customName ?? ""
                renamingSession = session
            },
            onFocus: { session in
                focusTerminal(for: session)
                onClose()
            },
            onOpenFinder: { session in
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
                onClose()
            },
            onCopyResume: { session in
                let command = "claude --resume \(session.id)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                onClose()
            }
        )

        return allCommands
    }

    private var filteredCommands: [QuickCommand] {
        guard isCommandMode else { return [] }
        let query = commandSearchText.lowercased()
        if query.isEmpty { return commands }
        return commands.filter { $0.name.lowercased().contains(query) }
    }

    // MARK: - Sessions

    private var filteredSessions: [Session] {
        guard !isCommandMode else { return [] }
        guard !sessionSearchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.displayName.localizedCaseInsensitiveContains(sessionSearchText) ||
            $0.projectPath.localizedCaseInsensitiveContains(sessionSearchText) ||
            ($0.summary ?? "").localizedCaseInsensitiveContains(sessionSearchText) ||
            ($0.customName ?? "").localizedCaseInsensitiveContains(sessionSearchText) ||
            ($0.branch ?? "").localizedCaseInsensitiveContains(sessionSearchText)
        }
    }

    private var needsAttention: [Session] {
        // Permission or question - actually needs action
        filteredSessions.filter { $0.needsAttention }
    }

    private var working: [Session] {
        filteredSessions.filter { $0.isActive && $0.workStatus == .working }
    }

    private var ready: [Session] {
        // Awaiting reply - Claude is done, low urgency
        filteredSessions.filter { $0.isActive && $0.isReady }
    }

    private var recent: [Session] {
        filteredSessions.filter { !$0.isActive }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    // Flat list for keyboard navigation (matches display order)
    private var allVisibleSessions: [Session] {
        working + needsAttention + ready + recent
    }

    // Total items for navigation (includes dashboard row when not in command mode)
    private var totalItems: Int {
        isCommandMode ? filteredCommands.count : allVisibleSessions.count + 1  // +1 for dashboard row
    }

    var body: some View {
        mainContent
            .onAppear {
                isSearchFocused = true
                selectedIndex = 0
            }
            .modifier(KeyboardNavigationModifier(
                onMoveUp: { moveSelection(by: -1) },
                onMoveDown: { moveSelection(by: 1) },
                onMoveToFirst: { selectedIndex = 0 },
                onMoveToLast: {
                    if totalItems > 0 { selectedIndex = totalItems - 1 }
                },
                onSelect: { selectCurrent() },
                onRename: { renameCurrentSelection() }
            ))
            .onChange(of: searchText) { oldValue, newValue in
                selectedIndex = 0  // Reset selection when search changes

                // Track context session when entering command mode
                let wasCommandMode = oldValue.hasPrefix(">")
                let isNowCommandMode = newValue.hasPrefix(">")
                if !wasCommandMode && isNowCommandMode {
                    // Entering command mode - save current session context
                    // Account for dashboard row at index 0 (session indices start at 1)
                    let sessionIndex = selectedIndex > 0 ? selectedIndex - 1 : 0
                    if sessionIndex < allVisibleSessions.count {
                        contextSession = allVisibleSessions[sessionIndex]
                    } else {
                        contextSession = allVisibleSessions.first
                    }
                } else if wasCommandMode && !isNowCommandMode {
                    // Leaving command mode - clear context
                    contextSession = nil
                }
            }
            .sheet(item: $renamingSession) { session in
                RenameSessionSheet(
                    session: session,
                    initialText: renameText,
                    onSave: { newName in
                        database.updateCustomName(
                            sessionId: session.id,
                            name: newName.isEmpty ? nil : newName
                        )
                        renamingSession = nil
                    },
                    onCancel: {
                        renamingSession = nil
                    }
                )
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()
                .foregroundStyle(Color.panelBorder)

            if isCommandMode {
                commandsView
            } else if allVisibleSessions.isEmpty {
                emptyState
            } else {
                resultsView
            }

            footerHint
        }
        .frame(width: 640)
        .background(Color.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.panelBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
    }

    // MARK: - Commands View

    private var commandsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Context session indicator
                if let session = contextSession ?? allVisibleSessions.first {
                    HStack(spacing: 10) {
                        Image(systemName: "target")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accent.opacity(0.6))

                        Text("Acting on")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)

                        Text(session.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.backgroundTertiary.opacity(0.4))
                }

                if filteredCommands.isEmpty {
                    commandEmptyState
                } else {
                    ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command: command, index: index)
                            .id("cmd-\(index)")
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 480)
    }

    private func commandRow(command: QuickCommand, index: Int) -> some View {
        Button {
            executeCommand(command)
        } label: {
            HStack(spacing: 14) {
                // Icon in colored container
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accent.opacity(0.1))
                        .frame(width: 32, height: 32)

                    Image(systemName: command.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accent.opacity(0.8))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(command.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    if command.requiresSession {
                        Text("Applies to selected session")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedIndex == index ? Color.accent.opacity(0.15) : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var commandEmptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.backgroundTertiary)
                    .frame(width: 56, height: 56)

                Image(systemName: "command")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 4) {
                Text("No commands found")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Try a different search term")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func executeCommand(_ command: QuickCommand) {
        if command.requiresSession {
            // Use the context session (selected when entering command mode) or first session
            let session = contextSession ?? allVisibleSessions.first
            guard session != nil else { return }
            command.action(session)
        } else {
            command.action(nil)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: isCommandMode ? "command" : "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isCommandMode ? Color.accent : Color.secondary)
                .frame(width: 24)

            TextField(isCommandMode ? "Search commands..." : "Search agents... (type > for commands)", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: - Results View

    private var resultsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Dashboard row (always first, index 0)
                    dashboardRow
                        .id("row-0")

                    // Sessions start at index 1
                    if !working.isEmpty {
                        sectionView(
                            title: "WORKING",
                            sessions: working,
                            color: .statusWorking,
                            icon: "bolt.fill",
                            startIndex: 1  // Offset by 1 for dashboard row
                        )
                    }

                    if !needsAttention.isEmpty {
                        sectionView(
                            title: "NEEDS ATTENTION",
                            sessions: needsAttention,
                            color: .statusWaiting,
                            icon: "exclamationmark.circle.fill",
                            startIndex: working.count + 1
                        )
                    }

                    if !ready.isEmpty {
                        sectionView(
                            title: "READY",
                            sessions: ready,
                            color: .statusSuccess,
                            icon: "checkmark.circle",
                            startIndex: working.count + needsAttention.count + 1
                        )
                    }

                    if !recent.isEmpty {
                        sectionView(
                            title: "RECENT",
                            sessions: recent,
                            color: .secondary,
                            icon: "clock",
                            startIndex: working.count + needsAttention.count + ready.count + 1
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 480)
            .onChange(of: selectedIndex) { _, newIndex in
                proxy.scrollTo("row-\(newIndex)", anchor: .center)
            }
        }
    }

    // Quick Actions section at the top
    private var dashboardRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            Text("QUICK ACTIONS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Button {
                onGoToDashboard()
                onClose()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accent.opacity(0.15))
                            .frame(width: 32, height: 32)

                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dashboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("View all agents overview")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text("⌘0")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedIndex == 0 ? Color.accent.opacity(0.12) : Color.backgroundTertiary.opacity(0.4))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            // Divider before sessions
            Rectangle()
                .fill(Color.panelBorder)
                .frame(height: 1)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
    }

    // MARK: - Section View

    private func sectionView(title: String, sessions: [Session], color: Color, icon: String, startIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .tracking(0.8)

                // Count badge
                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Session Rows
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                let globalIndex = startIndex + index
                switcherRow(session: session, index: globalIndex)
                    .id("row-\(globalIndex)")
            }
        }
    }

    // MARK: - Switcher Row

    private func switcherRow(session: Session, index: Int) -> some View {
        Button {
            onSelect(session.id)
        } label: {
            HStack(spacing: 14) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(statusColor(for: session))
                        .frame(width: 10, height: 10)

                    if session.isActive && session.workStatus == .working {
                        Circle()
                            .stroke(statusColor(for: session).opacity(0.3), lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 20, height: 20)

                // Content - stacked layout for better hierarchy
                VStack(alignment: .leading, spacing: 4) {
                    // Project name + branch (top line, smaller)
                    HStack(spacing: 8) {
                        Text(projectName(for: session))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        if let branch = session.branch {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9))
                                Text(branch)
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(Color.accent.opacity(0.7))
                        }
                    }

                    // Agent name (main line, prominent)
                    HStack(spacing: 10) {
                        Text(agentName(for: session))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        // Status badge
                        if session.isActive {
                            Text(statusLabel(for: session))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(statusColor(for: session))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusColor(for: session).opacity(0.12), in: Capsule())
                        } else if let endedAt = session.endedAt {
                            Text(endedAt, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                // Model badge
                ModelBadgeMini(model: session.model)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedIndex == index ? Color.accent.opacity(0.15) : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.backgroundTertiary)
                    .frame(width: 56, height: 56)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 4) {
                Text("No agents found")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                if !searchText.isEmpty {
                    Text("Try a different search term")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Footer

    private var footerHint: some View {
        HStack(spacing: 0) {
            if isCommandMode {
                hintItem(keys: "↑↓", label: "Navigate")
                footerDivider
                hintItem(keys: "↵", label: "Execute")
                footerDivider
                hintItem(keys: "⌫", label: "Back")
            } else {
                hintItem(keys: ">", label: "Commands")
                footerDivider
                hintItem(keys: "↑↓", label: "Navigate")
                footerDivider
                hintItem(keys: "↵", label: "Select")
                footerDivider
                hintItem(keys: "⌘R", label: "Rename")
            }
            footerDivider
            hintItem(keys: "esc", label: "Close")

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.backgroundTertiary.opacity(0.3))
    }

    private var footerDivider: some View {
        Rectangle()
            .fill(Color.panelBorder)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 12)
    }

    private func hintItem(keys: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func moveSelection(by delta: Int) {
        guard totalItems > 0 else { return }

        let newIndex = selectedIndex + delta
        if newIndex < 0 {
            selectedIndex = totalItems - 1
        } else if newIndex >= totalItems {
            selectedIndex = 0
        } else {
            selectedIndex = newIndex
        }
    }

    private func selectCurrent() {
        if isCommandMode {
            // Execute command
            guard selectedIndex < filteredCommands.count else { return }
            let command = filteredCommands[selectedIndex]
            executeCommand(command)
        } else {
            // Index 0 is dashboard
            if selectedIndex == 0 {
                onGoToDashboard()
                onClose()
                return
            }

            // Session indices are offset by 1
            let sessionIndex = selectedIndex - 1
            guard sessionIndex < allVisibleSessions.count else { return }
            let session = allVisibleSessions[sessionIndex]
            onSelect(session.id)
        }
    }

    private func renameCurrentSelection() {
        guard !isCommandMode else { return }
        guard selectedIndex > 0 else { return }  // Can't rename dashboard
        let sessionIndex = selectedIndex - 1  // Offset by 1 for dashboard row
        guard sessionIndex < allVisibleSessions.count else { return }
        let session = allVisibleSessions[sessionIndex]
        renameText = session.customName ?? ""
        renamingSession = session
    }

    private func focusTerminal(for session: Session) {
        if session.isActive {
            // Try to focus existing terminal
            if let terminalId = session.terminalSessionId, !terminalId.isEmpty,
               session.terminalApp == "iTerm.app" {
                let script = """
                tell application "iTerm2"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aSession in sessions of aTab
                                try
                                    if unique ID of aSession contains "\(terminalId)" then
                                        select aTab
                                        select aSession
                                        set index of aWindow to 1
                                        activate
                                        return
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
                runAppleScript(script)
            }
        } else {
            // Open new terminal with resume command
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
            runAppleScript(script)
        }
    }

    private func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }
    }

    private func statusColor(for session: Session) -> Color {
        guard session.isActive else { return .secondary.opacity(0.3) }
        switch session.workStatus {
        case .working: return .statusWorking
        case .waiting: return .statusWaiting
        case .permission: return .statusPermission
        case .unknown: return .secondary
        }
    }

    private func statusLabel(for session: Session) -> String {
        switch session.workStatus {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .permission: return "Permission"
        case .unknown: return ""
        }
    }

    private func projectName(for session: Session) -> String {
        session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
    }

    private func agentName(for session: Session) -> String {
        session.customName ?? session.summary ?? "Session"
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.opacity(0.5)
            .ignoresSafeArea()

        QuickSwitcher(
            sessions: [
                Session(
                    id: "1",
                    projectPath: "/Users/rob/Developer/vizzly-cli",
                    projectName: "vizzly-cli",
                    branch: "feat/auth",
                    model: "claude-opus-4-5-20251101",
                    contextLabel: "Auth refactor",
                    transcriptPath: nil,
                    status: .active,
                    workStatus: .working,
                    startedAt: Date(),
                    endedAt: nil,
                    endReason: nil,
                    totalTokens: 0,
                    totalCostUSD: 0,
                    lastActivityAt: nil,
                    lastTool: nil,
                    lastToolAt: nil,
                    promptCount: 0,
                    toolCount: 0,
                    terminalSessionId: nil,
                    terminalApp: nil
                ),
                Session(
                    id: "2",
                    projectPath: "/Users/rob/Developer/backchannel",
                    projectName: "backchannel",
                    branch: "main",
                    model: "claude-sonnet-4-20250514",
                    contextLabel: "API review",
                    transcriptPath: nil,
                    status: .active,
                    workStatus: .waiting,
                    startedAt: Date(),
                    endedAt: nil,
                    endReason: nil,
                    totalTokens: 0,
                    totalCostUSD: 0,
                    lastActivityAt: nil,
                    lastTool: nil,
                    lastToolAt: nil,
                    promptCount: 0,
                    toolCount: 0,
                    terminalSessionId: nil,
                    terminalApp: nil
                ),
                Session(
                    id: "3",
                    projectPath: "/Users/rob/Developer/docs",
                    projectName: "docs",
                    branch: "main",
                    model: "claude-haiku-3-5-20241022",
                    contextLabel: nil,
                    transcriptPath: nil,
                    status: .ended,
                    workStatus: .unknown,
                    startedAt: Date().addingTimeInterval(-7200),
                    endedAt: Date().addingTimeInterval(-3600),
                    endReason: nil,
                    totalTokens: 0,
                    totalCostUSD: 0,
                    lastActivityAt: nil,
                    lastTool: nil,
                    lastToolAt: nil,
                    promptCount: 0,
                    toolCount: 0,
                    terminalSessionId: nil,
                    terminalApp: nil
                )
            ],
            onSelect: { _ in },
            onGoToDashboard: {},
            onClose: {}
        )
    }
    .frame(width: 800, height: 600)
}

// MARK: - Keyboard Navigation Modifier

struct KeyboardNavigationModifier: ViewModifier {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onMoveToFirst: () -> Void
    let onMoveToLast: () -> Void
    let onSelect: () -> Void
    let onRename: () -> Void

    func body(content: Content) -> some View {
        content
            // Arrow keys
            .onKeyPress(keys: [.upArrow]) { _ in
                onMoveUp()
                return .handled
            }
            .onKeyPress(keys: [.downArrow]) { _ in
                onMoveDown()
                return .handled
            }
            // Enter to select
            .onKeyPress(keys: [.return]) { _ in
                onSelect()
                return .handled
            }
            // Handle all other keys for Emacs bindings and ⌘R
            .onKeyPress { keyPress in
                // Emacs: C-p (previous)
                if keyPress.key == "p" && keyPress.modifiers.contains(.control) {
                    onMoveUp()
                    return .handled
                }
                // Emacs: C-n (next)
                if keyPress.key == "n" && keyPress.modifiers.contains(.control) {
                    onMoveDown()
                    return .handled
                }
                // Emacs: C-a (first)
                if keyPress.key == "a" && keyPress.modifiers.contains(.control) {
                    onMoveToFirst()
                    return .handled
                }
                // Emacs: C-e (last)
                if keyPress.key == "e" && keyPress.modifiers.contains(.control) {
                    onMoveDown()
                    return .handled
                }
                // ⌘R to rename
                if keyPress.key == "r" && keyPress.modifiers.contains(.command) {
                    onRename()
                    return .handled
                }
                return .ignored
            }
    }
}
