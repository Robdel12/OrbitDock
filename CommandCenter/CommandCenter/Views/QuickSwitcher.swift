//
//  QuickSwitcher.swift
//  CommandCenter
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
        QuickCommand.sessionCommands(
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
        filteredSessions.filter { $0.needsAttention }
    }

    private var working: [Session] {
        filteredSessions.filter { $0.isActive && $0.workStatus == .working }
    }

    private var recent: [Session] {
        filteredSessions.filter { !$0.isActive }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    // Flat list for keyboard navigation (matches display order)
    private var allVisibleSessions: [Session] {
        working + needsAttention + recent
    }

    // Total items for navigation
    private var totalItems: Int {
        isCommandMode ? filteredCommands.count : allVisibleSessions.count
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
                    if selectedIndex < allVisibleSessions.count {
                        contextSession = allVisibleSessions[selectedIndex]
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
        .frame(width: 520)
        .background(Color.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.panelBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 15)
    }

    // MARK: - Commands View

    private var commandsView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Context session indicator
                if let session = contextSession ?? allVisibleSessions.first {
                    HStack(spacing: 8) {
                        Text("Acting on:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)

                        Text(session.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.backgroundTertiary.opacity(0.3))
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
        .frame(maxHeight: 340)
    }

    private func commandRow(command: QuickCommand, index: Int) -> some View {
        Button {
            executeCommand(command)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: command.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Text(command.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if command.requiresSession {
                    Text("on selected")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var commandEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)

            Text("No commands found")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
        HStack(spacing: 12) {
            Image(systemName: isCommandMode ? "command" : "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isCommandMode ? Color.accentColor : Color.secondary)

            TextField(isCommandMode ? "Search commands..." : "Search agents... (type > for commands)", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Text("⌘K")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - Results View

    private var resultsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !working.isEmpty {
                        sectionView(
                            title: "WORKING",
                            sessions: working,
                            color: .statusWorking,
                            icon: "bolt.fill",
                            startIndex: 0
                        )
                    }

                    if !needsAttention.isEmpty {
                        sectionView(
                            title: "NEEDS ATTENTION",
                            sessions: needsAttention,
                            color: .statusWaiting,
                            icon: "exclamationmark.circle.fill",
                            startIndex: working.count
                        )
                    }

                    if !recent.isEmpty {
                        sectionView(
                            title: "RECENT",
                            sessions: recent,
                            color: .secondary,
                            icon: "clock",
                            startIndex: working.count + needsAttention.count
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 340)
            .onChange(of: selectedIndex) { _, newIndex in
                proxy.scrollTo("row-\(newIndex)", anchor: .center)
            }
        }
    }

    // MARK: - Section View

    private func sectionView(title: String, sessions: [Session], color: Color, icon: String, startIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header - improved contrast
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)

                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color.opacity(0.9))
                    .tracking(0.5)

                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Rows
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
            HStack(spacing: 12) {
                // Status dot
                ZStack {
                    Circle()
                        .fill(statusColor(for: session))
                        .frame(width: 8, height: 8)

                    if session.isActive && session.workStatus == .working {
                        Circle()
                            .stroke(statusColor(for: session).opacity(0.4), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                }
                .frame(width: 14, height: 14)

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // Project name
                        Text(projectName(for: session))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("/")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(.quaternary)

                        // Agent name
                        Text(agentName(for: session))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    // Branch + status
                    HStack(spacing: 8) {
                        if let branch = session.branch {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8, weight: .medium))
                                Text(branch)
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.orange.opacity(0.8))
                        }

                        if session.isActive {
                            Text(statusLabel(for: session))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(statusColor(for: session))
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
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)

            VStack(spacing: 4) {
                Text("No agents found")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if !searchText.isEmpty {
                    Text("Try a different search term")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Footer

    private var footerHint: some View {
        HStack(spacing: 10) {
            if isCommandMode {
                hintItem(keys: "↑↓", label: "Navigate")
                hintItem(keys: "↵", label: "Execute")
                hintItem(keys: "⌫", label: "Back")
            } else {
                hintItem(keys: ">", label: "Commands")
                hintItem(keys: "↑↓", label: "Navigate")
                hintItem(keys: "↵", label: "Select")
                hintItem(keys: "⌘R", label: "Rename")
            }
            hintItem(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.backgroundTertiary.opacity(0.5))
    }

    private func hintItem(keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
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
            // Select session
            guard selectedIndex < allVisibleSessions.count else { return }
            let session = allVisibleSessions[selectedIndex]
            onSelect(session.id)
        }
    }

    private func renameCurrentSelection() {
        guard !isCommandMode else { return }
        guard selectedIndex < allVisibleSessions.count else { return }
        let session = allVisibleSessions[selectedIndex]
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
            onClose: {}
        )
    }
    .frame(width: 700, height: 500)
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
