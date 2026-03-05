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
      // Ghost action icons
      HStack(spacing: Spacing.xs) {
        if obs.workStatus == .working {
          CodexInterruptButton(sessionId: sessionId)
        }

        if obs.isDirectCodex || obs.isDirectClaude {
          providerModelControlButton
        }

        fileMentionControlButton
        commandDeckControlButton

        if shouldShowDictation {
          dictationControlButton
        }

        Rectangle()
          .fill(Color.surfaceBorder.opacity(OpacityTier.light))
          .frame(width: 0.5, height: 16)

        desktopWorkflowOverflowMenu

        if inputMode == .shell || inputMode == .reviewNotes {
          Button {
            withAnimation(Motion.gentle) {
              if inputMode == .shell { manualShellMode = false }
              if inputMode == .reviewNotes { manualReviewMode = false }
            }
          } label: {
            ghostActionLabel(icon: "xmark.circle", isActive: true, tint: Color.textSecondary)
          }
          .buttonStyle(.plain)
          .help("Exit \(inputMode == .shell ? "shell" : "review") mode")
        }
      }

      Spacer()

      // Follow + Send
      HStack(spacing: Spacing.sm_) {
        footerFollowControls
        composerSendButton
      }
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.bottom, Spacing.sm_)
  }

  var compactComposerFooter: some View {
    HStack(spacing: Spacing.sm_) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.xs) {
          if obs.workStatus == .working {
            CodexInterruptButton(sessionId: sessionId, isCompact: true)
          }

          if obs.isDirectCodex || obs.isDirectClaude {
            providerModelControlButton
          }

          commandDeckControlButton

          if shouldShowDictation {
            dictationControlButton
          }

          compactWorkflowOverflowMenu
        }
        .padding(.trailing, Spacing.xs)
      }
      .scrollIndicators(.hidden)

      // Pinned right: follow + send
      footerFollowControls
      composerSendButton
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.bottom, Spacing.sm)
  }

  // MARK: - Footer Helpers

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
    if obs.isDirectCodex, !selectedModel.isEmpty {
      Text(shortModelName(selectedModel))
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .help("Model: \(selectedModel)\nEffort: \(selectedEffort.displayName)")
    } else if obs.isDirectClaude, !effectiveClaudeModel.isEmpty {
      Text(shortModelName(effectiveClaudeModel))
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
    }
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
      if !isPinned, unreadCount > 0 {
        Button {
          isPinned = true
          unreadCount = 0
          scrollToBottomTrigger += 1
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
        isPinned.toggle()
        if isPinned {
          unreadCount = 0
          scrollToBottomTrigger += 1
        }
      } label: {
        Image(systemName: isPinned ? "arrow.down.to.line" : "pause.fill")
          .font(.system(size: isCompactLayout ? TypeScale.body : TypeScale.caption, weight: .semibold))
          .foregroundStyle(isPinned ? Color.textQuaternary : Color.statusReply)
          .frame(width: isCompactLayout ? 34 : 28, height: isCompactLayout ? 34 : 28)
          .background(
            isPinned ? Color.clear : Color.statusReply.opacity(OpacityTier.light),
            in: Circle()
          )
      }
      .buttonStyle(.plain)
    }
    .animation(Motion.standard, value: isPinned)
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
        Circle().fill(
          canSend
            ? LinearGradient(
              colors: [composerBorderColor, composerBorderColor.opacity(0.8)],
              startPoint: .top,
              endPoint: .bottom
            )
            : LinearGradient(colors: [Color.surfaceHover], startPoint: .top, endPoint: .bottom)
        )
      )
      .themeShadow(Shadow.glow(color: canSend ? composerBorderColor : .clear, intensity: 0.4))
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

  var modelEffortControlButton: some View {
    Button {
      showModelEffortPopover.toggle()
    } label: {
      ghostActionLabel(icon: "slider.horizontal.3", isActive: hasOverrides)
    }
    .buttonStyle(.plain)
    .help("Model and reasoning effort")
    .platformPopover(isPresented: $showModelEffortPopover) {
      #if os(iOS)
        NavigationStack {
          ModelEffortPopover(
            selectedModel: $selectedModel,
            selectedEffort: $selectedEffort,
            models: codexModelOptions
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showModelEffortPopover = false }
            }
          }
        }
      #else
        ModelEffortPopover(
          selectedModel: $selectedModel,
          selectedEffort: $selectedEffort,
          models: codexModelOptions
        )
      #endif
    }
  }

  var claudeModelControlButton: some View {
    Button {
      showClaudeModelPopover.toggle()
    } label: {
      ghostActionLabel(icon: "slider.horizontal.3", isActive: hasOverrides, tint: .providerClaude)
    }
    .buttonStyle(.plain)
    .help("Claude model override")
    .platformPopover(isPresented: $showClaudeModelPopover) {
      #if os(iOS)
        NavigationStack {
          ComposerClaudeModelPopover(
            selectedModel: $selectedClaudeModel,
            models: claudeModelOptions
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showClaudeModelPopover = false }
            }
          }
        }
      #else
        ComposerClaudeModelPopover(
          selectedModel: $selectedClaudeModel,
          models: claudeModelOptions
        )
      #endif
    }
  }

  @ViewBuilder
  var providerModelControlButton: some View {
    if obs.isDirectCodex {
      modelEffortControlButton
    } else if obs.isDirectClaude {
      claudeModelControlButton
    }
  }

  var fileMentionControlButton: some View {
    Button {
      openFilePicker()
    } label: {
      ghostActionLabel(icon: "doc.badge.plus", isActive: !attachedMentions.isEmpty, tint: .composerPrompt)
    }
    .buttonStyle(.plain)
    .help("Attach project files (@)")
    .platformPopover(isPresented: $showFilePickerPopover) {
      #if os(iOS)
        NavigationStack {
          ComposerFilePickerPopover(
            query: $filePickerQuery,
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
          query: $filePickerQuery,
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
    .help("Local Whisper dictation")
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

  @ViewBuilder
  var imageAttachmentDockControl: some View {
    #if os(macOS)
      Button {
        pickImages()
      } label: {
        actionDockLabel(
          icon: "paperclip",
          title: attachedImages.isEmpty ? "Images" : "Images \(attachedImages.count)",
          tint: .accent,
          isActive: !attachedImages.isEmpty
        )
      }
      .buttonStyle(.plain)
      .help("Attach images")
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
          icon: "paperclip",
          title: attachedImages.isEmpty ? "Images" : "Images \(attachedImages.count)",
          tint: .accent,
          isActive: !attachedImages.isEmpty
        )
      }
      .buttonStyle(.plain)
      .help("Attach images")
    #endif
  }

  var turnActionsDockMenu: some View {
    Menu {
      turnActionsMenuContent
    } label: {
      actionDockLabel(icon: "ellipsis.circle", title: "Turn", tint: Color.textTertiary)
    }
    .buttonStyle(.plain)
    .help("Turn actions")
  }

  @ViewBuilder
  var turnActionsMenuContent: some View {
    if obs.isDirectCodex || serverState.session(sessionId).hasSlashCommand("undo") {
      Button {
        serverState.undoLastTurn(sessionId: sessionId)
      } label: {
        Label("Undo Last Turn", systemImage: "arrow.uturn.backward")
      }
      .disabled(serverState.session(sessionId).undoInProgress)
    }

    if obs.isDirect, let lastUserMsg = obs.messages.last(where: \.isUser) {
      let hasRecentCheckpoint = obs.lastFilesPersistedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
      Button {
        serverState.rewindFiles(sessionId: sessionId, userMessageId: lastUserMsg.id)
      } label: {
        Label(
          hasRecentCheckpoint ? "Rewind Files (checkpoint saved)" : "Rewind Files",
          systemImage: "arrow.uturn.backward.circle"
        )
      }
      .disabled(obs.workStatus == .working)
    }

    Button {
      serverState.forkSession(sessionId: sessionId)
    } label: {
      Label("Fork Conversation", systemImage: "arrow.triangle.branch")
    }
    .disabled(!canForkConversation)

    Button {
      openForkToWorktreeSheet()
    } label: {
      Label("Fork to New Worktree", systemImage: "arrow.triangle.branch")
    }
    .disabled(!canForkToWorktree)

    Button {
      openForkToExistingWorktreeSheet()
    } label: {
      Label("Fork to Existing Worktree", systemImage: "arrow.triangle.branch.circlepath")
    }
    .disabled(!canForkToExistingWorktree)

    if obs.hasTokenUsage {
      Button {
        serverState.compactContext(sessionId: sessionId)
      } label: {
        Label("Compact Context", systemImage: "arrow.triangle.2.circlepath")
      }
    }

    if hasMcpData {
      Divider()
      Button {
        serverState.refreshMcpServers(sessionId: sessionId)
      } label: {
        Label("Refresh MCP Servers", systemImage: "arrow.clockwise")
      }
    }
  }

  var compactWorkflowOverflowMenu: some View {
    let attachmentCount = attachedImages.count + attachedMentions.count + selectedSkills.count

    return Menu {
      Section("Compose") {
        Button {
          openFilePicker()
        } label: {
          Label("Attach Files", systemImage: "doc.badge.plus")
        }

        if shouldShowDictation {
          Button {
            toggleDictation()
          } label: {
            Label(
              dictationController.isRecording ? "Stop Dictation" : "Start Dictation",
              systemImage: dictationController.isRecording ? "stop.fill" : "mic.fill"
            )
          }
          .disabled(dictationController.isBusy)
        }

        if hasSkillsPanel {
          Button {
            serverState.listSkills(sessionId: sessionId)
            onOpenSkills?()
          } label: {
            Label("Attach Skills", systemImage: "bolt.fill")
          }
        }

        Button {
          pickImages()
        } label: {
          Label("Attach Images", systemImage: "photo")
        }

        Button {
          _ = pasteImageFromClipboard()
        } label: {
          Label("Paste Image", systemImage: "doc.on.clipboard")
        }
        .disabled(!canPasteImageFromClipboard)

        if hasMcpData {
          Button {
            activateCommandDeck(prefill: "mcp")
          } label: {
            Label("Browse MCP", systemImage: "square.stack.3d.up.fill")
          }
        }

        Button {
          withAnimation(Motion.gentle) {
            manualShellMode.toggle()
            if manualShellMode { manualReviewMode = false }
          }
        } label: {
          Label(
            manualShellMode ? "Disable Shell Mode" : "Enable Shell Mode",
            systemImage: "terminal"
          )
        }
      }

      Section("Turn") {
        turnActionsMenuContent
      }
    } label: {
      actionDockLabel(
        icon: "ellipsis.circle",
        title: "More",
        tint: Color.textTertiary,
        isActive: attachmentCount > 0
      )
      .overlay(alignment: .topTrailing) {
        if attachmentCount > 0 {
          Text("\(min(attachmentCount, 9))")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(Color.accent, in: Capsule())
            .offset(x: 6, y: -5)
        }
      }
    }
    .buttonStyle(.plain)
    .help("More actions")
  }

  var desktopWorkflowOverflowMenu: some View {
    let hasActiveState = !selectedSkills.isEmpty || !attachedImages.isEmpty || !attachedMentions
      .isEmpty || manualShellMode

    return Menu {
      Section("Compose") {
        if shouldShowDictation {
          Button {
            toggleDictation()
          } label: {
            Label(
              dictationController.isRecording ? "Stop Dictation" : "Start Dictation",
              systemImage: dictationController.isRecording ? "stop.fill" : "mic.fill"
            )
          }
          .disabled(dictationController.isBusy)
        }

        if hasSkillsPanel {
          Button {
            serverState.listSkills(sessionId: sessionId)
            onOpenSkills?()
          } label: {
            Label("Attach Skills", systemImage: "bolt.fill")
          }
        }

        Button {
          pickImages()
        } label: {
          Label("Attach Images", systemImage: "photo")
        }

        Button {
          _ = pasteImageFromClipboard()
        } label: {
          Label("Paste Image", systemImage: "doc.on.clipboard")
        }
        .disabled(!canPasteImageFromClipboard)

        if hasMcpData {
          Button {
            activateCommandDeck(prefill: "mcp")
          } label: {
            Label("Browse MCP", systemImage: "square.stack.3d.up.fill")
          }
        }

        Button {
          withAnimation(Motion.gentle) {
            manualShellMode.toggle()
            if manualShellMode { manualReviewMode = false }
          }
        } label: {
          Label(
            manualShellMode ? "Disable Shell Mode" : "Enable Shell Mode",
            systemImage: "terminal"
          )
        }
      }

      Section("Turn") {
        turnActionsMenuContent
      }
    } label: {
      actionDockLabel(
        icon: "ellipsis.circle",
        title: "More",
        tint: Color.textTertiary,
        isActive: hasActiveState
      )
    }
    .buttonStyle(.plain)
    .help("More actions")
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
