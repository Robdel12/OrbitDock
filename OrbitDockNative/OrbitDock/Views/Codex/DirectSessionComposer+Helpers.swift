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
    shouldMaintainTypingFocus = true
    focusRequestSignal &+= 1
  }

  func relinquishComposerFocus() {
    shouldMaintainTypingFocus = false
    blurRequestSignal &+= 1
  }

  func handleComposerFocusEvent(_ event: ComposerTextAreaFocusEvent) {
    switch event {
      case .began:
        if !isFocused {
          isFocused = true
        }
        shouldMaintainTypingFocus = true

      case let .ended(userInitiated):
        if isFocused {
          isFocused = false
        }
        if userInitiated {
          shouldMaintainTypingFocus = false
          return
        }
        guard shouldMaintainTypingFocus, isSessionActive else { return }
        Task { @MainActor in
          await Task.yield()
          guard shouldMaintainTypingFocus, !isFocused, isSessionActive else { return }
          focusRequestSignal &+= 1
        }
    }
  }

  func moveComposerCursorToEnd() {
    moveCursorToEndSignal &+= 1
  }

  func setComposerMessage(_ newValue: String, moveCursorToEnd: Bool = false) {
    if message != newValue {
      message = newValue
    }
    if moveCursorToEnd {
      moveComposerCursorToEnd()
    }
  }

  // MARK: - Model

  func extractMcpServerName(from toolKey: String) -> String? {
    let parts = toolKey.split(separator: "__")
    if parts.count >= 2, parts[0] == "mcp" {
      return String(parts[1])
    }
    if parts.count >= 2 {
      return String(parts[0])
    }
    return nil
  }

  func shortModelName(_ model: String) -> String {
    // Strip common prefixes to get a compact display name
    let name = model
      .replacingOccurrences(of: "openai/", with: "")
      .replacingOccurrences(of: "anthropic/", with: "")
    // If it's already short (like "o3"), return as-is
    if name.count <= 8 { return name }
    // Take first component before a dash if very long
    let parts = name.split(separator: "-", maxSplits: 2)
    if parts.count >= 2 {
      return String(parts[0]) + "-" + String(parts[1])
    }
    return name
  }

  // MARK: - Message

  var canSend: Bool {
    if isDictationActive { return false }
    let hasContent = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if inputMode == .shell { return !isSending && hasContent }
    if isSessionWorking { return !isSending && (hasContent || hasAttachments) }
    let hasModel: Bool = if obs.isDirectCodex {
      !selectedModel.isEmpty
    } else if obs.isDirectClaude {
      !effectiveClaudeModel.isEmpty
    } else {
      obs.model != nil
    }
    return !isSending && (hasContent || hasAttachments) && hasModel
  }

  func sendMessage() {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isSending else { return }
    guard !trimmed.isEmpty || hasAttachments else { return }

    // Shell mode: route to executeShell
    if inputMode == .shell {
      guard isConnected else {
        errorMessage = "Server is offline. Shell command not sent."
        Platform.services.playHaptic(.error)
        return
      }
      Task { try? await serverState.executeShell(sessionId, command: trimmed) }
      Platform.services.playHaptic(.action)
      message = ""
      manualShellMode = false
      requestComposerFocus()
      return
    }

    // ! prefix: execute as shell command
    if trimmed.hasPrefix("!"), trimmed.count > 1 {
      guard isConnected else {
        errorMessage = "Server is offline. Shell command not sent."
        Platform.services.playHaptic(.error)
        return
      }
      let shellCmd = String(trimmed.dropFirst())
      Task { try? await serverState.executeShell(sessionId, command: shellCmd) }
      Platform.services.playHaptic(.action)
      message = ""
      requestComposerFocus()
      return
    }

    var expandedContent = trimmed
    for mention in attachedMentions {
      expandedContent = expandedContent.replacingOccurrences(of: "@\(mention.name)", with: mention.path)
    }
    let mentionInputs = attachedMentions.map { ServerMentionInput(name: $0.name, path: $0.path) }
    let hasAttachedImages = !attachedImages.isEmpty

    if isSessionWorking {
      guard !expandedContent.isEmpty || hasAttachedImages || !mentionInputs.isEmpty else { return }

      isSending = true
      Task {
        do {
          let uploadedImages = hasAttachedImages
            ? try await uploadAttachedImages(attachedImages)
            : []
          try await serverState.steerTurn(
            sessionId: sessionId,
            content: expandedContent,
            images: uploadedImages,
            mentions: mentionInputs
          )
          await MainActor.run {
            isSending = false
            completeSuccessfulComposerSend()
          }
        } catch {
          await MainActor.run {
            isSending = false
            Platform.services.playHaptic(.error)
            errorMessage = "Couldn't send steer message. Your draft is still here."
            requestComposerFocus()
          }
        }
      }
      return
    }

    let effectiveModel: String
    if obs.isDirectCodex {
      guard !selectedModel.isEmpty else {
        errorMessage = "No model available yet. Wait for model list to load."
        return
      }
      effectiveModel = selectedModel
    } else if obs.isDirectClaude {
      guard !effectiveClaudeModel.isEmpty else {
        errorMessage = "No Claude model available yet. Wait for model list to load."
        return
      }
      effectiveModel = effectiveClaudeModel
    } else {
      effectiveModel = obs.model ?? ""
    }

    let effort = selectedEffort.serialized

    let inlineSkillNames = extractInlineSkillNames(from: expandedContent)

    var skillPaths = selectedSkills
    for name in inlineSkillNames {
      if let skill = availableSkills.first(where: { $0.name == name }) {
        skillPaths.insert(skill.path)
      }
    }
    let skillInputs = skillPaths.compactMap { path -> ServerSkillInput? in
      guard let skill = availableSkills.first(where: { $0.path == path }) else { return nil }
      return ServerSkillInput(name: skill.name, path: skill.path)
    }

    // Prepend any pending shell context
    if let shellContext = obs.consumeShellContext() {
      expandedContent = "\(shellContext)\n\n\(expandedContent)"
    }

    isSending = true
    Task {
      do {
        let uploadedImages = hasAttachedImages
          ? try await uploadAttachedImages(attachedImages)
          : []
        try await serverState.sendMessage(
          sessionId: sessionId,
          content: expandedContent,
          model: effectiveModel,
          effort: effort,
          skills: skillInputs,
          images: uploadedImages,
          mentions: mentionInputs
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

  private func uploadAttachedImages(_ images: [AttachedImage]) async throws -> [ServerImageInput] {
    var uploaded: [ServerImageInput] = []
    uploaded.reserveCapacity(images.count)

    for image in images {
      let input = try await serverState.uploadImageAttachment(
        sessionId: sessionId,
        data: image.uploadData,
        mimeType: image.uploadMimeType,
        displayName: image.displayName ?? "image",
        pixelWidth: image.pixelWidth ?? 0,
        pixelHeight: image.pixelHeight ?? 0
      )
      uploaded.append(input)
    }

    return uploaded
  }

  private func completeSuccessfulComposerSend() {
    Platform.services.playHaptic(.action)
    errorMessage = nil
    message = ""
    withAnimation(Motion.gentle) {
      attachedImages = []
      attachedMentions = []
    }
    requestComposerFocus()
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
    serverState.refreshWorktreesForActiveSessions()
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
            try? await serverState.forkSessionToWorktree(
              sessionId: sessionId,
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
                    try? await serverState.forkSessionToExistingWorktree(
                      sessionId: sessionId, worktreeId: wt.id, nthUserMessage: nil
                    )
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
