//
//  AgentRowCompact.swift
//  OrbitDock
//
//  Compact agent row for the projects panel
//

import SwiftUI

struct AgentRowCompact: View {
    let session: Session
    let isSelected: Bool
    let onSelect: () -> Void
    var onRename: (() -> Void)? = nil

    @State private var isHovering = false

    private var displayStatus: SessionDisplayStatus {
        SessionDisplayStatus.from(session)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Status dot - using unified component
                SessionStatusDot(status: displayStatus)
                    .frame(width: 16, height: 16)

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Project name
                        Text(projectName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer()

                        // Model badge
                        ModelBadgeMini(model: session.model)
                    }

                    HStack(spacing: 6) {
                        // Agent name / context label
                        Text(agentName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if session.isActive {
                            Text("•")
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)

                            Text(displayStatus.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(displayStatus.color)
                        } else {
                            let duration = session.formattedDuration
                            if duration != "--" {
                                Text("•")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.quaternary)

                                Text(duration)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                onRename?()
            } label: {
                Label("Rename...", systemImage: "pencil")
            }

            Divider()

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

    // MARK: - Helpers

    private var projectName: String {
        session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
    }

    private var agentName: String {
        // Use displayName which already strips HTML tags
        session.displayName
    }

    private var backgroundColor: Color {
        if isSelected {
            return .surfaceSelected
        } else if isHovering {
            return .surfaceHover
        }
        return .clear
    }
}

// MARK: - Mini Model Badge

struct ModelBadgeMini: View {
    let model: String?

    private var displayModel: String {
        guard let model = model?.lowercased() else { return "?" }
        if model.contains("opus") { return "O" }
        if model.contains("sonnet") { return "S" }
        if model.contains("haiku") { return "H" }
        return "?"
    }

    private var fullName: String {
        guard let model = model?.lowercased() else { return "Unknown" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    private var modelColor: Color {
        guard let model = model?.lowercased() else { return .secondary }
        if model.contains("opus") { return .modelOpus }
        if model.contains("sonnet") { return .modelSonnet }
        if model.contains("haiku") { return .modelHaiku }
        return .secondary
    }

    var body: some View {
        Text(displayModel)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(modelColor)
            .frame(width: 18, height: 18)
            .background(modelColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(fullName)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 4) {
        AgentRowCompact(
            session: Session(
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
            isSelected: true,
            onSelect: {}
        )

        AgentRowCompact(
            session: Session(
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
            isSelected: false,
            onSelect: {}
        )

        AgentRowCompact(
            session: Session(
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
                endedAt: Date(),
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
            isSelected: false,
            onSelect: {}
        )
    }
    .padding()
    .background(Color.panelBackground)
    .frame(width: 280)
}
