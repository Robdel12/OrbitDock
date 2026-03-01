//
//  FlatSessionRow.swift
//  OrbitDock
//
//  Two-line session row for project stream. Prioritizes scannability:
//  Line 1: status dot + identity (branch + name) + model + duration
//  Line 2: first prompt snippet for context
//

import SwiftUI

struct FlatSessionRow: View {
  let session: Session
  let onSelect: () -> Void
  var isSelected: Bool = false
  var hideBranch: Bool = false

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerAppState.self) private var serverState
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

  /// Whether the label is a real name vs a first-prompt fallback.
  /// The rollout watcher stuffs first_prompt into custom_name as a placeholder —
  /// detect that and treat it as "no real name".
  private var hasRealName: Bool {
    if let summary = session.summary, !summary.isEmpty { return true }
    if let custom = session.customName, !custom.isEmpty {
      // If custom_name matches first_prompt, it's not a real name
      if let prompt = session.firstPrompt, !prompt.isEmpty {
        let customClean = custom.trimmingCharacters(in: .whitespaces)
        let promptClean = prompt.strippingXMLTags()
          .replacingOccurrences(of: "\n", with: " ")
          .trimmingCharacters(in: .whitespaces)
        if customClean.hasPrefix(String(promptClean.prefix(40))) {
          return false
        }
      }
      return true
    }
    return false
  }

  /// Smart name: real name → first prompt → generic fallback.
  /// Model shorthand is NOT used — the model badge already shows on the right.
  private var agentLabel: String {
    if hasRealName {
      if let custom = session.customName, !custom.isEmpty {
        return custom.strippingXMLTags()
      }
      if let summary = session.summary, !summary.isEmpty {
        return summary.strippingXMLTags()
      }
    }

    if let prompt = session.firstPrompt, !prompt.isEmpty {
      return cleanPrompt(prompt, maxLength: 65)
    }

    // customName that IS a real name but no first_prompt — use it
    if let custom = session.customName, !custom.isEmpty {
      return custom.strippingXMLTags()
    }

    return "Untitled session"
  }

  /// Context line — shows last message for current activity context,
  /// falling back to first prompt when no last message is available.
  private var contextLine: String? {
    // Prefer last message — shows what's happening now
    if let lastMsg = session.lastMessage, !lastMsg.isEmpty {
      let cleaned = cleanPrompt(lastMsg, maxLength: 80)
      // Don't show if it's identical to the agent label (avoids redundancy)
      if cleaned != agentLabel {
        return cleaned
      }
    }

    // Fall back to first prompt when there's a real name above
    if hasRealName {
      if let prompt = session.firstPrompt, !prompt.isEmpty {
        return cleanPrompt(prompt, maxLength: 80)
      }
    }

    return nil
  }

  private func cleanPrompt(_ prompt: String, maxLength: Int) -> String {
    let clean = prompt.strippingXMLTags()
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    if clean.count > maxLength {
      return String(clean.prefix(maxLength - 3)) + "..."
    }
    return clean
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
    let activity = session.lastActivityAt ?? session.startedAt
    guard let activity else { return nil }
    let interval = Date().timeIntervalSince(activity)

    if interval < 60 {
      return "just now"
    }
    if interval < 3_600 {
      return "\(Int(interval / 60))m"
    }
    if interval < 86_400 {
      let hours = Int(interval / 3_600)
      return "\(hours)h"
    }
    return "\(Int(interval / 86_400))d"
  }

  var body: some View {
    Button(action: onSelect) {
      Group {
        if isPhoneCompact {
          compactRowContent
        } else {
          regularRowContent
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 10)
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
    HStack(spacing: 10) {
      // Status dot
      SessionStatusDot(status: displayStatus, size: 8, showGlow: displayStatus.needsAttention)
        .frame(width: 14)

      // Main content — two lines
      VStack(alignment: .leading, spacing: 1) {
        // Line 1: name + branch + attention pill
        HStack(spacing: 5) {
          Text(agentLabel)
            .font(.system(
              size: hasRealName ? TypeScale.subhead : TypeScale.code,
              weight: hasRealName ? .semibold : .regular
            ))
            .foregroundStyle(hasRealName ? .primary : Color.textSecondary)
            .lineLimit(1)

          if session.endpointName != nil {
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
            HStack(spacing: 3) {
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
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }
      }

      Spacer()

      HStack(spacing: 6) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
    }
  }

  private var compactRowContent: some View {
    HStack(alignment: .top, spacing: 8) {
      SessionStatusDot(status: displayStatus, size: 7, showGlow: displayStatus.needsAttention)
        .frame(width: 12)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 3) {
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
            .foregroundStyle(Color.textQuaternary)
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
      HStack(spacing: 4) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        if session.isDirect {
          directPill
        }
        if let activityRecency {
          recencyBadge(activityRecency)
        }
      }

      HStack(spacing: 4) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        if session.isDirect {
          directPill
        }
      }

      HStack(spacing: 4) {
        SessionStatusBadge(status: displayStatus, showIcon: true, size: .compact)
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
    }
  }

  private var hasCompactSecondaryMeta: Bool {
    session.endpointName != nil || serverState.session(session.id).forkedFrom != nil || inlineBranch != nil || session
      .isWorktree
  }

  private var compactSecondaryMetaRow: some View {
    HStack(spacing: 4) {
      if session.endpointName != nil {
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
      .padding(.vertical, 2)
      .background(Color.accent.opacity(0.10), in: Capsule())
  }

  private func recencyBadge(_ value: String) -> some View {
    Text(value)
      .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.surfaceHover.opacity(0.32), in: Capsule())
  }

  // MARK: - Attention Pill

  private func attentionPill(icon: String, text: String, color: Color) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
      Text(text)
        .font(.system(size: TypeScale.body, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(OpacityTier.light), in: Capsule())
  }

  // MARK: - Background

  private var rowBackground: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(isSelected ? Color.surfaceSelected : (isHovering ? Color.surfaceHover : Color.clear))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .stroke(
              Color.surfaceBorder
                .opacity(isSelected ? OpacityTier.strong : (isHovering ? OpacityTier.medium : OpacityTier.subtle)),
              lineWidth: 1
            )
        )

      // Cyan edge bar when selected
      if isSelected {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(Color.accent)
          .frame(width: EdgeBar.width)
          .padding(.leading, 2)
          .padding(.vertical, Spacing.xs)
      }
    }
    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isSelected)
    .animation(.easeOut(duration: 0.12), value: isHovering)
  }

  // MARK: - Formatting

  private func formatTokens(_ value: Int) -> String {
    if value <= 0 { return "—" }
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
  }
}

#Preview {
  VStack(spacing: 2) {
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
  .padding(16)
  .background(Color.backgroundPrimary)
  .frame(width: 900)
}
