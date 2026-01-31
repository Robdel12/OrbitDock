//
//  MenuBarView.swift
//  OrbitDock
//

import SwiftUI

struct MenuBarView: View {
    @Environment(DatabaseManager.self) private var database
    @State private var sessions: [Session] = []

    var activeSessions: [Session] {
        sessions.filter { $0.isActive }
    }

    var recentSessions: [Session] {
        sessions.filter { !$0.isActive }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("OrbitDock")
                        .font(.system(size: 13, weight: .semibold))
                }

                Spacer()

                if !activeSessions.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.statusWorking)
                            .frame(width: 6, height: 6)
                        Text("\(activeSessions.count)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.statusWorking)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // Subscription Usage
            MenuBarUsageSection()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !activeSessions.isEmpty {
                        sectionHeader("Active")

                        ForEach(activeSessions) { session in
                            MenuBarSessionRow(session: session, isActive: true)
                        }
                    }

                    if !recentSessions.isEmpty {
                        if !activeSessions.isEmpty {
                            Divider()
                                .padding(.vertical, 8)
                        }

                        sectionHeader("Recent")

                        ForEach(recentSessions) { session in
                            MenuBarSessionRow(session: session, isActive: false)
                        }
                    }

                    if sessions.isEmpty {
                        emptyView
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)

            Divider()

            // Footer
            HStack {
                Button {
                    if let window = NSApplication.shared.windows.first(where: {
                        $0.title.contains("OrbitDock") || $0.contentView is NSHostingView<ContentView>
                    }) {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11))
                        Text("Open Window")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    loadSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .onAppear {
            loadSessions()
            database.onDatabaseChanged = { [self] in
                loadSessions()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No sessions")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func loadSessions() {
        sessions = database.fetchSessions()
    }
}

struct MenuBarSessionRow: View {
    let session: Session
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            ZStack {
                if isActive {
                    Circle()
                        .fill(Color.statusWorking.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .blur(radius: 3)
                }
                Circle()
                    .fill(isActive ? Color.statusWorking : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let branch = session.branch, !branch.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(branch)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Text(session.formattedDuration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            ModelBadge(model: session.model)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isHovering ? Color.primary.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovering = $0 }
    }
}

#Preview {
    MenuBarView()
        .environment(DatabaseManager.shared)
}
