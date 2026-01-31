//
//  DashboardView.swift
//  CommandCenter
//
//  Home view showing all sessions organized by project
//

import SwiftUI

struct DashboardView: View {
    let sessions: [Session]
    let onSelectSession: (String) -> Void
    let onOpenQuickSwitcher: () -> Void
    let onOpenPanel: () -> Void

    // Group sessions by project
    private var projectGroups: [ProjectGroup] {
        let grouped = Dictionary(grouping: sessions) { $0.projectPath }

        return grouped.map { path, sessions in
            let projectName = sessions.first?.projectName
                ?? path.components(separatedBy: "/").last
                ?? "Unknown"

            // Sort sessions: active first, then by attention priority, then by last activity
            let sorted = sessions.sorted { a, b in
                // Active sessions before ended
                if a.isActive && !b.isActive { return true }
                if !a.isActive && b.isActive { return false }

                if a.isActive && b.isActive {
                    // Priority order: Working > Needs Attention (permission/question) > Ready
                    let aPriority = attentionPriority(a)
                    let bPriority = attentionPriority(b)
                    if aPriority != bPriority { return aPriority < bPriority }
                    // Same priority: sort by last activity
                    let aTime = a.lastActivityAt ?? a.startedAt ?? .distantPast
                    let bTime = b.lastActivityAt ?? b.startedAt ?? .distantPast
                    return aTime > bTime
                }

                // Both ended: sort by last activity (or end date as fallback)
                let aTime = a.lastActivityAt ?? a.endedAt ?? .distantPast
                let bTime = b.lastActivityAt ?? b.endedAt ?? .distantPast
                return aTime > bTime
            }

            // Priority: 0 = working, 1 = needs attention, 2 = ready
            func attentionPriority(_ session: Session) -> Int {
                if session.workStatus == .working { return 0 }
                switch session.attentionReason {
                case .awaitingPermission, .awaitingQuestion: return 1
                case .awaitingReply: return 2
                case .none: return 3
                }
            }

            return ProjectGroup(
                projectPath: path,
                projectName: projectName,
                sessions: sorted
            )
        }
        .sorted { a, b in
            // Projects with active sessions first
            let aHasActive = a.sessions.contains { $0.isActive }
            let bHasActive = b.sessions.contains { $0.isActive }
            if aHasActive && !bHasActive { return true }
            if !aHasActive && bHasActive { return false }

            // Then by most recent activity
            let aLatest = a.sessions.first?.lastActivityAt ?? a.sessions.first?.startedAt ?? .distantPast
            let bLatest = b.sessions.first?.lastActivityAt ?? b.sessions.first?.startedAt ?? .distantPast
            return aLatest > bLatest
        }
    }

    // Sessions needing immediate attention
    private var attentionSessions: [Session] {
        sessions.filter { $0.needsAttention }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            dashboardHeader

            Divider()
                .foregroundStyle(Color.panelBorder)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Stats summary
                    StatsSummary(sessions: sessions)

                    // Attention banner (if any need attention)
                    if !attentionSessions.isEmpty {
                        attentionBanner
                    }

                    // Project groups
                    ForEach(projectGroups) { group in
                        ProjectSection(
                            group: group,
                            onSelectSession: onSelectSession
                        )
                    }

                    // Empty state
                    if sessions.isEmpty {
                        emptyState
                    }
                }
                .padding(24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color.backgroundPrimary)
    }

    // MARK: - Dashboard Header

    private var dashboardHeader: some View {
        HStack(spacing: 12) {
            // Panel toggle
            Button {
                onOpenPanel()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Toggle panel (⌘1)")

            Text("Command Center")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // Status summary in header
            if !sessions.isEmpty {
                HStack(spacing: 12) {
                    let workingCount = sessions.filter { $0.isActive && $0.workStatus == .working }.count
                    let waitingCount = attentionSessions.count

                    if workingCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.statusWorking)
                                .frame(width: 6, height: 6)
                            Text("\(workingCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text("Working")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if waitingCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.statusWaiting)
                                .frame(width: 6, height: 6)
                            Text("\(waitingCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text("Waiting")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Quick switch button
            Button {
                onOpenQuickSwitcher()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                    Text("Search")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.backgroundSecondary)
    }

    // MARK: - Attention Banner

    private var attentionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.statusWaiting)

                Text("\(attentionSessions.count) session\(attentionSessions.count == 1 ? "" : "s") need\(attentionSessions.count == 1 ? "s" : "") your attention")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }

            // Quick links to attention sessions
            HStack(spacing: 8) {
                ForEach(attentionSessions.prefix(4)) { session in
                    Button {
                        onSelectSession(session.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.workStatus == .permission ? Color.statusPermission : Color.statusWaiting)
                                .frame(width: 6, height: 6)

                            Text(session.customName ?? session.summary ?? "Session")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if attentionSessions.count > 4 {
                    Text("+\(attentionSessions.count - 4) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(Color.statusWaiting.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.statusWaiting.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.backgroundTertiary)
                    .frame(width: 80, height: 80)
                Image(systemName: "terminal")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 8) {
                Text("No Sessions Yet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Start a Claude Code session to see it here")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Project Group Model

struct ProjectGroup: Identifiable {
    let projectPath: String
    let projectName: String
    let sessions: [Session]

    var id: String { projectPath }

    var activeCount: Int {
        sessions.filter { $0.isActive }.count
    }

    var hasAttention: Bool {
        sessions.contains { $0.needsAttention }
    }
}

// MARK: - Project Section

struct ProjectSection: View {
    let group: ProjectGroup
    let onSelectSession: (String) -> Void

    @State private var isExpanded = true
    @State private var showAllEnded = false

    // Separate active and ended sessions
    private var activeSessions: [Session] {
        group.sessions.filter { $0.isActive }
    }

    private var endedSessions: [Session] {
        group.sessions.filter { !$0.isActive }
    }

    // Show max 3 ended by default
    private var visibleEndedSessions: [Session] {
        showAllEnded ? endedSessions : Array(endedSessions.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    // Expand/collapse chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    // Project icon
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    // Project name
                    Text(group.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    // Session count
                    Text("\(group.sessions.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)

                    // Active indicator
                    if group.activeCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(group.hasAttention ? Color.statusWaiting : Color.statusWorking)
                                .frame(width: 6, height: 6)
                            Text("\(group.activeCount) active")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(group.hasAttention ? Color.statusWaiting : Color.statusWorking)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            // Sessions list
            if isExpanded {
                VStack(spacing: 6) {
                    // Active sessions (always shown)
                    ForEach(activeSessions) { session in
                        TaskRow(session: session) {
                            onSelectSession(session.id)
                        }
                    }

                    // Ended sessions (collapsed by default, show max 3)
                    if !endedSessions.isEmpty {
                        // Divider between active and ended
                        if !activeSessions.isEmpty {
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color.surfaceBorder.opacity(0.5))
                                    .frame(height: 1)
                                Text("ended")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.quaternary)
                                Rectangle()
                                    .fill(Color.surfaceBorder.opacity(0.5))
                                    .frame(height: 1)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }

                        VStack(spacing: 0) {
                            ForEach(visibleEndedSessions) { session in
                                TaskRow(session: session) {
                                    onSelectSession(session.id)
                                }
                            }
                        }

                        // "Show more" button if there are hidden ended sessions
                        if endedSessions.count > 3 && !showAllEnded {
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    showAllEnded = true
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Show \(endedSessions.count - 3) more ended")
                                        .font(.system(size: 11, weight: .medium))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        } else if showAllEnded && endedSessions.count > 3 {
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    showAllEnded = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Show less")
                                        .font(.system(size: 11, weight: .medium))
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let session: Session
    let onSelect: () -> Void

    @State private var isHovering = false

    private var statusColor: Color {
        guard session.isActive else { return .secondary.opacity(0.4) }
        // Use attention reason for more nuanced colors
        switch session.attentionReason {
        case .none:
            return session.workStatus == .working ? .statusWorking : .secondary
        case .awaitingReply:
            return .blue.opacity(0.8)  // Ready/done - low urgency
        case .awaitingPermission:
            return .statusPermission   // Yellow - needs action
        case .awaitingQuestion:
            return .statusWaiting      // Orange - Claude asked something
        }
    }

    private var statusLabel: String {
        guard session.isActive else { return "Ended" }
        // Use attention reason for more specific labels
        switch session.attentionReason {
        case .none:
            return session.workStatus == .working ? "Working" : "Active"
        case .awaitingReply:
            return "Ready"
        case .awaitingPermission:
            if let tool = session.pendingToolName {
                return tool
            }
            return "Permission"
        case .awaitingQuestion:
            return "Question"
        }
    }

    private var statusIcon: String {
        guard session.isActive else { return "checkmark.circle" }
        switch session.attentionReason {
        case .none:
            return session.workStatus == .working ? "bolt.fill" : "circle"
        case .awaitingReply:
            return "checkmark.circle"
        case .awaitingPermission:
            return "lock.fill"
        case .awaitingQuestion:
            return "questionmark.bubble"
        }
    }

    private var taskTitle: String {
        session.customName ?? session.summary ?? "Session"
    }

    var body: some View {
        Button(action: onSelect) {
            if session.isActive {
                activeRowContent
            } else {
                endedRowContent
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                let command = "claude --resume \(session.id)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Active Row (Rich)

    private var activeRowContent: some View {
        HStack(spacing: 12) {
            // Left: Status indicator
            VStack {
                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)

                    if session.workStatus == .working {
                        Circle()
                            .stroke(statusColor.opacity(0.4), lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                }
            }
            .frame(width: 18)

            // Center: Title + stats
            VStack(alignment: .leading, spacing: 5) {
                // Task title
                Text(taskTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Stats row
                HStack(spacing: 10) {
                    // Current tool (if working)
                    if let tool = session.lastTool, session.workStatus == .working {
                        HStack(spacing: 4) {
                            Image(systemName: toolIcon(for: tool))
                                .font(.system(size: 10, weight: .medium))
                            Text(tool)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(statusColor)
                    }

                    // Duration
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(session.formattedDuration)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.tertiary)

                    // Tool count
                    if session.toolCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hammer")
                                .font(.system(size: 10))
                            Text("\(session.toolCount)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.tertiary)
                    }

                    // Branch
                    if let branch = session.branch, !branch.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(branch)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.orange.opacity(0.8))
                    }
                }
            }

            Spacer()

            // Right: Status badge + model
            HStack(spacing: 8) {
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15), in: Capsule())

                ModelBadgeMini(model: session.model)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(isHovering ? 0.25 : 0.1), lineWidth: 1)
        )
    }

    // MARK: - Ended Row (Compact)

    private var endedRowContent: some View {
        HStack(spacing: 12) {
            // Status dot (aligned with active row)
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .frame(width: 18)

            // Task title
            Text(taskTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            // Duration
            Text(session.formattedDuration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)

            // Tool count
            if session.toolCount > 0 {
                Text("\(session.toolCount) tools")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.quaternary)
            }

            // Ended badge
            Text("Ended")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.surfaceBorder.opacity(0.5), in: Capsule())

            ModelBadgeMini(model: session.model)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.surfaceHover : Color.clear)
        )
    }

    // MARK: - Helpers

    private func toolIcon(for tool: String) -> String {
        switch tool.lowercased() {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "write": return "square.and.pencil"
        case "bash": return "terminal"
        case "glob": return "folder.badge.gearshape"
        case "grep": return "magnifyingglass"
        case "task": return "person.2"
        case "webfetch": return "globe"
        case "websearch": return "magnifyingglass.circle"
        default: return "gearshape"
        }
    }
}

// MARK: - Preview

#Preview {
    DashboardView(
        sessions: [
            Session(
                id: "1",
                projectPath: "/Users/rob/Developer/claude-dashboard",
                projectName: "claude-dashboard",
                branch: "main",
                model: "claude-opus-4-5-20251101",
                summary: "SwiftUI macOS dashboard with navigation",
                status: .active,
                workStatus: .working,
                startedAt: Date().addingTimeInterval(-1380),
                toolCount: 251
            ),
            Session(
                id: "2",
                projectPath: "/Users/rob/Developer/claude-dashboard",
                projectName: "claude-dashboard",
                branch: "main",
                model: "claude-sonnet-4-20250514",
                summary: "Tool call data enrichment & read card UI",
                status: .active,
                workStatus: .waiting,
                startedAt: Date().addingTimeInterval(-1740),
                toolCount: 52
            ),
            Session(
                id: "3",
                projectPath: "/Users/rob/Developer/claude-dashboard",
                projectName: "claude-dashboard",
                model: "claude-sonnet-4-20250514",
                summary: "Quick Capture System for In-Progress sessions",
                status: .active,
                workStatus: .waiting,
                startedAt: Date().addingTimeInterval(-1500),
                toolCount: 25
            ),
            Session(
                id: "4",
                projectPath: "/Users/rob/Developer/vizzly",
                projectName: "vizzly",
                model: "claude-sonnet-4-20250514",
                summary: "Vizzly Enterprise Lunch & Learn presentation",
                status: .active,
                workStatus: .permission,
                startedAt: Date().addingTimeInterval(-540),
                toolCount: 9
            ),
            Session(
                id: "5",
                projectPath: "/Users/rob/Developer/claude-dashboard",
                projectName: "claude-dashboard",
                model: "claude-opus-4-5-20251101",
                summary: "Message truncation & conversation view fixes",
                status: .ended,
                workStatus: .unknown,
                startedAt: Date().addingTimeInterval(-7200),
                endedAt: Date().addingTimeInterval(-3600),
                toolCount: 68
            ),
            Session(
                id: "6",
                projectPath: "/Users/rob/Developer/vizzly",
                projectName: "vizzly",
                model: "claude-haiku-3-5-20241022",
                status: .ended,
                workStatus: .unknown,
                startedAt: Date().addingTimeInterval(-10800),
                endedAt: Date().addingTimeInterval(-7200),
                toolCount: 15
            )
        ],
        onSelectSession: { _ in },
        onOpenQuickSwitcher: {},
        onOpenPanel: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Empty") {
    DashboardView(
        sessions: [],
        onSelectSession: { _ in },
        onOpenQuickSwitcher: {},
        onOpenPanel: {}
    )
    .frame(width: 900, height: 500)
}
