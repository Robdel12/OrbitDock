//
//  SessionRowView.swift
//  CommandCenter
//

import SwiftUI

struct SessionRowView: View {
    let session: Session
    var isSelected: Bool = false

    private var statusColor: Color {
        if !session.isActive { return .secondary.opacity(0.3) }
        switch session.workStatus {
        case .working: return .green
        case .waiting: return .orange
        case .permission: return .yellow
        case .unknown: return .green.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Minimal status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if session.isActive && session.needsAttention {
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                }
                .frame(width: 20)

            // Main content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if session.isActive && session.workStatus != .unknown {
                        CompactStatusBadge(workStatus: session.workStatus)
                    }
                }

                HStack(spacing: 6) {
                    Text(shortenedPath(session.projectPath))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    if let branch = session.branch, !branch.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8, weight: .semibold))
                            Text(branch)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Right side - compact stats
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.formattedDuration)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                if session.toolCount > 0 {
                    Text("\(session.toolCount) tools")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }

            // Model badge - minimal
            CompactModelBadge(model: session.model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.surfaceSelected : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    private func shortenedPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return "~/" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}

// MARK: - Compact Components

struct CompactStatusBadge: View {
    let workStatus: Session.WorkStatus

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
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .permission: return "Permission"
        case .unknown: return ""
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct CompactModelBadge: View {
    let model: String?

    private var displayName: String {
        guard let model = model else { return "—" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return "Claude"
    }

    private var badgeColor: Color {
        guard let model = model else { return .secondary }
        if model.contains("opus") { return .purple }
        if model.contains("sonnet") { return .blue }
        if model.contains("haiku") { return .teal }
        return .secondary
    }

    var body: some View {
        Text(displayName)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Model Badge (Standalone - for detail view)

struct ModelBadge: View {
    let model: String?

    private var displayName: String {
        guard let model = model else { return "—" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return "Claude"
    }

    private var badgeColor: Color {
        guard let model = model else { return .secondary }
        if model.contains("opus") { return .purple }
        if model.contains("sonnet") { return .blue }
        if model.contains("haiku") { return .teal }
        return .secondary
    }

    var body: some View {
        Text(displayName)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Work Status Badge (Standalone - legacy support)

struct WorkStatusBadge: View {
    let workStatus: Session.WorkStatus

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
        case .waiting: return "hand.raised.fill"
        case .permission: return "lock.fill"
        case .unknown: return "circle"
        }
    }

    private var label: String {
        switch workStatus {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .permission: return "Permission"
        case .unknown: return ""
        }
    }

    var body: some View {
        if workStatus != .unknown {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
        }
    }
}

#Preview {
    VStack(spacing: 2) {
        SessionRowView(session: Session(
            id: "test-123",
            projectPath: "/Users/rob/Developer/vizzly-cli",
            projectName: "vizzly-cli",
            branch: "feat/plugin-git-api",
            model: "claude-opus-4-5-20251101",
            contextLabel: nil,
            transcriptPath: nil,
            status: .active,
            workStatus: .working,
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: nil,
            endReason: nil,
            totalTokens: 15000,
            totalCostUSD: 0.45,
            lastActivityAt: Date(),
            lastTool: "Edit",
            lastToolAt: Date(),
            promptCount: 12,
            toolCount: 45
        ), isSelected: true)

        SessionRowView(session: Session(
            id: "test-456",
            projectPath: "/Users/rob/Developer/backchannel",
            projectName: "backchannel",
            branch: "main",
            model: "claude-sonnet-4-20250514",
            contextLabel: nil,
            transcriptPath: nil,
            status: .active,
            workStatus: .waiting,
            startedAt: Date().addingTimeInterval(-1800),
            endedAt: nil,
            endReason: nil,
            totalTokens: 8500,
            totalCostUSD: 0.12,
            lastActivityAt: Date().addingTimeInterval(-300),
            lastTool: nil,
            lastToolAt: nil,
            promptCount: 5,
            toolCount: 23
        ))

        SessionRowView(session: Session(
            id: "test-789",
            projectPath: "/Users/rob/Developer/marketing",
            projectName: "marketing",
            branch: nil,
            model: "claude-sonnet-4-20250514",
            contextLabel: nil,
            transcriptPath: nil,
            status: .ended,
            workStatus: .unknown,
            startedAt: Date().addingTimeInterval(-7200),
            endedAt: Date().addingTimeInterval(-3600),
            endReason: "exit",
            totalTokens: 3200,
            totalCostUSD: 0.08,
            lastActivityAt: Date().addingTimeInterval(-3600),
            lastTool: nil,
            lastToolAt: nil,
            promptCount: 3,
            toolCount: 12
        ))
    }
    .padding()
    .frame(width: 380)
    .background(Color(nsColor: .windowBackgroundColor))
}
