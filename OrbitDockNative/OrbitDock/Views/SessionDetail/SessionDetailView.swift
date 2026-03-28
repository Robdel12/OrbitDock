//
//  SessionDetailView.swift
//  OrbitDock
//

import SwiftUI

struct SessionDetailView: View {
  @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
  @Environment(TerminalSessionRegistry.self) var terminalRegistry
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @Environment(\.modelPricingService) var modelPricingService
  @Environment(AppRouter.self) var router
  let sessionId: String
  let endpointId: UUID
  let sessionStore: SessionStore

  var scopedServerState: SessionStore {
    viewModel.sessionStore
  }

  @State var viewModel = SessionDetailViewModel()

  @AppStorage("chatViewMode") var chatViewMode: ChatViewMode = .focused
  @AppStorage("sessionDetail.showWorkerPanel") var showWorkerPanel = false

  var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  var actionBarState: SessionDetailActionBarState {
    viewModel.actionBarState
  }

  var screenPresentation: SessionDetailScreenPresentation {
    viewModel.screenPresentation
  }

  var body: some View {
    VStack(spacing: 0) {
      #if os(macOS)
        // Custom header on macOS (no native nav bar)
        HeaderView(
          sessionId: sessionId,
          endpointId: endpointId,
          presentation: screenPresentation,
          codexAccountStatus: scopedServerState.codexAccountStatus,
          onEndSession: screenPresentation.isActive ? { viewModel.endSession() } : nil,
          layoutConfig: screenPresentation.isDirect ? $viewModel.layoutConfig : nil,
          chatViewMode: $chatViewMode,
          workerPanelVisible: $showWorkerPanel,
          hasWorkerPanelContent: workerRosterPresentation != nil
        )

        Divider()
          .foregroundStyle(Color.panelBorder)
      #else
        // iOS: status strip only (native nav bar handles title + back)
        iOSStatusStrip

        Divider()
          .foregroundStyle(Color.panelBorder)
      #endif

      // Diff-available banner
      if viewModel.showDiffBanner, viewModel.layoutConfig == .conversationOnly {
        diffAvailableBanner
      }

      // Worktree cleanup banner
      if showWorktreeCleanupBanner {
        worktreeCleanupBanner
      }

      // Mission context banner
      if let issueId = screenPresentation.issueIdentifier {
        missionContextBanner(issueIdentifier: issueId, missionId: screenPresentation.missionId)
      }

      SessionDetailMainContentArea(layoutConfig: viewModel.layoutConfig) {
        conversationContent
      } review: {
        reviewCanvas
      } companion: {
        workerCompanionPanel
      }

      // Terminal bottom panel
      if viewModel.showTerminalPanel,
         let terminalId = viewModel.activeTerminalId,
         let session = terminalRegistry.session(for: terminalId) {
        Divider().foregroundStyle(Color.panelBorder)
        terminalPanel(session: session)
      }

      SessionDetailFooter(mode: footerMode) {
        DirectSessionComposer(
          sessionId: sessionId,
          sessionStore: scopedServerState,
          selectedSkills: $viewModel.selectedSkills,
          pendingPanelOpenSignal: viewModel.pendingApprovalPanelOpenSignal,
          followMode: viewModel.followMode,
          unreadCount: viewModel.unreadCount,
          onJumpToLatest: viewModel.jumpConversationToLatest,
          onTogglePinned: viewModel.toggleConversationFollowMode,
          onOpenTerminal: { terminalId in
            withAnimation(Motion.gentle) {
              viewModel.activeTerminalId = terminalId
              viewModel.showTerminalPanel = true
            }
          }
        )
      } takeOverBar: {
        TakeOverInputBar(
          onTakeOver: {
            Task { try? await scopedServerState.takeoverSession(sessionId) }
          },
          statusContent: {
            if isCompactLayout {
              passiveStatusStrip
            }
          }
        )
      } passiveActionBar: {
        actionBar
      }
    }
    .background(Color.backgroundPrimary)
    .task(id: "\(endpointId.uuidString):\(sessionId)") {
      viewModel.bind(
        sessionId: sessionId,
        endpointId: endpointId,
        runtimeRegistry: runtimeRegistry,
        fallbackStore: sessionStore,
        modelPricingService: modelPricingService
      )
      if showWorkerPanel {
        viewModel.loadSelectedWorkerTools()
      }
    }
    #if os(iOS)
    .navigationTitle(screenPresentation.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button { router.openQuickSwitcher() } label: {
          Image(systemName: "magnifyingglass")
        }
        iOSOverflowMenu
      }
    }
    #endif
    .environment(scopedServerState)
    .onChange(of: showWorkerPanel) { _, visible in
      guard visible else { return }
      viewModel.loadSelectedWorkerTools()
    }
    // Layout keyboard shortcuts
    .onKeyPress(phases: .down) { keyPress in
      guard let command = SessionDetailShortcutPlanner.command(
        isDirect: screenPresentation.isDirect,
        modifiers: keyPress.modifiers,
        key: keyPress.key
      ) else {
        return .ignored
      }

      withAnimation(Motion.gentle) {
        viewModel.selectLayout(
          SessionDetailShortcutPlanner.nextLayout(
            currentLayout: viewModel.layoutConfig,
            command: command
          )
        )
      }
      return .handled
    }
    // Diff-available banner trigger
    .onChange(of: viewModel.reviewState.diff) { oldDiff, newDiff in
      handleDiffChange(oldDiff: oldDiff, newDiff: newDiff)
    }
  }

  var sessionDetailWorktreeCleanupState: SessionDetailWorktreeCleanupBannerState? {
    viewModel.sessionDetailWorktreeCleanupState
  }

  // MARK: - iOS Native Nav Bar

  #if os(iOS)
    private var iOSStatusStrip: some View {
      HStack(spacing: Spacing.sm) {
        HeaderCompactStatusBadge(
          presentation: HeaderCompactPresentation.build(
            workStatus: screenPresentation.workStatus,
            provider: screenPresentation.provider,
            model: screenPresentation.model,
            effort: screenPresentation.effort
          )
        )
        .layoutPriority(1)

        Spacer(minLength: 0)

        ConversationViewModeToggle(
          chatViewMode: $chatViewMode,
          showsContainerChrome: false
        )
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(Color.backgroundSecondary)
    }

    private var iOSOverflowMenu: some View {
      Menu {
        // Session info
        if let endpointName = screenPresentation.endpointName {
          Text("Endpoint: \(endpointName)")
        }
        ForEach(screenPresentation.capabilities) { cap in
          if let icon = cap.icon {
            Label(cap.label, systemImage: icon)
          } else {
            Text(cap.label)
          }
        }

        Divider()

        // Layout (only for direct sessions)
        if screenPresentation.isDirect {
          Section("Layout") {
            ForEach(LayoutConfiguration.allCases, id: \.self) { config in
              Button {
                withAnimation(Motion.gentle) {
                  viewModel.selectLayout(config)
                }
              } label: {
                Label(config.label, systemImage: config.icon)
              }
            }
          }
        }

        HeaderContinuationMenuSection(
          continuation: screenPresentation.continuation
        )

        Divider()

        HeaderDebugContextMenu(
          sessionId: screenPresentation.debugContext.sessionId,
          threadId: screenPresentation.debugContext.threadId,
          projectPath: screenPresentation.debugContext.projectPath,
          provider: screenPresentation.debugContext.provider,
          codexIntegrationMode: screenPresentation.debugContext.codexIntegrationMode,
          claudeIntegrationMode: screenPresentation.debugContext.claudeIntegrationMode
        )

        if screenPresentation.isActive {
          Divider()
          Button(role: .destructive) {
            viewModel.endSession()
          } label: {
            Label("End Session", systemImage: "stop.circle")
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
    }
  #endif

  // MARK: - Action Bar

  var actionBar: some View {
    Group {
      if isCompactLayout {
        compactActionBar
      } else {
        regularActionBar
      }
    }
  }

  // Remaining sections and imperative handlers live in companion files so this root
  // stays focused on feature composition and lifecycle wiring.

  // MARK: - Mission Context Banner

  func missionContextBanner(issueIdentifier: String, missionId: String?) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "target")
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(.blue)

      Text(issueIdentifier)
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(.blue)

      Text("Mission session")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)

      Spacer()

      if let missionId {
        Button {
          router.navigateToMission(missionId: missionId, endpointId: endpointId)
        } label: {
          Text("View Mission")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.blue.opacity(0.08))
  }

  // MARK: - Terminal Panel

  func terminalPanel(session: TerminalSessionController) -> some View {
    VStack(spacing: 0) {
      // Drag handle + title bar
      HStack(spacing: Spacing.sm) {
        Button {
          withAnimation(Motion.gentle) {
            viewModel.showTerminalPanel = false
          }
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .frame(width: 22, height: 22)
            .background(Color.surfaceHover.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .help("Close terminal")

        Image(systemName: "terminal")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.terminal)

        Text(session.title)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)

        Spacer()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
      .background(Color.backgroundCode.opacity(0.8))

      // Terminal renderer
      TerminalView(session: session)
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
    }
    .background(Color.backgroundCode)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  // MARK: - Helpers

  var shouldSubscribeToServerSession: Bool {
    viewModel.shouldSubscribeToServerSession
  }
}

#Preview {
  SessionDetailView(
    sessionId: "preview-123",
    endpointId: UUID(),
    sessionStore: SessionStore.preview()
  )
  .environment(AttentionService())
  .environment(AppRouter())
  .frame(width: 800, height: 600)
}
