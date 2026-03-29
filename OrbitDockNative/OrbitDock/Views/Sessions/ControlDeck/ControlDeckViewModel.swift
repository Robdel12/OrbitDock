import Foundation

@MainActor
@Observable
final class ControlDeckViewModel {
  // MARK: - Deck-native state (no Server* types)

  private(set) var snapshot: ControlDeckSnapshot?
  private(set) var presentation: ControlDeckPresentation?
  private(set) var pendingApproval: ControlDeckApproval?
  private(set) var skills: [ControlDeckSkill] = []
  private(set) var isLoading = false
  var lastError: String?

  // MARK: - Binding

  @ObservationIgnored private var currentSessionId: String?
  @ObservationIgnored private var currentSessionStore: SessionStore?

  func bind(sessionId: String, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
  }

  // MARK: - Bootstrap

  func refresh() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }

    isLoading = true
    lastError = nil

    do {
      let serverSnapshot = try await store.fetchControlDeckSnapshot(sessionId: sessionId)
      applySnapshotPayload(serverSnapshot)
      await loadCodexModelsIfNeeded(for: serverSnapshot.state.provider)
    } catch {
      lastError = String(describing: error)
    }

    isLoading = false
  }

  // MARK: - Skills

  func loadSkills() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await store.listSkills(sessionId: sessionId)
      let serverSkills = store.session(sessionId).skills
      skills = serverSkills.filter(\.enabled).map(ControlDeckSnapshotMapper.mapSkill)
    } catch {
      lastError = String(describing: error)
    }
  }

  // MARK: - Submit / Steer

  func submitTurn(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) async throws {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }

    let request = ControlDeckSubmitEncoder.encode(
      draft: draft,
      uploadedImageIds: uploadedImageIds,
      availableSkills: skills
    )

    try await store.submitControlDeckTurn(sessionId: sessionId, request: request)
  }

  func steerTurn(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) async throws {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    try await store.steerTurn(
      sessionId: sessionId,
      content: draft.trimmedText,
      images: ControlDeckSubmitEncoder.encodeSteerImages(
        draft.attachments,
        uploadedImageIds: uploadedImageIds
      ),
      mentions: ControlDeckSubmitEncoder.encodeSteerMentions(draft.attachments)
    )
  }

  func interruptSession() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await store.interruptSession(sessionId)
    } catch {
      lastError = String(describing: error)
    }
  }

  // MARK: - Image Upload

  /// Uploads an image and returns the server attachment ID (ServerImageInput.value).
  func uploadImage(
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int?,
    pixelHeight: Int?
  ) async throws -> String {
    guard let sessionId = currentSessionId, let store = currentSessionStore else {
      throw ControlDeckError.notBound
    }

    let result = try await store.clients.controlDeck.uploadImageAttachment(
      sessionId: sessionId,
      data: data,
      mimeType: mimeType,
      displayName: displayName,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    return result.attachmentId
  }

  // MARK: - Preferences

  func updatePreferences(_ preferences: ControlDeckPreferences) async throws {
    guard let store = currentSessionStore else { return }

    let serverPrefs = ControlDeckPreferencesEncoder.encode(preferences)
    let updated = try await store.updateControlDeckPreferences(serverPrefs)

    if var current = snapshot {
      current = ControlDeckSnapshot(
        revision: current.revision,
        sessionId: current.sessionId,
        state: current.state,
        capabilities: current.capabilities,
        preferences: ControlDeckSnapshotMapper.mapPreferences(updated),
        tokenUsage: current.tokenUsage,
        tokenUsageSnapshotKind: current.tokenUsageSnapshotKind,
        tokenStatus: current.tokenStatus
      )
      snapshot = current
      presentation = ControlDeckPresentationBuilder.build(
        snapshot: current,
        isLoading: false,
        hasPendingApproval: pendingApproval != nil,
        availableModels: availableModels
      )
    }
  }

  // MARK: - Approval Sync

  /// Call from a task that observes session changes to keep approval in sync.
  func syncApproval() {
    guard let sessionId = currentSessionId, let store = currentSessionStore else {
      pendingApproval = nil
      return
    }
    let session = store.session(sessionId)
    if let serverApproval = session.pendingApproval {
      pendingApproval = ControlDeckSnapshotMapper.mapApproval(serverApproval)
    } else {
      pendingApproval = nil
    }

    // Sync live session flags into the snapshot so mode resolves correctly
    if let snap = snapshot {
      let resolvedProjectPath = session.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
      let projectPath = resolvedProjectPath.isEmpty ? snap.state.projectPath : resolvedProjectPath
      let currentCwd = nonEmpty(session.currentCwd) ?? snap.state.currentCwd
      let gitBranch = nonEmpty(session.branch) ?? snap.state.gitBranch

      let updatedState = ControlDeckSessionState(
        provider: snap.state.provider,
        controlMode: snap.state.controlMode,
        lifecycle: snap.state.lifecycle,
        acceptsUserInput: session.acceptsUserInput,
        steerable: session.steerable,
        projectPath: projectPath,
        currentCwd: currentCwd,
        gitBranch: gitBranch,
        config: snap.state.config
      )
      let updatedSnap = ControlDeckSnapshot(
        revision: snap.revision,
        sessionId: snap.sessionId,
        state: updatedState,
        capabilities: snap.capabilities,
        preferences: snap.preferences,
        tokenUsage: snap.tokenUsage,
        tokenUsageSnapshotKind: snap.tokenUsageSnapshotKind,
        tokenStatus: snap.tokenStatus
      )
      snapshot = updatedSnap
      presentation = ControlDeckPresentationBuilder.build(
        snapshot: updatedSnap,
        isLoading: false,
        hasPendingApproval: pendingApproval != nil,
        availableModels: availableModels
      )
    }
  }

  // MARK: - Approval Actions

  func approveTool(decision: ApprovalsClient.ToolApprovalDecision, message: String? = nil) async {
    guard let sessionId = currentSessionId,
          let store = currentSessionStore,
          let requestId = pendingApproval?.requestId else { return }
    do {
      _ = try await store.approveTool(
        sessionId: sessionId,
        requestId: requestId,
        decision: decision,
        message: message
      )
      syncApproval()
    } catch {
      lastError = String(describing: error)
    }
  }

  func answerQuestion(answer: String, questionId: String? = nil) async {
    guard let sessionId = currentSessionId,
          let store = currentSessionStore,
          let requestId = pendingApproval?.requestId else { return }
    do {
      _ = try await store.answerQuestion(
        sessionId: sessionId,
        requestId: requestId,
        answer: answer,
        questionId: questionId
      )
      syncApproval()
    } catch {
      lastError = String(describing: error)
    }
  }

  func respondToPermission(grant: Bool, scope: ServerPermissionGrantScope = .turn) async {
    guard let sessionId = currentSessionId,
          let store = currentSessionStore,
          let requestId = pendingApproval?.requestId else { return }
    do {
      _ = try await store.respondToPermissionRequest(
        sessionId: sessionId,
        requestId: requestId,
        scope: scope,
        grantRequestedPermissions: grant
      )
      syncApproval()
    } catch {
      lastError = String(describing: error)
    }
  }

  // MARK: - Session Config Mutations

  func updateModel(_ model: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      var request = ServerControlDeckConfigUpdateRequest()
      request.model = model
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      applySnapshotPayload(updated)
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateEffort(_ effort: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      var request = ServerControlDeckConfigUpdateRequest()
      request.effort = effort
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      applySnapshotPayload(updated)
    } catch {
      lastError = String(describing: error)
    }
  }

  func updatePermissionMode(_ mode: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      var request = ServerControlDeckConfigUpdateRequest()
      request.permissionMode = mode
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      applySnapshotPayload(updated)
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateApprovalPolicy(_ policy: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      var request = ServerControlDeckConfigUpdateRequest()
      request.approvalPolicy = policy
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      applySnapshotPayload(updated)
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateCollaborationMode(_ mode: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      var request = ServerControlDeckConfigUpdateRequest()
      request.collaborationMode = mode
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      applySnapshotPayload(updated)
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateAutoReview(_ value: String) async {
    guard let sessionId = currentSessionId,
          let store = currentSessionStore,
          let option = snapshot?.capabilities.autoReviewOptions.first(where: { $0.value == value })
    else { return }
    do {
      var request = ServerControlDeckConfigUpdateRequest()
      request.approvalPolicy = option.approvalPolicy
      request.sandboxMode = option.sandboxMode
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      applySnapshotPayload(updated)
    } catch {
      lastError = String(describing: error)
    }
  }

  // MARK: - Forwarded Infrastructure

  var projectFileIndex: ProjectFileIndex? {
    currentSessionStore?.projectFileIndex
  }

  var projectPath: String? {
    snapshot?.state.projectPath
  }

  var canSubmit: Bool {
    snapshot?.state.acceptsUserInput ?? false
  }

  var availableModels: [String] {
    guard let store = currentSessionStore, let snap = snapshot else { return [] }
    switch snap.state.provider {
      case .claude:
        return ServerClaudeModelOption.defaults.map(\.value)
      case .codex:
        return store.codexModels.map(\.model)
    }
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private func applySnapshotPayload(_ payload: ServerControlDeckSnapshotPayload) {
    lastError = nil
    snapshot = ControlDeckSnapshotMapper.map(payload)
    syncApproval()
  }

  private func loadCodexModelsIfNeeded(for provider: ServerProvider) async {
    guard provider == .codex, let store = currentSessionStore else { return }
    guard store.codexModels.isEmpty else {
      rebuildPresentation()
      return
    }

    if let models = try? await store.clients.usage.listCodexModels() {
      store.codexModels = models
    }

    rebuildPresentation()
  }

  private func rebuildPresentation() {
    guard let snapshot else {
      presentation = nil
      return
    }

    presentation = ControlDeckPresentationBuilder.build(
      snapshot: snapshot,
      isLoading: isLoading,
      hasPendingApproval: pendingApproval != nil,
      availableModels: availableModels
    )
  }
}

// MARK: - Errors

enum ControlDeckError: Error {
  case notBound
}
