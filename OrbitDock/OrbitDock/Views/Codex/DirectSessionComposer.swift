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

  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @AppStorage("whisperDictationEnabled") private var whisperDictationEnabled = true

  @State private var message = ""
  @State private var isSending = false
  @State private var errorMessage: String?
  @State private var selectedModel: String = ""
  @State private var selectedClaudeModel: String = ""
  @State private var selectedEffort: EffortLevel = .default
  @State private var showModelEffortPopover = false
  @State private var showClaudeModelPopover = false
  @State private var showFilePickerPopover = false
  @State private var filePickerQuery = ""
  @State private var commandDeckActive = false
  @State private var commandDeckQuery = ""
  @State private var commandDeckIndex = 0
  @State private var completionActive = false
  @State private var completionQuery = ""
  @State private var completionIndex = 0
  @State private var isFocused = false
  @State private var composerInputHeight: CGFloat = 30

  /// Attachments
  // Internal visibility keeps image input logic split into platform extension files.
  @State var attachedImages: [AttachedImage] = []
  @State private var attachedMentions: [AttachedMention] = []
  @State private var mentionActive = false
  @State private var mentionQuery = ""
  @State private var mentionIndex = 0
  #if os(iOS)
    // Internal visibility keeps iOS picker handling in DirectSessionComposer+ImageIOS.swift.
    @State var photoPickerItems: [PhotosPickerItem] = []
    @State var isPhotoPickerPresented = false
    @State var photoPickerLoadTask: Task<Void, Never>?
  #endif

  /// Input mode
  @State private var manualReviewMode = false
  @State private var manualShellMode = false
  @State private var dictationController = WhisperDictationController()
  @State private var dictationDraftBaseMessage: String?
  @State private var showForkToWorktreeSheet = false
  @State private var showForkToExistingWorktreeSheet = false

  private var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var inputMode: InputMode {
    if manualShellMode { return .shell }
    if manualReviewMode { return .reviewNotes }
    if isSessionWorking { return .steer }
    return .prompt
  }

  private var composerBorderColor: Color {
    switch inputMode {
      case .steer: .composerSteer
      case .reviewNotes: .composerReview
      case .shell: .composerShell
      default: .composerPrompt
    }
  }

  private var isSessionWorking: Bool {
    obs.workStatus == .working
  }

  private var isSessionActive: Bool {
    obs.isActive
  }

  private var draftStorageKey: String {
    "endpoint:\(serverState.endpointId.uuidString)::session:\(sessionId)"
  }

  private var connectionStatus: ConnectionStatus {
    runtimeRegistry.connectionStatusByEndpointId[serverState.endpointId] ?? serverState.connection.status
  }

  private var isConnected: Bool {
    if case .connected = connectionStatus {
      return true
    }
    return false
  }

  private var connectionPillTint: Color {
    switch connectionStatus {
      case .connected:
        .statusSuccess
      case .connecting:
        .statusWaiting
      case .disconnected:
        .textQuaternary
      case .failed:
        .statusError
    }
  }

  private var connectionPillIcon: String {
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

  private var connectionPillLabel: String {
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

  private var connectionNoticeMessage: String? {
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

  private var showReconnectButton: Bool {
    switch connectionStatus {
      case .disconnected, .failed:
        true
      case .connecting, .connected:
        false
    }
  }

  private var hasOverrides: Bool {
    if obs.isDirectCodex {
      return selectedEffort != .default || selectedModel != defaultCodexModelSelection
    }
    if obs.isDirectClaude {
      return !selectedClaudeModel.isEmpty && selectedClaudeModel != defaultClaudeModelSelection
    }
    return false
  }

  private var availableSkills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter(\.enabled)
  }

  private var filteredSkills: [ServerSkillMetadata] {
    guard !completionQuery.isEmpty else { return availableSkills }
    let q = completionQuery.lowercased()
    return availableSkills.filter { $0.name.lowercased().contains(q) }
  }

  private var shouldShowCompletion: Bool {
    completionActive && !filteredSkills.isEmpty
  }

  private var hasInlineSkills: Bool {
    let names = Set(availableSkills.map(\.name))
    return message.components(separatedBy: .whitespacesAndNewlines).contains { word in
      word.hasPrefix("$") && names.contains(String(word.dropFirst()))
    }
  }

  private var codexModelOptions: [ServerCodexModelOption] {
    serverState.codexModels
  }

  private var codexModelOptionsSignature: String {
    codexModelOptions.map(\.model).joined(separator: "|")
  }

  private var claudeModelOptions: [ServerClaudeModelOption] {
    serverState.claudeModels
  }

  private var claudeModelOptionsSignature: String {
    claudeModelOptions.map(\.value).joined(separator: "|")
  }

  private var defaultCodexModelSelection: String {
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

  private var defaultClaudeModelSelection: String {
    if let current = obs.model,
       claudeModelOptions.contains(where: { $0.value == current })
    {
      return current
    }
    return claudeModelOptions.first?.value ?? obs.model ?? ""
  }

  private var effectiveClaudeModel: String {
    if !selectedClaudeModel.isEmpty {
      return selectedClaudeModel
    }
    if let sessionModel = obs.model, !sessionModel.isEmpty {
      return sessionModel
    }
    return defaultClaudeModelSelection
  }

  private var projectPath: String? {
    obs.projectPath
  }

  private var fileIndex: ProjectFileIndex {
    serverState.projectFileIndex
  }

  private var forkWorktreeDisplayRepoPath: String? {
    if let root = obs.repositoryRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
      return root
    }
    if !obs.projectPath.isEmpty {
      return obs.projectPath
    }
    return nil
  }

  private var forkToExistingCandidates: [ServerWorktreeSummary] {
    guard let repoPath = forkWorktreeDisplayRepoPath else { return [] }
    return serverState.worktrees(for: repoPath)
      .filter {
        $0.status != .removed && $0.diskPresent && $0.worktreePath != repoPath
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private var canForkConversation: Bool {
    !obs.forkInProgress
  }

  private var canForkToWorktree: Bool {
    forkWorktreeDisplayRepoPath != nil && canForkConversation
  }

  private var canForkToExistingWorktree: Bool {
    forkWorktreeDisplayRepoPath != nil && canForkConversation
  }

  private var filteredFiles: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    return fileIndex.search(mentionQuery, in: path)
  }

  private var shouldShowMentionCompletion: Bool {
    mentionActive && !filteredFiles.isEmpty
  }

  private var shouldShowCommandDeck: Bool {
    commandDeckActive && !commandDeckItems.isEmpty
  }

  private var hasSkillsPanel: Bool {
    obs.isDirectCodex || serverState.session(sessionId).hasClaudeSkills
  }

  private var hasMcpData: Bool {
    serverState.session(sessionId).hasMcpData
  }

  private var mcpToolEntries: [ComposerMcpToolEntry] {
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

  private var mcpResourceEntries: [ComposerMcpResourceEntry] {
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

  private var commandDeckItems: [ComposerCommandDeckItem] {
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

  private var filePickerResults: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    let trimmed = filePickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return Array(fileIndex.files(for: path).prefix(220))
    }
    return Array(fileIndex.search(trimmed, in: path).prefix(300))
  }

  private var hasAttachments: Bool {
    !attachedImages.isEmpty || !attachedMentions.isEmpty
  }

  private var isDictationActive: Bool {
    dictationController.state == .recording ||
      dictationController.state == .requestingPermission ||
      dictationController.state == .transcribing
  }

  private var shouldShowDictation: Bool {
    whisperDictationEnabled && dictationController.isSupported
  }

  private var composerErrorMessage: String? {
    errorMessage ?? dictationController.errorMessage
  }

  private var composerPlaceholder: String {
    if inputMode == .shell { return "Run a shell command..." }
    if isSessionWorking { return "Steer the current turn..." }
    return "Send a message..."
  }

  private var isCompactLayout: Bool {
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
        composerRow
        statusBar
        if let notice = connectionNoticeMessage {
          connectionNoticeRow(notice)
        }
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
    }
    .onChange(of: message) { _, newValue in
      ComposerDraftStore.save(newValue, for: draftStorageKey)
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

  // MARK: - Fork To Worktree

  @ViewBuilder
  private var forkToWorktreeSheet: some View {
    if let repoPath = forkWorktreeDisplayRepoPath {
      CreateWorktreeSheet(
        repoPath: repoPath,
        projectName: obs.projectName ?? URL(fileURLWithPath: repoPath).lastPathComponent,
        onCancel: {
          showForkToWorktreeSheet = false
        },
        onCreate: { branchName, baseBranch in
          serverState.forkSessionToWorktree(
            sessionId: sessionId,
            branchName: branchName,
            baseBranch: baseBranch
          )
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
  private var forkToExistingWorktreeSheet: some View {
    if forkWorktreeDisplayRepoPath != nil {
      VStack(spacing: 0) {
        HStack {
          Text("Fork to Existing Worktree")
            .font(.system(size: 13, weight: .semibold))
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)

        Divider()

        if forkToExistingCandidates.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: 24))
              .foregroundStyle(Color.textQuaternary)

            Text("No existing worktrees")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.textTertiary)

            Text("Create one first or refresh to discover tracked worktrees.")
              .font(.system(size: 11))
              .foregroundStyle(Color.textQuaternary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 24)
        } else {
          ScrollView {
            VStack(spacing: 2) {
              ForEach(forkToExistingCandidates) { wt in
                Button {
                  serverState.forkSessionToExistingWorktree(sessionId: sessionId, worktreeId: wt.id)
                  showForkToExistingWorktreeSheet = false
                } label: {
                  HStack(spacing: 8) {
                    Circle()
                      .fill(statusColor(for: wt.status))
                      .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 2) {
                      Text(wt.customName ?? wt.branch)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                      Text(wt.worktreePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                    }

                    Spacer()

                    if wt.activeSessionCount > 0 {
                      Text("\(wt.activeSessionCount)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.textQuaternary)
                    }
                  }
                  .padding(.horizontal, 8)
                  .padding(.vertical, 8)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(obs.forkInProgress)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
          }
          .frame(maxHeight: isCompactLayout ? .infinity : 320)
        }

        Divider()

        HStack {
          Button {
            refreshForkExistingWorktrees()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
              .font(.system(size: 11, weight: .medium))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.textSecondary)

          Spacer()

          Button("Cancel") {
            showForkToExistingWorktreeSheet = false
          }
          .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

  // MARK: - Token Progress Strip

  private var tokenStrip: some View {
    let pct = tokenContextPercentage
    let color: Color = pct > 0.9 ? .statusError : pct > 0.7 ? .statusReply : .accent

    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Rectangle().fill(color.opacity(OpacityTier.subtle))
        Rectangle()
          .fill(
            LinearGradient(
              colors: [color.opacity(0.7), color],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: geo.size.width * pct)
          .shadow(color: color.opacity(isCompactLayout ? 0.55 : 0.22), radius: isCompactLayout ? 4 : 1.5, y: 0)
      }
    }
    .frame(height: isCompactLayout ? 3 : 2)
    .clipShape(RoundedRectangle(cornerRadius: isCompactLayout ? 0 : 2, style: .continuous))
    .help(tokenTooltipText)
  }

  private var tokenContextPercentage: Double {
    obs.contextFillFraction
  }

  private var tokenTooltipText: String {
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

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.1fk", Double(count) / 1_000)
    }
    return "\(count)"
  }

  @ViewBuilder
  private var composerTextInput: some View {
    ComposerTextArea(
      text: $message,
      placeholder: composerPlaceholder,
      isFocused: $isFocused,
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

  private var promptSuggestionChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(obs.promptSuggestions, id: \.self) { suggestion in
          Button {
            sendSuggestion(suggestion)
          } label: {
            Text(suggestion)
              .font(.caption)
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(Color.backgroundSecondary)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  private func sendSuggestion(_ suggestion: String) {
    guard let conn = runtimeRegistry.connection(for: serverState.endpointId) else { return }
    conn.sendMessage(sessionId: sessionId, content: suggestion)
  }

  private var composerRow: some View {
    VStack(spacing: 0) {
      // Text input
      composerTextInput
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)

      // Unified footer: actions + metadata + send
      composerFooter
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(
          isCompactLayout
            ? composerBorderColor.opacity(0.04)
            : Color.backgroundTertiary.opacity(0.17)
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(
          isFocused || inputMode != .prompt
            ? composerBorderColor.opacity(0.5)
            : Color.surfaceBorder.opacity(isCompactLayout ? 0.35 : (canSend ? 0.34 : 0.18)),
          lineWidth: isFocused || inputMode != .prompt ? 1.5 : 1
        )
    )
    .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
    .padding(.vertical, isCompactLayout ? Spacing.sm : 8)
  }

  // MARK: - Status Bar (informational metadata below composer)

  @ViewBuilder
  private var statusBar: some View {
    if isCompactLayout {
      compactStatusBar
    } else {
      desktopStatusBar
    }
  }

  private var desktopStatusBar: some View {
    HStack(spacing: 8) {
      if !isConnected {
        connectionStatusPill
      }

      if obs.isDirectCodex {
        AutonomyPill(sessionId: sessionId, size: .statusBar)
      } else if obs.isDirectClaude {
        ClaudePermissionPill(sessionId: sessionId, size: .statusBar)
      }

      if isSessionWorking {
        workingSteerLabel
      }

      if obs.hasTokenUsage {
        footerTokenLabel
      }

      footerModelLabel

      if let branch = obs.branch, !branch.isEmpty {
        footerBranchLabel(branch)
      }

      if !obs.projectPath.isEmpty {
        statusBarCwdLabel(obs.projectPath)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.lg + 10)
    .padding(.top, 1)
    .padding(.bottom, 9)
  }

  private var compactStatusBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        if !isConnected {
          connectionStatusPill
        }

        if obs.isDirectCodex {
          AutonomyPill(sessionId: sessionId, size: .statusBar)
        } else if obs.isDirectClaude {
          ClaudePermissionPill(sessionId: sessionId, size: .statusBar)
        }

        if isSessionWorking {
          workingSteerLabel
        }

        if obs.hasTokenUsage {
          compactFooterTokenChip
        }

        footerModelLabel

        if let branch = obs.branch, !branch.isEmpty {
          footerBranchLabel(branch)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.md + Spacing.sm)
    }
    .scrollIndicators(.hidden)
  }

  private var connectionStatusPill: some View {
    HStack(spacing: 4) {
      Image(systemName: connectionPillIcon)
        .font(.system(size: 9, weight: .semibold))
      Text(connectionPillLabel)
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(connectionPillTint)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(connectionPillTint.opacity(OpacityTier.light), in: Capsule())
  }

  private func connectionNoticeRow(_ message: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: connectionPillIcon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(connectionPillTint)

      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      Spacer(minLength: 0)

      if showReconnectButton {
        Button("Reconnect") {
          runtimeRegistry.reconnect(endpointId: serverState.endpointId)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Color.accent)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.xs)
  }

  private func statusBarCwdLabel(_ cwd: String) -> some View {
    let display = (cwd as NSString).lastPathComponent
    return HStack(spacing: 2) {
      Image(systemName: "folder")
        .font(.system(size: 9, weight: .medium))
      Text(display)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
    .foregroundStyle(Color.textQuaternary)
    .help(cwd)
  }

  private var workingSteerLabel: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(Color.composerSteer)
        .frame(width: 6, height: 6)
      Text("Working - Steering enabled")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.composerSteer)
        .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      Color.composerSteer.opacity(OpacityTier.light),
      in: Capsule()
    )
    .help("Model is currently working. You can keep steering with full composer tools.")
  }

  // MARK: - Action Footer (actions + follow + send)

  @ViewBuilder
  private var composerFooter: some View {
    if isCompactLayout {
      compactComposerFooter
    } else {
      desktopComposerFooter
    }
  }

  private var desktopComposerFooter: some View {
    HStack(spacing: 4) {
      // Ghost action icons
      HStack(spacing: 2) {
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

        desktopWorkflowOverflowMenu

        if inputMode == .shell || inputMode == .reviewNotes {
          Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
      HStack(spacing: 6) {
        footerFollowControls
        composerSendButton
      }
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
  }

  private var compactComposerFooter: some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
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
        .padding(.trailing, 4)
      }
      .scrollIndicators(.hidden)

      // Pinned right: follow + send
      footerFollowControls
      composerSendButton
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.bottom, 8)
  }

  // MARK: - Footer Helpers

  private var footerTokenLabel: some View {
    let pct = Int(tokenContextPercentage * 100)
    let color: Color = pct > 90 ? .statusError : pct > 70 ? .statusReply : .accent
    let displayPct = if tokenContextPercentage > 0, pct == 0 { "< 1" } else { "\(pct)" }

    return HStack(spacing: 3) {
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
    .font(.system(size: 10, weight: .medium, design: .monospaced))
    .help(tokenTooltipText)
  }

  @ViewBuilder
  private var footerModelLabel: some View {
    if obs.isDirectCodex, !selectedModel.isEmpty {
      Text(shortModelName(selectedModel))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .help("Model: \(selectedModel)\nEffort: \(selectedEffort.displayName)")
    } else if obs.isDirectClaude, !effectiveClaudeModel.isEmpty {
      Text(shortModelName(effectiveClaudeModel))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
    }
  }

  private func footerBranchLabel(_ branch: String) -> some View {
    HStack(spacing: 2) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 9, weight: .medium))
      Text(branch)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
    .foregroundStyle(Color.gitBranch.opacity(0.65))
    .help(branch)
  }

  private var footerFollowControls: some View {
    HStack(spacing: 4) {
      if !isPinned, unreadCount > 0 {
        Button {
          isPinned = true
          unreadCount = 0
          scrollToBottomTrigger += 1
        } label: {
          Text("\(unreadCount)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
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
          .font(.system(size: isCompactLayout ? 13 : 11, weight: .semibold))
          .foregroundStyle(isPinned ? Color.textQuaternary : Color.statusReply)
          .frame(width: isCompactLayout ? 34 : 26, height: isCompactLayout ? 34 : 26)
          .background(
            isPinned ? Color.clear : Color.statusReply.opacity(OpacityTier.light),
            in: RoundedRectangle(cornerRadius: isCompactLayout ? Radius.md : Radius.sm, style: .continuous)
          )
      }
      .buttonStyle(.plain)
    }
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPinned)
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: unreadCount)
  }

  private var composerSendButton: some View {
    Button(action: sendMessage) {
      Group {
        if isSending {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: isSessionWorking ? "arrow.uturn.right" : "arrow.up")
            .font(.system(size: isCompactLayout ? TypeScale.subhead : 12, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: isCompactLayout ? 34 : 26, height: isCompactLayout ? 34 : 26)
      .background(
        Circle().fill(canSend ? composerBorderColor : Color.surfaceHover)
      )
      .shadow(color: canSend ? composerBorderColor.opacity(0.4) : .clear, radius: 6, y: 0)
    }
    .buttonStyle(.plain)
    .disabled(!canSend)
  }

  private var compactFooterTokenChip: some View {
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
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Color.surfaceHover.opacity(0.5), in: Capsule())
      .help(tokenTooltipText)
  }

  // MARK: - Composer Action Button

  private var modelEffortControlButton: some View {
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

  private var claudeModelControlButton: some View {
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
  private var providerModelControlButton: some View {
    if obs.isDirectCodex {
      modelEffortControlButton
    } else if obs.isDirectClaude {
      claudeModelControlButton
    }
  }

  private var fileMentionControlButton: some View {
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

  private var dictationControlButton: some View {
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

  private var commandDeckControlButton: some View {
    Button {
      toggleCommandDeck()
    } label: {
      ghostActionLabel(icon: "slash.circle", isActive: shouldShowCommandDeck)
    }
    .buttonStyle(.plain)
    .help("Command deck (/)")
  }

  @ViewBuilder
  private var imageAttachmentDockControl: some View {
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

  private var turnActionsDockMenu: some View {
    Menu {
      turnActionsMenuContent
    } label: {
      actionDockLabel(icon: "ellipsis.circle", title: "Turn", tint: Color.textTertiary)
    }
    .buttonStyle(.plain)
    .help("Turn actions")
  }

  @ViewBuilder
  private var turnActionsMenuContent: some View {
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

  private var compactWorkflowOverflowMenu: some View {
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
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accent, in: Capsule())
            .offset(x: 6, y: -5)
        }
      }
    }
    .buttonStyle(.plain)
    .help("More actions")
  }

  private var desktopWorkflowOverflowMenu: some View {
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
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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

  private func ghostActionLabel(
    icon: String,
    isActive: Bool = false,
    tint: Color = .accent
  ) -> some View {
    Image(systemName: icon)
      .font(.system(size: isCompactLayout ? 14 : 12, weight: isCompactLayout ? .semibold : .medium))
      .foregroundStyle(isActive ? tint : (isCompactLayout ? Color.textTertiary : Color.textQuaternary))
      .frame(width: isCompactLayout ? 34 : 26, height: isCompactLayout ? 34 : 26)
      .background(
        isCompactLayout
          ? (isActive ? tint.opacity(OpacityTier.light) : Color.surfaceHover.opacity(0.5))
          : (isActive ? tint.opacity(0.08) : Color.clear),
        in: RoundedRectangle(cornerRadius: isCompactLayout ? Radius.md : Radius.sm, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
  }

  private func actionDockLabel(
    icon: String,
    title: String,
    tint: Color,
    isActive: Bool = false
  ) -> some View {
    ghostActionLabel(icon: icon, isActive: isActive, tint: tint)
      .accessibilityLabel(title)
  }

  // MARK: - Resume Row (ended session)

  private var resumeRow: some View {
    HStack {
      Button {
        connLog(.info, category: .resume, "Resume button tapped", sessionId: sessionId)
        serverState.resumeSession(sessionId)
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: TypeScale.code, weight: .medium))
          Text("Resume")
            .font(.system(size: TypeScale.code, weight: .medium))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          Color.accent.opacity(OpacityTier.light),
          in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        )
        .foregroundStyle(Color.accent)
      }
      .buttonStyle(.plain)

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

  private func errorRow(_ error: String) -> some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(error)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if shouldShowOpenMicrophoneSettingsAction {
        Button("Open Settings") {
          _ = Platform.services.openMicrophonePrivacySettings()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Color.accent)
      }
      Button("Dismiss") {
        if errorMessage != nil {
          errorMessage = nil
        } else {
          dictationController.clearError()
        }
      }
      .buttonStyle(.plain)
      .font(.caption)
      .foregroundStyle(Color.accent)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.bottom, Spacing.sm)
  }

  private var shouldShowOpenMicrophoneSettingsAction: Bool {
    errorMessage == nil && dictationController.isMicrophonePermissionDenied
  }

  // MARK: - Helpers

  private func extractMcpServerName(from toolKey: String) -> String? {
    let parts = toolKey.split(separator: "__")
    if parts.count >= 2, parts[0] == "mcp" {
      return String(parts[1])
    }
    if parts.count >= 2 {
      return String(parts[0])
    }
    return nil
  }

  private func shortModelName(_ model: String) -> String {
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

  private var canSend: Bool {
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

  private func sendMessage() {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isSending else { return }
    guard !trimmed.isEmpty || hasAttachments else { return }

    // Shell mode: route to executeShell
    if inputMode == .shell {
      guard isConnected else {
        errorMessage = "Server is offline. Shell command not sent."
        return
      }
      serverState.executeShell(sessionId: sessionId, command: trimmed)
      message = ""
      manualShellMode = false
      return
    }

    // ! prefix: execute as shell command
    if trimmed.hasPrefix("!"), trimmed.count > 1 {
      guard isConnected else {
        errorMessage = "Server is offline. Shell command not sent."
        return
      }
      let shellCmd = String(trimmed.dropFirst())
      serverState.executeShell(sessionId: sessionId, command: shellCmd)
      message = ""
      return
    }

    var expandedContent = trimmed
    for mention in attachedMentions {
      expandedContent = expandedContent.replacingOccurrences(of: "@\(mention.name)", with: mention.path)
    }
    let mentionInputs = attachedMentions.map { ServerMentionInput(name: $0.name, path: $0.path) }
    let imageInputs = attachedImages.map(\.serverInput)

    if isSessionWorking {
      guard !expandedContent.isEmpty || !imageInputs.isEmpty || !mentionInputs.isEmpty else { return }
      let disposition = serverState.steerTurn(
        sessionId: sessionId,
        content: expandedContent,
        images: imageInputs,
        mentions: mentionInputs
      )

      switch disposition {
        case .sent:
          errorMessage = nil
          message = ""
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            attachedImages = []
            attachedMentions = []
          }
        case .queued:
          errorMessage = "Offline: steering message queued and will send after reconnect."
          message = ""
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            attachedImages = []
            attachedMentions = []
          }
        case .dropped:
          errorMessage = "Couldn't send steer message. Your draft is still here."
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

    let disposition = serverState.sendMessage(
      sessionId: sessionId,
      content: expandedContent,
      model: effectiveModel,
      effort: effort,
      skills: skillInputs,
      images: imageInputs,
      mentions: mentionInputs
    )

    switch disposition {
      case .sent:
        errorMessage = nil
        message = ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          attachedImages = []
          attachedMentions = []
        }
      case .queued:
        errorMessage = "Offline: message queued and will send after reconnect."
        message = ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          attachedImages = []
          attachedMentions = []
        }
      case .dropped:
        errorMessage = "Couldn't send message. Your draft is still here."
    }
  }

  private func openForkToWorktreeSheet() {
    guard canForkToWorktree else {
      errorMessage = "This session does not have a git repository root to create a worktree from."
      return
    }
    showForkToWorktreeSheet = true
  }

  private func openForkToExistingWorktreeSheet() {
    guard canForkToExistingWorktree else {
      errorMessage = "This session does not have a git repository root to select a worktree from."
      return
    }
    showForkToExistingWorktreeSheet = true
  }

  private func refreshForkExistingWorktrees() {
    guard let repoPath = forkWorktreeDisplayRepoPath else { return }
    serverState.connection.listWorktrees(repoRoot: repoPath)
  }

  private func statusColor(for status: ServerWorktreeStatus) -> Color {
    switch status {
      case .active: .statusSuccess
      case .orphaned: .statusReply
      case .stale: .statusWaiting
      case .removing: .textQuaternary
      case .removed: .textQuaternary
    }
  }

  @MainActor
  private func beginDictationDraftState() {
    dictationDraftBaseMessage = message
  }

  @MainActor
  private func clearDictationDraftState() {
    dictationDraftBaseMessage = nil
  }

  @MainActor
  private func updateDictationLivePreview(_ transcript: String) {
    guard let baseMessage = dictationDraftBaseMessage else { return }
    let normalized = DictationTextFormatter.normalizeTranscription(transcript)
    let merged = DictationTextFormatter.merge(existing: baseMessage, dictated: normalized)
    guard merged != message else { return }
    message = merged
  }

  @MainActor
  private func applyDictationPreviewToComposer(_ transcript: String) {
    guard let baseMessage = dictationDraftBaseMessage else { return }
    let normalized = DictationTextFormatter.normalizeTranscription(transcript)
    let merged = DictationTextFormatter.merge(existing: baseMessage, dictated: normalized)
    guard merged != message else { return }
    message = merged
  }

  @MainActor
  private func toggleDictation() {
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
      } else {
        beginDictationDraftState()
        await dictationController.start()
        if !dictationController.isRecording {
          clearDictationDraftState()
        }
      }
    }
  }

  // MARK: - Inline Skill Completion

  private func updateSkillCompletion(_ text: String) {
    guard let dollarIdx = text.lastIndex(of: "$") else {
      completionActive = false
      return
    }

    let afterDollar = text[text.index(after: dollarIdx)...]

    if afterDollar.contains(where: \.isWhitespace) {
      completionActive = false
      return
    }

    let query = String(afterDollar)

    if availableSkills.contains(where: { $0.name == query }) {
      completionActive = false
      return
    }

    if availableSkills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }

    completionQuery = query
    completionIndex = 0
    completionActive = true
  }

  private func acceptSkillCompletion(_ skill: ServerSkillMetadata) {
    if let dollarIdx = message.lastIndex(of: "$") {
      let prefix = String(message[..<dollarIdx])
      message = prefix + "$" + skill.name + " "
    }
    completionActive = false
    completionQuery = ""
    completionIndex = 0
    isFocused = true
  }

  private func extractInlineSkillNames(from text: String) -> [String] {
    let skillNameSet = Set(availableSkills.map(\.name))
    var names: [String] = []

    for word in text.components(separatedBy: .whitespacesAndNewlines) {
      guard word.hasPrefix("$") else { continue }
      let raw = String(word.dropFirst())
      let name = raw.trimmingCharacters(in: .punctuationCharacters)
      if skillNameSet.contains(name) {
        names.append(name)
      }
    }

    return names
  }

  // MARK: - @ Mention Completion

  private func updateMentionCompletion(_ text: String) {
    guard let atIdx = text.lastIndex(of: "@") else {
      mentionActive = false
      return
    }

    if atIdx != text.startIndex {
      let before = text[text.index(before: atIdx)]
      if !before.isWhitespace {
        mentionActive = false
        return
      }
    }

    let afterAt = text[text.index(after: atIdx)...]

    if afterAt.contains(where: \.isWhitespace) {
      mentionActive = false
      return
    }

    let query = String(afterAt)

    if attachedMentions.contains(where: { $0.name == query || $0.path.hasSuffix(query) }) {
      mentionActive = false
      return
    }

    mentionQuery = query
    mentionIndex = 0
    mentionActive = true

    loadProjectFilesIfNeeded()
  }

  private func acceptMentionCompletion(_ file: ProjectFileIndex.ProjectFile) {
    if let atIdx = message.lastIndex(of: "@") {
      let prefix = String(message[..<atIdx])
      message = prefix + "@" + file.name + " "
    }
    mentionActive = false
    mentionQuery = ""
    mentionIndex = 0
    isFocused = true

    addMentionAttachment(file)
  }

  private func addMentionAttachment(_ file: ProjectFileIndex.ProjectFile) {
    guard !attachedMentions.contains(where: { $0.id == file.id }) else { return }
    let absolutePath = if let base = projectPath {
      (base as NSString).appendingPathComponent(file.relativePath)
    } else {
      file.relativePath
    }
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      attachedMentions.append(AttachedMention(id: file.id, name: file.name, path: absolutePath))
    }
  }

  private func attachMentionFromPicker(_ file: ProjectFileIndex.ProjectFile) {
    replaceTrailingCommandDeckToken(with: "@\(file.name)")
    addMentionAttachment(file)
    showFilePickerPopover = false
    clearCommandDeckState()
    isFocused = true
  }

  private func openFilePicker() {
    guard projectPath != nil else {
      errorMessage = "No project path available for this session."
      return
    }
    filePickerQuery = ""
    loadProjectFilesIfNeeded()
    showFilePickerPopover = true
  }

  // MARK: - Command Deck

  private func isCommandDeckTokenStart(_ index: String.Index, in text: String) -> Bool {
    if index == text.startIndex {
      return true
    }
    return text[text.index(before: index)].isWhitespace
  }

  private func updateCommandDeckCompletion(_ text: String) {
    guard let slashIdx = text.lastIndex(of: "/") else {
      commandDeckActive = false
      commandDeckQuery = ""
      commandDeckIndex = 0
      return
    }

    guard isCommandDeckTokenStart(slashIdx, in: text) else {
      commandDeckActive = false
      return
    }

    let afterSlash = text[text.index(after: slashIdx)...]
    if afterSlash.contains(where: \.isWhitespace) {
      commandDeckActive = false
      return
    }

    commandDeckQuery = String(afterSlash)
    commandDeckIndex = 0
    commandDeckActive = true

    if hasSkillsPanel, availableSkills.isEmpty {
      serverState.listSkills(sessionId: sessionId)
    }
    if serverState.session(sessionId).mcpTools.isEmpty {
      serverState.listMcpTools(sessionId: sessionId)
    }
    loadProjectFilesIfNeeded()
  }

  private func loadProjectFilesIfNeeded() {
    guard let path = projectPath, !fileIndex.isReady(for: path) else { return }
    Task { @MainActor in
      await fileIndex.loadIfNeeded(path)
    }
  }

  private func toggleCommandDeck() {
    if shouldShowCommandDeck {
      clearCommandDeckState()
      removeTrailingCommandDeckToken()
      return
    }
    activateCommandDeck()
  }

  private func activateCommandDeck(prefill: String? = nil) {
    let token = "/" + (prefill ?? "")
    if let slashIdx = message.lastIndex(of: "/") {
      let afterSlash = message[message.index(after: slashIdx)...]
      if isCommandDeckTokenStart(slashIdx, in: message), !afterSlash.contains(where: \.isWhitespace) {
        let prefix = String(message[..<slashIdx])
        message = prefix + token
      } else if message.isEmpty || message.hasSuffix(" ") || message.hasSuffix("\n") {
        message += token
      } else {
        message += " " + token
      }
    } else if message.isEmpty || message.hasSuffix(" ") || message.hasSuffix("\n") {
      message += token
    } else {
      message += " " + token
    }
    updateCommandDeckCompletion(message)
    isFocused = true
  }

  private func clearCommandDeckState() {
    commandDeckActive = false
    commandDeckQuery = ""
    commandDeckIndex = 0
  }

  private func removeTrailingCommandDeckToken() {
    guard let slashIdx = message.lastIndex(of: "/") else { return }
    guard isCommandDeckTokenStart(slashIdx, in: message) else { return }
    let afterSlash = message[message.index(after: slashIdx)...]
    guard !afterSlash.contains(where: \.isWhitespace) else { return }
    message = String(message[..<slashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func replaceTrailingCommandDeckToken(with replacement: String, appendSpace: Bool = true) {
    guard let slashIdx = message.lastIndex(of: "/"),
          isCommandDeckTokenStart(slashIdx, in: message)
    else {
      if message.isEmpty {
        message = replacement + (appendSpace ? " " : "")
      } else {
        let spacer = message.hasSuffix(" ") || message.hasSuffix("\n") ? "" : " "
        message += spacer + replacement + (appendSpace ? " " : "")
      }
      return
    }
    let afterSlash = message[message.index(after: slashIdx)...]
    guard !afterSlash.contains(where: \.isWhitespace) else {
      let spacer = message.hasSuffix(" ") || message.hasSuffix("\n") ? "" : " "
      message += spacer + replacement + (appendSpace ? " " : "")
      return
    }

    let prefix = String(message[..<slashIdx])
    let suffix = appendSpace ? " " : ""
    message = prefix + replacement + suffix
  }

  private func acceptCommandDeckItem(_ item: ComposerCommandDeckItem) {
    switch item.kind {
      case .openFilePicker:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        openFilePicker()

      case .openSkillsPanel:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        if hasSkillsPanel {
          serverState.listSkills(sessionId: sessionId)
        }
        onOpenSkills?()

      case .toggleShellMode:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          manualShellMode.toggle()
          if manualShellMode { manualReviewMode = false }
        }

      case let .insertText(text):
        clearCommandDeckState()
        replaceTrailingCommandDeckToken(with: text, appendSpace: false)

      case .refreshMcp:
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        serverState.refreshMcpServers(sessionId: sessionId)

      case let .attachFile(file):
        clearCommandDeckState()
        attachMentionFromPicker(file)

      case let .attachSkill(skill):
        selectedSkills.insert(skill.path)
        clearCommandDeckState()
        replaceTrailingCommandDeckToken(with: "$\(skill.name)")

      case let .insertMcpTool(server, tool):
        clearCommandDeckState()
        let snippet = "Use MCP tool \(server).\(tool.name)"
        replaceTrailingCommandDeckToken(with: snippet)

      case let .insertMcpResource(server, resource):
        clearCommandDeckState()
        let snippet = "Use MCP resource \(server):\(resource.uri)"
        replaceTrailingCommandDeckToken(with: snippet)
    }
    isFocused = true
  }

  // MARK: - Keyboard Navigation

  private enum ComposerCompletionCommand {
    case escape
    case upArrow
    case downArrow
    case accept
    case controlN
    case controlP
  }

  private func handleComposerTextAreaKeyCommand(_ keyCommand: ComposerTextAreaKeyCommand) -> Bool {
    switch keyCommand {
      case .commandShiftT:
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          manualShellMode.toggle()
          if manualShellMode { manualReviewMode = false }
        }
        return true

      case .shiftReturn:
        message += "\n"
        return true

      case .escape:
        return handleCompletionCommand(.escape)

      case .upArrow:
        return handleCompletionCommand(.upArrow)

      case .downArrow:
        return handleCompletionCommand(.downArrow)

      case .tab:
        return handleCompletionCommand(.accept)

      case .controlN:
        return handleCompletionCommand(.controlN)

      case .controlP:
        return handleCompletionCommand(.controlP)

      case .returnKey:
        if handleCompletionCommand(.accept) {
          return true
        }
        let hasContent = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasContent || hasAttachments {
          sendMessage()
          return true
        }
        return false
    }
  }

  private func handleCompletionCommand(_ command: ComposerCompletionCommand) -> Bool {
    if command == .escape {
      if shouldShowCommandDeck {
        clearCommandDeckState()
        removeTrailingCommandDeckToken()
        return true
      }
      if mentionActive {
        mentionActive = false
        return true
      }
      guard completionActive else { return false }
      completionActive = false
      return true
    }

    if shouldShowCommandDeck {
      return handleCommandDeckCommand(command)
    }

    if shouldShowMentionCompletion {
      return handleMentionCommand(command)
    }

    guard shouldShowCompletion else { return false }

    switch command {
      case .upArrow:
        completionIndex = max(0, completionIndex - 1)
        return true
      case .downArrow:
        completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
        return true
      case .controlN:
        completionIndex = min(filteredSkills.count - 1, completionIndex + 1)
        return true
      case .controlP:
        completionIndex = max(0, completionIndex - 1)
        return true
      case .accept:
        acceptSkillCompletion(filteredSkills[completionIndex])
        return true
      case .escape:
        return false
    }
  }

  private func handleCommandDeckCommand(_ command: ComposerCompletionCommand) -> Bool {
    let maxIndex = commandDeckItems.count - 1
    guard maxIndex >= 0 else { return false }

    switch command {
      case .upArrow:
        commandDeckIndex = max(0, commandDeckIndex - 1)
        return true
      case .downArrow:
        commandDeckIndex = min(maxIndex, commandDeckIndex + 1)
        return true
      case .controlN:
        commandDeckIndex = min(maxIndex, commandDeckIndex + 1)
        return true
      case .controlP:
        commandDeckIndex = max(0, commandDeckIndex - 1)
        return true
      case .accept:
        if commandDeckIndex < commandDeckItems.count {
          acceptCommandDeckItem(commandDeckItems[commandDeckIndex])
        }
        return true
      case .escape:
        return false
    }
  }

  private func handleMentionCommand(_ command: ComposerCompletionCommand) -> Bool {
    let maxIndex = filteredFiles.count - 1
    guard maxIndex >= 0 else { return false }

    switch command {
      case .upArrow:
        mentionIndex = max(0, mentionIndex - 1)
        return true
      case .downArrow:
        mentionIndex = min(maxIndex, mentionIndex + 1)
        return true
      case .controlN:
        mentionIndex = min(maxIndex, mentionIndex + 1)
        return true
      case .controlP:
        mentionIndex = max(0, mentionIndex - 1)
        return true
      case .accept:
        if mentionIndex < filteredFiles.count {
          acceptMentionCompletion(filteredFiles[mentionIndex])
        }
        return true
      case .escape:
        return false
    }
  }

  // MARK: - Image Input

  // Implemented in DirectSessionComposer+ImageShared.swift and platform extensions.
}

// MARK: - Interrupt Button

struct CodexInterruptButton: View {
  let sessionId: String
  var isCompact: Bool = false
  @Environment(ServerAppState.self) private var serverState

  @State private var isInterrupting = false
  @State private var isHovering = false

  private var size: CGFloat {
    isCompact ? 34 : 26
  }

  var body: some View {
    Button(action: interrupt) {
      Group {
        if isInterrupting {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "stop.fill")
            .font(.system(size: isCompact ? 14 : 12, weight: .semibold))
        }
      }
      .foregroundStyle(Color.statusError)
      .frame(width: size, height: size)
      .background(
        Color.statusError.opacity(isHovering ? OpacityTier.medium : OpacityTier.light),
        in: RoundedRectangle(cornerRadius: isCompact ? Radius.md : Radius.sm, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .disabled(isInterrupting)
    .platformHover($isHovering)
    .animation(.easeOut(duration: 0.15), value: isHovering)
    .help("Stop")
    .onChange(of: workStatus) { _, newValue in
      if isInterrupting, newValue != .working {
        isInterrupting = false
      }
    }
  }

  private func interrupt() {
    isInterrupting = true
    serverState.interruptSession(sessionId)
  }

  private var workStatus: Session.WorkStatus {
    serverState.session(sessionId).workStatus
  }
}

// MARK: - Skill Completion List

private struct SkillCompletionList: View {
  let skills: [ServerSkillMetadata]
  let selectedIndex: Int
  let query: String
  let onSelect: (ServerSkillMetadata) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(skills.prefix(8).enumerated()), id: \.element.id) { index, skill in
            Button { onSelect(skill) } label: {
              HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                  .font(.caption2)
                  .foregroundStyle(Color.accent)
                  .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                  skillNameView(skill.name)
                  if let desc = skill.shortDescription ?? Optional(skill.description), !desc.isEmpty {
                    Text(desc)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer()
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(index == selectedIndex ? Color.accent.opacity(0.15) : Color.clear)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
      }
      .scrollIndicators(.hidden)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo(newIndex, anchor: .center)
      }
    }
    .frame(maxHeight: 200)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.3), radius: 8, y: -2)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func skillNameView(_ name: String) -> some View {
    if !query.isEmpty, let range = name.range(of: query, options: .caseInsensitive) {
      let before = String(name[name.startIndex ..< range.lowerBound])
      let match = String(name[range])
      let after = String(name[range.upperBound...])
      Text("\(Text(before))\(Text(match).foregroundStyle(Color.accent))\(Text(after))")
        .font(.callout.weight(.medium))
    } else {
      Text(name)
        .font(.callout.weight(.medium))
    }
  }
}

private struct ComposerMcpToolEntry: Identifiable {
  let id: String
  let server: String
  let tool: ServerMcpTool
}

private struct ComposerMcpResourceEntry: Identifiable {
  let id: String
  let server: String
  let resource: ServerMcpResource
}

private struct ComposerCommandDeckItem: Identifiable {
  enum Kind {
    case openFilePicker
    case openSkillsPanel
    case toggleShellMode
    case insertText(String)
    case refreshMcp
    case attachFile(ProjectFileIndex.ProjectFile)
    case attachSkill(ServerSkillMetadata)
    case insertMcpTool(server: String, tool: ServerMcpTool)
    case insertMcpResource(server: String, resource: ServerMcpResource)
  }

  let id: String
  let section: String
  let icon: String
  let title: String
  let subtitle: String?
  let tint: Color
  let kind: Kind
}

private struct ComposerCommandDeckList: View {
  let items: [ComposerCommandDeckItem]
  let selectedIndex: Int
  let query: String
  let onSelect: (ComposerCommandDeckItem) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index == 0 || items[index - 1].section != item.section {
              Text(item.section)
                .font(.system(size: TypeScale.caption, weight: .bold))
                .foregroundStyle(Color.textQuaternary)
                .padding(.horizontal, 10)
                .padding(.top, index == 0 ? 8 : 10)
                .padding(.bottom, 4)
            }

            Button {
              onSelect(item)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: item.icon)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(item.tint)
                  .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                  highlighted(item.title)
                    .font(.system(size: TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                  if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                      .font(.system(size: TypeScale.caption))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                  }
                }

                Spacer()
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                index == selectedIndex ? item.tint.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
      }
      .scrollIndicators(.hidden)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo(newIndex, anchor: .center)
      }
    }
    .frame(maxHeight: 290)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
    .shadow(color: .black.opacity(0.3), radius: 8, y: -2)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
    )
  }

  private func highlighted(_ text: String) -> Text {
    guard !query.isEmpty, let stringRange = text.range(of: query, options: .caseInsensitive) else {
      return Text(text)
    }
    var attributed = AttributedString(text)
    if let attributedRange = Range(stringRange, in: attributed) {
      attributed[attributedRange].foregroundColor = .accent
    }
    return Text(attributed)
  }
}

private struct ComposerFilePickerPopover: View {
  @Binding var query: String
  let files: [ProjectFileIndex.ProjectFile]
  let onSelect: (ProjectFileIndex.ProjectFile) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      TextField("Search files…", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.subhead))

      if files.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "doc.text.magnifyingglass")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
          Text("No files found")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
              Button {
                onSelect(file)
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: fileIcon(for: file.name))
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Color.composerPrompt)
                    .frame(width: 14)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                      .font(.system(size: TypeScale.subhead, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                    Text(file.relativePath)
                      .font(.system(size: TypeScale.caption, design: .monospaced))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                  }
                  Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(Spacing.md)
    .background(Color.backgroundSecondary)
  }

  private func fileIcon(for name: String) -> String {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    switch ext {
      case "swift": return "swift"
      case "rs": return "gearshape.2"
      case "js", "ts", "jsx", "tsx": return "curlybraces"
      case "py": return "chevron.left.forwardslash.chevron.right"
      case "sh", "bash", "zsh": return "terminal"
      case "json", "yaml", "yml", "toml": return "doc.text"
      case "md", "txt": return "doc.plaintext"
      case "html", "css": return "globe"
      default: return "doc"
    }
  }
}

private struct ComposerClaudeModelPopover: View {
  @Binding var selectedModel: String
  let models: [ServerClaudeModelOption]

  @State private var query = ""

  private var filteredModels: [ServerClaudeModelOption] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return models }
    let lower = trimmed.lowercased()
    return models.filter { option in
      option.displayName.lowercased().contains(lower) ||
        option.value.lowercased().contains(lower) ||
        option.description.lowercased().contains(lower)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      TextField("Search Claude models", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.subhead))

      if filteredModels.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "cpu")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
          Text("No Claude models available")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filteredModels) { model in
              let isSelected = model.value == selectedModel
              Button {
                selectedModel = model.value
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.providerClaude : Color.textQuaternary)
                    .frame(width: 14)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                      .font(.system(size: TypeScale.subhead, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                    Text(model.value)
                      .font(.system(size: TypeScale.caption, design: .monospaced))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                  }
                  Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                  isSelected ? Color.providerClaude.opacity(0.14) : Color.clear,
                  in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(Spacing.md)
    .background(Color.backgroundSecondary)
  }
}

private enum ComposerDraftStore {
  private static let keyPrefix = "orbitdock.direct-composer-draft"

  static func load(for key: String, defaults: UserDefaults = .standard) -> String? {
    let value = defaults.string(forKey: storageKey(for: key))
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static func save(_ value: String, for key: String, defaults: UserDefaults = .standard) {
    let storageKey = storageKey(for: key)
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      defaults.removeObject(forKey: storageKey)
      return
    }
    defaults.set(value, forKey: storageKey)
  }

  private static func storageKey(for key: String) -> String {
    "\(keyPrefix).\(key)"
  }
}

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
