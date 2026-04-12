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

  @State var viewModel: SessionDetailViewModel
  @State var isDirectControlDeckFocused = false

  init(sessionId: String, endpointId: UUID, sessionStore: SessionStore) {
    self.sessionId = sessionId
    self.endpointId = endpointId
    self.sessionStore = sessionStore
    _viewModel = State(
      initialValue: SessionDetailViewModel(
        sessionId: sessionId,
        endpointId: endpointId,
        sessionStore: sessionStore
      )
    )
  }

  var scopedServerState: SessionStore {
    sessionStore
  }

  @AppStorage("chatViewMode") var chatViewMode: ChatViewMode = .focused
  @AppStorage("sessionDetail.showWorkerPanel") var showWorkerPanel = false
  private var bindingIdentity: String {
    "\(endpointId.uuidString):\(sessionId):\(ObjectIdentifier(sessionStore))"
  }

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
      topChrome

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

      terminalStripSection

      SessionDetailFooter(mode: footerMode) {
        directSessionFooter
      } takeOverBar: {
        TakeOverInputBar(
          onTakeOver: {
            Task {
              try? await scopedServerState.takeoverSession(
                sessionId,
                model: nil, approvalPolicy: nil, approvalPolicyDetails: nil,
                sandboxMode: nil, permissionMode: nil, collaborationMode: nil,
                multiAgent: nil, personality: nil, serviceTier: nil,
                developerInstructions: nil
              )
            }
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
    .task(id: bindingIdentity) {
      viewModel.bind(
        sessionId: sessionId,
        endpointId: endpointId,
        sessionStore: sessionStore,
        modelPricingService: modelPricingService
      )
      await viewModel.refresh()
      // Restore terminal if one already exists in the registry for this session
      if viewModel.terminal.activeTerminalId == nil {
        let prefix = "term-\(sessionId)-"
        if let existingId = terminalRegistry.sessions.keys.first(where: { $0.hasPrefix(prefix) }) {
          viewModel.terminal.activeTerminalId = existingId
          viewModel.terminal.showPanel = true
        }
      }
      if showWorkerPanel {
        viewModel.worker.loadDetails(
          sessionId: sessionId,
          sessionStore: scopedServerState,
          layoutConfig: viewModel.layoutConfig
        )
      }
    }
    .task(id: bindingIdentity + ":ws") {
      let (stream, _) = sessionStore.sessionDetailRefreshRequests(for: sessionId)
      for await _ in stream {
        await viewModel.refresh()
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
      viewModel.worker.loadDetails(
        sessionId: sessionId,
        sessionStore: scopedServerState,
        layoutConfig: viewModel.layoutConfig
      )
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
    .onChange(of: viewModel.reviewState.turnCount) { oldCount, newCount in
      handleReviewTurnCountChange(oldCount: oldCount, newCount: newCount)
    }
    .focusedSceneValue(\.sessionDetailTerminalToggle) {
      viewModel.terminal.showPanel.toggle()
    }
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

  var shouldSubscribeToServerSession: Bool {
    viewModel.shouldSubscribeToServerSession
  }
}

private struct SessionDetailTerminalToggleFocusedValueKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var sessionDetailTerminalToggle: (() -> Void)? {
    get { self[SessionDetailTerminalToggleFocusedValueKey.self] }
    set { self[SessionDetailTerminalToggleFocusedValueKey.self] = newValue }
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
