//
//  SessionRowView.swift
//  OrbitDock
//

import SwiftUI

struct SessionRowView: View {
  let session: Session
  var isSelected: Bool = false

  @Environment(ServerAppState.self) private var serverState

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  var body: some View {
    HStack(spacing: Spacing.md_) {
      // Status dot - using unified component
      SessionStatusDot(status: displayStatus)
        .frame(width: 20)

      // Main content
      VStack(alignment: .leading, spacing: Spacing.gap) {
        HStack(spacing: Spacing.sm_) {
          Text(session.displayName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if serverState.session(session.id).forkedFrom != nil {
            ForkBadge()
          }

          if session.isActive, session.workStatus != .unknown {
            CompactStatusBadge(workStatus: session.workStatus)
          }
        }

        HStack(spacing: Spacing.sm_) {
          Text(shortenedPath(session.projectPath))
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)

          if let branch = session.branch, !branch.isEmpty {
            HStack(spacing: Spacing.xxs) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .semibold))
              Text(branch)
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.secondary.opacity(0.7))
            .lineLimit(1)
          }
        }
      }

      Spacer()

      // Unread badge
      if session.unreadCount > 0 {
        Text(session.unreadCount > 99 ? "99+" : "\(session.unreadCount)")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, Spacing.xxs)
          .background(Color.accent, in: Capsule())
      }

      // Right side - compact stats
      VStack(alignment: .trailing, spacing: Spacing.xxs) {
        Text(session.formattedDuration)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)

        if session.toolCount > 0 {
          Text("\(session.toolCount) tools")
            .font(.system(size: TypeScale.mini))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      // Provider + Model badge
      UnifiedModelBadge(model: session.model, provider: session.provider, size: .compact)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(isSelected ? Color.surfaceSelected : Color.clear)
    )
    .padding(.horizontal, Spacing.sm_)
  }

  private func shortenedPath(_ path: String) -> String {
    let components = path.components(separatedBy: "/")
    if components.count > 3 {
      return "~/" + components.suffix(2).joined(separator: "/")
    }
    return path
  }
}

// MARK: - Compact Components

struct CompactStatusBadge: View {
  let session: Session

  /// Legacy initializer for backward compatibility
  init(workStatus: Session.WorkStatus) {
    // Create a minimal session for the status - this is a compatibility shim
    self.session = Session(
      id: "", projectPath: "", status: .active, workStatus: workStatus
    )
  }

  init(session: Session) {
    self.session = session
  }

  var body: some View {
    SessionStatusBadge(session: session, size: .compact)
  }
}

// MARK: - Work Status Badge (Standalone - legacy support)

struct WorkStatusBadge: View {
  let session: Session

  /// Legacy initializer for backward compatibility
  init(workStatus: Session.WorkStatus) {
    self.session = Session(
      id: "", projectPath: "", status: .active, workStatus: workStatus
    )
  }

  init(session: Session) {
    self.session = session
  }

  var body: some View {
    let displayStatus = SessionDisplayStatus.from(session)
    if displayStatus != .ended {
      SessionStatusBadge(status: displayStatus, size: .regular)
    }
  }
}

// MARK: - Fork Badge

struct ForkBadge: View {
  var body: some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 8, weight: .bold))
      Text("Fork")
        .font(.system(size: TypeScale.mini, weight: .medium))
    }
    .foregroundStyle(Color.accent)
    .padding(.horizontal, 5)
    .padding(.vertical, Spacing.xxs)
    .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
  }
}

struct PlanModeBadge: View {
  var body: some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: "map.fill")
        .font(.system(size: 8, weight: .bold))
      Text("Planning")
        .font(.system(size: TypeScale.mini, weight: .medium))
    }
    .foregroundStyle(Color.statusQuestion)
    .padding(.horizontal, 5)
    .padding(.vertical, Spacing.xxs)
    .background(Color.statusQuestion.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
  }
}

#Preview {
  VStack(spacing: Spacing.xxs) {
    SessionRowView(session: Session(
      id: "test-123",
      projectPath: "/Users/developer/Developer/vizzly-cli",
      projectName: "vizzly-cli",
      branch: "feat/plugin-git-api",
      model: "claude-opus-4-5-20251101",
      contextLabel: nil,
      transcriptPath: nil,
      status: .active,
      workStatus: .working,
      startedAt: Date().addingTimeInterval(-3_600),
      endedAt: nil,
      endReason: nil,
      totalTokens: 15_000,
      totalCostUSD: 0.45,
      lastActivityAt: Date(),
      lastTool: "Edit",
      lastToolAt: Date(),
      promptCount: 12,
      toolCount: 45
    ), isSelected: true)

    SessionRowView(session: Session(
      id: "test-456",
      projectPath: "/Users/developer/Developer/backchannel",
      projectName: "backchannel",
      branch: "main",
      model: "claude-sonnet-4-20250514",
      contextLabel: nil,
      transcriptPath: nil,
      status: .active,
      workStatus: .waiting,
      startedAt: Date().addingTimeInterval(-1_800),
      endedAt: nil,
      endReason: nil,
      totalTokens: 8_500,
      totalCostUSD: 0.12,
      lastActivityAt: Date().addingTimeInterval(-300),
      lastTool: nil,
      lastToolAt: nil,
      promptCount: 5,
      toolCount: 23
    ))

    SessionRowView(session: Session(
      id: "test-789",
      projectPath: "/Users/developer/Developer/marketing",
      projectName: "marketing",
      branch: nil,
      model: "claude-sonnet-4-20250514",
      contextLabel: nil,
      transcriptPath: nil,
      status: .ended,
      workStatus: .unknown,
      startedAt: Date().addingTimeInterval(-7_200),
      endedAt: Date().addingTimeInterval(-3_600),
      endReason: "exit",
      totalTokens: 3_200,
      totalCostUSD: 0.08,
      lastActivityAt: Date().addingTimeInterval(-3_600),
      lastTool: nil,
      lastToolAt: nil,
      promptCount: 3,
      toolCount: 12
    ))
  }
  .padding()
  .frame(width: 380)
  .background(Color.backgroundPrimary)
}
