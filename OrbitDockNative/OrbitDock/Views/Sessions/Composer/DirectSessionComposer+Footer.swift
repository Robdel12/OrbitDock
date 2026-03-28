//
//  DirectSessionComposer+Footer.swift
//  OrbitDock
//
//  Composer footer, control buttons, and overflow menus.
//

import SwiftUI

extension DirectSessionComposer {
  // MARK: - Action Footer (actions + follow + send)

  @ViewBuilder
  var composerFooter: some View {
    if isCompactLayout {
      compactComposerFooter
    } else {
      desktopComposerFooter
    }
  }

  var desktopComposerFooter: some View {
    HStack(spacing: Spacing.xs) {
      desktopComposeControls

      Spacer()

      // Action cluster (varies by state)
      composerFooterActions
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.bottom, Spacing.sm_)
  }

  var isCompactPassiveMode: Bool {
    guard let model = pendingApprovalModel else { return false }
    return model.mode == .takeover || model.mode == .passiveBlocked
  }

  @ViewBuilder
  var compactComposerFooter: some View {
    if isCompactPassiveMode {
      EmptyView()
    } else if let model = pendingApprovalModel, pendingState.isExpanded {
      // Active approval — full-width action bar with approve/deny actions trailing
      HStack(spacing: Spacing.sm_) {
        Spacer(minLength: 0)
        pendingFooterActions(model)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.bottom, Spacing.sm)
    } else {
      HStack(spacing: Spacing.sm_) {
        HStack(spacing: Spacing.xs) {
          compactComposeControls
        }
        Spacer(minLength: 0)
        composerSendButton
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.bottom, Spacing.sm)
    }
  }

  /// Footer action cluster — swaps between normal send and pending approval actions.
  /// Used by desktop layout (compact uses inline send button).
  @ViewBuilder
  var composerFooterActions: some View {
    if let model = pendingApprovalModel, pendingState.isExpanded {
      pendingFooterActions(model)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    } else {
      HStack(spacing: Spacing.sm_) {
        footerFollowControls
        composerSendButton
      }
      .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
  }

  // MARK: - Footer Helpers

  var desktopComposeControls: some View {
    HStack(spacing: Spacing.xs) {
      primaryComposeControls(isCompact: false)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.light))
        .frame(width: 0.5, height: 16)

      desktopWorkflowOverflowMenu
      exitInputModeButton
    }
  }

  var compactComposeControls: some View {
    Group {
      primaryComposeControls(isCompact: true)
      compactWorkflowOverflowMenu
      exitInputModeButton
    }
  }

  @ViewBuilder
  func primaryComposeControls(isCompact: Bool) -> some View {
    if obs.workStatus == .working {
      CodexInterruptButton(workStatus: obs.workStatus, isCompact: isCompact) {
        Task {
          try? await viewModel.interruptSession()
        }
      }
    }

    if obs.isDirectCodex || obs.isDirectClaude {
      providerModelControlButton
    }

    if !isCompact {
      imageAttachmentDockControl
      fileMentionControlButton
    }

    commandDeckControlButton
    terminalControlButton

    if shouldShowDictation {
      dictationControlButton
    }
  }

  @ViewBuilder
  var exitInputModeButton: some View {
    if inputMode == .shell || inputMode == .reviewNotes {
      Button {
        withAnimation(Motion.gentle) {
          if inputMode == .shell { manualShellMode = false }
          if inputMode == .reviewNotes { manualReviewMode = false }
        }
        Platform.services.playHaptic(.selection)
      } label: {
        ghostActionLabel(icon: "xmark.circle", isActive: true, tint: Color.textSecondary)
      }
      .buttonStyle(.plain)
      .help("Exit \(inputMode == .shell ? "shell" : "review") mode")
    }
  }

  var footerTokenLabel: some View {
    let pct = Int(tokenContextPercentage * 100)
    let color: Color = pct > 90 ? .statusError : pct > 70 ? .statusReply : .accent
    let displayPct = if tokenContextPercentage > 0, pct == 0 { "< 1" } else { "\(pct)" }

    return HStack(spacing: Spacing.gap) {
      Text("\(displayPct)%")
        .foregroundStyle(color)
      if let window = obs.contextWindow {
        let total = obs.effectiveContextInputTokens
        Text("·")
          .foregroundStyle(Color.textQuaternary)
        Text("\(formatTokenCount(total))/\(formatTokenCount(window))")
          .foregroundStyle(Color.textTertiary)
      }
    }
    .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
    .help(tokenTooltipText)
  }

  @ViewBuilder
  var footerModelLabel: some View {
    if obs.isDirectCodex, !effectiveCodexModel.isEmpty {
      Text(footerModelSummary)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .help("Model: \(effectiveCodexModel)\nEffort: \(selectedEffort.displayName)")
    } else if obs.isDirectClaude, !effectiveClaudeModel.isEmpty {
      Text(footerModelSummary)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .help("Model: \(effectiveClaudeModel)\nEffort: \(footerEffortLabel ?? "Default")")
    }
  }

  private var footerModelSummary: String {
    let modelName = if obs.isDirectCodex {
      DirectSessionComposerProviderPlanner.compactModelName(effectiveCodexModel)
    } else {
      DirectSessionComposerProviderPlanner.compactModelName(effectiveClaudeModel)
    }

    guard let footerEffortLabel else { return modelName }
    return "\(modelName) • \(footerEffortLabel)"
  }

  private var footerEffortLabel: String? {
    if obs.isDirectCodex {
      return selectedEffort.displayName
    }
    return HeaderCompactPresentation.effortLabel(for: obs.effort)
  }

  func footerBranchLabel(_ branch: String) -> some View {
    HStack(spacing: Spacing.xxs) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: TypeScale.mini, weight: .medium))
      Text(branch)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
    .foregroundStyle(Color.gitBranch.opacity(0.65))
    .help(branch)
  }

  var footerFollowControls: some View {
    HStack(spacing: Spacing.xs) {
      if !followMode.isFollowing, unreadCount > 0 {
        Button {
          onJumpToLatest()
          Platform.services.playHaptic(.selection)
        } label: {
          Text("\(unreadCount)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accent, in: Capsule())
        }
        .buttonStyle(.plain)
      }

      Button {
        onTogglePinned()
        Platform.services.playHaptic(.selection)
      } label: {
        Image(systemName: followMode.isFollowing ? "arrow.down.to.line" : followMode.controlIcon)
          .font(.system(size: isCompactLayout ? TypeScale.body : TypeScale.caption, weight: .semibold))
          .foregroundStyle(followMode.isFollowing ? Color.textQuaternary : Color.statusReply)
          .frame(width: isCompactLayout ? 34 : 28, height: isCompactLayout ? 34 : 28)
          .background(
            followMode.isFollowing ? Color.clear : Color.statusReply.opacity(OpacityTier.light),
            in: Circle()
          )
      }
      .buttonStyle(.plain)
    }
    .animation(Motion.standard, value: followMode)
    .animation(Motion.standard, value: unreadCount)
  }

  var composerSendButton: some View {
    Button(action: sendMessage) {
      Group {
        if isSending {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: isSessionWorking ? "arrow.uturn.right" : "arrow.up")
            .font(.system(size: isCompactLayout ? TypeScale.subhead : TypeScale.caption, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: isCompactLayout ? 34 : 28, height: isCompactLayout ? 34 : 28)
      .background(
        Circle().fill(canSend ? composerBorderColor.opacity(0.85) : Color.surfaceHover)
      )
    }
    .buttonStyle(.plain)
    .disabled(!canSend)
    .animation(Motion.gentle, value: canSend)
  }

  var compactFooterTokenChip: some View {
    let pct = Int(tokenContextPercentage * 100)
    let color: Color = pct > 90 ? .statusError : pct > 70 ? .statusReply : .accent
    let displayPct = if tokenContextPercentage > 0, pct == 0 { "< 1" } else { "\(pct)" }
    let total = obs.effectiveContextInputTokens

    let text = if total > 0, let window = obs.contextWindow {
      "\(displayPct)%·\(formatTokenCount(total))/\(formatTokenCount(window))"
    } else {
      "\(displayPct)%"
    }

    return Text(text)
      .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.gap)
      .background(Color.surfaceHover.opacity(0.5), in: Capsule())
      .help(tokenTooltipText)
  }

  // MARK: - Composer Action Buttons

  var fileMentionControlButton: some View {
    Button {
      openFilePicker()
    } label: {
      ghostActionLabel(icon: "doc.badge.plus", isActive: attachmentState.hasMentions, tint: .composerPrompt)
    }
    .buttonStyle(.plain)
    .help("Attach project files (@)")
    .platformPopover(isPresented: $composerState.showFilePickerPopover) {
      #if os(iOS)
        NavigationStack {
          ComposerFilePickerPopover(
            query: $composerState.filePickerQuery,
            files: filePickerResults,
            onSelect: attachMentionFromPicker
          )
          .navigationTitle("Project Files")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") { showFilePickerPopover = false }
            }
          }
        }
        .frame(minWidth: 340, minHeight: 320)
      #else
        ComposerFilePickerPopover(
          query: $composerState.filePickerQuery,
          files: filePickerResults,
          onSelect: attachMentionFromPicker
        )
        .frame(minWidth: 340, minHeight: 320)
      #endif
    }
  }

  var dictationControlButton: some View {
    Button {
      toggleDictation()
    } label: {
      ghostActionLabel(
        icon: dictationController.isRecording ? "stop.fill" : "mic.fill",
        isActive: dictationController.isRecording,
        tint: dictationController.isRecording ? .statusError : .accent
      )
    }
    .buttonStyle(.plain)
    .disabled(dictationController.isBusy)
    .help("Apple dictation")
  }

  var commandDeckControlButton: some View {
    Button {
      toggleCommandDeck()
    } label: {
      ghostActionLabel(icon: "slash.circle", isActive: shouldShowCommandDeck)
    }
    .buttonStyle(.plain)
    .help("Command deck (/)")
  }

  var terminalControlButton: some View {
    Button {
      launchTerminal()
    } label: {
      ghostActionLabel(icon: "terminal", tint: .terminal)
    }
    .buttonStyle(.plain)
    .help("Open terminal")
  }

  @ViewBuilder
  var imageAttachmentDockControl: some View {
    #if os(macOS)
      Button {
        pickImages()
      } label: {
        actionDockLabel(
          icon: "photo.badge.plus",
          title: attachmentState.images.isEmpty ? "Images" : "Images \(attachmentState.images.count)",
          tint: .accent,
          isActive: attachmentState.hasImages
        )
      }
      .buttonStyle(.plain)
      .help("Attach images, paste, or drop")
      .contextMenu {
        Button {
          _ = pasteImageFromClipboard()
        } label: {
          Label("Paste Image", systemImage: "doc.on.clipboard")
        }
        .disabled(!canPasteImageFromClipboard)
      }
    #else
      Menu {
        Button {
          pickImages()
        } label: {
          Label("Choose Photos", systemImage: "photo.on.rectangle")
        }

        Button {
          _ = pasteImageFromClipboard()
        } label: {
          Label("Paste Image", systemImage: "doc.on.clipboard")
        }
        .disabled(!canPasteImageFromClipboard)
      } label: {
        actionDockLabel(
          icon: "photo.badge.plus",
          title: attachmentState.images.isEmpty ? "Images" : "Images \(attachmentState.images.count)",
          tint: .accent,
          isActive: attachmentState.hasImages
        )
      }
      .buttonStyle(.plain)
      .help("Attach images or paste from the clipboard")
    #endif
  }

  // MARK: - Terminal Launch

  func launchTerminal() {
    // Reuse existing terminal if one is already registered for this session
    let terminalPrefix = "term-\(sessionId)-"
    if let existingId = terminalRegistry.sessions.keys.first(where: { $0.hasPrefix(terminalPrefix) }) {
      onOpenTerminal?(existingId)
      Platform.services.playHaptic(.selection)
      return
    }

    let terminalId = "term-\(sessionId)-\(UUID().uuidString.prefix(8).lowercased())"
    let controller = TerminalSessionController(terminalId: terminalId)

    // Wire output: controller sends encoded key input → server PTY
    let endpointId = viewModel.endpointId
    controller.sendToServer = { [weak runtimeRegistry] data in
      guard let runtime = runtimeRegistry?.runtimesByEndpointId[endpointId] else { return }
      runtime.connection.sendTerminalInput(terminalId: terminalId, data: data)
    }
    controller.sendResize = { [weak runtimeRegistry] cols, rows in
      guard let runtime = runtimeRegistry?.runtimesByEndpointId[endpointId] else { return }
      runtime.connection.sendTerminalResize(terminalId: terminalId, cols: cols, rows: rows)
    }

    terminalRegistry.register(controller)

    // Wire up server connection: event listener + create PTY
    let cwd = obs.projectPath.isEmpty ? "~" : obs.projectPath
    if let runtime = runtimeRegistry.runtimesByEndpointId[endpointId] {
      let token = runtime.connection.addListener { [weak controller] event in
        switch event {
        case let .terminalOutput(tid, data) where tid == terminalId:
          controller?.feedOutput(data)
        case let .terminalExited(tid, _) where tid == terminalId:
          controller?.setConnected(false)
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
        cwd: cwd,
        cols: 80,
        rows: 24,
        sessionId: sessionId
      )
    }

    onOpenTerminal?(terminalId)
    Platform.services.playHaptic(.selection)
  }

  func ghostActionLabel(
    icon: String,
    isActive: Bool = false,
    tint: Color = .accent
  ) -> some View {
    GhostActionIcon(
      icon: icon,
      isActive: isActive,
      tint: tint,
      isCompactLayout: isCompactLayout
    )
  }

  func actionDockLabel(
    icon: String,
    title: String,
    tint: Color,
    isActive: Bool = false
  ) -> some View {
    ghostActionLabel(icon: icon, isActive: isActive, tint: tint)
      .accessibilityLabel(title)
  }
}

// MARK: - Ghost Action Icon (self-contained hover)

/// A single ghost icon button label with built-in macOS hover feedback.
struct GhostActionIcon: View {
  let icon: String
  var isActive: Bool = false
  var tint: Color = .accent
  var isCompactLayout: Bool = false

  @State private var isHovered = false

  var body: some View {
    Image(systemName: icon)
      .font(.system(
        size: isCompactLayout ? TypeScale.subhead : TypeScale.caption,
        weight: isCompactLayout ? .semibold : .medium
      ))
      .foregroundStyle(foregroundColor)
      .frame(width: isCompactLayout ? 34 : 26, height: isCompactLayout ? 34 : 26)
      .background(backgroundColor, in: shape)
      .contentShape(shape)
      .onHover { hovering in
        isHovered = hovering
      }
      .animation(Motion.hover, value: isHovered)
  }

  private var foregroundColor: Color {
    if isActive { return tint }
    if isHovered { return isCompactLayout ? Color.textSecondary : Color.textTertiary }
    return isCompactLayout ? Color.textTertiary : Color.textQuaternary
  }

  private var backgroundColor: some ShapeStyle {
    if isCompactLayout {
      return isActive
        ? tint.opacity(OpacityTier.light)
        : Color.surfaceHover.opacity(0.5)
    }
    if isActive {
      return tint.opacity(OpacityTier.subtle)
    }
    if isHovered {
      return Color.surfaceHover.opacity(0.7)
    }
    return Color.clear.opacity(0)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: isCompactLayout ? Radius.md : Radius.sm, style: .continuous)
  }
}
