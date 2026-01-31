//
//  HeaderView.swift
//  CommandCenter
//
//  Compact header bar for session detail view
//

import SwiftUI

struct HeaderView: View {
    let session: Session
    let usageStats: TranscriptUsageStats
    let currentTool: String?
    let onTogglePanel: () -> Void
    let onOpenSwitcher: () -> Void
    let onFocusTerminal: () -> Void
    let onGoToDashboard: () -> Void

    @State private var isHoveringPath = false
    @State private var isHoveringProject = false
    @AppStorage("preferredEditor") private var preferredEditor: String = ""

    private var statusColor: Color {
        switch session.workStatus {
        case .working: return .statusWorking
        case .waiting: return .statusWaiting
        case .permission: return .statusPermission
        case .unknown: return .statusWorking.opacity(0.6)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Nav buttons
                HStack(spacing: 4) {
                    // Panel toggle
                    Button(action: onTogglePanel) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle projects panel (⌘1)")

                    // Home / Dashboard button
                    Button(action: onGoToDashboard) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Go to dashboard (⌘0)")
                }

                // Status dot
                ZStack {
                    Circle()
                        .fill(session.isActive ? statusColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)

                    if session.isActive && session.workStatus == .working {
                        Circle()
                            .stroke(statusColor.opacity(0.4), lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                }

                // Project / Agent name
                Button(action: onOpenSwitcher) {
                    HStack(spacing: 6) {
                        Text(projectName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("/")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(.quaternary)

                        Text(agentName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isHoveringProject ? Color.surfaceHover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringProject = $0 }
                .help("Switch agents")

                // Model badge (inline)
                ModelBadgeCompact(model: session.model)

                // Status pill (only when active)
                if session.isActive {
                    StatusPillCompact(workStatus: session.workStatus, currentTool: currentTool)
                }

                Spacer()

                // Stats row (compact)
                HStack(spacing: 16) {
                    // Context gauge
                    ContextGaugeCompact(stats: usageStats)

                    // Cost
                    if usageStats.estimatedCostUSD > 0 {
                        Text(usageStats.formattedCost)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                    }

                    // Duration
                    Text(session.formattedDuration)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Quick actions
                HStack(spacing: 4) {
                    Button(action: onOpenSwitcher) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 28)
                            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Search sessions")

                    Button(action: onFocusTerminal) {
                        Image(systemName: session.isActive ? "arrow.up.forward.app" : "terminal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(session.isActive ? "Focus terminal (⌘⇧F)" : "Resume in terminal")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Secondary row: path + branch
            HStack(spacing: 12) {
                Spacer()
                    .frame(width: 40) // Align with content after toggle

                // Branch
                if let branch = session.branch, !branch.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                        Text(branch)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.orange)
                }

                // Path (click to open in editor)
                Button {
                    openInEditor(session.projectPath)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                        Text(shortenPath(session.projectPath))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(isHoveringPath ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringPath = $0 }
                .help("Open in editor")
                .contextMenu {
                    Button("Open in Editor") {
                        openInEditor(session.projectPath)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
                    }
                    Divider()
                    Menu("Set Editor") {
                        Button("Use $EDITOR") {
                            preferredEditor = ""
                        }
                        Divider()
                        Button("Emacs") { preferredEditor = "emacs" }
                        Button("VS Code") { preferredEditor = "code" }
                        Button("Cursor") { preferredEditor = "cursor" }
                        Button("Zed") { preferredEditor = "zed" }
                        Button("Sublime Text") { preferredEditor = "subl" }
                        Button("Vim") { preferredEditor = "vim" }
                        Button("Neovim") { preferredEditor = "nvim" }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color.backgroundSecondary)
    }

    // MARK: - Helpers

    private var projectName: String {
        session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
    }

    private var agentName: String {
        session.customName ?? session.summary ?? "Session"
    }

    private func shortenPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 4 {
            return "~/.../" + components.suffix(2).joined(separator: "/")
        }
        return path.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
    }

    private func openInEditor(_ path: String) {
        // Determine which editor to use
        let editor: String
        if !preferredEditor.isEmpty {
            editor = preferredEditor
        } else if let envEditor = ProcessInfo.processInfo.environment["VISUAL"] {
            editor = envEditor
        } else if let envEditor = ProcessInfo.processInfo.environment["EDITOR"] {
            editor = envEditor
        } else {
            // Fallback: reveal in Finder
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            return
        }

        // Try to open with the editor
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [editor, path]
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        do {
            try process.run()
        } catch {
            // Fallback: try opening as an app with `open -a`
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = ["-a", editor, path]
            try? openProcess.run()
        }
    }
}

// MARK: - Compact Components

struct ModelBadgeCompact: View {
    let model: String?

    private var displayModel: String {
        guard let model = model?.lowercased() else { return "?" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return String(model.prefix(6))
    }

    private var modelColor: Color {
        guard let model = model?.lowercased() else { return .secondary }
        if model.contains("opus") { return .purple }
        if model.contains("sonnet") { return .blue }
        if model.contains("haiku") { return .teal }
        return .secondary
    }

    var body: some View {
        Text(displayModel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(modelColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(modelColor.opacity(0.12), in: Capsule())
    }
}

struct StatusPillCompact: View {
    let workStatus: Session.WorkStatus
    let currentTool: String?

    private var color: Color {
        switch workStatus {
        case .working: return .statusWorking
        case .waiting: return .statusWaiting
        case .permission: return .statusPermission
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
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
        }
    }
}

struct ContextGaugeCompact: View {
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
            .frame(width: 32, height: 4)

            Text("\(Int(stats.contextPercentage * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(progressColor)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        HeaderView(
            session: Session(
                id: "test-123",
                projectPath: "/Users/rob/Developer/vizzly-cli",
                projectName: "vizzly-cli",
                branch: "feat/auth-system",
                model: "claude-opus-4-5-20251101",
                contextLabel: "Auth refactor",
                transcriptPath: nil,
                status: .active,
                workStatus: .working,
                startedAt: Date().addingTimeInterval(-3600),
                endedAt: nil,
                endReason: nil,
                totalTokens: 50000,
                totalCostUSD: 1.23,
                lastActivityAt: Date(),
                lastTool: "Edit",
                lastToolAt: Date(),
                promptCount: 45,
                toolCount: 123,
                terminalSessionId: nil,
                terminalApp: nil
            ),
            usageStats: {
                var stats = TranscriptUsageStats()
                stats.inputTokens = 100000
                stats.outputTokens = 50000
                stats.contextUsed = 150000
                stats.model = "opus"
                return stats
            }(),
            currentTool: "Edit",
            onTogglePanel: {},
            onOpenSwitcher: {},
            onFocusTerminal: {},
            onGoToDashboard: {}
        )

        Divider().opacity(0.3)

        Color.backgroundPrimary
            .frame(height: 400)
    }
    .frame(width: 900)
    .background(Color.backgroundPrimary)
}
