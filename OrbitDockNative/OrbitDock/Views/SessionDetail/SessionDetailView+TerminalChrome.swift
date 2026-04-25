import SwiftUI

extension SessionDetailView {
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

  @ViewBuilder
  var terminalStripSection: some View {
    if screenPresentation.isDirect {
      EmptyView()
    } else if viewModel.terminal.showPanel,
      let terminalId = viewModel.terminal.activeTerminalId,
      let session = terminalRegistry.session(for: terminalId)
    {
      VStack(spacing: 0) {
        TerminalLiveStrip(session: session, onTap: {
          handleTerminalStripTap(session: session)
        }, fallbackPath: screenPresentation.projectPath)
        .transition(.move(edge: .bottom).combined(with: .opacity))

        if !isCompactLayout && viewModel.terminal.showInlineTerminal {
          terminalPanel(session: session)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      #if os(iOS)
        .fullScreenCover(isPresented: $viewModel.terminal.showInteractiveSheet) {
          TerminalInteractiveSheet(session: session)
        }
      #endif
    } else if screenPresentation.isActive {
      terminalLaunchStrip
    }
  }

  var directSessionFooter: some View {
    VStack(spacing: 0) {
      if screenPresentation.isActive || screenPresentation.displayStatus != .ended {
        directSessionDockHeader
      }

      if !isCompactLayout, let session = controlDeckTerminalSession, viewModel.terminal.showInlineTerminal {
        dividerLine

        terminalPanel(session: session)
          .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      dividerLine

      ControlDeckScreen(
        sessionId: sessionId,
        interaction: viewModel.interaction,
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
      .fullScreenCover(isPresented: $viewModel.terminal.showInteractiveSheet) {
        if let session = controlDeckTerminalSession {
          TerminalInteractiveSheet(session: session)
        } else {
          Color.clear
        }
      }
    #endif
  }

  @ViewBuilder
  var topChrome: some View {
    #if os(macOS)
      HeaderView(
        sessionId: sessionId,
        endpointId: endpointId,
        presentation: screenPresentation,
        codexAccountStatus: scopedSession.codexAccountStatus,
        onEndSession: screenPresentation.isActive ? { viewModel.endSession() } : nil,
        onManageCapabilities: screenPresentation.provider == .codex ? { openCapabilitiesSheet() } : nil,
        layoutConfig: screenPresentation.isDirect ? $viewModel.layoutConfig : nil,
        chatViewMode: $chatViewMode,
        workerPanelVisible: $showWorkerPanel,
        hasWorkerPanelContent: workerRosterPresentation != nil
      )

      Divider()
        .foregroundStyle(Color.panelBorder)
    #else
      iOSStatusStrip

      Divider()
        .foregroundStyle(Color.panelBorder)
    #endif
  }

  private var controlDeckTerminalSession: TerminalSessionController? {
    guard viewModel.terminal.showPanel,
      let terminalId = viewModel.terminal.activeTerminalId
    else { return nil }
    return terminalRegistry.session(for: terminalId)
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
    if isCompactLayout {
      #if os(iOS)
        viewModel.terminal.showInteractiveSheet = true
      #endif
    } else {
      withAnimation(Motion.gentle) {
        viewModel.terminal.showInlineTerminal.toggle()
      }
    }
  }

  private func launchTerminal() {
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

    withAnimation(Motion.gentle) {
      viewModel.terminal.activeTerminalId = terminalId
      viewModel.terminal.showPanel = true
      if isCompactLayout {
        #if os(iOS)
          viewModel.terminal.showInteractiveSheet = true
        #endif
      } else {
        viewModel.terminal.showInlineTerminal = true
      }
    }
    Platform.services.playHaptic(.selection)

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

  private func terminalPanel(session: TerminalSessionController) -> some View {
    TerminalView(session: session)
      .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
      .background(Color.backgroundCode)
  }
}
