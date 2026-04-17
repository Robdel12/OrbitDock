import SwiftUI

extension ControlDeckScreen {
  var currentMode: ControlDeckMode {
    sessionModel.presentation?.mode ?? .disabled
  }

  var canSubmit: Bool {
    let modeAllowsInput = currentMode == .compose || currentMode == .steer
    return modeAllowsInput && composer.draft.hasContent && !composer.isSubmitting && !sessionModel.isResuming
  }

  var isInputEnabled: Bool {
    (currentMode == .compose || currentMode == .steer) && !composer.isSubmitting && !sessionModel.isResuming
  }

  var shouldShowDictation: Bool {
    localDictationEnabled && LocalDictationAvailabilityResolver.current == .available
  }

  var isDictationActive: Bool {
    composer.dictationController.state == .recording
      || composer.dictationController.state == .requestingPermission
      || composer.dictationController.state == .transcribing
  }

  var dictationAction: (() -> Void)? {
    shouldShowDictation ? { toggleDictation() } : nil
  }

  var isApprovalMode: Bool {
    currentMode == .approval && sessionModel.pendingApproval != nil
  }

  var shouldShowCompletionPanel: Bool {
    composer.completionState.isActive && !isApprovalMode
  }

  var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  var horizontalContentPadding: CGFloat {
    isCompact ? Spacing.sm : Spacing.md
  }

  var completionPanelWidth: CGFloat {
    let available = max(composer.controlDeckWidth - (horizontalContentPadding * 2), 0)
    guard available > 0 else { return 520 }
    return available
  }

  var currentSuggestions: [ControlDeckCompletionSuggestion] {
    composer.currentSuggestions(
      availableSkills: sessionModel.skills,
      projectPath: sessionModel.projectPath,
      projectFileIndex: sessionModel.projectFileIndex
    )
  }

  var controlDeckBody: some View {
    ControlDeckView(
      composer: composer,
      isSubmitting: composer.isSubmitting,
      isResuming: sessionModel.isResuming,
      isInputEnabled: isInputEnabled,
      canSubmit: canSubmit,
      presentation: sessionModel.presentation,
      pendingApproval: sessionModel.pendingApproval,
      errorMessage: sessionModel.lastError,
      chromeStyle: chromeStyle,
      onTextChange: handleTextChange,
      onKeyCommand: handleKeyCommand,
      onFocusEvent: handleFocusEvent,
      onPasteImage: pasteImageFromClipboard,
      canPasteImage: { supportsImageClipboardPaste },
      onAddImage: { composer.isImportingAttachments = true },
      onRemoveAttachment: { composer.draft.attachments.remove(id: $0) },
      onDropImages: handleDrop,
      onSubmit: submitDraft,
      onResume: resumeSession,
      onApprove: { Task { await sessionModel.approveTool(decision: .approved) } },
      onApproveForSession: { Task { await sessionModel.approveTool(decision: .approvedForSession) } },
      onApproveAlwaysForHost: { host in
        Task { await sessionModel.approveToolAlwaysAllowHost(host) }
      },
      onDeny: { Task { await sessionModel.approveTool(decision: .denied) } },
      onAnswer: { answer, promptId in
        Task { await sessionModel.answerQuestion(answer: answer, questionId: promptId) }
      },
      onSubmitAllAnswers: { answers in
        Task { await sessionModel.answerQuestionBatch(answers: answers) }
      },
      onGrantPermission: { Task { await sessionModel.respondToPermission(grant: true, scope: .turn) } },
      onGrantPermissionForSession: {
        Task { await sessionModel.respondToPermission(grant: true, scope: .session) }
      },
      onDenyPermission: { Task { await sessionModel.respondToPermission(grant: false) } },
      terminalTitle: terminalTitle,
      currentTool: currentTool,
      onToggleTerminal: onToggleTerminal,
      onModuleAction: handleModuleAction,
      onApprovalReviewerAction: handleApprovalReviewerAction,
      onSandboxPolicyAction: handleSandboxPolicyAction,
      isDictating: isDictationActive,
      onDictation: dictationAction,
      onInterrupt: { Task { await sessionModel.interruptSession() } }
    )
    .background(
      GeometryReader { proxy in
        Color.clear.preference(key: ControlDeckWidthPreferenceKey.self, value: proxy.size.width)
      }
    )
    .overlay(alignment: .topLeading) {
      if shouldShowCompletionPanel {
        completionPanelOverlay
      }
    }
    .onPreferenceChange(ControlDeckWidthPreferenceKey.self) { width in
      guard width > 0 else { return }
      composer.controlDeckWidth = width
    }
    .onPreferenceChange(ControlDeckCompletionPanelHeightPreferenceKey.self) { height in
      guard height > 0 else { return }
      composer.completionPanelHeight = height
    }
    .zIndex(2)
  }

  var completionPanelOverlay: some View {
    ControlDeckCompletionPanel(
      mode: composer.completionState.mode,
      suggestions: currentSuggestions,
      selectedIndex: composer.completionState.selectedIndex,
      onSelect: acceptSuggestion
    )
    .frame(width: completionPanelWidth, alignment: .leading)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: ControlDeckCompletionPanelHeightPreferenceKey.self,
          value: proxy.size.height
        )
      }
    )
    .offset(x: horizontalContentPadding, y: -(composer.completionPanelHeight + Spacing.xs))
    .transition(.move(edge: .top).combined(with: .opacity))
    .animation(Motion.gentle, value: shouldShowCompletionPanel)
    .zIndex(10)
  }

  var loadingView: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, minHeight: 60)
      .background(Color.backgroundSecondary)
      .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
  }

  func errorView(_ error: String) -> some View {
    VStack(spacing: Spacing.sm) {
      Text(error)
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.statusPermission)
        .lineLimit(3)
      Button("Retry") { Task { await sessionModel.refresh() } }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity)
    .background(Color.backgroundSecondary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(Color.panelBorder, lineWidth: 1)
    )
  }
}

struct ControlDeckWidthPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct ControlDeckCompletionPanelHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
