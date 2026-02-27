//
//  SidebarAttentionRow.swift
//  OrbitDock
//
//  Attention queue row — shows sessions needing approval or answers.
//

import SwiftUI

struct SidebarAttentionRow: View {
  let session: Session
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  private var toolLabel: String {
    if let tool = session.lastTool {
      return tool
    }
    return displayStatus == .question ? "Question" : "Permission"
  }

  private var blockedDuration: String? {
    guard let toolAt = session.lastToolAt else { return nil }
    let interval = Date().timeIntervalSince(toolAt)
    if interval < 60 { return nil }
    let minutes = Int(interval / 60)
    if minutes >= 60 {
      let hours = minutes / 60
      let remaining = minutes % 60
      return "\(hours)h \(remaining)m"
    }
    return "\(minutes)m"
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        // Status icon
        Image(systemName: displayStatus.icon)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(displayStatus.color)
          .frame(width: 18)

        // Project name + tool info
        VStack(alignment: .leading, spacing: 2) {
          Text(session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          HStack(spacing: 4) {
            Text(toolLabel)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.textTertiary)

            if let duration = blockedDuration {
              Text("·")
                .font(.system(size: 8))
                .foregroundStyle(Color.textQuaternary)
              Text(duration)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }
          }
        }

        Spacer(minLength: 4)

        // Review button
        Text("Review")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(displayStatus.color)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(
            displayStatus.color.opacity(0.15),
            in: Capsule()
          )
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(backgroundColor)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var backgroundColor: Color {
    if isSelected {
      return .surfaceSelected
    } else if isHovering {
      return .surfaceHover
    }
    return displayStatus.color.opacity(0.06)
  }
}

#Preview {
  VStack(spacing: 4) {
    SidebarAttentionRow(
      session: Session(
        id: "1",
        projectPath: "/Users/dev/vizzly-cli",
        projectName: "vizzly-cli",
        branch: "main",
        model: "claude-opus-4-5-20251101",
        contextLabel: nil,
        transcriptPath: nil,
        status: .active,
        workStatus: .permission,
        startedAt: Date(),
        endedAt: nil,
        endReason: nil,
        totalTokens: 0,
        totalCostUSD: 0,
        lastActivityAt: nil,
        lastTool: "Bash",
        lastToolAt: Date().addingTimeInterval(-180),
        promptCount: 0,
        toolCount: 0,
        terminalSessionId: nil,
        terminalApp: nil
      ),
      isSelected: false,
      onSelect: {}
    )

    SidebarAttentionRow(
      session: Session(
        id: "2",
        projectPath: "/Users/dev/OrbitDock",
        projectName: "OrbitDock",
        branch: "feat/sidebar",
        model: "claude-sonnet-4-20250514",
        contextLabel: nil,
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
        lastToolAt: Date().addingTimeInterval(-60),
        promptCount: 0,
        toolCount: 0,
        terminalSessionId: nil,
        terminalApp: nil
      ),
      isSelected: true,
      onSelect: {}
    )
  }
  .padding(8)
  .background(Color.panelBackground)
  .frame(width: 320)
}
