//
//  SidebarProjectGroup.swift
//  OrbitDock
//
//  Collapsible project group containing session rows.
//

import SwiftUI

struct SidebarProjectGroup: View {
  let group: ProjectGroup
  let selectedSessionId: String?
  let onSelectSession: (String) -> Void
  var onRenameSession: ((Session) -> Void)?

  @State private var isExpanded = true

  private var activeSessionCount: Int {
    group.sessions.filter(\.isActive).count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Group header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 10)

          Text(group.projectName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)

          if activeSessionCount > 0 {
            Text("\(activeSessionCount)")
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .foregroundStyle(Color.textTertiary)
          }

          Spacer()

          if let endpointName = group.endpointName {
            Text(endpointName)
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Session rows
      if isExpanded {
        ForEach(group.sessions, id: \.scopedID) { session in
          SidebarSessionRow(
            session: session,
            isSelected: selectedSessionId == session.scopedID,
            onSelect: { onSelectSession(session.scopedID) },
            onRename: {
              onRenameSession?(session)
            }
          )
          .padding(.leading, 16)
        }
      }
    }
  }
}

#Preview {
  VStack(spacing: 8) {
    SidebarProjectGroup(
      group: ProjectGroup(
        groupKey: "OrbitDock",
        projectPath: "/Users/dev/OrbitDock",
        projectName: "OrbitDock",
        endpointName: nil,
        sessions: [
          Session(
            id: "1",
            projectPath: "/Users/dev/OrbitDock",
            projectName: "OrbitDock",
            branch: "feat/sidebar",
            model: "claude-opus-4-5-20251101",
            contextLabel: "Sidebar Redesign",
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
            projectPath: "/Users/dev/OrbitDock",
            projectName: "OrbitDock",
            branch: "main",
            model: "claude-sonnet-4-20250514",
            contextLabel: "Fix Scroll Anchor",
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
        ],
        totalCost: 0,
        totalTokens: 0,
        latestActivityAt: Date()
      ),
      selectedSessionId: "1",
      onSelectSession: { _ in }
    )
  }
  .padding(8)
  .background(Color.panelBackground)
  .frame(width: 320)
}
