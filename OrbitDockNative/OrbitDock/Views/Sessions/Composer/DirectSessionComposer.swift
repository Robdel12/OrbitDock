//
//  DirectSessionComposer.swift
//  OrbitDock
//
//  Unified composer for direct sessions.
//  Two layers: composer (text input + action dock) → instrument strip.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
  import PhotosUI
#endif

struct DirectSessionComposer: View {
  let sessionId: String
  let sessionStore: SessionStore
  @Binding var selectedSkills: Set<String>
  var pendingPanelOpenSignal: Int = 0
  let followMode: ConversationFollowMode
  let unreadCount: Int
  let onJumpToLatest: () -> Void
  let onTogglePinned: () -> Void
  var onOpenTerminal: ((String) -> Void)?
  @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
  @Environment(AppRouter.self) var router
  @Environment(TerminalSessionRegistry.self) var terminalRegistry
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @AppStorage("localDictationEnabled") var localDictationEnabled = true
  @State var viewModel: DirectSessionComposerViewModel

  @State var composerState = DirectSessionComposerState()
  @State var inputState = DirectSessionComposerInputState()
  @State var codexInspectorResponse: SessionsClient.CodexInspectorResponse?
  @State var codexInspectorError: String?
  @State var codexInspectorLoading = false
  @State var showCodexInspector = false
  @State var scopedCodexModels: [ServerCodexModelOption]?
  @State var scopedCodexModelsLoading = false
  @State var scopedCodexModelsError: String?
  @State var scopedCodexModelsRequestID = 0

  /// Attachments
  @State var attachmentState = DirectSessionComposerAttachmentState()
  #if os(iOS)
    @State var photoPickerItems: [PhotosPickerItem] = []
    @State var isPhotoPickerPresented = false
    @State var photoPickerLoadTask: Task<Void, Never>?
  #endif

  /// Input mode
  @State var dictationController = LocalDictationController()
  @State var pendingState = DirectSessionComposerPendingState()

  init(
    sessionId: String,
    sessionStore: SessionStore,
    selectedSkills: Binding<Set<String>>,
    pendingPanelOpenSignal: Int = 0,
    followMode: ConversationFollowMode,
    unreadCount: Int,
    onJumpToLatest: @escaping () -> Void,
    onTogglePinned: @escaping () -> Void,
    onOpenTerminal: ((String) -> Void)? = nil
  ) {
    self.sessionId = sessionId
    self.sessionStore = sessionStore
    _selectedSkills = selectedSkills
    self.pendingPanelOpenSignal = pendingPanelOpenSignal
    self.followMode = followMode
    self.unreadCount = unreadCount
    self.onJumpToLatest = onJumpToLatest
    self.onTogglePinned = onTogglePinned
    self.onOpenTerminal = onOpenTerminal

    let initialViewModel = DirectSessionComposerViewModel()
    initialViewModel.bind(sessionId: sessionId, sessionStore: sessionStore)
    _viewModel = State(initialValue: initialViewModel)
  }

  var message: String {
    get { composerState.message }
    nonmutating set { composerState.message = newValue }
  }

  var isSending: Bool {
    get { composerState.isSending }
    nonmutating set { composerState.isSending = newValue }
  }

  var errorMessage: String? {
    get { composerState.errorMessage }
    nonmutating set { composerState.errorMessage = newValue }
  }

  var selectedModel: String {
    get { composerState.selectedModel }
    nonmutating set { composerState.selectedModel = newValue }
  }

  var selectedClaudeModel: String {
    get { composerState.selectedClaudeModel }
    nonmutating set { composerState.selectedClaudeModel = newValue }
  }

  var selectedEffort: EffortLevel {
    get { composerState.selectedEffort }
    nonmutating set { composerState.selectedEffort = newValue }
  }

  var showModelEffortPopover: Bool {
    get { composerState.showModelEffortPopover }
    nonmutating set { composerState.showModelEffortPopover = newValue }
  }

  var showClaudeModelPopover: Bool {
    get { composerState.showClaudeModelPopover }
    nonmutating set { composerState.showClaudeModelPopover = newValue }
  }

  var showCodexSettingsSheet: Bool {
    get { composerState.showCodexSettingsSheet }
    nonmutating set { composerState.showCodexSettingsSheet = newValue }
  }

  var showCodexConfigManagerSheet: Bool {
    get { composerState.showCodexConfigManagerSheet }
    nonmutating set { composerState.showCodexConfigManagerSheet = newValue }
  }

  var showFilePickerPopover: Bool {
    get { composerState.showFilePickerPopover }
    nonmutating set { composerState.showFilePickerPopover = newValue }
  }

  var filePickerQuery: String {
    get { composerState.filePickerQuery }
    nonmutating set { composerState.filePickerQuery = newValue }
  }

  var manualReviewMode: Bool {
    get { composerState.manualReviewMode }
    nonmutating set { composerState.manualReviewMode = newValue }
  }

  var manualShellMode: Bool {
    get { composerState.manualShellMode }
    nonmutating set { composerState.manualShellMode = newValue }
  }

  var dictationDraftBaseMessage: String? {
    get { composerState.dictationDraftBaseMessage }
    nonmutating set { composerState.dictationDraftBaseMessage = newValue }
  }

  var showForkToWorktreeSheet: Bool {
    get { composerState.showForkToWorktreeSheet }
    nonmutating set { composerState.showForkToWorktreeSheet = newValue }
  }

  var showForkToExistingWorktreeSheet: Bool {
    get { composerState.showForkToExistingWorktreeSheet }
    nonmutating set { composerState.showForkToExistingWorktreeSheet = newValue }
  }

  var permissionPanelExpanded: Bool {
    get { composerState.permissionPanelExpanded }
    nonmutating set { composerState.permissionPanelExpanded = newValue }
  }

  // MARK: - Body

  var body: some View {
    DirectSessionComposerShell(
      isSessionActive: isSessionActive,
      isCompactLayout: isCompactLayout,
      hasError: composerErrorMessage != nil,
      leading: { composerLeadingSections },
      activeSurface: { composerSurface },
      resume: { resumeRow },
      errorRow: {
        if let error = composerErrorMessage {
          errorRow(error)
        }
      }
    )
    .sheet(isPresented: $composerState.showForkToWorktreeSheet) {
      forkToWorktreeSheet
    }
    .sheet(isPresented: $composerState.showForkToExistingWorktreeSheet) {
      forkToExistingWorktreeSheet
    }
    .sheet(isPresented: $showCodexInspector) {
      CodexConfigInspectorSheet(
        response: codexInspectorResponse,
        errorMessage: codexInspectorError,
        isLoading: codexInspectorLoading,
        onRefresh: {
          inspectCodexConfig()
        },
        onManageConfig: {
          showCodexConfigManagerSheet = true
        }
      )
    }
    .sheet(isPresented: $composerState.showCodexSettingsSheet) {
      NavigationStack {
        CodexSessionSettingsSheet(
          projectPath: projectPath,
          modelOption: currentCodexModelOption,
          approvalPolicy: currentCodexApprovalPolicy,
          approvalPolicyDetails: currentCodexApprovalPolicyDetails,
          sandboxMode: currentCodexSandboxMode,
          configMode: currentCodexConfigMode,
          configProfile: currentCodexConfigProfile,
          modelProvider: currentCodexModelProvider,
          collaborationMode: currentCodexCollaborationMode,
          multiAgentEnabled: currentCodexMultiAgentEnabled,
          personality: currentCodexPersonality,
          serviceTier: currentCodexServiceTier,
          developerInstructions: obs.developerInstructions,
          fetchCatalog: { cwd in
            try await viewModel.fetchCodexConfigCatalog(cwd: cwd)
          },
          onApply: applyCodexSessionSettings,
          onReset: resetCodexSessionOverrides,
          onInspect: {
            showCodexSettingsSheet = false
            inspectCodexConfig()
          },
          onManageConfig: {
            showCodexSettingsSheet = false
            showCodexConfigManagerSheet = true
          },
          onDone: {
            showCodexSettingsSheet = false
          }
        )
        .navigationTitle("Codex Session Overrides")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") {
                showCodexSettingsSheet = false
              }
            }
          }
      }
      #if os(macOS)
      .frame(minWidth: 820, idealWidth: 860, minHeight: 720, idealHeight: 780)
      #endif
    }
    .sheet(isPresented: $composerState.showCodexConfigManagerSheet) {
      if let projectPath {
        CodexConfigManagerSheet(
          cwd: projectPath,
          fetchDocuments: { cwd in
            try await viewModel.fetchCodexConfigDocuments(cwd: cwd)
          },
          batchWrite: { request in
            try await viewModel.batchWriteCodexConfig(request)
          },
          onDidChange: {}
        )
      }
    }
    #if os(iOS)
    .photosPicker(
      isPresented: $isPhotoPickerPresented,
      selection: $photoPickerItems,
      maxSelectionCount: 5,
      matching: .images
    )
    #endif
    .onDrop(of: [.image, .fileURL], isTargeted: $attachmentState.isImageDropTargeted) { providers in
      handleDrop(providers)
    }
    .task(id: "\(sessionStore.endpointId.uuidString):\(sessionId)") {
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore)
    }
    .task(id: sessionId) {
      selectedModel = ""
      selectedClaudeModel = ""
      selectedEffort = .default

      if obs.isDirectCodex {
        viewModel.refreshCodexModels()
        refreshScopedCodexModelsIfNeeded()
        // Restore persisted effort level from server state
        if let saved = obs.effort, let level = EffortLevel(rawValue: saved) {
          selectedEffort = level
        }
      } else if obs.isDirectClaude {
        if selectedClaudeModel.isEmpty {
          selectedClaudeModel = defaultClaudeModelSelection
        }
      }
      if message.isEmpty, let restoredDraft = ComposerDraftStore.load(for: draftStorageKey) {
        message = restoredDraft
      }
      resetPendingPanelStateForRequest()
      guard obs.isActive else { return }
      await Task.yield()
      // On compact (iPhone), don't auto-summon the keyboard — let the user
      // read the conversation first and tap when ready to type.
      if !isCompactLayout {
        requestComposerFocus()
      }
    }
    .task(id: projectPath) {
      guard let path = projectPath else { return }
      await fileIndex.loadIfNeeded(path)
    }
    .task(id: codexModelScopeSignature) {
      refreshScopedCodexModelsIfNeeded()
    }
    .onChange(of: message) { _, newValue in
      ComposerDraftStore.save(newValue, for: draftStorageKey)
    }
    .onChange(of: obs.rowEntriesRevision) { _, _ in
      reconcileRecoveredSendIfNeeded()
    }
    .onChange(of: pendingApprovalIdentity) { _, newValue in
      resetPendingPanelStateForRequest()
      guard !newValue.isEmpty, newValue != pendingState.lastHapticApprovalIdentity else {
        pendingState.lastHapticApprovalIdentity = newValue
        return
      }
      pendingState.lastHapticApprovalIdentity = newValue
      Platform.services.playHaptic(.warning)
    }
    .onChange(of: pendingPanelOpenSignal) { _, newValue in
      guard newValue > 0 else { return }
      withAnimation(Motion.standard) {
        pendingState.isExpanded = true
      }
      // Dismiss keyboard when approval panel opens — on compact the panel
      // and keyboard together leave almost no conversation visible.
      if isCompactLayout {
        relinquishComposerFocus()
      }
    }
    .onChange(of: codexModelOptionsSignature) { _, _ in
      guard obs.isDirectCodex else { return }
      guard codexAllowsModelSelection else {
        selectedModel = ""
        return
      }
      if !selectedModel.isEmpty, !codexModelOptions.contains(where: { $0.model == selectedModel }) {
        selectedModel = ""
      }
    }
    .onChange(of: currentCodexConfigMode) { _, newValue in
      guard obs.isDirectCodex else { return }
      if newValue != .custom {
        selectedModel = ""
      }
    }
    .onChange(of: claudeModelOptionsSignature) { _, _ in
      guard obs.isDirectClaude else { return }
      if selectedClaudeModel.isEmpty || !claudeModelOptions.contains(where: { $0.value == selectedClaudeModel }) {
        selectedClaudeModel = defaultClaudeModelSelection
      }
    }
    .onChange(of: localDictationEnabled) { _, enabled in
      guard !enabled else { return }
      Task { @MainActor in
        await dictationController.cancel()
        clearDictationDraftState()
      }
    }
    .onChange(of: dictationController.liveTranscript) { _, transcript in
      guard dictationController.isRecording else { return }
      updateDictationLivePreview(transcript)
    }
    .onDisappear {
      Task { @MainActor in
        await dictationController.cancel()
        clearDictationDraftState()
      }
    }
    #if os(iOS)
    .onChange(of: photoPickerItems) { _, newItems in
      handlePhotoPickerSelection(newItems)
    }
    .onDisappear {
      photoPickerLoadTask?.cancel()
      photoPickerLoadTask = nil
    }
    #endif
  }

  @ViewBuilder
  var composerTextInput: some View {
    ComposerTextArea(
      text: $composerState.message,
      placeholder: composerPlaceholder,
      focusRequestSignal: $inputState.focus.focusRequestSignal,
      blurRequestSignal: $inputState.focus.blurRequestSignal,
      moveCursorToEndSignal: $inputState.focus.moveCursorToEndSignal,
      measuredHeight: $inputState.focus.measuredHeight,
      isEnabled: !isSending && !isDictationActive,
      minLines: isCompactLayout ? 1 : 2,
      maxLines: isCompactLayout ? 3 : 4,
      onPasteImage: { pasteImageFromClipboard() },
      canPasteImage: { canPasteImageFromClipboard },
      onKeyCommand: handleComposerTextAreaKeyCommand,
      onFocusEvent: handleComposerFocusEvent
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: inputState.focus.measuredHeight)
    .animation(Motion.snappy, value: inputState.focus.measuredHeight)
    .layoutPriority(1)
    #if os(iOS)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { relinquishComposerFocus() }
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
      }
    #endif
      .onChange(of: message) { _, newValue in
        if isDictationActive { return }
        updateCommandDeckCompletion(newValue)
        updateSkillCompletion(newValue)
        updateMentionCompletion(newValue)
      }
  }

  @ViewBuilder
  var composerLeadingSections: some View {
    if shouldShowCommandDeck {
      ComposerCommandDeckList(
        items: commandDeckItems,
        selectedIndex: inputState.commandDeck.index,
        query: inputState.commandDeck.query,
        onSelect: acceptCommandDeckItem
      )
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    if shouldShowCompletion, !shouldShowCommandDeck {
      SkillCompletionList(
        skills: filteredSkills,
        selectedIndex: inputState.skillCompletion.index,
        query: inputState.skillCompletion.query,
        onSelect: acceptSkillCompletion
      )
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    if shouldShowMentionCompletion, !shouldShowCommandDeck {
      MentionCompletionList(
        files: filteredFiles,
        selectedIndex: inputState.mentionCompletion.index,
        query: inputState.mentionCompletion.query,
        onSelect: acceptMentionCompletion
      )
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    if hasAttachments {
      AttachmentBar(
        images: attachedImagesBinding,
        mentions: attachedMentionsBinding,
        imageLoader: viewModel.imageLoader
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    if !obs.promptSuggestions.isEmpty, isSessionActive, !isSessionWorking {
      promptSuggestionChips
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    if let rateLimitInfo = obs.rateLimitInfo, rateLimitInfo.needsDisplay {
      RateLimitBanner(info: rateLimitInfo)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  // MARK: - Composer Row

  var promptSuggestionChips: some View {
    DirectSessionComposerPromptSuggestions(
      suggestions: obs.promptSuggestions,
      onSelect: sendSuggestion
    )
  }

  func sendSuggestion(_ suggestion: String) {
    Task { try? await viewModel.sendMessage(content: suggestion) }
  }

  // MARK: - Composer Surface

  var hasStatusBarContent: Bool {
    DirectSessionComposerProviderPlanner.hasStatusBarContent(
      isConnected: isConnected,
      isDirectCodex: obs.isDirectCodex,
      isDirectClaude: obs.isDirectClaude,
      isSessionWorking: isSessionWorking,
      hasTokenUsage: obs.hasTokenUsage,
      selectedCodexModel: effectiveCodexModel,
      effectiveClaudeModel: effectiveClaudeModel,
      branch: obs.branch,
      projectPath: obs.projectPath
    )
  }

  var composerSurface: some View {
    DirectSessionComposerSurface(
      composerBorderColor: composerBorderColor,
      inputMode: inputMode,
      pendingApprovalIdentity: pendingApprovalIdentity,
      pendingPanelExpanded: pendingState.isExpanded,
      permissionPanelExpanded: permissionPanelExpanded,
      isFocused: inputState.focus.isFocused,
      isDropTargeted: attachmentState.isImageDropTargeted,
      isCompactLayout: isCompactLayout,
      idleBorderOpacity: isCompactLayout ? 0.35 : (canSend ? 0.34 : 0.18),
      topSections: { composerSurfaceTopSections },
      input: {
        composerTextInput
          .padding(.horizontal, Spacing.md_)
          .padding(.top, pendingApprovalModel != nil ? Spacing.xs : Spacing.sm)
          .padding(.bottom, Spacing.xs)
      },
      footer: { composerFooter },
      bottomSections: { composerSurfaceBottomSections },
      dropOverlay: { composerDropTargetOverlay }
    )
  }

  @ViewBuilder
  var composerSurfaceTopSections: some View {
    if permissionPanelExpanded, obs.isDirect {
      PermissionInlinePanel(
        state: viewModel.permissionPanelState,
        isExpanded: $composerState.permissionPanelExpanded,
        onLoadRules: {
          try? await viewModel.loadPermissionRules()
        },
        onSelectAutonomy: { level in
          try? await viewModel.updateAutonomy(level)
        },
        onSelectPermissionMode: { mode in
          try? await viewModel.updateClaudePermissionMode(mode)
        },
        onRemoveRule: { pattern, behavior in
          try? await viewModel.removePermissionRule(pattern: pattern, behavior: behavior)
        }
      )
      .transition(.move(edge: .top).combined(with: .opacity))
    }

    if let model = pendingApprovalModel {
      pendingInlineZone(model)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  @ViewBuilder
  var composerSurfaceBottomSections: some View {
    if hasStatusBarContent {
      composerStatusDivider
      statusBar
    }

    if let notice = connectionNoticeMessage {
      connectionNoticeRow(notice)
        .padding(.top, Spacing.xxs)
    }

    if let notice = codexScopedModelNoticeMessage {
      codexScopedModelNoticeRow(notice, isLoading: scopedCodexModelsLoading)
        .padding(.top, Spacing.xxs)
    }
  }

  var composerStatusDivider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
      .frame(height: 0.5)
      .padding(.horizontal, Spacing.sm)
  }

  @ViewBuilder
  var composerDropTargetOverlay: some View {
    if attachmentState.isImageDropTargeted {
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.accent.opacity(0.16))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .strokeBorder(Color.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
        )
        .overlay {
          Label("Drop images to attach", systemImage: "photo.badge.plus")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(
              Capsule()
                .fill(Color.backgroundPrimary.opacity(0.82))
            )
        }
        .padding(Spacing.xs)
        .transition(.opacity)
    }
  }

  // MARK: - Resume Row (ended session)

  var resumeRow: some View {
    DirectSessionComposerResumeRow(
      lastActivityAt: obs.lastActivityAt,
      onResume: {
        connLog(.info, category: .resume, "Resume button tapped", sessionId: sessionId)
        Task { try? await viewModel.resumeSession() }
      }
    )
  }

  // MARK: - Error Row

  func errorRow(_ error: String) -> some View {
    DirectSessionComposerErrorRow(
      error: error,
      showsOpenSettingsAction: shouldShowOpenMicrophoneSettingsAction,
      onOpenSettings: {
        _ = Platform.services.openMicrophonePrivacySettings()
      },
      onDismiss: {
        if errorMessage != nil {
          errorMessage = nil
        } else {
          dictationController.clearError()
        }
      }
    )
  }

  var shouldShowOpenMicrophoneSettingsAction: Bool {
    errorMessage == nil && dictationController.isMicrophonePermissionDenied
  }

  // MARK: - Image Input

  // Implemented in DirectSessionComposer+ImageShared.swift and platform extensions.
}

// CodexInterruptButton — see CodexInterruptButton.swift

// Standalone types: see ComposerCompletionLists.swift, CodexInterruptButton.swift

#Preview {
  @Previewable @State var skills: Set<String> = []
  @Previewable @State var followMode: ConversationFollowMode = .following
  @Previewable @State var unread = 0
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  let sessionStore = SessionStore.preview()
  let router = AppRouter()
  DirectSessionComposer(
    sessionId: "test-session",
    sessionStore: sessionStore,
    selectedSkills: $skills,
    followMode: followMode,
    unreadCount: unread,
    onJumpToLatest: {
      followMode = .following
      unread = 0
    },
    onTogglePinned: {
      followMode = followMode.isFollowing ? .detachedByUser : .following
      if followMode.isFollowing {
        unread = 0
      }
    }
  )
  .environment(runtimeRegistry)
  .environment(router)
  .frame(width: 600)
}
