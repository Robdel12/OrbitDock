//
//  SidebarSessionRow.swift
//  OrbitDock
//
//  Compact session row for the workspace sidebar.
//

import SwiftUI

struct SidebarSessionRow: View {
  let session: Session
  let isSelected: Bool
  let onSelect: () -> Void
  var onRename: (() -> Void)?

  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        SessionStatusDot(status: displayStatus, size: 8)

        Text(session.displayName)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)

        Spacer(minLength: 4)

        if session.isActive {
          Text(displayStatus.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(displayStatus.color)
        }

        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
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
        _ = Platform.services.revealInFileBrowser(session.projectPath)
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Button {
        let command = "claude --resume \(session.id)"
        Platform.services.copyToClipboard(command)
      } label: {
        Label("Copy Resume Command", systemImage: "doc.on.doc")
      }
    }
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

#Preview {
  VStack(spacing: 2) {
    SidebarSessionRow(
      session: Session(
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
      isSelected: true,
      onSelect: {}
    )

    SidebarSessionRow(
      session: Session(
        id: "2",
        projectPath: "/Users/dev/vizzly-cli",
        projectName: "vizzly-cli",
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
      isSelected: false,
      onSelect: {}
    )
  }
  .padding(8)
  .background(Color.panelBackground)
  .frame(width: 320)
}
