//
//  ActiveSessionRow.swift
//  OrbitDock
//
//  Rich row for active sessions with inline actions
//

import SwiftUI

struct ActiveSessionRow: View {
  let session: Session
  let onSelect: () -> Void
  let onFocusTerminal: (() -> Void)?
  var isSelected: Bool = false

  @Environment(ServerAppState.self) private var serverState
  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  private var isWorking: Bool {
    displayStatus == .working
  }

  private var activityText: String {
    switch displayStatus {
      case .permission:
        if let tool = session.pendingToolName {
          return "Permission: \(tool)"
        }
        return "Needs permission"

      case .question:
        if let question = session.pendingQuestion {
          let truncated = question.count > 40 ? String(question.prefix(37)) + "..." : question
          return "Q: \"\(truncated)\""
        }
        return "Question waiting"

      case .working:
        if let tool = session.lastTool {
          return tool
        }
        return "Working"

      case .reply:
        return "Awaiting reply"

      case .ended:
        return "Ended"
    }
  }

  private var activityIcon: String {
    switch displayStatus {
      case .permission:
        return "lock.fill"

      case .question:
        return "questionmark.bubble"

      case .working:
        if let tool = session.lastTool {
          return ToolCardStyle.icon(for: tool)
        }
        return "bolt.fill"

      case .reply:
        return "bubble.left"

      case .ended:
        return "moon.fill"
    }
  }

  /// Whether this status needs the user to take action (permission or question)
  private var needsAttention: Bool {
    displayStatus.needsAttention
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Status dot with glow
        SessionStatusDot(status: displayStatus, size: 10, showGlow: true)
          .frame(width: 28)

        // Name + activity
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(session.displayName)
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            if serverState.session(session.id).forkedFrom != nil {
              ForkBadge()
            }
          }

          HStack(spacing: 6) {
            Image(systemName: activityIcon)
              .font(.system(size: TypeScale.caption, weight: .medium))
            Text(activityText)
              .font(.system(size: TypeScale.body, weight: .medium))
              .lineLimit(1)
          }
          .foregroundStyle(needsAttention ? displayStatus.color : .secondary)
        }

        Spacer()

        // Right side: inline action OR stats
        if needsAttention {
          inlineActionButton
        } else {
          statsSection
        }

        // Provider + Model badge
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
      .padding(.vertical, Spacing.md)
      .padding(.horizontal, Spacing.md)
      .background(rowBackground)
      .overlay(rowBorder)
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

      if let onFocus = onFocusTerminal {
        Divider()
        Button(action: onFocus) {
          Label("Focus Terminal", systemImage: "terminal")
        }
      }
    }
  }

  // MARK: - Inline Action Button

  private var inlineActionButton: some View {
    Button {
      // For now, just select the session to view it
      // Future: could trigger terminal focus or direct approval
      onSelect()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: displayStatus == .question ? "eye" : "arrow.right.circle")
          .font(.system(size: TypeScale.caption, weight: .semibold))
        Text(displayStatus == .question ? "View" : "Review")
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .foregroundStyle(displayStatus.color)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 5)
      .background(displayStatus.color.opacity(OpacityTier.light), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Stats Section

  private var statsSection: some View {
    HStack(spacing: Spacing.md) {
      // Duration
      HStack(spacing: Spacing.xs) {
        Image(systemName: "clock")
          .font(.system(size: TypeScale.caption))
        Text(session.formattedDuration)
          .font(.system(size: TypeScale.body, weight: .medium, design: .monospaced))
      }
      .foregroundStyle(.tertiary)

      // Branch (if present)
      if let branch = session.branch, !branch.isEmpty {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: TypeScale.caption))
          Text(branch)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .lineLimit(1)
        }
        .foregroundStyle(Color.gitBranch.opacity(OpacityTier.vivid))
      }
    }
  }

  // MARK: - Background & Border

  private var rowBackground: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(isSelected ? Color.accent
          .opacity(OpacityTier.light) : (isHovering ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.6)))

      // Left accent bar when selected
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Color.accent)
        .frame(width: EdgeBar.width)
        .padding(.leading, Spacing.xs)
        .padding(.vertical, Spacing.sm)
        .opacity(isSelected ? 1 : 0)
        .scaleEffect(x: 1, y: isSelected ? 1 : 0.5, anchor: .center)
    }
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
  }

  private var rowBorder: some View {
    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      .stroke(
        needsAttention
          ? displayStatus.color.opacity(isHovering ? OpacityTier.strong : OpacityTier.medium)
          : displayStatus.color.opacity(isHovering ? OpacityTier.medium : OpacityTier.subtle),
        lineWidth: needsAttention ? 1.5 : 1
      )
  }

}

// MARK: - Preview

#Preview {
  VStack(spacing: 8) {
    // Working session
    ActiveSessionRow(
      session: Session(
        id: "1",
        projectPath: "/Users/developer/Developer/vizzly-cli",
        projectName: "vizzly-cli",
        branch: "main",
        model: "claude-opus-4-5-20251101",
        summary: "Building the new CLI interface",
        status: .active,
        workStatus: .working,
        startedAt: Date().addingTimeInterval(-8_100),
        lastTool: "Edit"
      ),
      onSelect: {},
      onFocusTerminal: nil
    )

    // Permission needed
    ActiveSessionRow(
      session: Session(
        id: "2",
        projectPath: "/Users/developer/Developer/vizzly-core",
        projectName: "vizzly-core",
        branch: "feature/auth",
        model: "claude-sonnet-4-20250514",
        summary: "Implementing OAuth flow",
        status: .active,
        workStatus: .permission,
        startedAt: Date().addingTimeInterval(-2_700),
        attentionReason: .awaitingPermission,
        pendingToolName: "Bash"
      ),
      onSelect: {},
      onFocusTerminal: nil
    )

    // Question waiting
    ActiveSessionRow(
      session: Session(
        id: "3",
        projectPath: "/Users/developer/Developer/marketing",
        projectName: "marketing",
        model: "claude-sonnet-4-20250514",
        summary: "Landing page redesign",
        status: .active,
        workStatus: .waiting,
        startedAt: Date().addingTimeInterval(-1_500),
        attentionReason: .awaitingQuestion,
        pendingQuestion: "Should I use the new color palette or stick with the existing brand colors?"
      ),
      onSelect: {},
      onFocusTerminal: nil
    )

    // Ready (awaiting reply)
    ActiveSessionRow(
      session: Session(
        id: "4",
        projectPath: "/Users/developer/Developer/docs",
        projectName: "docs",
        model: "claude-haiku-3-5-20241022",
        summary: "Documentation updates",
        status: .active,
        workStatus: .waiting,
        startedAt: Date().addingTimeInterval(-720),
        attentionReason: .awaitingReply
      ),
      onSelect: {},
      onFocusTerminal: nil
    )
  }
  .padding()
  .background(Color.backgroundPrimary)
}
