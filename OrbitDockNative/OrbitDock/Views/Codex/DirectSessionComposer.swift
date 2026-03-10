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
  @Binding var selectedSkills: Set<String>
  var pendingPanelOpenSignal: Int = 0
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int
  @Environment(SessionStore.self) var serverState
  @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
  @Environment(AppRouter.self) var router
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @AppStorage("localDictationEnabled") var localDictationEnabled = true

  @State var message = ""
  @State var isSending = false
  @State var errorMessage: String?
  @State var selectedModel: String = ""
  @State var selectedClaudeModel: String = ""
  @State var selectedEffort: EffortLevel = .default
  @State var showModelEffortPopover = false
  @State var showClaudeModelPopover = false
  @State var showFilePickerPopover = false
  @State var filePickerQuery = ""
  @State var inputState = DirectSessionComposerInputState()

  /// Attachments
  @State var attachmentState = DirectSessionComposerAttachmentState()
  #if os(iOS)
    @State var photoPickerItems: [PhotosPickerItem] = []
    @State var isPhotoPickerPresented = false
    @State var photoPickerLoadTask: Task<Void, Never>?
  #endif

  /// Input mode
  @State var manualReviewMode = false
  @State var manualShellMode = false
  @State var dictationController = LocalDictationController()
  @State var dictationDraftBaseMessage: String?
  @State var showForkToWorktreeSheet = false
  @State var showForkToExistingWorktreeSheet = false
  @State var pendingState = DirectSessionComposerPendingState()
  @State var permissionPanelExpanded = false
  var obs: SessionObservable {
    serverState.session(sessionId)
  }

  var sessionSummary: Session? {
    serverState.sessions.first(where: { $0.id == sessionId })
  }

  var currentContinuation: SessionContinuation {
    SessionContinuation(
      endpointId: serverState.endpointId,
      sessionId: sessionId,
      provider: obs.provider,
      displayName: sessionSummary?.displayName ?? obs.displayName,
      projectPath: obs.projectPath,
      model: obs.model,
      hasGitRepository: obs.branch != nil || obs.repositoryRoot != nil || obs.isWorktree
    )
  }

  var canContinueInNewSession: Bool {
    !serverState.isRemoteConnection
  }

  var pendingApprovalModel: ApprovalCardModel? {
    guard let summary = sessionSummary else { return nil }
    let pendingApproval = obs.pendingApproval
    return ApprovalCardModelBuilder.build(
      session: summary,
      pendingApproval: pendingApproval,
      approvalHistory: obs.approvalHistory,
      transcriptMessages: serverState.conversation(sessionId).messages
    )
  }

  var pendingApprovalIdentity: String {
    pendingApprovalModel?.approvalId ?? ""
  }

  var inputMode: InputMode {
    if manualShellMode { return .shell }
    if manualReviewMode { return .reviewNotes }
    if isSessionWorking { return .steer }
    return .prompt
  }

  var composerBorderColor: Color {
    if let model = pendingApprovalModel {
      return pendingPanelModeColor(model)
    }
    switch inputMode {
      case .steer: return .composerSteer
      case .reviewNotes: return .composerReview
      case .shell: return .composerShell
      default: return .composerPrompt
    }
  }

  var isSessionWorking: Bool {
    obs.workStatus == .working
  }

  var isSessionActive: Bool {
    obs.isActive
  }

  var draftStorageKey: String {
    "endpoint:\(serverState.endpointId.uuidString)::session:\(sessionId)"
  }

  var connectionStatus: ConnectionStatus {
    runtimeRegistry.displayConnectionStatus(for: serverState.endpointId)
  }

  var isConnected: Bool {
    if case .connected = connectionStatus {
      return true
    }
    return false
  }

  var connectionPillTint: Color {
    switch connectionStatus {
      case .connected:
        .feedbackPositive
      case .connecting:
        .feedbackCaution
      case .disconnected:
        .textQuaternary
      case .failed:
        .statusError
    }
  }

  var connectionPillIcon: String {
    switch connectionStatus {
      case .connected:
        "network"
      case .connecting:
        "arrow.triangle.2.circlepath"
      case .disconnected:
        "wifi.slash"
      case .failed:
        "exclamationmark.triangle.fill"
    }
  }

  var connectionPillLabel: String {
    switch connectionStatus {
      case .connected:
        "Connected"
      case .connecting:
        "Reconnecting"
      case .disconnected:
        "Offline"
      case .failed:
        "Connect failed"
    }
  }

  var connectionNoticeMessage: String? {
    switch connectionStatus {
      case .connected:
        return nil
      case .connecting:
        return "Reconnecting to server. Messages sent now will queue and auto-send."
      case .disconnected:
        return "Server disconnected. Messages sent now will queue and auto-send."
      case let .failed(reason):
        if reason.isEmpty {
          return "Server connection failed. Messages sent now will queue and auto-send."
        }
        return "Server connection failed (\(reason)). Messages sent now will queue and auto-send."
    }
  }

  var showReconnectButton: Bool {
    switch connectionStatus {
      case .disconnected, .failed:
        true
      case .connecting, .connected:
        false
    }
  }

  var hasOverrides: Bool {
    DirectSessionComposerProviderPlanner.hasOverrides(
      providerMode: providerMode,
      selectedCodexModel: selectedModel,
      selectedClaudeModel: selectedClaudeModel,
      currentModel: obs.model,
      selectedEffort: selectedEffort,
      codexOptions: codexModelOptions,
      claudeOptions: claudeModelOptions
    )
  }

  var availableSkills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter(\.enabled)
  }

  var filteredSkills: [ServerSkillMetadata] {
    guard !inputState.skillCompletion.query.isEmpty else { return availableSkills }
    let q = inputState.skillCompletion.query.lowercased()
    return availableSkills.filter { $0.name.lowercased().contains(q) }
  }

  var shouldShowCompletion: Bool {
    inputState.skillCompletion.isActive && !filteredSkills.isEmpty
  }

  var hasInlineSkills: Bool {
    !DirectSessionComposerSkillPlanner.inlineSkillNames(
      in: message,
      availableSkillNames: Set(availableSkills.map(\.name))
    ).isEmpty
  }

  var codexModelOptions: [ServerCodexModelOption] {
    serverState.codexModels
  }

  var codexModelOptionsSignature: String {
    codexModelOptions.map(\.model).joined(separator: "|")
  }

  var claudeModelOptions: [ServerClaudeModelOption] {
    serverState.claudeModels
  }

  var claudeModelOptionsSignature: String {
    claudeModelOptions.map(\.value).joined(separator: "|")
  }

  var defaultCodexModelSelection: String {
    DirectSessionComposerProviderPlanner.defaultCodexModelSelection(
      currentModel: obs.model,
      options: codexModelOptions
    )
  }

  var defaultClaudeModelSelection: String {
    DirectSessionComposerProviderPlanner.defaultClaudeModelSelection(
      currentModel: obs.model,
      options: claudeModelOptions
    )
  }

  var effectiveClaudeModel: String {
    DirectSessionComposerProviderPlanner.effectiveClaudeModel(
      selectedClaudeModel: selectedClaudeModel,
      sessionModel: obs.model,
      options: claudeModelOptions
    )
  }

  var projectPath: String? {
    let normalized = obs.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  var fileIndex: ProjectFileIndex {
    serverState.projectFileIndex
  }

  var forkWorktreeDisplayRepoPath: String? {
    if let root = obs.repositoryRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
      return root
    }
    if !obs.projectPath.isEmpty {
      return obs.projectPath
    }
    return nil
  }

  var forkToExistingCandidates: [ServerWorktreeSummary] {
    guard let repoPath = forkWorktreeDisplayRepoPath else { return [] }
    return serverState.worktrees(for: repoPath)
      .filter {
        $0.status != .removed && $0.diskPresent && $0.worktreePath != repoPath
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  var canForkConversation: Bool {
    !obs.forkInProgress
  }

  var canForkToWorktree: Bool {
    forkWorktreeDisplayRepoPath != nil && canForkConversation
  }

  var canForkToExistingWorktree: Bool {
    forkWorktreeDisplayRepoPath != nil && canForkConversation
  }

  var filteredFiles: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    return fileIndex.search(inputState.mentionCompletion.query, in: path)
  }

  var shouldShowMentionCompletion: Bool {
    inputState.mentionCompletion.isActive && !filteredFiles.isEmpty
  }

  var shouldShowCommandDeck: Bool {
    inputState.commandDeck.isActive && !commandDeckItems.isEmpty
  }

  var hasSkillsPanel: Bool {
    obs.isDirectCodex || serverState.session(sessionId).hasClaudeSkills
  }

  var hasMcpData: Bool {
    serverState.session(sessionId).hasMcpData
  }

  var mcpToolEntries: [ComposerMcpToolEntry] {
    DirectSessionComposerCommandDeckPlanner.mcpToolEntries(from: serverState.session(sessionId).mcpTools)
  }

  var mcpResourceEntries: [ComposerMcpResourceEntry] {
    DirectSessionComposerCommandDeckPlanner.mcpResourceEntries(from: serverState.session(sessionId).mcpResources)
  }

  var commandDeckItems: [ComposerCommandDeckItem] {
    let projectFiles: [ProjectFileIndex.ProjectFile]
    if let path = projectPath {
      let query = inputState.commandDeck.query.trimmingCharacters(in: .whitespacesAndNewlines)
      projectFiles = if query.isEmpty {
        Array(fileIndex.files(for: path).prefix(7))
      } else {
        Array(fileIndex.search(query, in: path).prefix(9))
      }
    } else {
      projectFiles = []
    }

    return DirectSessionComposerCommandDeckPlanner.buildItems(
      DirectSessionComposerCommandDeckContext(
        query: inputState.commandDeck.query,
        hasSkillsPanel: hasSkillsPanel,
        hasMcpData: hasMcpData,
        manualShellMode: manualShellMode,
        projectFiles: projectFiles,
        availableSkills: availableSkills,
        mcpToolEntries: mcpToolEntries,
        mcpResourceEntries: mcpResourceEntries
      )
    )
  }

  var filePickerResults: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    let trimmed = filePickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return Array(fileIndex.files(for: path).prefix(220))
    }
    return Array(fileIndex.search(trimmed, in: path).prefix(300))
  }

  var hasAttachments: Bool {
    attachmentState.hasAttachments
  }

  var attachedImagesBinding: Binding<[AttachedImage]> {
    Binding(
      get: { attachmentState.images },
      set: { attachmentState.images = $0 }
    )
  }

  var attachedMentionsBinding: Binding<[AttachedMention]> {
    Binding(
      get: { attachmentState.mentions },
      set: { attachmentState.mentions = $0 }
    )
  }

  var isDictationActive: Bool {
    dictationController.state == .recording ||
      dictationController.state == .requestingPermission ||
      dictationController.state == .transcribing
  }

  var shouldShowDictation: Bool {
    localDictationEnabled && LocalDictationAvailabilityResolver.current == .available
  }

  var composerErrorMessage: String? {
    errorMessage ?? dictationController.errorMessage
  }

  var composerPlaceholder: String {
    if inputMode == .shell { return "Run a shell command..." }
    if isSessionWorking { return "Steer the current turn..." }
    return "Send a message..."
  }

  var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      composerLeadingSections

      // ━━━ Composer area ━━━
      if isSessionActive {
        composerSurface
      } else {
        // Ended session — resume button
        resumeRow
      }

      // ━━━ Error message ━━━
      if let error = composerErrorMessage {
        errorRow(error)
      }
    }
    .background(isCompactLayout ? Color.backgroundSecondary : Color.clear)
    .sheet(isPresented: $showForkToWorktreeSheet) {
      forkToWorktreeSheet
    }
    .sheet(isPresented: $showForkToExistingWorktreeSheet) {
      forkToExistingWorktreeSheet
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
    .task(id: sessionId) {
      if obs.isDirectCodex {
        serverState.refreshCodexModels()
        if selectedModel.isEmpty {
          selectedModel = defaultCodexModelSelection
        }
        // Restore persisted effort level from server state
        if let saved = obs.effort, let level = EffortLevel(rawValue: saved) {
          selectedEffort = level
        }
      } else if obs.isDirectClaude {
        serverState.refreshClaudeModels()
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
      requestComposerFocus()
    }
    .task(id: projectPath) {
      guard let path = projectPath else { return }
      await fileIndex.loadIfNeeded(path)
    }
    .onChange(of: message) { _, newValue in
      ComposerDraftStore.save(newValue, for: draftStorageKey)
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
    }
    .onChange(of: codexModelOptionsSignature) { _, _ in
      guard obs.isDirectCodex else { return }
      if selectedModel.isEmpty || !codexModelOptions.contains(where: { $0.model == selectedModel }) {
        selectedModel = defaultCodexModelSelection
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
      text: $message,
      placeholder: composerPlaceholder,
      focusRequestSignal: $inputState.focus.focusRequestSignal,
      blurRequestSignal: $inputState.focus.blurRequestSignal,
      moveCursorToEndSignal: $inputState.focus.moveCursorToEndSignal,
      measuredHeight: $inputState.focus.measuredHeight,
      isEnabled: !isSending && !isDictationActive,
      minLines: 2,
      maxLines: 4,
      onPasteImage: { pasteImageFromClipboard() },
      canPasteImage: { canPasteImageFromClipboard },
      onKeyCommand: handleComposerTextAreaKeyCommand,
      onFocusEvent: handleComposerFocusEvent
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: inputState.focus.measuredHeight)
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
      AttachmentBar(images: attachedImagesBinding, mentions: attachedMentionsBinding)
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
    Task { try? await serverState.sendMessage(sessionId: sessionId, content: suggestion) }
  }

  // MARK: - Composer Surface

  var hasStatusBarContent: Bool {
    DirectSessionComposerProviderPlanner.hasStatusBarContent(
      isConnected: isConnected,
      isDirectCodex: obs.isDirectCodex,
      isDirectClaude: obs.isDirectClaude,
      isSessionWorking: isSessionWorking,
      hasTokenUsage: obs.hasTokenUsage,
      selectedCodexModel: selectedModel,
      effectiveClaudeModel: effectiveClaudeModel,
      branch: obs.branch,
      projectPath: obs.projectPath
    )
  }

  var composerSurface: some View {
    VStack(spacing: 0) {
      composerSurfaceTopSections

      // Text input
      composerTextInput
        .padding(.horizontal, Spacing.md_)
        .padding(.top, pendingApprovalModel != nil ? Spacing.xs : Spacing.sm)
        .padding(.bottom, Spacing.xs)

      // Unified footer: actions + metadata + send
      composerFooter

      composerSurfaceBottomSections
    }
    .background(composerSurfaceBackground)
    .overlay(composerSurfaceBorder)
    .overlay(composerDropTargetOverlay)
    .animation(Motion.gentle, value: inputMode)
    .animation(Motion.standard, value: pendingApprovalIdentity)
    .animation(Motion.standard, value: pendingState.isExpanded)
    .animation(Motion.standard, value: permissionPanelExpanded)
    .animation(Motion.hover, value: inputState.focus.isFocused)
    .animation(Motion.standard, value: attachmentState.isImageDropTargeted)
    .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  @ViewBuilder
  var composerSurfaceTopSections: some View {
    if permissionPanelExpanded, obs.isDirect {
      PermissionInlinePanel(
        sessionId: sessionId,
        isExpanded: $permissionPanelExpanded
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

  var composerSurfaceBackground: some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .fill(
        isCompactLayout
          ? composerBorderColor.opacity(0.04)
          : Color.backgroundTertiary.opacity(0.17)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .fill(composerBorderColor.opacity(OpacityTier.tint))
      )
  }

  var composerSurfaceBorder: some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .strokeBorder(
        inputState.focus.isFocused || inputMode != .prompt
          ? composerBorderColor.opacity(0.5)
          : Color.surfaceBorder.opacity(isCompactLayout ? 0.35 : (canSend ? 0.34 : 0.18)),
        lineWidth: inputState.focus.isFocused || inputMode != .prompt ? 1.5 : 1
      )
  }

  // MARK: - Resume Row (ended session)

  var resumeRow: some View {
    DirectSessionComposerResumeRow(
      lastActivityAt: obs.lastActivityAt,
      onResume: {
        connLog(.info, category: .resume, "Resume button tapped", sessionId: sessionId)
        Task { try? await serverState.resumeSession(sessionId) }
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
  @Previewable @State var pinned = true
  @Previewable @State var unread = 0
  @Previewable @State var scroll = 0
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  let sessionStore = SessionStore()
  let router = AppRouter()
  DirectSessionComposer(
    sessionId: "test-session",
    selectedSkills: $skills,
    isPinned: $pinned,
    unreadCount: $unread,
    scrollToBottomTrigger: $scroll
  )
  .environment(sessionStore)
  .environment(runtimeRegistry)
  .environment(router)
  .frame(width: 600)
}
