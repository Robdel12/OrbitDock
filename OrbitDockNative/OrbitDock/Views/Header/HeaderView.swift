//
//  HeaderView.swift
//  OrbitDock
//
//  Compact header bar for session detail view
//

import SwiftUI

struct HeaderView: View {
  @Environment(AppRouter.self) private var router

  let sessionId: String
  let endpointId: UUID
  var onEndSession: (() -> Void)?
  var layoutConfig: Binding<LayoutConfiguration>?
  var chatViewMode: Binding<ChatViewMode>?
  @Binding var selectedCommentIds: Set<String>
  var onNavigateToComment: ((ServerReviewComment) -> Void)?
  var onSendReview: (() -> Void)?

  @Environment(SessionStore.self) private var serverState
  @State private var isHoveringBack = false
  @State private var isHoveringProject = false
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var statusColor: Color {
    switch obs.workStatus {
      case .working: .statusWorking
      case .waiting: .statusReply
      case .permission: .statusPermission
      case .unknown: .statusWorking.opacity(0.6)
    }
  }

  private var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  private var currentContinuation: SessionContinuation {
    SessionContinuation(
      endpointId: endpointId,
      sessionId: sessionId,
      provider: obs.provider,
      displayName: agentName,
      projectPath: obs.projectPath,
      model: obs.model,
      hasGitRepository: obs.branch != nil || obs.repositoryRoot != nil || obs.isWorktree
    )
  }

  var body: some View {
    HeaderShell {
      if isCompactLayout {
        compactHeader
      } else {
        regularHeader
      }
    }
  }

  // MARK: - Layouts

  private var regularHeader: some View {
    HeaderRegularShell(
      leading: {
        backButton
        SessionStatusDot(status: obs.displayStatus, size: 10)
        sessionTitleDropdown
        UnifiedModelBadge(model: obs.model, provider: obs.provider, size: .compact)
        if let effort = HeaderCompactPresentation.effortLabel(for: obs.effort) {
          Text(effort)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(HeaderCompactPresentation.effortColor(for: obs.effort))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(HeaderCompactPresentation.effortColor(for: obs.effort).opacity(0.12), in: Capsule())
        }
      },
      intelligence: {
        if let layoutBinding = layoutConfig {
          ContextualStatusStrip(
            sessionId: sessionId,
            layoutConfig: layoutBinding,
            selectedCommentIds: $selectedCommentIds,
            onNavigateToComment: onNavigateToComment,
            onSendReview: onSendReview
          )
        }
      },
      controls: {
        if let chatModeBinding = chatViewMode {
          ConversationViewModeToggle(chatViewMode: chatModeBinding)
        }

        if let layoutBinding = layoutConfig {
          layoutToggle(layoutBinding)
        }

        HStack(spacing: Spacing.xxs) {
          navButton(icon: "magnifyingglass", action: { router.openQuickSwitcher() }, help: "Search sessions (⌘K)")
          overflowMenu
        }
      }
    )
  }

  // MARK: - Back Button

  private var backButton: some View {
    Button(action: {
      Platform.services.playHaptic(.navigation)
      router.goToDashboard()
    }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "chevron.left")
          .font(.system(size: TypeScale.caption, weight: .semibold))
        Text("Dashboard")
          .font(.system(size: TypeScale.body, weight: .medium))
      }
      .foregroundStyle(isHoveringBack ? Color.textPrimary : Color.textSecondary)
      .padding(.vertical, Spacing.xs)
      .padding(.horizontal, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isHoveringBack ? Color.surfaceHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHoveringBack = $0 }
    .help("Go to dashboard (⌘0)")
  }

  // MARK: - Session Title Dropdown

  private var sessionTitleDropdown: some View {
    Button(action: {
      Platform.services.playHaptic(.selection)
      router.openQuickSwitcher()
    }) {
      HStack(spacing: Spacing.xs) {
        Text(agentName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Image(systemName: "chevron.down")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.vertical, Spacing.xs)
      .padding(.horizontal, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isHoveringProject ? Color.surfaceHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHoveringProject = $0 }
    .contextMenu {
      if obs.endpointName != nil {
        Text("Endpoint: \(obs.endpointName ?? "")")
      }
      ForEach(SessionCapability.capabilities(for: obs)) { cap in
        if let icon = cap.icon {
          Label(cap.label, systemImage: icon)
        } else {
          Text(cap.label)
        }
      }
      Divider()
      debugContextMenu
    }
  }

  // MARK: - Overflow Menu

  private var overflowMenu: some View {
    Menu {
      continueMenuSection

      if obs.isDirect, obs.isActive, let onEnd = onEndSession {
        Divider()
        Button(role: .destructive) {
          onEnd()
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .help("More options")
  }

  private var compactHeader: some View {
    HeaderCompactShell(
      primaryRow: { compactPrimaryRow },
      controlRow: { compactControlRow }
    )
  }

  private var compactPrimaryRow: some View {
    HStack(spacing: Spacing.xs) {
      Button(action: { router.goToDashboard() }) {
        Image(systemName: "chevron.left")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
          .frame(width: 26, height: 26)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
      }
      .buttonStyle(.plain)
      .help("Dashboard (⌘0)")

      Button(action: { router.openQuickSwitcher() }) {
        HStack(spacing: Spacing.xs) {
          SessionStatusDot(status: obs.displayStatus, size: 10)

          Text(agentName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Image(systemName: "chevron.down")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isHoveringProject ? Color.surfaceHover : Color.clear)
        )
      }
      .buttonStyle(.plain)
      .onHover { isHoveringProject = $0 }
      .contextMenu {
        debugContextMenu
      }
      .layoutPriority(1)

      Spacer(minLength: 0)

      navButton(icon: "magnifyingglass", action: { router.openQuickSwitcher() }, help: "Search sessions (⌘K)")

      compactOverflowMenu
    }
    .padding(.horizontal, Spacing.md)
  }

  private var compactControlRow: some View {
    HStack(spacing: Spacing.sm) {
      compactStatusSummaryBadge
        .layoutPriority(1)

      Spacer(minLength: 0)

      if hasCompactModeControls {
        compactModeControls
      }
    }
    .padding(.horizontal, Spacing.md)
  }

  private var compactStatusSummaryBadge: some View {
    HeaderCompactStatusBadge(
      presentation: HeaderCompactPresentation.build(
        workStatus: obs.workStatus,
        provider: obs.provider,
        model: obs.model,
        effort: obs.effort
      )
    )
  }

  private var compactModeControls: some View {
    HStack(spacing: Spacing.xs) {
      if let layoutBinding = layoutConfig {
        compactLayoutToggle(layoutBinding)
      }

      if showsConversationModeToggleInCompact, let chatModeBinding = chatViewMode {
        ConversationViewModeToggle(
          chatViewMode: chatModeBinding,
          showsContainerChrome: false
        )
      }
    }
    .padding(Spacing.xxs)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.58))
    )
    .themeShadow(Shadow.md)
  }

  private func compactLayoutToggle(_ binding: Binding<LayoutConfiguration>) -> some View {
    HStack(spacing: Spacing.xxs) {
      ForEach(LayoutConfiguration.allCases, id: \.self) { config in
        let isSelected = binding.wrappedValue == config
        Button {
          withAnimation(Motion.gentle) {
            binding.wrappedValue = isSelected ? .conversationOnly : config
          }
        } label: {
          Image(systemName: config.icon)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(isSelected ? Color.accent : Color.textSecondary)
            .frame(width: 24, height: 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var hasCompactModeControls: Bool {
    layoutConfig != nil || showsConversationModeToggleInCompact
  }

  private var showsConversationModeToggleInCompact: Bool {
    guard chatViewMode != nil else { return false }
    if let layoutMode = layoutConfig?.wrappedValue, layoutMode == .reviewOnly {
      return false
    }
    return true
  }

  private var compactOverflowMenu: some View {
    Menu {
      if let layoutBinding = layoutConfig {
        Section("Layout") {
          ForEach(LayoutConfiguration.allCases, id: \.self) { config in
            Button {
              withAnimation(Motion.gentle) {
                layoutBinding.wrappedValue = config
              }
            } label: {
              Label(config.label, systemImage: config.icon)
            }
          }
        }
      }

      continueMenuSection

      if obs.isDirect, obs.isActive, let onEnd = onEndSession {
        Divider()
        Button(role: .destructive) {
          onEnd()
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .help("More")
  }

  @ViewBuilder
  private var continueMenuSection: some View {
    Section("Continue In New Session") {
      Button {
        router.openNewSession(provider: .claude, continuation: currentContinuation)
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        router.openNewSession(provider: .codex, continuation: currentContinuation)
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    }
  }

  // MARK: - Nav Button Helper

  private func navButton(
    icon: String,
    action: @escaping () -> Void,
    help: String
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: - Layout Toggle

  private func layoutToggle(_ binding: Binding<LayoutConfiguration>) -> some View {
    HStack(spacing: Spacing.xxs) {
      ForEach(LayoutConfiguration.allCases, id: \.self) { config in
        let isSelected = binding.wrappedValue == config

        Button {
          withAnimation(Motion.gentle) {
            // Clicking the active button toggles back to conversation-only
            binding.wrappedValue = isSelected ? .conversationOnly : config
          }
        } label: {
          Image(systemName: config.icon)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(isSelected ? Color.accent : .secondary)
            .frame(width: 26, height: 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(config.label)
      }
    }
    .padding(Spacing.xxs)
    .background(
      Color.backgroundTertiary.opacity(0.5),
      in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
    )
  }

  // MARK: - Debug Context Menu

  @ViewBuilder
  private var debugContextMenu: some View {
    Button("Copy Session ID") {
      copyToClipboard(sessionId)
    }

    if let threadId = obs.codexThreadId {
      Button("Copy Thread ID") {
        copyToClipboard(threadId)
      }
    }

    Button("Copy Project Path") {
      copyToClipboard(obs.projectPath)
    }

    Divider()

    if let mode = obs.codexIntegrationMode {
      Text("Integration: \(String(describing: mode))")
    }
    if let mode = obs.claudeIntegrationMode {
      Text("Integration: \(String(describing: mode))")
    }
    Text("Provider: \(obs.provider.rawValue)")

    Divider()

    Button("Open Server Log") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/server.log").expandingTildeInPath))
    }

    if obs.provider == .codex {
      Button("Open Codex Log") {
        _ = Platform.services
          .openURL(URL(fileURLWithPath: NSString("~/.orbitdock/logs/codex.log").expandingTildeInPath))
      }
    }

    Button("Open Database") {
      _ = Platform.services.openURL(URL(fileURLWithPath: NSString("~/.orbitdock/orbitdock.db").expandingTildeInPath))
    }
  }

  private func copyToClipboard(_ text: String) {
    Platform.services.copyToClipboard(text)
  }

  // MARK: - Helpers

  private var agentName: String {
    obs.displayName
  }

}

// MARK: - Preview

#Preview {
  @Previewable @State var commentIds: Set<String> = []
  VStack(spacing: 0) {
    HeaderView(
      sessionId: "test-123",
      endpointId: UUID(),
      selectedCommentIds: $commentIds
    )
    .environment(AppRouter())

    Divider().opacity(0.3)

    Color.backgroundPrimary
      .frame(height: 400)
  }
  .frame(width: 900)
  .background(Color.backgroundPrimary)
  .environment(SessionStore())
}
