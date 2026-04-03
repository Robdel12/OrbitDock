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
  @State private var isDirectControlDeckFocused = false

  @AppStorage("chatViewMode") var chatViewMode: ChatViewMode = .focused
  @AppStorage("sessionDetail.showWorkerPanel") var showWorkerPanel = false
  private var bindingIdentity: String {
    let resolvedStore = runtimeRegistry.sessionStore(for: endpointId, fallback: sessionStore)
    return "\(endpointId.uuidString):\(sessionId):\(ObjectIdentifier(resolvedStore))"
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

      terminalStripSection

      SessionDetailFooter(mode: footerMode) {
        directSessionFooter
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
    .task(id: bindingIdentity) {
      viewModel.bind(
        sessionId: sessionId,
        endpointId: endpointId,
        runtimeRegistry: runtimeRegistry,
        fallbackStore: sessionStore,
        modelPricingService: modelPricingService
      )
      // Restore terminal if one already exists in the registry for this session
      if viewModel.activeTerminalId == nil {
        let prefix = "term-\(sessionId)-"
        if let existingId = terminalRegistry.sessions.keys.first(where: { $0.hasPrefix(prefix) }) {
          viewModel.activeTerminalId = existingId
          viewModel.showTerminalPanel = true
        }
      }
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

  // MARK: - Terminal Strip

  private var controlDeckTerminalSession: TerminalSessionController? {
    guard viewModel.showTerminalPanel,
          let terminalId = viewModel.activeTerminalId
    else { return nil }
    return terminalRegistry.session(for: terminalId)
  }

  @ViewBuilder
  var terminalStripSection: some View {
    if screenPresentation.isDirect {
      EmptyView()
    } else if viewModel.showTerminalPanel,
       let terminalId = viewModel.activeTerminalId,
       let session = terminalRegistry.session(for: terminalId) {
      VStack(spacing: 0) {
        TerminalLiveStrip(session: session, onTap: {
          handleTerminalStripTap(session: session)
        }, fallbackPath: screenPresentation.projectPath)
        .transition(.move(edge: .bottom).combined(with: .opacity))

        #if os(macOS)
        if viewModel.showInlineTerminal {
          terminalPanel(session: session)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        #endif
      }
      #if os(iOS)
      .fullScreenCover(isPresented: $viewModel.showTerminalInteractiveSheet) {
        TerminalInteractiveSheet(session: session)
      }
      #endif
    } else if screenPresentation.isActive {
      // No terminal — show launch button
      terminalLaunchStrip
    }
  }

  private var directSessionFooter: some View {
    VStack(spacing: 0) {
      if screenPresentation.isActive || screenPresentation.displayStatus != .ended {
        directSessionDockHeader
      }

      #if os(macOS)
        if let session = controlDeckTerminalSession, viewModel.showInlineTerminal {
          dividerLine

          terminalPanel(session: session)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      #endif

      dividerLine

      ControlDeckScreen(
        sessionId: sessionId,
        sessionStore: scopedServerState,
        chromeStyle: .embedded,
        terminalTitle: controlDeckTerminalSession?.title,
        sessionDisplayStatus: screenPresentation.displayStatus,
        currentTool: currentTool,
        onFocusStateChange: { isDirectControlDeckFocused = $0 },
        onToggleTerminal: {
          if let session = controlDeckTerminalSession {
            handleTerminalStripTap(session: session)
          }
        }
      )
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(
          directSessionControlDeckBorderColor,
          lineWidth: directSessionControlDeckBorderWidth
        )
    )
    .padding(.horizontal, Spacing.sm)
    .padding(.bottom, Spacing.xs)
    #if os(iOS)
    .fullScreenCover(isPresented: $viewModel.showTerminalInteractiveSheet) {
      if let session = controlDeckTerminalSession {
        TerminalInteractiveSheet(session: session)
      } else {
        Color.clear
      }
    }
    #endif
  }

  private var directSessionControlDeckBorderColor: Color {
    if screenPresentation.displayStatus == .working {
      return Color.feedbackWarning.opacity(OpacityTier.vivid)
    }
    if isDirectControlDeckFocused {
      return Color.accent.opacity(0.5)
    }
    return Color.panelBorder
  }

  private var directSessionControlDeckBorderWidth: CGFloat {
    isDirectControlDeckFocused || screenPresentation.displayStatus == .working ? 1.25 : 1
  }

  @ViewBuilder
  private var topChrome: some View {
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
  }

  @ViewBuilder
  private var directSessionDockHeader: some View {
    OrbitStatusIndicator(
      displayStatus: screenPresentation.displayStatus,
      currentTool: currentTool,
      chromeStyle: .embedded,
      showsDetail: !isCompactLayout
    )
    .overlay(alignment: .trailing) {
      if let session = controlDeckTerminalSession {
        inlineTerminalStrip(session: session)
          .padding(.trailing, Spacing.md)
      } else if screenPresentation.isActive {
        inlineTerminalLaunchStrip
          .padding(.trailing, Spacing.md)
      }
    }
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.xxs)
  }

  private var dividerLine: some View {
    Color.surfaceBorder.opacity(0.28)
      .frame(height: 1)
      .padding(.horizontal, Spacing.md)
  }

  private var terminalLaunchTitle: String {
    shortenedTerminalPath(screenPresentation.projectPath) ?? "Launch interactive shell"
  }

  private func inlineTerminalTitle(_ session: TerminalSessionController) -> String {
    let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty || title == "Terminal" {
      return shortenedTerminalPath(screenPresentation.projectPath) ?? "Terminal"
    }
    if title.contains("/") {
      return shortenedTerminalPath(title) ?? title
    }
    return title
  }

  private func inlineTerminalStrip(session: TerminalSessionController) -> some View {
    Button {
      handleTerminalStripTap(session: session)
    } label: {
      HStack(spacing: Spacing.xs) {
        Text("Terminal")
          .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
        if !isCompactLayout {
          Text("·")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
          Text(inlineTerminalTitle(session))
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }
      .padding(.leading, Spacing.sm)
      .frame(maxWidth: isCompactLayout ? 160 : 420, alignment: .trailing)
    }
    .buttonStyle(.plain)
  }

  private var inlineTerminalLaunchStrip: some View {
    Button {
      launchTerminal()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "chevron.right")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.terminal)
        Text("Terminal")
          .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
        if !isCompactLayout {
          Text("·")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
          Text(terminalLaunchTitle)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
          Image(systemName: "plus.circle.fill")
            .font(.system(size: IconScale.xs, weight: .bold))
            .foregroundStyle(Color.accent)
        }
      }
      .padding(.leading, Spacing.sm)
      .frame(maxWidth: isCompactLayout ? 160 : 420, alignment: .trailing)
    }
    .buttonStyle(.plain)
    .help("Launch terminal")
  }

  private var terminalLaunchStrip: some View {
    Button {
      launchTerminal()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
        Image(systemName: "chevron.right")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.terminal)
          .frame(width: 12, height: 16)

        HStack(spacing: Spacing.xs) {
          Text("Terminal")
            .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.textPrimary)

          Text("·")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.textQuaternary)

          Text(terminalLaunchTitle)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        Image(systemName: "plus.circle.fill")
          .font(.system(size: IconScale.xs, weight: .bold))
          .foregroundStyle(Color.accent)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Launch terminal")
  }

  private func shortenedTerminalPath(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let path = trimmed.replacingOccurrences(of: "^~", with: NSHomeDirectory(), options: .regularExpression)
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
      let suffix = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if suffix.isEmpty { return "~" }
      if let last = suffix.split(separator: "/").last {
        return "~/\(last)"
      }
      return "~"
    }

    if let last = path.split(separator: "/").last, !last.isEmpty {
      return String(last)
    }
    return trimmed
  }

  private func handleTerminalStripTap(session: TerminalSessionController) {
    #if os(iOS)
    viewModel.showTerminalInteractiveSheet = true
    #else
    withAnimation(Motion.gentle) {
      viewModel.showInlineTerminal.toggle()
    }
    #endif
  }

  func launchTerminal() {
    let terminalId = "term-\(sessionId)-\(UUID().uuidString.prefix(8).lowercased())"
    let controller = TerminalSessionController(terminalId: terminalId)

    let endpointId = self.endpointId
    controller.sendToServer = { [weak runtimeRegistry] data in
      guard let runtime = runtimeRegistry?.runtimesByEndpointId[endpointId] else { return }
      runtime.connection.sendTerminalInput(terminalId: terminalId, data: data)
    }
    controller.sendResize = { [weak runtimeRegistry] cols, rows in
      guard let runtime = runtimeRegistry?.runtimesByEndpointId[endpointId] else { return }
      runtime.connection.sendTerminalResize(terminalId: terminalId, cols: cols, rows: rows)
    }

    terminalRegistry.register(controller)

    // Show strip and open terminal immediately
    withAnimation(Motion.gentle) {
      viewModel.activeTerminalId = terminalId
      viewModel.showTerminalPanel = true
      #if os(iOS)
      viewModel.showTerminalInteractiveSheet = true
      #else
      viewModel.showInlineTerminal = true
      #endif
    }
    Platform.services.playHaptic(.selection)

    // Wire server connection and create PTY
    let cwd = screenPresentation.projectPath
    if let runtime = runtimeRegistry.runtimesByEndpointId[endpointId] {
      let token = runtime.connection.addListener { [weak controller] event in
        switch event {
        case let .terminalOutput(tid, data) where tid == terminalId:
          controller?.feedOutput(data)
          controller?.setConnected(true)
        case let .terminalExited(tid, _) where tid == terminalId:
          controller?.setConnected(false)
          controller?.removeListener?()
        default:
          break
        }
      }
      let connection = runtime.connection
      controller.removeListener = { [weak connection] in
        connection?.removeListener(token)
      }

      connection.sendCreateTerminal(
        terminalId: terminalId,
        cwd: cwd.isEmpty ? "~" : cwd,
        cols: 80,
        rows: 24,
        sessionId: sessionId
      )
    }
  }

  // MARK: - Terminal Panel (macOS inline)

  #if os(macOS)
  func terminalPanel(session: TerminalSessionController) -> some View {
    TerminalView(session: session)
      .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
      .background(Color.backgroundCode)
  }
  #endif

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
