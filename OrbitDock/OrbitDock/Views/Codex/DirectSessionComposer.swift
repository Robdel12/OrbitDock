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
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int
  var onOpenSkills: (() -> Void)?

  @Environment(ServerAppState.self) var serverState
  @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @AppStorage("whisperDictationEnabled") var whisperDictationEnabled = true

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
  @State var commandDeckActive = false
  @State var commandDeckQuery = ""
  @State var commandDeckIndex = 0
  @State var completionActive = false
  @State var completionQuery = ""
  @State var completionIndex = 0
  @State var isFocused = false
  @State var moveCursorToEndSignal = 0
  @State var composerInputHeight: CGFloat = 30

  /// Attachments
  @State var attachedImages: [AttachedImage] = []
  @State var attachedMentions: [AttachedMention] = []
  @State var mentionActive = false
  @State var mentionQuery = ""
  @State var mentionIndex = 0
  #if os(iOS)
    @State var photoPickerItems: [PhotosPickerItem] = []
    @State var isPhotoPickerPresented = false
    @State var photoPickerLoadTask: Task<Void, Never>?
  #endif

  /// Input mode
  @State var manualReviewMode = false
  @State var manualShellMode = false
  @State var dictationController = WhisperDictationController()
  @State var dictationDraftBaseMessage: String?
  @State var showForkToWorktreeSheet = false
  @State var showForkToExistingWorktreeSheet = false
  @State var pendingPanelExpanded = true
  @State var pendingPanelPromptIndex = 0
  @State var pendingPanelAnswers: [String: [String]] = [:]
  @State var pendingPanelDrafts: [String: String] = [:]
  @State var pendingPanelShowDenyReason = false
  @State var pendingPanelDenyReason = ""
  @State var pendingPanelMeasuredContentHeight: CGFloat = 0
  @State var pendingPanelHovering = false
  @State var permissionPanelExpanded = false
  @State var hoveringSuggestion: String?

  var obs: SessionObservable {
    serverState.session(sessionId)
  }

  var sessionSummary: Session? {
    serverState.sessions.first(where: { $0.id == sessionId })
  }

  var pendingApprovalModel: ApprovalCardModel? {
    guard let summary = sessionSummary else { return nil }
    let pendingApproval = obs.pendingApproval
    return ApprovalCardModelBuilder.build(
      session: summary,
      pendingApproval: pendingApproval,
      approvalHistory: obs.approvalHistory,
      transcriptMessages: obs.messages
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
    runtimeRegistry.connectionStatusByEndpointId[serverState.endpointId] ?? serverState.connection.status
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
    if obs.isDirectCodex {
      return selectedEffort != .default || selectedModel != defaultCodexModelSelection
    }
    if obs.isDirectClaude {
      return !selectedClaudeModel.isEmpty && selectedClaudeModel != defaultClaudeModelSelection
    }
    return false
  }

  var availableSkills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter(\.enabled)
  }

  var filteredSkills: [ServerSkillMetadata] {
    guard !completionQuery.isEmpty else { return availableSkills }
    let q = completionQuery.lowercased()
    return availableSkills.filter { $0.name.lowercased().contains(q) }
  }

  var shouldShowCompletion: Bool {
    completionActive && !filteredSkills.isEmpty
  }

  var hasInlineSkills: Bool {
    let names = Set(availableSkills.map(\.name))
    return message.components(separatedBy: .whitespacesAndNewlines).contains { word in
      word.hasPrefix("$") && names.contains(String(word.dropFirst()))
    }
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
    if let current = obs.model,
       codexModelOptions.contains(where: { $0.model == current })
    {
      return current
    }
    if let model = codexModelOptions.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return codexModelOptions.first(where: { !$0.model.isEmpty })?.model ?? ""
  }

  var defaultClaudeModelSelection: String {
    if let current = obs.model,
       claudeModelOptions.contains(where: { $0.value == current })
    {
      return current
    }
    return claudeModelOptions.first?.value ?? obs.model ?? ""
  }

  var effectiveClaudeModel: String {
    if !selectedClaudeModel.isEmpty {
      return selectedClaudeModel
    }
    if let sessionModel = obs.model, !sessionModel.isEmpty {
      return sessionModel
    }
    return defaultClaudeModelSelection
  }

  var projectPath: String? {
    obs.projectPath
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
    return fileIndex.search(mentionQuery, in: path)
  }

  var shouldShowMentionCompletion: Bool {
    mentionActive && !filteredFiles.isEmpty
  }

  var shouldShowCommandDeck: Bool {
    commandDeckActive && !commandDeckItems.isEmpty
  }

  var hasSkillsPanel: Bool {
    obs.isDirectCodex || serverState.session(sessionId).hasClaudeSkills
  }

  var hasMcpData: Bool {
    serverState.session(sessionId).hasMcpData
  }

  var mcpToolEntries: [ComposerMcpToolEntry] {
    serverState.session(sessionId).mcpTools.compactMap { key, tool in
      guard let server = extractMcpServerName(from: key) else { return nil }
      return ComposerMcpToolEntry(id: key, server: server, tool: tool)
    }
    .sorted {
      if $0.server == $1.server {
        return $0.tool.name < $1.tool.name
      }
      return $0.server < $1.server
    }
  }

  var mcpResourceEntries: [ComposerMcpResourceEntry] {
    serverState.session(sessionId).mcpResources.flatMap { server, resources in
      resources.map { resource in
        ComposerMcpResourceEntry(id: "\(server)|\(resource.uri)", server: server, resource: resource)
      }
    }
    .sorted {
      if $0.server == $1.server {
        return $0.resource.uri < $1.resource.uri
      }
      return $0.server < $1.server
    }
  }

  var commandDeckItems: [ComposerCommandDeckItem] {
    let trimmedQuery = commandDeckQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = trimmedQuery.lowercased()

    func matches(_ values: [String]) -> Bool {
      guard !query.isEmpty else { return true }
      return values.contains { $0.lowercased().contains(query) }
    }

    var items: [ComposerCommandDeckItem] = []

    if matches(["file", "files", "mention", "attach", "project"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:file-picker",
        section: "Actions",
        icon: "paperclip",
        title: "Attach Project Files",
        subtitle: "Browse project files and add @mentions",
        tint: .composerPrompt,
        kind: .openFilePicker
      ))
    }

    if hasSkillsPanel, matches(["skill", "skills", "agent", "attach"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:skills",
        section: "Actions",
        icon: "bolt.fill",
        title: "Attach Skills",
        subtitle: "Pick enabled skills for this turn",
        tint: .toolSkill,
        kind: .openSkillsPanel
      ))
    }

    if matches(["shell", "terminal", "command", "run"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:shell-mode",
        section: "Actions",
        icon: "terminal",
        title: manualShellMode ? "Disable Shell Mode" : "Enable Shell Mode",
        subtitle: "Switch composer into command execution mode",
        tint: .shellAccent,
        kind: .toggleShellMode
      ))
      items.append(ComposerCommandDeckItem(
        id: "action:shell-prefix",
        section: "Actions",
        icon: "exclamationmark.bubble",
        title: "Insert ! Shell Prefix",
        subtitle: "Type !<command> to run shell directly",
        tint: .shellAccent,
        kind: .insertText("!")
      ))
    }

    if hasMcpData, matches(["mcp", "server", "tools", "refresh"]) {
      items.append(ComposerCommandDeckItem(
        id: "action:mcp-refresh",
        section: "Actions",
        icon: "arrow.clockwise",
        title: "Refresh MCP Servers",
        subtitle: "Reload MCP tools and auth status",
        tint: .toolMcp,
        kind: .refreshMcp
      ))
    }

    if let path = projectPath {
      let files = if query.isEmpty {
        Array(fileIndex.files(for: path).prefix(7))
      } else {
        Array(fileIndex.search(query, in: path).prefix(9))
      }
      for file in files {
        items.append(ComposerCommandDeckItem(
          id: "file:\(file.id)",
          section: "Files",
          icon: "doc.text",
          title: file.name,
          subtitle: file.relativePath,
          tint: .composerPrompt,
          kind: .attachFile(file)
        ))
      }
    }

    let matchingSkills = availableSkills.filter { skill in
      query.isEmpty || matches([skill.name, skill.shortDescription ?? "", skill.description])
    }
    for skill in matchingSkills.prefix(8) {
      items.append(ComposerCommandDeckItem(
        id: "skill:\(skill.path)",
        section: "Skills",
        icon: "bolt.fill",
        title: "$\(skill.name)",
        subtitle: skill.shortDescription ?? skill.description,
        tint: .toolSkill,
        kind: .attachSkill(skill)
      ))
    }

    for entry in mcpToolEntries where query.isEmpty || matches([
      entry.server,
      entry.tool.name,
      entry.tool.title ?? "",
      entry.tool.description ?? "",
    ]) {
      items.append(ComposerCommandDeckItem(
        id: "mcp-tool:\(entry.id)",
        section: "MCP Tools",
        icon: "square.stack.3d.up.fill",
        title: "\(entry.server).\(entry.tool.name)",
        subtitle: entry.tool.description ?? "Insert MCP tool reference",
        tint: .toolMcp,
        kind: .insertMcpTool(server: entry.server, tool: entry.tool)
      ))
    }

    for entry in mcpResourceEntries where query.isEmpty || matches([
      entry.server,
      entry.resource.name,
      entry.resource.uri,
      entry.resource.description ?? "",
    ]) {
      items.append(ComposerCommandDeckItem(
        id: "mcp-resource:\(entry.id)",
        section: "MCP Resources",
        icon: "tray.full.fill",
        title: "\(entry.server): \(entry.resource.name)",
        subtitle: entry.resource.uri,
        tint: .toolMcp,
        kind: .insertMcpResource(server: entry.server, resource: entry.resource)
      ))
    }

    return items.prefix(18).map { $0 }
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
    !attachedImages.isEmpty || !attachedMentions.isEmpty
  }

  var isDictationActive: Bool {
    dictationController.state == .recording ||
      dictationController.state == .requestingPermission ||
      dictationController.state == .transcribing
  }

  var shouldShowDictation: Bool {
    whisperDictationEnabled && dictationController.isSupported
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
      // ━━━ Command Deck (/ trigger) ━━━
      if shouldShowCommandDeck {
        ComposerCommandDeckList(
          items: commandDeckItems,
          selectedIndex: commandDeckIndex,
          query: commandDeckQuery,
          onSelect: acceptCommandDeckItem
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Skill completion ($ trigger) ━━━
      if shouldShowCompletion, !shouldShowCommandDeck {
        SkillCompletionList(
          skills: filteredSkills,
          selectedIndex: completionIndex,
          query: completionQuery,
          onSelect: acceptSkillCompletion
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Mention completion (@ trigger) ━━━
      if shouldShowMentionCompletion, !shouldShowCommandDeck {
        MentionCompletionList(
          files: filteredFiles,
          selectedIndex: mentionIndex,
          query: mentionQuery,
          onSelect: acceptMentionCompletion
        )
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Attachment bar ━━━
      if hasAttachments {
        AttachmentBar(images: $attachedImages, mentions: $attachedMentions)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Prompt suggestion chips ━━━
      if !obs.promptSuggestions.isEmpty, isSessionActive, !isSessionWorking {
        promptSuggestionChips
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // ━━━ Rate limit banner ━━━
      if let rateLimitInfo = obs.rateLimitInfo, rateLimitInfo.needsDisplay {
        RateLimitBanner(info: rateLimitInfo)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

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
    .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
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
      if let path = projectPath {
        await fileIndex.loadIfNeeded(path)
      }
      if message.isEmpty, let restoredDraft = ComposerDraftStore.load(for: draftStorageKey) {
        message = restoredDraft
      }
      resetPendingPanelStateForRequest()
    }
    .onChange(of: message) { _, newValue in
      ComposerDraftStore.save(newValue, for: draftStorageKey)
    }
    .onChange(of: pendingApprovalIdentity) { _, _ in
      resetPendingPanelStateForRequest()
    }
    .onReceive(NotificationCenter.default.publisher(for: .openPendingActionPanel)) { notification in
      guard let requestedSessionId = notification.userInfo?["sessionId"] as? String else { return }
      guard requestedSessionId == sessionId else { return }
      withAnimation(Motion.standard) {
        pendingPanelExpanded = true
      }
      isPinned = true
      unreadCount = 0
      scrollToBottomTrigger += 1
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
    .onChange(of: whisperDictationEnabled) { _, enabled in
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
      isFocused: $isFocused,
      moveCursorToEndSignal: $moveCursorToEndSignal,
      measuredHeight: $composerInputHeight,
      isEnabled: !isSending,
      minLines: 2,
      maxLines: 4,
      onPasteImage: { pasteImageFromClipboard() },
      canPasteImage: { canPasteImageFromClipboard },
      onKeyCommand: handleComposerTextAreaKeyCommand
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: composerInputHeight)
    .layoutPriority(1)
    #if os(iOS)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { isFocused = false }
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

  // MARK: - Composer Row

  var promptSuggestionChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm) {
        ForEach(obs.promptSuggestions, id: \.self) { suggestion in
          let isHovered = hoveringSuggestion == suggestion
          Button {
            sendSuggestion(suggestion)
          } label: {
            Text(suggestion)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(isHovered ? Color.textPrimary : Color.textSecondary)
              .lineLimit(1)
              .padding(.horizontal, Spacing.md_)
              .padding(.vertical, Spacing.sm_)
              .background(
                RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
                  .fill(isHovered ? Color.surfaceHover : Color.backgroundTertiary.opacity(0.5))
              )
              .overlay(
                RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
                  .strokeBorder(
                    isHovered
                      ? Color.accent.opacity(OpacityTier.light)
                      : Color.surfaceBorder.opacity(OpacityTier.subtle),
                    lineWidth: 1
                  )
              )
              .animation(Motion.hover, value: isHovered)
          }
          .buttonStyle(.plain)
          .onHover { hovering in
            hoveringSuggestion = hovering ? suggestion : nil
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
    }
  }

  func sendSuggestion(_ suggestion: String) {
    guard let conn = runtimeRegistry.connection(for: serverState.endpointId) else { return }
    conn.sendMessage(sessionId: sessionId, content: suggestion)
  }

  // MARK: - Composer Surface

  var hasStatusBarContent: Bool {
    !isConnected
      || obs.isDirectCodex
      || obs.isDirectClaude
      || isSessionWorking
      || obs.hasTokenUsage
      || !selectedModel.isEmpty
      || !effectiveClaudeModel.isEmpty
      || obs.branch != nil
      || !obs.projectPath.isEmpty
  }

  var composerSurface: some View {
    VStack(spacing: 0) {
      // Permission summary panel (toggled from status bar pill)
      if permissionPanelExpanded, obs.isDirect {
        PermissionInlinePanel(
          sessionId: sessionId,
          isExpanded: $permissionPanelExpanded
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }

      // Inline approval zone (when pending)
      if let model = pendingApprovalModel {
        pendingInlineZone(model)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      // Text input
      composerTextInput
        .padding(.horizontal, Spacing.md_)
        .padding(.top, pendingApprovalModel != nil ? Spacing.xs : Spacing.sm)
        .padding(.bottom, Spacing.xs)

      // Unified footer: actions + metadata + send
      composerFooter

      // Internal status zone
      if hasStatusBarContent {
        Rectangle()
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .frame(height: 0.5)
          .padding(.horizontal, Spacing.sm)
        statusBar
      }

      // Connection notice (inside card)
      if let notice = connectionNoticeMessage {
        connectionNoticeRow(notice)
          .padding(.top, Spacing.xxs)
      }
    }
    .background(composerSurfaceBackground)
    .overlay(composerSurfaceBorder)
    .animation(Motion.gentle, value: inputMode)
    .animation(Motion.standard, value: pendingApprovalIdentity)
    .animation(Motion.standard, value: pendingPanelExpanded)
    .animation(Motion.standard, value: permissionPanelExpanded)
    .animation(Motion.hover, value: isFocused)
    .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
    .padding(.vertical, Spacing.sm)
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
        isFocused || inputMode != .prompt
          ? composerBorderColor.opacity(0.5)
          : Color.surfaceBorder.opacity(isCompactLayout ? 0.35 : (canSend ? 0.34 : 0.18)),
        lineWidth: isFocused || inputMode != .prompt ? 1.5 : 1
      )
  }

  // MARK: - Resume Row (ended session)

  var resumeRow: some View {
    HStack {
      Button {
        connLog(.info, category: .resume, "Resume button tapped", sessionId: sessionId)
        serverState.resumeSession(sessionId)
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "arrow.counterclockwise")
          Text("Resume")
        }
      }
      .buttonStyle(GhostButtonStyle(color: .accent))

      Spacer()

      if let lastActivity = obs.lastActivityAt {
        Text(lastActivity, style: .relative)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Error Row

  func errorRow(_ error: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.feedbackWarning)
      Text(error)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
      Spacer()
      if shouldShowOpenMicrophoneSettingsAction {
        Button("Open Settings") {
          _ = Platform.services.openMicrophonePrivacySettings()
        }
        .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
      }
      Button("Dismiss") {
        if errorMessage != nil {
          errorMessage = nil
        } else {
          dictationController.clearError()
        }
      }
      .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.sm)
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
  DirectSessionComposer(
    sessionId: "test-session",
    selectedSkills: $skills,
    isPinned: $pinned,
    unreadCount: $unread,
    scrollToBottomTrigger: $scroll
  )
  .environment(ServerAppState())
  .environment(ServerRuntimeRegistry.shared)
  .frame(width: 600)
}
