//
//  ContentView.swift
//  CommandCenter
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(DatabaseManager.self) private var database
    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var statusFilter: Session.SessionStatus? = nil
    @State private var searchText = ""
    @State private var refreshTimer: Timer?

    var filteredSessions: [Session] {
        var result = sessions

        if let filter = statusFilter {
            result = result.filter { $0.status == filter }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.projectPath.localizedCaseInsensitiveContains(searchText) ||
                ($0.branch ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.contextLabel ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var activeSessions: [Session] {
        filteredSessions.filter { $0.isActive }
    }

    var endedSessions: [Session] {
        filteredSessions.filter { !$0.isActive }
    }

    var workingSessions: [Session] {
        sessions.filter { $0.isActive && $0.workStatus == .working }
    }

    var waitingSessions: [Session] {
        sessions.filter { $0.needsAttention }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            detailContent
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                globalStatsBar
            }
        }
        .onAppear {
            loadSessions()
            database.onDatabaseChanged = { [self] in
                loadSessions()
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                loadSessions()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSession)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String,
               let session = sessions.first(where: { $0.id == sessionId }) {
                selectedSession = session
            }
        }
    }

    // MARK: - Global Stats Bar

    private var globalStatsBar: some View {
        HStack(spacing: 20) {
            StatPill(
                icon: "bolt.fill",
                value: "\(workingSessions.count)",
                label: "Working",
                color: workingSessions.isEmpty ? .secondary : .green,
                isActive: !workingSessions.isEmpty
            )

            StatPill(
                icon: "hand.raised.fill",
                value: "\(waitingSessions.count)",
                label: "Waiting",
                color: waitingSessions.isEmpty ? .secondary : .orange,
                isActive: !waitingSessions.isEmpty
            )

            Divider()
                .frame(height: 16)

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .medium))
                Text("\(sessions.filter { isToday($0.startedAt) }.count) today")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10, weight: .medium))
                Text("\(formatMessageCount(UsageManager.shared.totalMessagesThisWeek)) this week")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .help("Total messages this week")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func isToday(_ date: Date?) -> Bool {
        guard let date = date else { return false }
        return Calendar.current.isDateInToday(date)
    }

    private func formatMessageCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Filter tabs
            filterBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()
                .opacity(0.3)

            // Needs attention banner
            if !waitingSessions.isEmpty && statusFilter != .ended {
                needsAttentionBanner
            }

            // Session list
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !activeSessions.isEmpty {
                        sessionSection(title: "Active", sessions: activeSessions, color: .green)
                    }

                    if !endedSessions.isEmpty {
                        sessionSection(title: "Recent", sessions: Array(endedSessions.prefix(25)), color: .secondary)
                    }

                    if filteredSessions.isEmpty {
                        emptyStateView
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search...")
        .background(Color.backgroundPrimary)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach([nil, Session.SessionStatus.active, Session.SessionStatus.ended], id: \.self) { filter in
                FilterPill(
                    title: filterTitle(for: filter),
                    count: filterCount(for: filter),
                    isSelected: statusFilter == filter
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        statusFilter = filter
                    }
                }
            }

            Spacer()

            Button {
                loadSessions()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh sessions")
        }
    }

    // MARK: - Needs Attention Banner

    private var needsAttentionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Needs Attention")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(waitingSessions.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
            }

            VStack(spacing: 4) {
                ForEach(Array(waitingSessions.prefix(3).enumerated()), id: \.element.id) { _, session in
                    AttentionRow(session: session) {
                        selectedSession = session
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.orange.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sessionSection(title: String, sessions: [Session], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.quaternary)
                    .tracking(0.5)

                Text("\(sessions.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(color.opacity(0.8))
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 2)

            ForEach(Array(sessions.enumerated()), id: \.element.id) { _, session in
                SessionRowView(session: session, isSelected: selectedSession?.id == session.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            selectedSession = session
                        }
                    }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)

            VStack(spacing: 6) {
                Text("No Sessions")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Start a Claude Code session\nto see it here")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Detail

    private var detailContent: some View {
        Group {
            if let session = selectedSession {
                SessionDetailView(session: session)
            } else {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(.quaternary.opacity(0.5))
                            .frame(width: 80, height: 80)
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(spacing: 4) {
                        Text("Select a Session")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Choose a session from the sidebar to view details")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func filterTitle(for filter: Session.SessionStatus?) -> String {
        switch filter {
        case nil: return "All"
        case .active: return "Active"
        case .ended: return "Ended"
        case .idle: return "Idle"
        }
    }

    private func filterCount(for filter: Session.SessionStatus?) -> Int {
        switch filter {
        case nil: return sessions.count
        case .active: return sessions.filter { $0.status == .active }.count
        case .ended: return sessions.filter { $0.status == .ended }.count
        case .idle: return sessions.filter { $0.status == .idle }.count
        }
    }

    private func loadSessions() {
        let oldWaitingIds = Set(waitingSessions.map { $0.id })
        sessions = database.fetchSessions()

        // Check for new sessions needing attention and send notifications
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
                    ? AnyShapeStyle(Color.accentColor)
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
