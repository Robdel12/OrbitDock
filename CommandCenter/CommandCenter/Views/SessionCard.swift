//
//  SessionCard.swift
//  OrbitDock
//
//  Grid card for displaying session in dashboard
//

import SwiftUI

struct SessionCard: View {
  let session: Session
  let onSelect: () -> Void

  @State private var isHovering = false

  private var statusColor: Color {
    guard session.isActive else { return .secondary.opacity(0.4) }
    switch session.workStatus {
      case .working: return .statusWorking
      case .waiting: return .statusWaiting
      case .permission: return .statusPermission
      case .unknown: return .secondary
    }
  }

  private var statusLabel: String {
    guard session.isActive else { return "Ended" }
    switch session.workStatus {
      case .working: return "Working"
      case .waiting: return "Waiting"
      case .permission: return "Permission"
      case .unknown: return "Active"
    }
  }

  private var projectName: String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
  }

  private var agentName: String {
    session.displayName
  }

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 8) {
        // Top row: Status dot + Project + Model
        HStack(spacing: 8) {
          // Status dot with pulse for working
          ZStack {
            Circle()
              .fill(statusColor)
              .frame(width: 8, height: 8)

            if session.isActive, session.workStatus == .working {
              Circle()
                .stroke(statusColor.opacity(0.4), lineWidth: 1.5)
                .frame(width: 14, height: 14)
            }
          }
          .frame(width: 14, height: 14)

          Text(projectName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Spacer()

          ModelBadge(model: session.model, provider: session.provider)
        }

        // Agent name/summary
        Text(agentName)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        // Status + tool
        HStack(spacing: 4) {
          Text(statusLabel)
            .foregroundStyle(statusColor)

          if let tool = session.lastTool, session.isActive {
            Text("•")
              .foregroundStyle(.quaternary)
            Text(tool.capitalized)
              .foregroundStyle(.tertiary)
          }
        }
        .font(.system(size: 10, weight: .medium))

        // Stats row: duration, cost
        HStack(spacing: 6) {
          Text(session.formattedDuration)

          if session.totalCostUSD > 0 {
            Text("•")
              .foregroundStyle(.quaternary)
            Text(session.formattedCost)
          }

          if session.toolCount > 0 {
            Text("•")
              .foregroundStyle(.quaternary)
            Text("\(session.toolCount) tools")
          }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.backgroundTertiary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(isHovering ? Color.surfaceBorder.opacity(0.8) : Color.surfaceBorder.opacity(0.4), lineWidth: 1)
      )
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
}

// MARK: - Preview

#Preview {
  HStack(spacing: 12) {
    SessionCard(
      session: Session(
        id: "1",
        projectPath: "/Users/developer/Developer/vizzly-cli",
        projectName: "vizzly-cli",
        branch: "feat/auth",
        model: "claude-opus-4-5-20251101",
        contextLabel: "Auth refactor",
        transcriptPath: nil,
        status: .active,
        workStatus: .working,
        startedAt: Date().addingTimeInterval(-1_380),
        endedAt: nil,
        endReason: nil,
        totalTokens: 45_000,
        totalCostUSD: 1.20,
        lastActivityAt: nil,
        lastTool: "Edit",
        lastToolAt: nil,
        promptCount: 12,
        toolCount: 45,
        terminalSessionId: nil,
        terminalApp: nil
      ),
      onSelect: {}
    )

    SessionCard(
      session: Session(
        id: "2",
        projectPath: "/Users/developer/Developer/backchannel",
        projectName: "backchannel",
        branch: "main",
        model: "claude-sonnet-4-20250514",
        contextLabel: "API review",
        transcriptPath: nil,
        status: .active,
        workStatus: .waiting,
        startedAt: Date().addingTimeInterval(-300),
        endedAt: nil,
        endReason: nil,
        totalTokens: 12_000,
        totalCostUSD: 0.12,
        lastActivityAt: nil,
        lastTool: nil,
        lastToolAt: nil,
        promptCount: 3,
        toolCount: 8,
        terminalSessionId: nil,
        terminalApp: nil
      ),
      onSelect: {}
    )

    SessionCard(
      session: Session(
        id: "3",
        projectPath: "/Users/developer/Developer/docs",
        projectName: "docs",
        branch: "main",
        model: "claude-haiku-3-5-20241022",
        contextLabel: "API cleanup",
        transcriptPath: nil,
        status: .ended,
        workStatus: .unknown,
        startedAt: Date().addingTimeInterval(-7_200),
        endedAt: Date().addingTimeInterval(-5_400),
        endReason: nil,
        totalTokens: 8_000,
        totalCostUSD: 0.08,
        lastActivityAt: nil,
        lastTool: nil,
        lastToolAt: nil,
        promptCount: 5,
        toolCount: 15,
        terminalSessionId: nil,
        terminalApp: nil
      ),
      onSelect: {}
    )
  }
  .padding(20)
  .background(Color.backgroundPrimary)
  .frame(width: 800)
}
