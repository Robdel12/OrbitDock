//
//  DirectSessionComposer+Helpers.swift
//  OrbitDock
//
//  Utility methods: cursor, model, message sending, dictation, worktree sheets, tokens.
//

import SwiftUI

extension DirectSessionComposer {
  // MARK: - Cursor

  func requestComposerFocus() {
    inputState.focus.requestFocus()
  }

  func relinquishComposerFocus() {
    inputState.focus.relinquishFocus()
  }

  func handleComposerFocusEvent(_ event: ComposerTextAreaFocusEvent) {
    let shouldRefocus = inputState.focus.handle(event, isSessionActive: isSessionActive)
    guard shouldRefocus else { return }
    Task { @MainActor in
      await Task.yield()
      guard inputState.focus.shouldMaintainTypingFocus,
            !inputState.focus.isFocused,
            isSessionActive
      else { return }
      inputState.focus.focusRequestSignal &+= 1
    }
  }

  func moveComposerCursorToEnd() {
    inputState.focus.moveCursorToEnd()
  }

  func setComposerMessage(_ newValue: String, moveCursorToEnd: Bool = false) {
    if message != newValue {
      message = newValue
    }
    if moveCursorToEnd {
      moveComposerCursorToEnd()
    }
  }

  // MARK: - Message

  var canSend: Bool {
    guard !isDictationActive else { return false }
    return DirectSessionComposerActionPlanner.canSend(sendContext)
  }

  func sendMessage() {
    let sendPlan = DirectSessionComposerActionPlanner.planSend(sendContext)
    guard sendPlan != .blocked else { return }

    switch sendPlan {
      case .blocked:
        return

      case let .offlineShell(message):
        errorMessage = message
        Platform.services.playHaptic(.error)
        return

      case let .missingModel(message):
        errorMessage = message
        return

      case let .executeShell(command, exitsShellMode):
        Task { try? await viewModel.executeShell(command: command) }
        Platform.services.playHaptic(.action)
        self.message = ""
        if exitsShellMode {
          manualShellMode = false
        }
        requestComposerFocus()
        return

      case .steer, .send:
        break
    }

    let preparedAction = DirectSessionComposerExecutionPlanner.prepare(
      sendPlan: sendPlan,
      message: sendContext.trimmedMessage,
      attachments: attachmentState,
      shellContext: viewModel.consumeShellContext(),
      selectedSkillPaths: selectedSkills,
      availableSkills: availableSkills
    )
    if case .blocked = preparedAction {
      return
    }

    isSending = true
    DirectSessionComposerSendRecovery.trackAttempt(in: &composerState, preparedAction: preparedAction)
    Task {
      do {
        try await DirectSessionComposerExecutionCoordinator.execute(
          preparedAction,
          using: makeExecutionPorts()
        )
        await MainActor.run {
          isSending = false
          completeSuccessfulComposerSend()
        }
      } catch {
        await MainActor.run {
          isSending = false
          Platform.services.playHaptic(.error)
          errorMessage = "Couldn't send message. Your draft is still here."
          requestComposerFocus()
        }
      }
    }
  }

  var sendContext: DirectSessionComposerSendContext {
    DirectSessionComposerSendContext(
      inputMode: composerSendMode,
      rawMessage: message,
      hasAttachments: attachmentState.hasImages,
      hasMentions: attachmentState.hasMentions,
      isSending: isSending,
      isConnected: isConnected,
      providerMode: providerMode,
      selectedCodexModel: selectedModel,
      selectedClaudeModel: effectiveClaudeModel,
      inheritedModel: obs.model,
      effort: selectedEffort.serialized ?? ""
    )
  }

  var providerMode: ComposerProviderMode {
    if obs.isDirectCodex {
      return .directCodex
    }
    if obs.isDirectClaude {
      return .directClaude
    }
    return .inherited
  }

  var composerSendMode: ComposerSendMode {
    switch inputMode {
      case .prompt:
        .prompt
      case .steer:
        .steer
      case .reviewNotes:
        .reviewNotes
      case .shell:
        .shell
    }
  }

  private func makeExecutionPorts() -> DirectSessionComposerExecutionPorts {
    DirectSessionComposerExecutionPorts(
      uploadImages: { images in
        var uploaded: [ServerImageInput] = []
        uploaded.reserveCapacity(images.count)

        for image in images {
          let input = try await viewModel.uploadImageAttachment(
            data: image.uploadData,
            mimeType: image.uploadMimeType,
            displayName: image.displayName ?? "image",
            pixelWidth: image.pixelWidth ?? 0,
            pixelHeight: image.pixelHeight ?? 0
          )
          uploaded.append(input)
        }

        return uploaded
      },
      sendMessage: { request in
        try await viewModel.sendMessage(request)
      },
      steerTurn: { request in
        try await viewModel.steerTurn(request)
      }
    )
  }

  private func completeSuccessfulComposerSend() {
    finishComposerSend(playHaptic: true)
  }

  private func recoverComposerSendAfterAppend() {
    finishComposerSend(playHaptic: false)
  }

  private func finishComposerSend(playHaptic: Bool) {
    if playHaptic {
      Platform.services.playHaptic(.action)
    }
    errorMessage = nil
    message = ""
    DirectSessionComposerSendRecovery.clear(&composerState)
    withAnimation(Motion.gentle) {
      attachmentState.clearAfterSend()
    }
    requestComposerFocus()
  }

  func reconcileRecoveredSendIfNeeded() {
    guard DirectSessionComposerSendRecovery.shouldRecover(
      pendingContent: composerState.pendingRecoveredSendContent,
      pendingStartedAt: composerState.pendingRecoveredSendStartedAt,
      latestUserEntry: latestConversationUserEntry
    )
    else {
      return
    }

    isSending = false
    recoverComposerSendAfterAppend()
  }

  @MainActor
  func applyCodexSessionSettings(
    configMode: ServerCodexConfigMode,
    configProfile: String?,
    modelProvider: String?,
    collaborationMode: CodexCollaborationMode,
    multiAgentEnabled: Bool,
    personality: CodexPersonalityPreset,
    serviceTier: CodexServiceTierPreset,
    developerInstructions: String?
  ) async throws {
    let currentInstructions = normalizedCodexInstructions(obs.developerInstructions)
    let nextInstructions = normalizedCodexInstructions(developerInstructions)
    _ = configMode
    _ = configProfile
    _ = modelProvider

    do {
      try await viewModel.updateCodexSessionOverrides(
        configMode: nil,
        configProfile: nil,
        modelProvider: nil,
        collaborationMode: collaborationMode != currentCodexCollaborationMode
          ? .set(collaborationMode.rawValue)
          : nil,
        multiAgent: multiAgentEnabled != currentCodexMultiAgentEnabled
          ? .set(multiAgentEnabled)
          : nil,
        personality: personality != currentCodexPersonality
          ? codexStringPatch(for: personality.requestValue)
          : nil,
        serviceTier: serviceTier != currentCodexServiceTier
          ? codexStringPatch(for: serviceTier.requestValue)
          : nil,
        developerInstructions: nextInstructions != currentInstructions
          ? codexStringPatch(for: nextInstructions)
          : nil
      )
      Platform.services.playHaptic(.action)
    } catch {
      Platform.services.playHaptic(.error)
      throw error
    }
  }

  @MainActor
  func resetCodexSessionOverrides() async throws {
    do {
      try await viewModel.updateCodexSessionOverrides(
        configMode: nil,
        configProfile: nil,
        modelProvider: nil,
        collaborationMode: .clear,
        multiAgent: .clear,
        personality: .clear,
        serviceTier: .clear,
        developerInstructions: .clear
      )
      Platform.services.playHaptic(.action)
    } catch {
      Platform.services.playHaptic(.error)
      throw error
    }
  }

  private func codexStringPatch(for value: String?) -> SessionsClient.OptionalStringPatch {
    guard let value else { return .clear }
    return .set(value)
  }

  private func normalizedCodexInstructions(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func inspectCodexConfig() {
    showCodexSettingsSheet = false

    guard let projectPath else {
      codexInspectorError =
        "This session needs a project folder before OrbitDock can resolve the Codex config layers that apply here."
      codexInspectorResponse = nil
      showCodexInspector = true
      return
    }

    codexInspectorLoading = true
    codexInspectorError = nil
    showCodexInspector = true

    let overrides = currentCodexOverrides
    let request = SessionsClient.CodexInspectRequest(
      cwd: projectPath,
      codexConfigSource: currentCodexConfigSource,
      codexConfigMode: currentCodexConfigMode,
      codexConfigProfile: currentCodexConfigProfile,
      model: overrides.model,
      modelProvider: currentCodexOverrides.modelProvider ?? currentCodexModelProvider,
      approvalPolicy: overrides.approvalPolicy,
      sandboxMode: overrides.sandboxMode,
      collaborationMode: overrides.collaborationMode,
      multiAgent: overrides.multiAgent,
      personality: overrides.personality,
      serviceTier: overrides.serviceTier,
      developerInstructions: overrides.developerInstructions,
      effort: overrides.effort
    )

    Task {
      do {
        codexInspectorResponse = try await viewModel.inspectCodexConfig(request)
      } catch {
        codexInspectorResponse = nil
        codexInspectorError = error.localizedDescription
      }
      codexInspectorLoading = false
    }
  }

  // MARK: - Dictation

  @MainActor
  func beginDictationDraftState() {
    dictationDraftBaseMessage = message
  }

  @MainActor
  func clearDictationDraftState() {
    dictationDraftBaseMessage = nil
  }

  @MainActor
  func updateDictationLivePreview(_ transcript: String) {
    guard let baseMessage = dictationDraftBaseMessage else { return }
    let normalized = DictationTextFormatter.normalizeTranscription(transcript)
    let merged = DictationTextFormatter.merge(existing: baseMessage, dictated: normalized)
    guard merged != message else { return }
    message = merged
  }

  @MainActor
  func applyDictationPreviewToComposer(_ transcript: String) {
    guard let baseMessage = dictationDraftBaseMessage else { return }
    let normalized = DictationTextFormatter.normalizeTranscription(transcript)
    let merged = DictationTextFormatter.merge(existing: baseMessage, dictated: normalized)
    guard merged != message else { return }
    message = merged
  }

  @MainActor
  func toggleDictation() {
    guard shouldShowDictation else { return }
    Task { @MainActor in
      if dictationController.isRecording {
        if let dictated = await dictationController.stop() {
          if dictationDraftBaseMessage != nil {
            applyDictationPreviewToComposer(dictated)
          } else {
            message = DictationTextFormatter.merge(existing: message, dictated: dictated)
          }
        }
        clearDictationDraftState()
        Platform.services.playHaptic(.action)
      } else {
        beginDictationDraftState()
        await dictationController.start()
        if dictationController.isRecording {
          Platform.services.playHaptic(.action)
        } else {
          clearDictationDraftState()
          if dictationController.errorMessage != nil {
            Platform.services.playHaptic(.error)
          }
        }
      }
    }
  }

  // MARK: - Worktree

  func openForkToWorktreeSheet() {
    guard canForkToWorktree else {
      errorMessage = "This session does not have a git repository root to create a worktree from."
      return
    }
    showForkToWorktreeSheet = true
  }

  func openForkToExistingWorktreeSheet() {
    guard canForkToExistingWorktree else {
      errorMessage = "This session does not have a git repository root to select a worktree from."
      return
    }
    showForkToExistingWorktreeSheet = true
  }

  func refreshForkExistingWorktrees() {
    guard forkWorktreeDisplayRepoPath != nil else { return }
    viewModel.refreshWorktreesForActiveSessions()
  }

  func statusColor(for status: ServerWorktreeStatus) -> Color {
    switch status {
      case .active: .feedbackPositive
      case .orphaned: .statusReply
      case .stale: .feedbackCaution
      case .removing: .textQuaternary
      case .removed: .textQuaternary
    }
  }

  // MARK: - Token

  var tokenContextPercentage: Double {
    obs.contextFillFraction
  }

  var tokenTooltipText: String {
    var parts: [String] = []
    if let input = obs.inputTokens {
      parts.append("Input: \(formatTokenCount(input))")
    }
    if let output = obs.outputTokens {
      parts.append("Output: \(formatTokenCount(output))")
    }
    if let cached = obs.cachedTokens, cached > 0,
       obs.effectiveContextInputTokens > 0
    {
      let percent = Int(obs.effectiveCacheHitPercent)
      parts.append("Cached: \(formatTokenCount(cached)) (\(percent)% savings)")
    }
    if let window = obs.contextWindow {
      parts.append("Context: \(formatTokenCount(window))")
    }
    return parts.isEmpty ? "Token usage" : parts.joined(separator: "\n")
  }

  func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.1fk", Double(count) / 1_000)
    }
    return "\(count)"
  }

  // MARK: - Fork Sheets

  @ViewBuilder
  var forkToWorktreeSheet: some View {
    if let repoPath = forkWorktreeDisplayRepoPath {
      CreateWorktreeSheet(
        repoPath: repoPath,
        projectName: obs.projectName ?? URL(fileURLWithPath: repoPath).lastPathComponent,
        onCancel: {
          showForkToWorktreeSheet = false
        },
        onCreate: { branchName, baseBranch in
          Task {
            try? await viewModel.forkSessionToWorktree(
              branchName: branchName,
              baseBranch: baseBranch,
              nthUserMessage: nil
            )
          }
          showForkToWorktreeSheet = false
        }
      )
    } else {
      VStack(spacing: Spacing.md) {
        Text("Worktree unavailable for this session.")
          .font(.system(size: TypeScale.subhead, weight: .medium))
          .foregroundStyle(Color.textSecondary)
        Button("Close") {
          showForkToWorktreeSheet = false
        }
      }
      .padding(Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .ifMacOS { view in
        view.frame(width: 320)
      }
      .background(Color.panelBackground)
    }
  }

  @ViewBuilder
  var forkToExistingWorktreeSheet: some View {
    if forkWorktreeDisplayRepoPath != nil {
      VStack(spacing: 0) {
        HStack {
          Text("Fork to Existing Worktree")
            .font(.system(size: TypeScale.body, weight: .semibold))
          Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)

        Divider()

        if forkToExistingCandidates.isEmpty {
          VStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: TypeScale.chatHeading1))
              .foregroundStyle(Color.textQuaternary)

            Text("No existing worktrees")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)

            Text("Create one first or refresh to discover tracked worktrees.")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textQuaternary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.xl)
        } else {
          ScrollView {
            VStack(spacing: Spacing.xxs) {
              ForEach(forkToExistingCandidates) { wt in
                Button {
                  Task {
                    try? await viewModel.forkSessionToExistingWorktree(worktreeId: wt.id, nthUserMessage: nil)
                  }
                  showForkToExistingWorktreeSheet = false
                } label: {
                  HStack(spacing: Spacing.sm) {
                    Circle()
                      .fill(statusColor(for: wt.status))
                      .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                      Text(wt.customName ?? wt.branch)
                        .font(.system(size: TypeScale.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                      Text(wt.worktreePath)
                        .font(.system(size: TypeScale.micro, design: .monospaced))
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                    }

                    Spacer()

                    if wt.activeSessionCount > 0 {
                      Text("\(wt.activeSessionCount)")
                        .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.textQuaternary)
                    }
                  }
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.sm)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(obs.forkInProgress)
              }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
          }
          .frame(maxHeight: isCompactLayout ? .infinity : 320)
        }

        Divider()

        HStack {
          Button {
            refreshForkExistingWorktrees()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
              .font(.system(size: TypeScale.meta, weight: .medium))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.textSecondary)

          Spacer()

          Button("Cancel") {
            showForkToExistingWorktreeSheet = false
          }
          .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .ifMacOS { view in
        view.frame(width: 420)
      }
      .background(Color.panelBackground)
      .onAppear {
        refreshForkExistingWorktrees()
      }
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
    } else {
      VStack(spacing: Spacing.md) {
        Text("Worktree unavailable for this session.")
          .font(.system(size: TypeScale.subhead, weight: .medium))
          .foregroundStyle(Color.textSecondary)
        Button("Close") {
          showForkToExistingWorktreeSheet = false
        }
      }
      .padding(Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .ifMacOS { view in
        view.frame(width: 320)
      }
      .background(Color.panelBackground)
      #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      #endif
    }
  }
}
