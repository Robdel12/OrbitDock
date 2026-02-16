//
//  AttentionBanner.swift
//  OrbitDock
//
//  Conditional interrupt zone — only renders when sessions need attention.
//  Shows permission/question sessions with action buttons.
//

import SwiftUI

struct AttentionBanner: View {
  let sessions: [Session]
  let onSelectSession: (String) -> Void

  private var attentionSessions: [Session] {
    sessions
      .filter { $0.isActive && SessionDisplayStatus.from($0).needsAttention }
      .sorted { lhs, rhs in
        let lhsStatus = SessionDisplayStatus.from(lhs)
        let rhsStatus = SessionDisplayStatus.from(rhs)

        // Permission before question
        if lhsStatus != rhsStatus {
          if lhsStatus == .permission { return true }
          if rhsStatus == .permission { return false }
        }

        // Oldest blocked first
        let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
        let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
        return lhsDate < rhsDate
      }
  }

  var body: some View {
    if !attentionSessions.isEmpty {
      VStack(spacing: 4) {
        ForEach(attentionSessions) { session in
          AttentionBannerItem(
            session: session,
            onSelect: { onSelectSession(session.id) }
          )
        }
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }
}

// MARK: - Banner Item

private struct AttentionBannerItem: View {
  let session: Session
  let onSelect: () -> Void

  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  private var edgeColor: Color {
    displayStatus.color
  }

  private var contextText: String {
    switch displayStatus {
      case .permission:
        if let tool = session.pendingToolName {
          return "Needs approval: \(tool)"
        }
        return "Needs permission"
      case .question:
        if let question = session.pendingQuestion {
          let truncated = question.count > 60 ? String(question.prefix(57)) + "..." : question
          return "Q: \"\(truncated)\""
        }
        return "Question waiting"
      default:
        return ""
    }
  }

  private var blockedDuration: String {
    guard let activity = session.lastActivityAt else { return "" }
    let interval = Date().timeIntervalSince(activity)
    if interval < 60 { return "just now" }
    if interval < 3_600 {
      return "\(Int(interval / 60))m"
    }
    return "\(Int(interval / 3_600))h \(Int(interval.truncatingRemainder(dividingBy: 3_600) / 60))m"
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 0) {
        // Colored edge bar
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(edgeColor)
          .frame(width: EdgeBar.width)
          .padding(.vertical, 4)

        HStack(spacing: 10) {
          // Status icon
          Image(systemName: displayStatus.icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(edgeColor)
            .frame(width: 20)

          // Project + session identity + context
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
              Text(session.projectName ?? "Unknown")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)

              if let branch = session.branch, !branch.isEmpty {
                Text("·")
                  .foregroundStyle(Color.textQuaternary)
                Text(branch.count > 28 ? String(branch.prefix(26)) + "…" : branch)
                  .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.gitBranch.opacity(0.7))
                  .lineLimit(1)
              }

              // Session name for identification
              if let name = session.customName ?? session.summary {
                Text("·")
                  .foregroundStyle(Color.textQuaternary)
                Text(name.strippingXMLTags())
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }

            Text(contextText)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(edgeColor.opacity(0.9))
              .lineLimit(1)
          }

          Spacer()

          // Blocked duration
          if !blockedDuration.isEmpty {
            Text(blockedDuration)
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
          }

          // Action button
          HStack(spacing: 4) {
            Image(systemName: displayStatus == .question ? "eye" : "arrow.right.circle")
              .font(.system(size: 10, weight: .semibold))
            Text(displayStatus == .question ? "View" : "Review")
              .font(.system(size: 10, weight: .semibold))
          }
          .foregroundStyle(edgeColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(edgeColor.opacity(OpacityTier.light), in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(edgeColor.opacity(isHovering ? 0.08 : 0.04))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .stroke(edgeColor.opacity(isHovering ? 0.28 : 0.18), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    AttentionBanner(
      sessions: [
        Session(
          id: "1",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "main",
          model: "claude-opus-4-5-20251101",
          summary: "Lets catch up on the layout",
          status: .active,
          workStatus: .permission,
          startedAt: Date().addingTimeInterval(-32_400),
          lastActivityAt: Date().addingTimeInterval(-300),
          attentionReason: .awaitingPermission,
          pendingToolName: "Bash"
        ),
        Session(
          id: "2",
          projectPath: "/Users/dev/vizzly",
          projectName: "vizzly",
          branch: "feat/auth",
          model: "claude-sonnet-4-20250514",
          summary: "OAuth flow",
          status: .active,
          workStatus: .waiting,
          startedAt: Date().addingTimeInterval(-1_500),
          lastActivityAt: Date().addingTimeInterval(-600),
          attentionReason: .awaitingQuestion,
          pendingQuestion: "Should I use the editorial type scale or keep the current one?"
        ),
      ],
      onSelectSession: { _ in }
    )

    // Empty state — should render nothing
    AttentionBanner(
      sessions: [
        Session(
          id: "3",
          projectPath: "/Users/dev/project",
          projectName: "project",
          status: .active,
          workStatus: .working
        ),
      ],
      onSelectSession: { _ in }
    )
  }
  .padding(24)
  .background(Color.backgroundPrimary)
  .frame(width: 800)
}
