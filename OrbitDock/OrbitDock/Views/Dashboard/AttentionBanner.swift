//
//  AttentionBanner.swift
//  OrbitDock
//
//  Conditional interrupt zone — only renders when sessions need attention.
//  Shows permission/question sessions with action buttons.
//

import SwiftUI

struct AttentionBanner: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let sessions: [Session]

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
    let visible = Array(attentionSessions.prefix(3))
    let overflow = attentionSessions.count - visible.count

    if !visible.isEmpty {
      VStack(spacing: Spacing.xs) {
        ForEach(visible, id: \.scopedID) { session in
          AttentionBannerItem(
            session: session,
            onSelect: {
              withAnimation(Motion.standard) {
                router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
              }
            }
          )
        }

        if overflow > 0 {
          Text("+\(overflow) more")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.xs)
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
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(edgeColor)
          .frame(width: EdgeBar.width)
          .padding(.vertical, Spacing.xs)

        HStack(spacing: Spacing.md_) {
          // Pulsing status dot
          Circle()
            .fill(edgeColor)
            .frame(width: 8, height: 8)
            .themeShadow(Shadow.glow(color: edgeColor, intensity: 0.5))
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: true)

          // Context text with inline duration
          HStack(spacing: 5) {
            Text(contextText)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(edgeColor)
              .lineLimit(1)

            if !blockedDuration.isEmpty {
              Text("(\(blockedDuration) ago)")
                .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }
          }

          Spacer()

          // Project identity
          Text(session.projectName ?? "Unknown")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, Spacing.md_)
        .padding(.vertical, Spacing.sm)
      }
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(edgeColor.opacity(isHovering ? 0.15 : 0.10))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .stroke(edgeColor.opacity(isHovering ? 0.35 : 0.25), lineWidth: 1.5)
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: Spacing.lg) {
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
      ]
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
      ]
    )
  }
  .padding(Spacing.xl)
  .background(Color.backgroundPrimary)
  .frame(width: 800)
  .environment(AppRouter())
  .environment(ServerRuntimeRegistry.shared)
}
