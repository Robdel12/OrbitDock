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

  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  private var isWorking: Bool {
    displayStatus == .working
  }

  private var activityText: String {
    // For attention items, show what needs action
    if displayStatus == .attention {
      if session.attentionReason == .awaitingQuestion {
        if let question = session.pendingQuestion {
          let truncated = question.count > 40 ? String(question.prefix(37)) + "..." : question
          return "Question: \"\(truncated)\""
        }
        return "Question waiting"
      }
      if let tool = session.pendingToolName {
        return "Permission: \(tool)"
      }
      return "Needs attention"
    }

    // For working, show current tool
    if isWorking, let tool = session.lastTool {
      return "\(tool)"
    }

    // For ready, show awaiting reply
    if displayStatus == .ready {
      return "Awaiting reply"
    }

    return "Active"
  }

  private var activityIcon: String {
    if displayStatus == .attention {
      if session.attentionReason == .awaitingQuestion {
        return "questionmark.bubble"
      }
      return "lock.fill"
    }

    if isWorking, let tool = session.lastTool {
      return toolIcon(for: tool)
    }

    if displayStatus == .ready {
      return "bubble.left"
    }

    return "bolt"
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Status dot with glow
        SessionStatusDot(status: displayStatus, size: 10, showGlow: true)
          .frame(width: 28)

        // Name + activity
        VStack(alignment: .leading, spacing: 3) {
          Text(session.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          HStack(spacing: 6) {
            Image(systemName: activityIcon)
              .font(.system(size: 10, weight: .medium))
            Text(activityText)
              .font(.system(size: 11, weight: .medium))
              .lineLimit(1)
          }
          .foregroundStyle(displayStatus == .attention ? Color.statusAttention : .secondary)
        }

        Spacer()

        // Right side: inline action OR stats
        if displayStatus == .attention {
          inlineActionButton
        } else {
          statsSection
        }

        // Model badge
        ModelBadgeMini(model: session.model)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
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
        Image(systemName: session.attentionReason == .awaitingQuestion ? "eye" : "arrow.right.circle")
          .font(.system(size: 10, weight: .semibold))
        Text(session.attentionReason == .awaitingQuestion ? "View" : "Review")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(Color.statusAttention)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.statusAttention.opacity(0.15), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Stats Section

  private var statsSection: some View {
    HStack(spacing: 10) {
      // Duration
      HStack(spacing: 4) {
        Image(systemName: "clock")
          .font(.system(size: 10))
        Text(session.formattedDuration)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
      }
      .foregroundStyle(.tertiary)

      // Branch (if present)
      if let branch = session.branch, !branch.isEmpty {
        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 10))
          Text(branch)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
        }
        .foregroundStyle(Color.gitBranch.opacity(0.8))
      }
    }
  }

  // MARK: - Background & Border

  private var rowBackground: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(isHovering ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.6))
  }

  private var rowBorder: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .stroke(
        displayStatus == .attention
          ? Color.statusAttention.opacity(isHovering ? 0.4 : 0.25)
          : displayStatus.color.opacity(isHovering ? 0.2 : 0.1),
        lineWidth: 1
      )
  }

  // MARK: - Helpers

  private func toolIcon(for tool: String) -> String {
    switch tool.lowercased() {
      case "read": "doc.text"
      case "edit": "pencil"
      case "write": "square.and.pencil"
      case "bash": "terminal"
      case "glob": "folder.badge.gearshape"
      case "grep": "magnifyingglass"
      case "task": "person.2"
      case "webfetch": "globe"
      case "websearch": "magnifyingglass.circle"
      case "skill": "sparkles"
      default: "gearshape"
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 8) {
    // Working session
    ActiveSessionRow(
      session: Session(
        id: "1",
        projectPath: "/Users/rob/Developer/vizzly-cli",
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
        projectPath: "/Users/rob/Developer/vizzly-core",
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
        projectPath: "/Users/rob/Developer/marketing",
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
        projectPath: "/Users/rob/Developer/docs",
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
