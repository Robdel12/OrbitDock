//
//  ActivityStreamCard.swift
//  OrbitDock
//
//  Three distinct card variants driven by session status:
//  - Attention: large, colored, with inline action context
//  - Working: medium, shows activity pulse
//  - Compact: two-line row for ready/idle sessions
//
//  Design invariants:
//  - All cards use Spacing.lg_ (14pt) horizontal padding
//  - Right column (model + time) is fixed-width for cross-row alignment
//  - Context lines use textSecondary (0.65) not textTertiary (0.50)
//  - Metadata items separated by dot dividers, not just spacing
//

import SwiftUI

// MARK: - Attention Card (large, prominent, demands action)

struct AttentionCard: View {
  let session: RootSessionNode
  let onSelect: () -> Void

  @Environment(\.rootSessionActions) private var rootSessionActions
  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    session.displayStatus
  }

  private var statusColor: Color {
    displayStatus.color
  }

  private var agentLabel: String {
    SessionCardHelpers.agentLabel(for: session)
  }

  private var actionDescription: String {
    if displayStatus == .permission, let tool = session.pendingToolName {
      return "Wants to run \(tool)"
    }
    if displayStatus == .question {
      return "Has a question for you"
    }
    return "Needs your attention"
  }

  private var passiveBadge: some View {
    Text("passive")
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, 5)
      .padding(.vertical, Spacing.xxs)
      .background(Color.textTertiary.opacity(0.10), in: Capsule())
  }

  var body: some View {
    Button {
      Platform.services.playHaptic(.navigation)
      onSelect()
    } label: {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Top: status icon + description + model
        HStack(spacing: Spacing.sm) {
          Image(systemName: displayStatus.icon)
            .font(.system(size: TypeScale.subhead, weight: .bold))
            .foregroundStyle(statusColor)

          Text(actionDescription)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(statusColor)

          Spacer(minLength: Spacing.sm)

          trailingBadge
        }

        // Agent name + project + branch
        HStack(spacing: 0) {
          Text(agentLabel)
            .font(.system(size: TypeScale.subhead, weight: .bold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          metadataDivider

          Text(SessionCardHelpers.projectName(for: session))
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          if let branch = SessionCardHelpers.branch(for: session, maxLength: 20) {
            metadataDivider
            Text(branch)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.gitBranch.opacity(0.7))
          }

          if session.isPassiveCodex {
            metadataDivider
            passiveBadge
          }

          if let issueId = session.issueIdentifier {
            metadataDivider
            Text(issueId)
              .font(.system(size: TypeScale.micro, weight: .bold))
              .padding(.horizontal, 6)
              .padding(.vertical, Spacing.xxs)
              .background(Color.blue.opacity(0.15))
              .foregroundStyle(.blue)
              .clipShape(Capsule())
          }
        }

        // Context line
        if let context = SessionCardHelpers.contextLine(for: session) {
          Text(context)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md)
      .background(
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(statusColor.opacity(OpacityTier.tint))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .stroke(statusColor.opacity(isHovering ? 0.35 : 0.20), lineWidth: 1)
            )

          // Bold edge bar
          UnevenRoundedRectangle(
            topLeadingRadius: Radius.lg,
            bottomLeadingRadius: Radius.lg,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
          )
          .fill(statusColor)
          .frame(width: EdgeBar.width)
        }
      )
      .animation(Motion.hover, value: isHovering)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu { SessionCardHelpers.baseContextMenu(for: session)
      if session.isActive, session.isDirect {
        Divider()
        Button(role: .destructive) {
          Task { await endSession() }
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
  }

  private func endSession() async {
    try? await rootSessionActions.endSession(session)
  }

  private var trailingBadge: some View {
    HStack(spacing: Spacing.sm_) {
      UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)

      if let recency = SessionCardHelpers.recency(for: session) {
        Text(recency)
          .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .frame(minWidth: 22, alignment: .trailing)
      }
    }
  }

  private var metadataDivider: some View {
    Text(" \u{2022} ")
      .font(.system(size: TypeScale.mini))
      .foregroundStyle(Color.textQuaternary)
  }
}

// MARK: - Working Card (medium, activity-focused)

struct WorkingCard: View {
  let session: RootSessionNode
  let onSelect: () -> Void

  @Environment(\.rootSessionActions) private var rootSessionActions
  @State private var isHovering = false

  private var agentLabel: String {
    SessionCardHelpers.agentLabel(for: session)
  }

  private var passiveBadge: some View {
    Text("passive")
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, 5)
      .padding(.vertical, Spacing.xxs)
      .background(Color.textTertiary.opacity(0.10), in: Capsule())
  }

  var body: some View {
    Button {
      Platform.services.playHaptic(.navigation)
      onSelect()
    } label: {
      VStack(alignment: .leading, spacing: Spacing.sm_) {
        // Name + trailing column
        HStack(spacing: Spacing.sm) {
          Text(agentLabel)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Spacer(minLength: Spacing.sm)

          HStack(spacing: Spacing.sm_) {
            UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)

            if let recency = SessionCardHelpers.recency(for: session) {
              Text(recency)
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
                .frame(minWidth: 22, alignment: .trailing)
            }
          }
        }

        // Project + branch
        HStack(spacing: 0) {
          Text(SessionCardHelpers.projectName(for: session))
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          if let branch = SessionCardHelpers.branch(for: session, maxLength: 18) {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(branch)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.gitBranch.opacity(0.7))
          }

          if session.isPassiveCodex {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            passiveBadge
          }

          if let issueId = session.issueIdentifier {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(issueId)
              .font(.system(size: TypeScale.micro, weight: .bold))
              .padding(.horizontal, 6)
              .padding(.vertical, Spacing.xxs)
              .background(Color.blue.opacity(0.15))
              .foregroundStyle(.blue)
              .clipShape(Capsule())
          }
        }

        // Context
        if let context = SessionCardHelpers.contextLine(for: session) {
          Text(context)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md_)
      .background(
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(isHovering ? Color.surfaceHover : Color.backgroundSecondary.opacity(0.4))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
                .stroke(Color.statusWorking.opacity(isHovering ? 0.25 : 0.12), lineWidth: 1)
            )

          // Cyan edge bar — working indicator
          UnevenRoundedRectangle(
            topLeadingRadius: Radius.ml,
            bottomLeadingRadius: Radius.ml,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
          )
          .fill(Color.statusWorking)
          .frame(width: EdgeBar.width)
        }
      )
      .animation(Motion.hover, value: isHovering)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu { SessionCardHelpers.baseContextMenu(for: session)
      if session.isActive, session.isDirect {
        Divider()
        Button(role: .destructive) {
          Task { await endSession() }
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
  }

  private func endSession() async {
    try? await rootSessionActions.endSession(session)
  }
}

// MARK: - Compact Row (two-line, for ready/idle sessions)

struct CompactSessionRow: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.rootSessionActions) private var rootSessionActions

  let session: RootSessionNode
  let onSelect: () -> Void
  var isSelected: Bool = false

  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    session.displayStatus
  }

  private var agentLabel: String {
    SessionCardHelpers.agentLabel(for: session)
  }

  private var passiveBadge: some View {
    Text("passive")
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, 5)
      .padding(.vertical, Spacing.xxs)
      .background(Color.textTertiary.opacity(0.10), in: Capsule())
  }

  private var isPhoneCompact: Bool {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass).isPhoneCompact
  }

  var body: some View {
    Button {
      Platform.services.playHaptic(.navigation)
      onSelect()
    } label: {
      if isPhoneCompact {
        phoneLayout
      } else {
        desktopLayout
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu { SessionCardHelpers.baseContextMenu(for: session)
      if session.isActive, session.isDirect {
        Divider()
        Button(role: .destructive) {
          Task { await endSession() }
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
  }

  private func endSession() async {
    try? await rootSessionActions.endSession(session)
  }

  // MARK: - Desktop: two-line row

  private var desktopLayout: some View {
    HStack(spacing: Spacing.md_) {
      // Unread dot — reserve this channel for unread activity, not session status.
      UnreadIndicatorDot(isVisible: session.hasUnreadMessages, size: 7)
        .frame(width: 10)

      // Two-line content block
      VStack(alignment: .leading, spacing: Spacing.xs) {
        // Line 1: name + metadata
        HStack(spacing: 0) {
          Text(agentLabel)
            .font(.system(size: TypeScale.body, weight: session.hasUnreadMessages ? .semibold : .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(" \u{2022} ")
            .font(.system(size: TypeScale.mini))
            .foregroundStyle(Color.textQuaternary)

          Text(SessionCardHelpers.projectName(for: session))
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          if let branch = SessionCardHelpers.branch(for: session, maxLength: 16) {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(branch)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.gitBranch.opacity(0.7))
          }

          if session.isPassiveCodex {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            passiveBadge
          }

          if let issueId = session.issueIdentifier {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(issueId)
              .font(.system(size: TypeScale.micro, weight: .bold))
              .padding(.horizontal, 6)
              .padding(.vertical, Spacing.xxs)
              .background(Color.blue.opacity(0.15))
              .foregroundStyle(.blue)
              .clipShape(Capsule())
          }
        }

        // Line 2: context
        if let context = SessionCardHelpers.contextLine(for: session) {
          Text(context)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: Spacing.sm)

      // Fixed trailing column — always aligned across rows
      HStack(spacing: Spacing.sm_) {
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)

        if let recency = SessionCardHelpers.recency(for: session) {
          Text(recency)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .frame(minWidth: 24, alignment: .trailing)
        }
      }
    }
    .padding(.horizontal, Spacing.lg_)
    .padding(.vertical, Spacing.md_)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
        .fill(isSelected ? Color.surfaceSelected : (isHovering ? Color.surfaceHover : Color.clear))
    )
    .animation(Motion.hover, value: isHovering)
  }

  // MARK: - Phone: multi-line, everything visible

  private var phoneLayout: some View {
    HStack(alignment: .top, spacing: Spacing.md_) {
      UnreadIndicatorDot(isVisible: session.hasUnreadMessages, size: 7)
        .frame(width: 10)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: Spacing.sm_) {
        // Line 1: name
        Text(agentLabel)
          .font(.system(size: TypeScale.body, weight: session.hasUnreadMessages ? .semibold : .medium))
          .foregroundStyle(.primary)
          .lineLimit(2)

        // Line 2: context
        if let context = SessionCardHelpers.contextLine(for: session) {
          Text(context)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
        }

        // Line 3: metadata
        HStack(spacing: 0) {
          Text(SessionCardHelpers.projectName(for: session))
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          if let branch = SessionCardHelpers.branch(for: session, maxLength: 14) {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(branch)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.gitBranch.opacity(0.7))
          }

          if session.isPassiveCodex {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            passiveBadge
          }

          if let issueId = session.issueIdentifier {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(issueId)
              .font(.system(size: TypeScale.micro, weight: .bold))
              .padding(.horizontal, 6)
              .padding(.vertical, Spacing.xxs)
              .background(Color.blue.opacity(0.15))
              .foregroundStyle(.blue)
              .clipShape(Capsule())
          }

          Spacer(minLength: Spacing.sm)

          UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)

          if let recency = SessionCardHelpers.recency(for: session) {
            Text(" \u{2022} ")
              .font(.system(size: TypeScale.mini))
              .foregroundStyle(Color.textQuaternary)
            Text(recency)
              .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }
        }
      }
    }
    .padding(.horizontal, Spacing.lg_)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
        .fill(isSelected ? Color.surfaceSelected : Color.clear)
    )
  }
}

// MARK: - Shared Helpers

enum SessionCardHelpers {
  static func agentLabel(for session: RootSessionNode) -> String {
    session.displayTitle
  }

  static func projectName(for session: RootSessionNode) -> String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
  }

  static func branch(for session: RootSessionNode, maxLength: Int) -> String? {
    guard let branch = session.branch, !branch.isEmpty else { return nil }
    if branch.count > maxLength {
      return String(branch.prefix(maxLength - 2)) + "…"
    }
    return branch
  }

  static func contextLine(for session: RootSessionNode) -> String? {
    session.contextLine
  }

  static func recency(for session: RootSessionNode) -> String? {
    DashboardFormatters.recency(for: session.lastActivityAt ?? session.startedAt)
  }

  private static func hasExplicitTitle(_ session: RootSessionNode) -> Bool {
    [session.displayTitle].contains { value in
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  @ViewBuilder
  static func baseContextMenu(for session: RootSessionNode) -> some View {
    Button {
      _ = Platform.services.revealInFileBrowser(session.projectPath)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      let command = "claude --resume \(session.sessionId)"
      Platform.services.copyToClipboard(command)
    } label: {
      Label("Copy Resume Command", systemImage: "doc.on.doc")
    }
  }

}
