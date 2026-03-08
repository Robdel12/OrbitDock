//
//  FlatSessionRow.swift
//  OrbitDock
//
//  Two-line session row shared by dashboard archive surfaces. Prioritizes scannability:
//  Line 1: unread dot + identity (branch + name) + status + model
//  Line 2: first prompt snippet for context
//

import SwiftUI

struct FlatSessionRow: View {
  let session: Session
  let onSelect: () -> Void
  var isSelected: Bool = false
  var hideBranch: Bool = false
  var isAttentionPromoted: Bool = false

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  private var hasMultipleEndpoints: Bool {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).count > 1
  }

  /// Whether the title comes from a named conversation rather than the prompt fallback.
  private var hasExplicitTitle: Bool {
    [session.customName, session.summary].contains { value in
      guard let value else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var agentLabel: String {
    session.displayName
  }

  /// Context line — shows last message for current activity context,
  /// falling back to first prompt when no last message is available.
  private var contextLine: String? {
    // Prefer last message — shows what's happening now
    if let lastMsg = session.lastMessage, !lastMsg.isEmpty {
      let cleaned = DashboardFormatters.cleanPrompt(lastMsg, maxLength: 100)
      // Don't show if it's identical to the agent label (avoids redundancy)
      if cleaned != agentLabel {
        return cleaned
      }
    }

    // Fall back to first prompt when there's a real name above
    if hasExplicitTitle {
      if let prompt = session.firstPrompt, !prompt.isEmpty {
        return DashboardFormatters.cleanPrompt(prompt, maxLength: 100)
      }
    }

    return nil
  }

  /// Branch to show inline — hidden when suppressed by project header or when on default branch
  private var inlineBranch: String? {
    guard !hideBranch else { return nil }
    guard let branch = session.branch, !branch.isEmpty else { return nil }
    let maxLength = isPhoneCompact ? 16 : 24
    if branch.count > maxLength {
      return String(branch.prefix(maxLength - 2)) + "…"
    }
    return branch
  }

  private var activityRecency: String? {
    DashboardFormatters.recency(for: session.lastActivityAt ?? session.startedAt)
  }

  var body: some View {
    Button {
      Platform.services.playHaptic(.navigation)
      onSelect()
    } label: {
      Group {
        if isPhoneCompact {
          compactRowContent
        } else {
          regularRowContent
        }
      }
      .padding(.vertical, isAttentionPromoted ? Spacing.md : Spacing.md_)
      .padding(.horizontal, Spacing.md_)
      .background(rowBackground)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
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

      if session.isActive, session.isDirect {
        Divider()
        Button(role: .destructive) {
          serverState.endSession(session.id)
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
  }

  private var regularRowContent: some View {
    HStack(spacing: Spacing.md_) {
      // Reserve the leading dot for unread state.
      UnreadIndicatorDot(isVisible: session.hasUnreadMessages, size: 8)
        .frame(width: 14)

      // Main content — two lines
      VStack(alignment: .leading, spacing: 1) {
        // Line 1: name + branch + attention pill
        HStack(spacing: 5) {
          Text(agentLabel)
            .font(.system(
              size: hasExplicitTitle ? TypeScale.subhead : TypeScale.code,
              weight: hasExplicitTitle ? .semibold : .regular
            ))
            .foregroundStyle(hasExplicitTitle ? .primary : Color.textSecondary)
            .lineLimit(1)

          if hasMultipleEndpoints, session.endpointName != nil {
            EndpointBadge(endpointName: session.endpointName)
          }

          if serverState.session(session.id).forkedFrom != nil {
            ForkBadge()
          }

          if serverState.session(session.id).permissionMode == .plan {
            PlanModeBadge()
          }

          // Branch badge — subtle, after the name
          if let branch = inlineBranch {
            HStack(spacing: Spacing.gap) {
              Text(branch)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.gitBranch.opacity(0.7))
                .lineLimit(1)
              if session.isWorktree {
                WorktreeBadge()
              }
            }
          } else if session.isWorktree {
            WorktreeBadge()
          }

          // Attention context (inline pill)
          if displayStatus == .permission, let tool = session.pendingToolName {
            attentionPill(icon: "lock.fill", text: tool, color: .statusPermission)
          } else if displayStatus == .question {
            attentionPill(icon: "questionmark.bubble", text: "Question", color: .statusQuestion)
          }
        }

        // Line 2: context snippet (if available)
        if let context = contextLine {
          Text(context)
            .font(.system(size: TypeScale.caption, weight: .regular))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }

      Spacer()

      HStack(spacing: Spacing.sm_) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
    }
  }

  private var compactRowContent: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      UnreadIndicatorDot(isVisible: session.hasUnreadMessages, size: 7)
        .frame(width: 12)
        .padding(.top, Spacing.xxs)

      VStack(alignment: .leading, spacing: Spacing.gap) {
        HStack(spacing: 5) {
          Text(agentLabel)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if displayStatus == .permission, let tool = session.pendingToolName {
            attentionPill(icon: "lock.fill", text: tool, color: .statusPermission)
          } else if displayStatus == .question {
            attentionPill(icon: "questionmark.bubble", text: "Question", color: .statusQuestion)
          }
        }

        if let context = contextLine {
          Text(context)
            .font(.system(size: TypeScale.caption, weight: .regular))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }

        compactPrimaryMetaRow

        if hasCompactSecondaryMeta {
          compactSecondaryMetaRow
        }
      }

      Spacer(minLength: 0)
    }
  }

  private var compactPrimaryMetaRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.xs) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        if session.isDirect {
          directPill
        }
        if let activityRecency {
          recencyBadge(activityRecency)
        }
      }

      HStack(spacing: Spacing.xs) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        if session.isDirect {
          directPill
        }
      }

      HStack(spacing: Spacing.xs) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
    }
  }

  private var hasCompactSecondaryMeta: Bool {
    (hasMultipleEndpoints && session.endpointName != nil)
      || serverState.session(session.id).forkedFrom != nil || inlineBranch != nil || session
      .isWorktree
  }

  private var compactSecondaryMetaRow: some View {
    HStack(spacing: Spacing.xs) {
      if hasMultipleEndpoints, session.endpointName != nil {
        EndpointBadge(endpointName: session.endpointName)
      }

      if serverState.session(session.id).forkedFrom != nil {
        ForkBadge()
      }

      if let branch = inlineBranch {
        Text(branch)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.gitBranch.opacity(0.72))
          .lineLimit(1)
      }

      if session.isWorktree {
        WorktreeBadge()
      }
    }
  }

  private var directPill: some View {
    Text("direct")
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(Color.accent.opacity(0.65))
      .padding(.horizontal, 5)
      .padding(.vertical, Spacing.xxs)
      .background(Color.accent.opacity(0.10), in: Capsule())
  }

  private func recencyBadge(_ value: String) -> some View {
    Text(value)
      .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .padding(.horizontal, 5)
      .padding(.vertical, Spacing.xxs)
      .background(Color.surfaceHover.opacity(0.32), in: Capsule())
  }

  // MARK: - Attention Pill

  private func attentionPill(icon: String, text: String, color: Color) -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
      Text(text)
        .font(.system(size: TypeScale.body, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xxs)
    .background(color.opacity(OpacityTier.light), in: Capsule())
  }

  // MARK: - Background

  private var rowBackground: some View {
    let attentionColor = displayStatus.color

    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(rowFillColor)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .stroke(rowStrokeColor, lineWidth: isAttentionPromoted ? 1.5 : 1)
        )

      // Edge bar — attention color when promoted, cyan when selected
      if isAttentionPromoted || isSelected {
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(isSelected ? Color.accent : attentionColor)
          .frame(width: EdgeBar.width)
          .padding(.leading, Spacing.xxs)
          .padding(.vertical, Spacing.xs)
      }
    }
    .animation(Motion.snappy, value: isSelected)
    .animation(Motion.hover, value: isHovering)
  }

  private var rowFillColor: Color {
    if isSelected { return Color.surfaceSelected }
    if isAttentionPromoted { return displayStatus.color.opacity(OpacityTier.tint) }
    if isHovering { return Color.surfaceHover }
    return Color.clear
  }

  private var rowStrokeColor: Color {
    if isSelected {
      return Color.surfaceBorder.opacity(OpacityTier.strong)
    }
    if isAttentionPromoted {
      return displayStatus.color.opacity(0.25)
    }
    if isHovering {
      return Color.surfaceBorder.opacity(OpacityTier.medium)
    }
    return Color.surfaceBorder.opacity(OpacityTier.subtle)
  }

}

#Preview {
  VStack(spacing: Spacing.xxs) {
    // Has summary — shows prompt as context
    FlatSessionRow(
      session: Session(
        id: "1",
        projectPath: "/Users/dev/project",
        projectName: "project",
        branch: "main",
        model: "claude-opus-4-5-20251101",
        summary: "Refactoring layout components",
        firstPrompt: "Lets refactor the dashboard to use a flat project-first layout",
        status: .active,
        workStatus: .working,
        startedAt: Date().addingTimeInterval(-2_460),
        totalTokens: 7_600
      ),
      onSelect: {},
      isSelected: true
    )

    // No summary, has first prompt — prompt becomes the label
    FlatSessionRow(
      session: Session(
        id: "2",
        projectPath: "/Users/dev/project",
        projectName: "project",
        branch: "feat/auth",
        model: "claude-sonnet-4-20250514",
        firstPrompt: "Can we create a makefile to wrap up our build commands?",
        status: .active,
        workStatus: .permission,
        startedAt: Date().addingTimeInterval(-720),
        totalTokens: 2_100,
        attentionReason: .awaitingPermission,
        pendingToolName: "Bash"
      ),
      onSelect: {}
    )

    // No summary, no prompt — model shorthand as label
    FlatSessionRow(
      session: Session(
        id: "3",
        projectPath: "/Users/dev/project",
        projectName: "project",
        branch: "main",
        model: "claude-haiku-3-5-20241022",
        status: .active,
        workStatus: .waiting,
        startedAt: Date().addingTimeInterval(-300),
        totalTokens: 500,
        attentionReason: .awaitingReply
      ),
      onSelect: {}
    )

    // Codex session with branch on different project
    FlatSessionRow(
      session: Session(
        id: "4",
        projectPath: "/Users/dev/vizzly",
        projectName: "vizzly",
        branch: "feat/oauth",
        model: "gpt-5.3",
        summary: "Implementing OAuth provider",
        firstPrompt: "Hi claude! Lets implement the OAuth provider for Google",
        status: .active,
        workStatus: .working,
        startedAt: Date().addingTimeInterval(-1_200),
        totalTokens: 12_500,
        provider: .codex
      ),
      onSelect: {}
    )
  }
  .padding(Spacing.lg)
  .background(Color.backgroundPrimary)
  .frame(width: 900)
}
