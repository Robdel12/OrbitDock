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
  private(set) var isLoadingSkills = false
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
      applySnapshotPayload(serverSnapshot, source: "refresh")
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
    guard !isLoadingSkills else { return }
    isLoadingSkills = true
    defer { isLoadingSkills = false }

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
    let requestData = configUpdateLogData(request: request)
    print(
      "[ControlDeckTrace] config update request sid=\(sessionId) fields=\((requestData["changedFields"] as? [String]) ?? []) model=\(request.model ?? "") effort=\(request.effort ?? "") approval=\(request.approvalPolicy ?? "") permission=\(request.permissionMode ?? "") collaboration=\(request.collaborationMode ?? "") reviewer=\(request.approvalsReviewer?.rawValue ?? "")"
    )
    netLog(.info, cat: .store, "ControlDeck config update requested", sid: sessionId, data: requestData)
    do {
      let updated = try await store.clients.controlDeck.updateConfig(sessionId, request: request)
      print(
        "[ControlDeckTrace] config update response sid=\(sessionId) revision=\(updated.revision) model=\(updated.state.config.model ?? "") effort=\(updated.state.config.effort ?? "") approval=\(updated.state.config.approvalPolicy ?? "") permission=\(updated.state.config.permissionMode ?? "") collaboration=\(updated.state.config.collaborationMode ?? "") reviewer=\(updated.state.config.approvalsReviewer?.rawValue ?? "")"
      )
      applySnapshotToSessionState(updated, sessionId: sessionId, store: store)
      netLog(
        .info,
        cat: .store,
        "ControlDeck config update response received",
        sid: sessionId,
        data: snapshotLogData(snapshot: updated, source: "config_update_response")
      )
      applySnapshotPayload(updated, source: "config_update")
    } catch {
      var errorData = requestData
      errorData["error"] = String(describing: error)
      print("[ControlDeckTrace] config update failed sid=\(sessionId) error=\(String(describing: error))")
      netLog(.error, cat: .store, "ControlDeck config update failed", sid: sessionId, data: errorData)
      throw error
    }
  }

  private func applyConfigUpdate(
    action: String,
    value: String,
    configure: (inout ServerControlDeckConfigUpdateRequest) -> Void
  ) async {
    print(
      "[ControlDeckTrace] \(action) called value=\(value) hasSessionId=\(currentSessionId != nil) hasStore=\(currentSessionStore != nil)"
    )
    guard let sessionId = currentSessionId, let store = currentSessionStore else {
      print("[ControlDeckTrace] \(action) skipped missing binding")
      return
    }
    do {
      try await updateConfig(sessionId: sessionId, store: store, configure: configure)
    } catch {
      print("[ControlDeckTrace] \(action) failed error=\(String(describing: error))")
      lastError = String(describing: error)
    }
  }

  func updateModel(_ model: String) async {
    await applyConfigUpdate(action: "updateModel", value: model) { request in
      request.model = model
    }
  }

  func updateEffort(_ effort: String) async {
    await applyConfigUpdate(action: "updateEffort", value: effort) { request in
      request.effort = effort
    }
  }

  func updatePermissionMode(_ mode: String) async {
    await applyConfigUpdate(action: "updatePermissionMode", value: mode) { request in
      request.permissionMode = mode
    }
  }

  func updateApprovalPolicy(_ policy: String) async {
    await applyConfigUpdate(action: "updateApprovalPolicy", value: policy) { request in
      request.approvalPolicy = policy
    }
  }

  func updateApprovalsReviewer(_ reviewer: ServerCodexApprovalsReviewer) async {
    await applyConfigUpdate(action: "updateApprovalsReviewer", value: reviewer.rawValue) { request in
      request.approvalsReviewer = reviewer
    }
  }

  func updateCollaborationMode(_ mode: String) async {
    await applyConfigUpdate(action: "updateCollaborationMode", value: mode) { request in
      request.collaborationMode = mode
    }
  }

  func updateAutoReview(_ value: String) async {
    guard let option = snapshot?.capabilities.autoReviewOptions.first(where: { $0.value == value }) else {
      print("[ControlDeckTrace] updateAutoReview skipped missing binding or option")
      return
    }
    await applyConfigUpdate(action: "updateAutoReview", value: value) { request in
      request.approvalPolicy = option.approvalPolicy
      request.sandboxMode = option.sandboxMode
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
    let capabilities = CapabilitiesService(sessionStore: store)
    let skills = try await capabilities.listSkills(sessionId: sessionId)
    return skills.filter(\.enabled).map(ControlDeckSnapshotMapper.mapSkill)
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

  private func applySnapshotPayload(
    _ payload: ServerControlDeckSnapshotPayload,
    source: String
  ) {
    lastError = nil
    print(
      "[ControlDeckTrace] apply snapshot sid=\(payload.sessionId) source=\(source) revision=\(payload.revision) model=\(payload.state.config.model ?? "") effort=\(payload.state.config.effort ?? "") approval=\(payload.state.config.approvalPolicy ?? "") permission=\(payload.state.config.permissionMode ?? "") collaboration=\(payload.state.config.collaborationMode ?? "") reviewer=\(payload.state.config.approvalsReviewer?.rawValue ?? "") codexMode=\(payload.state.config.codexConfigMode?.rawValue ?? "") codexProfile=\(payload.state.config.codexConfigProfile ?? "") codexProvider=\(payload.state.config.codexModelProvider ?? "")"
    )
    netLog(
      .info,
      cat: .store,
      "ControlDeck snapshot apply start",
      sid: payload.sessionId,
      data: snapshotLogData(snapshot: payload, source: source)
    )
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

  private func configUpdateLogData(
    request: ServerControlDeckConfigUpdateRequest
  ) -> [String: Any] {
    let changedFields = [
      request.model != nil ? "model" : nil,
      request.effort != nil ? "effort" : nil,
      request.approvalPolicy != nil ? "approval_policy" : nil,
      request.approvalPolicyDetails != nil ? "approval_policy_details" : nil,
      request.sandboxMode != nil ? "sandbox_mode" : nil,
      request.approvalsReviewer != nil ? "approvals_reviewer" : nil,
      request.permissionMode != nil ? "permission_mode" : nil,
      request.collaborationMode != nil ? "collaboration_mode" : nil,
    ].compactMap { $0 }

    return [
      "changedFields": changedFields,
      "model": request.model ?? "",
      "effort": request.effort ?? "",
      "approvalPolicy": request.approvalPolicy ?? "",
      "approvalPolicyDetails": request.approvalPolicyDetails?.legacySummary ?? "",
      "sandboxMode": request.sandboxMode ?? "",
      "approvalsReviewer": request.approvalsReviewer?.rawValue ?? "",
      "permissionMode": request.permissionMode ?? "",
      "collaborationMode": request.collaborationMode ?? "",
    ]
  }

  private func snapshotLogData(
    snapshot: ServerControlDeckSnapshotPayload,
    source: String
  ) -> [String: Any] {
    [
      "source": source,
      "revision": snapshot.revision,
      "provider": snapshot.state.provider.rawValue,
      "controlMode": snapshot.state.controlMode.rawValue,
      "lifecycleState": snapshot.state.lifecycleState.rawValue,
      "model": snapshot.state.config.model ?? "",
      "effort": snapshot.state.config.effort ?? "",
      "approvalPolicy": snapshot.state.config.approvalPolicy ?? "",
      "sandboxMode": snapshot.state.config.sandboxMode ?? "",
      "permissionMode": snapshot.state.config.permissionMode ?? "",
      "collaborationMode": snapshot.state.config.collaborationMode ?? "",
      "approvalsReviewer": snapshot.state.config.approvalsReviewer?.rawValue ?? "",
      "codexConfigMode": snapshot.state.config.codexConfigMode?.rawValue ?? "",
      "codexConfigProfile": snapshot.state.config.codexConfigProfile ?? "",
      "codexModelProvider": snapshot.state.config.codexModelProvider ?? "",
      "effortOptions": snapshot.capabilities.effortOptions.map(\.value),
      "approvalModeOptions": snapshot.capabilities.approvalModeOptions.map(\.value),
      "permissionModeOptions": snapshot.capabilities.permissionModeOptions.map(\.value),
      "collaborationModeOptions": snapshot.capabilities.collaborationModeOptions.map(\.value),
      "autoReviewOptions": snapshot.capabilities.autoReviewOptions.map(\.value),
    ]
  }

  private func applySnapshotToSessionState(
    _ snapshot: ServerControlDeckSnapshotPayload,
    sessionId: String,
    store: SessionStore
  ) {
    let config = snapshot.state.config
    let changes = ServerStateChanges(
      approvalPolicy: .some(config.approvalPolicy),
      approvalPolicyDetails: .some(config.approvalPolicyDetails),
      sandboxMode: .some(config.sandboxMode),
      approvalsReviewer: .some(config.approvalsReviewer),
      collaborationMode: .some(config.collaborationMode),
      codexConfigMode: .some(config.codexConfigMode),
      codexConfigProfile: .some(config.codexConfigProfile),
      codexModelProvider: .some(config.codexModelProvider),
      model: .some(config.model),
      effort: .some(config.effort),
      permissionMode: .some(config.permissionMode)
    )
    store.handleSessionDelta(sessionId, changes)
    print(
      "[ControlDeckTrace] applied snapshot to shared session state sid=\(sessionId) model=\(config.model ?? "") effort=\(config.effort ?? "") permission=\(config.permissionMode ?? "") collaboration=\(config.collaborationMode ?? "")"
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
