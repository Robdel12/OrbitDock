import Foundation

@MainActor
@Observable
final class ControlDeckViewModel {
  private struct BindingContext {
    let sessionId: String
    let store: SessionStore
  }

  // MARK: - Deck-native state (no Server* types)

  private(set) var snapshot: ControlDeckSnapshot?
  private(set) var presentation: ControlDeckPresentation?
  private(set) var pendingApproval: ControlDeckApproval?
  private(set) var skills: [ControlDeckSkill] = []
  private(set) var isLoading = false
  private(set) var isResuming = false
  private(set) var controlMode: ControlDeckControlMode = .passive
  private(set) var lifecycle: ControlDeckLifecycle = .ended
  private(set) var acceptsUserInput = false
  private(set) var steerable = false
  var lastError: String?

  // MARK: - Binding

  @ObservationIgnored private var currentSessionId: String?
  @ObservationIgnored private var currentSessionStore: SessionStore?
  @ObservationIgnored private var lastLoggedSessionSignature: String?

  func bind(sessionId: String, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
  }

  // MARK: - Bootstrap

  func refresh() async {
    guard let binding = currentBindingContext else { return }
    let sessionId = binding.sessionId
    let store = binding.store
    print("[ResumeTrace] VM refresh start sid=\(sessionId)")
    netLog(.debug, cat: .store, "ControlDeck refresh started", sid: sessionId)

    isLoading = true
    lastError = nil
    defer {
      if isCurrent(binding) {
        isLoading = false
      }
    }

    do {
      let serverSnapshot = try await store.fetchControlDeckSnapshot(sessionId: sessionId)
      guard isCurrent(binding) else { return }
      applySnapshotPayload(serverSnapshot)
      await loadCodexModelsIfNeeded(for: serverSnapshot.state.provider, binding: binding)
      guard isCurrent(binding) else { return }
      print("[ResumeTrace] VM refresh finish sid=\(sessionId)")
      netLog(.debug, cat: .store, "ControlDeck refresh finished", sid: sessionId)
    } catch {
      guard isCurrent(binding) else { return }
      lastError = String(describing: error)
      print("[ResumeTrace] VM refresh failed sid=\(sessionId) error=\(String(describing: error))")
      netLog(.error, cat: .store, "ControlDeck refresh failed", sid: sessionId, data: [
        "error": String(describing: error),
      ])
    }
  }

  // MARK: - Skills

  func loadSkills() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      skills = try await fetchEnabledSkills(sessionId: sessionId, store: store)
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
    let availableSkills = try await resolveSkillsForSubmit(
      draft: draft,
      sessionId: sessionId,
      store: store
    )

    let request = ControlDeckSubmitEncoder.encode(
      draft: draft,
      uploadedImageIds: uploadedImageIds,
      availableSkills: availableSkills
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

  func resumeSession() async {
    guard let binding = currentBindingContext else { return }
    let sessionId = binding.sessionId
    let store = binding.store
    guard !isResuming else { return }
    isResuming = true
    print(
      "[ResumeTrace] VM resume start sid=\(sessionId) lifecycle=\(lifecycle.rawValue) control=\(controlMode.rawValue) accepts=\(acceptsUserInput) steerable=\(steerable)"
    )
    netLog(.info, cat: .store, "ControlDeck resume started", sid: sessionId, data: [
      "lifecycle": lifecycle.rawValue,
      "controlMode": controlMode.rawValue,
      "acceptsUserInput": acceptsUserInput,
      "steerable": steerable,
    ])
    defer {
      if isCurrent(binding) {
        isResuming = false
      }
    }
    do {
      try await store.resumeSession(sessionId)
      guard isCurrent(binding) else { return }
      syncApproval()
      print(
        "[ResumeTrace] VM resume sync sid=\(sessionId) lifecycle=\(lifecycle.rawValue) control=\(controlMode.rawValue) accepts=\(acceptsUserInput) steerable=\(steerable) mode=\(presentation?.mode.debugLabel ?? "nil")"
      )
      netLog(.info, cat: .store, "ControlDeck resume sync complete", sid: sessionId, data: [
        "lifecycle": lifecycle.rawValue,
        "controlMode": controlMode.rawValue,
        "acceptsUserInput": acceptsUserInput,
        "steerable": steerable,
        "mode": presentation?.mode.debugLabel ?? "nil",
      ])
      // Keep UI responsive: the resume response already contains enough state
      // to unlock the deck; fetch snapshot details in the background.
      Task { await refresh() }
    } catch {
      lastError = String(describing: error)
      print("[ResumeTrace] VM resume failed sid=\(sessionId) error=\(String(describing: error))")
      netLog(.error, cat: .store, "ControlDeck resume failed", sid: sessionId, data: [
        "error": String(describing: error),
      ])
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
    syncApproval(mergeSessionState: true)
  }

  func syncApproval(mergeSessionState: Bool) {
    guard let sessionId = currentSessionId, let store = currentSessionStore else {
      pendingApproval = nil
      controlMode = .passive
      lifecycle = .ended
      acceptsUserInput = false
      steerable = false
      return
    }
    let session = store.session(sessionId)
    controlMode = mapControlMode(session.controlMode)
    lifecycle = mapLifecycle(session.lifecycleState)
    acceptsUserInput = session.acceptsUserInput
    steerable = session.steerable

    if let serverApproval = session.pendingApproval {
      pendingApproval = ControlDeckSnapshotMapper.mapApproval(serverApproval)
    } else {
      pendingApproval = nil
    }

    if mergeSessionState, let snap = snapshot {
      let resolvedProjectPath = session.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
      let projectPath = resolvedProjectPath.isEmpty ? snap.state.projectPath : resolvedProjectPath
      let currentCwd = nonEmpty(session.currentCwd) ?? snap.state.currentCwd
      let gitBranch = nonEmpty(session.branch) ?? snap.state.gitBranch

      let updatedState = ControlDeckSessionState(
        provider: snap.state.provider,
        controlMode: controlMode,
        lifecycle: lifecycle,
        acceptsUserInput: acceptsUserInput,
        steerable: steerable,
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
    }

    rebuildPresentation()
    logSessionStateIfChanged(source: "syncApproval")
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

  private func updateConfig(
    sessionId: String,
    store: SessionStore,
    configure: (inout ServerControlDeckConfigUpdateRequest) -> Void
  ) async throws {
    var request = ServerControlDeckConfigUpdateRequest()
    configure(&request)
    let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
    applySnapshotPayload(updated)
  }

  func updateModel(_ model: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await updateConfig(sessionId: sessionId, store: store) { $0.model = model }
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateEffort(_ effort: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await updateConfig(sessionId: sessionId, store: store) { $0.effort = effort }
    } catch {
      lastError = String(describing: error)
    }
  }

  func updatePermissionMode(_ mode: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await updateConfig(sessionId: sessionId, store: store) { $0.permissionMode = mode }
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateApprovalPolicy(_ policy: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await updateConfig(sessionId: sessionId, store: store) { $0.approvalPolicy = policy }
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateApprovalsReviewer(_ reviewer: ServerCodexApprovalsReviewer) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await updateConfig(sessionId: sessionId, store: store) { $0.approvalsReviewer = reviewer }
    } catch {
      lastError = String(describing: error)
    }
  }

  func updateCollaborationMode(_ mode: String) async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    do {
      try await updateConfig(sessionId: sessionId, store: store) { $0.collaborationMode = mode }
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
      try await updateConfig(sessionId: sessionId, store: store) {
        $0.approvalPolicy = option.approvalPolicy
        $0.sandboxMode = option.sandboxMode
      }
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

  private func fetchEnabledSkills(sessionId: String, store: SessionStore) async throws -> [ControlDeckSkill] {
    try await store.listSkills(sessionId: sessionId)
    return store.session(sessionId).skills.filter(\.enabled).map(ControlDeckSnapshotMapper.mapSkill)
  }

  private func resolveSkillsForSubmit(
    draft: ControlDeckDraft,
    sessionId: String,
    store: SessionStore
  ) async throws -> [ControlDeckSkill] {
    if !skills.isEmpty {
      return skills
    }

    let requiresSkillResolution = draft.text.contains("$") || !draft.selectedSkillPaths.isEmpty
    guard requiresSkillResolution else { return [] }

    let fetched = try await fetchEnabledSkills(sessionId: sessionId, store: store)
    skills = fetched
    return fetched
  }

  private func applySnapshotPayload(_ payload: ServerControlDeckSnapshotPayload) {
    lastError = nil
    let mapped = ControlDeckSnapshotMapper.map(payload)
    snapshot = mapped
    controlMode = mapped.state.controlMode
    lifecycle = mapped.state.lifecycle
    acceptsUserInput = mapped.state.acceptsUserInput
    steerable = mapped.state.steerable
    syncApproval(mergeSessionState: false)
  }

  private func logSessionStateIfChanged(source: String) {
    let signature = [
      "source=\(source)",
      "lifecycle=\(lifecycle.rawValue)",
      "control=\(controlMode.rawValue)",
      "accepts=\(acceptsUserInput)",
      "steerable=\(steerable)",
      "approval=\(pendingApproval?.requestId ?? "-")",
      "mode=\(presentation?.mode.debugLabel ?? "nil")",
    ].joined(separator: "|")

    guard signature != lastLoggedSessionSignature else { return }
    lastLoggedSessionSignature = signature
    netLog(.debug, cat: .store, "ControlDeck session state updated", sid: currentSessionId, data: [
      "source": source,
      "lifecycle": lifecycle.rawValue,
      "controlMode": controlMode.rawValue,
      "acceptsUserInput": acceptsUserInput,
      "steerable": steerable,
      "pendingApprovalId": pendingApproval?.requestId ?? "",
      "presentationMode": presentation?.mode.debugLabel ?? "nil",
    ])
    if let sid = currentSessionId {
      print(
        "[ResumeTrace] VM state sid=\(sid) source=\(source) lifecycle=\(lifecycle.rawValue) control=\(controlMode.rawValue) accepts=\(acceptsUserInput) steerable=\(steerable) approval=\(pendingApproval?.requestId ?? "-") mode=\(presentation?.mode.debugLabel ?? "nil")"
      )
    }
  }

  private var currentBindingContext: BindingContext? {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return nil }
    return BindingContext(sessionId: sessionId, store: store)
  }

  private func isCurrent(_ binding: BindingContext) -> Bool {
    currentSessionId == binding.sessionId && currentSessionStore === binding.store
  }

  private func loadCodexModelsIfNeeded(for provider: ServerProvider, binding: BindingContext) async {
    guard provider == .codex else {
      if isCurrent(binding) {
        rebuildPresentation()
      }
      return
    }

    guard isCurrent(binding) else { return }
    let store = binding.store
    guard store.codexModels.isEmpty else {
      rebuildPresentation()
      return
    }

    if let models = try? await store.clients.usage.listCodexModels() {
      guard isCurrent(binding) else { return }
      store.codexModels = models
    }

    guard isCurrent(binding) else { return }
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

  private func mapControlMode(_ mode: ServerSessionControlMode) -> ControlDeckControlMode {
    switch mode {
      case .direct: .direct
      case .passive: .passive
    }
  }

  private func mapLifecycle(_ lifecycle: ServerSessionLifecycleState) -> ControlDeckLifecycle {
    switch lifecycle {
      case .open: .open
      case .resumable: .resumable
      case .ended: .ended
    }
  }
}

private extension ControlDeckMode {
  var debugLabel: String {
    switch self {
      case .compose: "compose"
      case .steer: "steer"
      case .approval: "approval"
      case .disabled: "disabled"
    }
  }
}

// MARK: - Errors

enum ControlDeckError: Error {
  case notBound
}
