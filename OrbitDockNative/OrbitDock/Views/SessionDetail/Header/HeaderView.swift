import SwiftUI

struct HeaderView: View {
  @Environment(AppRouter.self) private var router
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let sessionId: String
  let endpointId: UUID
  let presentation: SessionDetailScreenPresentation
  let codexAccountStatus: ServerCodexAccountStatus?
  var onEndSession: (() -> Void)?
  var layoutConfig: Binding<LayoutConfiguration>?
  var chatViewMode: Binding<ChatViewMode>?
  var workerPanelVisible: Binding<Bool>?
  var hasWorkerPanelContent = false

  @State private var isHoveringBack = false

  private var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  private var chromePresentation: HeaderViewPresentation {
    HeaderViewPlanner.presentation(
      hasLayoutToggle: layoutConfig != nil,
      hasChatModeToggle: chatViewMode != nil,
      compactLayout: layoutConfig?.wrappedValue
    )
  }

  private var currentContinuation: SessionContinuation {
    presentation.continuation
  }

  var body: some View {
    HeaderShell {
      Group {
        if isCompactLayout {
          compactHeader
        } else {
          regularHeader
        }
      }
    }
  }

  private var regularHeader: some View {
    HStack(alignment: .center, spacing: Spacing.md) {
      backButton

      titleRow
        .frame(maxWidth: .infinity, alignment: .leading)

      controlTray
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.panelBorder.opacity(0.55), lineWidth: 1)
    )
  }

  private var compactHeader: some View {
    HStack(spacing: Spacing.sm) {
      compactBackButton

      compactTitleRow
        .frame(maxWidth: .infinity, alignment: .leading)

      compactControlCluster
      compactOverflowMenu
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.panelBorder.opacity(0.55), lineWidth: 1)
    )
  }

  private var backButton: some View {
    Button(action: {
      Platform.services.playHaptic(.navigation)
      router.goToDashboard(source: .sessionHeader)
    }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "chevron.left")
          .font(.system(size: TypeScale.caption, weight: .semibold))
        Text("Dashboard")
          .font(.system(size: TypeScale.body, weight: .medium))
      }
      .foregroundStyle(isHoveringBack ? Color.textPrimary : Color.textSecondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(isHoveringBack ? Color.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: Radius.md))
    }
    .buttonStyle(.plain)
    .onHover { isHoveringBack = $0 }
    .help("Go to dashboard (⌘0)")
  }

  private var compactBackButton: some View {
    Button(action: { router.goToDashboard(source: .sessionHeader) }) {
      Image(systemName: "chevron.left")
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover.opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.md))
    }
    .buttonStyle(.plain)
    .help("Dashboard (⌘0)")
  }

  private var titleRow: some View {
    Button(action: { router.openQuickSwitcher() }) {
      HStack(spacing: Spacing.sm) {
        SessionStatusDot(status: presentation.displayStatus, size: 9)

        Text(presentation.displayName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)

        Image(systemName: "chevron.down")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      if let endpointName = presentation.endpointName {
        Text("Endpoint: \(endpointName)")
      }
      ForEach(presentation.capabilities) { cap in
        if let icon = cap.icon {
          Label(cap.label, systemImage: icon)
        } else {
          Text(cap.label)
        }
      }
      Divider()
      HeaderDebugContextMenu(
        sessionId: presentation.debugContext.sessionId,
        threadId: presentation.debugContext.threadId,
        projectPath: presentation.debugContext.projectPath,
        provider: presentation.debugContext.provider,
        codexIntegrationMode: presentation.debugContext.codexIntegrationMode,
        claudeIntegrationMode: presentation.debugContext.claudeIntegrationMode
      )
    }
  }

  private var compactTitleRow: some View {
    HStack(spacing: Spacing.sm) {
      SessionStatusDot(status: presentation.displayStatus, size: 8)
      Text(presentation.displayName)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
      Image(systemName: "chevron.down")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    }
  }

  private var controlTray: some View {
    HStack(spacing: Spacing.xs) {
      if let chatModeBinding = chatViewMode {
        ConversationViewModeToggle(
          chatViewMode: chatModeBinding,
          presentation: .compactLabeled,
          showsContainerChrome: false
        )
      }

      if let layoutBinding = layoutConfig {
        layoutToggle(layoutBinding)
      }

      if let workerPanelVisible, hasWorkerPanelContent {
        workerPanelToggle(workerPanelVisible)
      }

      navButton(icon: "magnifyingglass", action: { router.openQuickSwitcher() }, help: "Search sessions (⌘K)")
      overflowMenu
    }
  }

  private var compactControlCluster: some View {
    HStack(spacing: Spacing.xs) {
      if let layoutBinding = layoutConfig {
        compactLayoutToggle(layoutBinding)
      }

      if let workerPanelVisible, hasWorkerPanelContent {
        compactWorkerPanelToggle(workerPanelVisible)
      }

      if chromePresentation.showsConversationModeToggleInCompact, let chatModeBinding = chatViewMode {
        ConversationViewModeToggle(
          chatViewMode: chatModeBinding,
          showsContainerChrome: false
        )
      }
    }
  }

  private var overflowMenu: some View {
    Menu {
      HeaderContinuationMenuSection(continuation: currentContinuation)

      if presentation.isActive, let onEnd = onEndSession {
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
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover.opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(Color.surfaceBorder.opacity(0.3), lineWidth: 1)
        )
    }
    .menuStyle(.borderlessButton)
    .help("More options")
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

      HeaderContinuationMenuSection(continuation: currentContinuation)

      if presentation.isActive, let onEnd = onEndSession {
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
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover.opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.md))
    }
    .menuStyle(.borderlessButton)
    .help("More")
  }

  private func navButton(icon: String, action: @escaping () -> Void, help: String) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover.opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(Color.surfaceBorder.opacity(0.3), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private func layoutToggle(_ binding: Binding<LayoutConfiguration>) -> some View {
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
            .frame(width: 26, height: 22)
            .background(
              isSelected ? Color.accent.opacity(OpacityTier.light) : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(Spacing.xxs)
    .background(Color.surfaceHover.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.md))
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

  private func workerPanelToggle(_ binding: Binding<Bool>) -> some View {
    let isVisible = binding.wrappedValue
    return Button {
      withAnimation(Motion.gentle) {
        binding.wrappedValue.toggle()
      }
    } label: {
      Image(systemName: "person.2.crop.square.stack.fill")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(isVisible ? Color.accent : Color.textSecondary)
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover.opacity(0.75), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(isVisible ? Color.accent.opacity(0.55) : Color.surfaceBorder.opacity(0.3), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help(isVisible ? "Hide workers" : "Show workers")
  }

  private func compactWorkerPanelToggle(_ binding: Binding<Bool>) -> some View {
    let isVisible = binding.wrappedValue
    return Button {
      withAnimation(Motion.gentle) {
        binding.wrappedValue.toggle()
      }
    } label: {
      Image(systemName: "person.2.crop.square.stack.fill")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(isVisible ? Color.accent : Color.textSecondary)
        .frame(width: 24, height: 22)
        .background(
          isVisible ? Color.accent.opacity(OpacityTier.light) : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .help(isVisible ? "Hide workers" : "Show workers")
  }
}

#Preview {
  let store = SessionStore.preview()
  let session = store.session("test-123")
  let headerPresentation = SessionDetailScreenPresentation(
    displayName: session.displayName,
    isDirect: session.isDirect,
    isActive: session.isActive,
    displayStatus: session.displayStatus,
    workStatus: session.workStatus,
    provider: session.provider,
    model: session.model,
    effort: session.effort,
    endpointName: session.endpointName,
    projectPath: session.projectPath,
    issueIdentifier: session.issueIdentifier,
    missionId: session.missionId,
    capabilities: session.isDirect ? [.direct] : (session.provider == .codex ? [.passive] : []),
    continuation: SessionContinuation(
      endpointId: UUID(),
      sessionId: "test-123",
      provider: session.provider,
      displayName: session.displayName,
      projectPath: session.projectPath,
      model: session.model,
      hasGitRepository: session.branch != nil || session.repositoryRoot != nil || session.isWorktree
    ),
    debugContext: SessionDetailDebugContext(
      sessionId: "test-123",
      threadId: session.codexThreadId,
      projectPath: session.projectPath,
      provider: session.provider,
      codexIntegrationMode: session.codexIntegrationMode.map { String(describing: $0) },
      claudeIntegrationMode: session.claudeIntegrationMode.map { String(describing: $0) }
    )
  )

  VStack(spacing: 0) {
    HeaderView(
      sessionId: "test-123",
      endpointId: UUID(),
      presentation: headerPresentation,
      codexAccountStatus: nil
    )
    .environment(AppRouter())

    Divider().opacity(0.3)

    Color.backgroundPrimary
      .frame(height: 400)
  }
  .frame(width: 900)
  .background(Color.backgroundPrimary)
}
