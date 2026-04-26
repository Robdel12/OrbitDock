import Foundation

extension SessionInteractionModel {
  var projectFileIndex: ProjectFileIndex? {
    currentSession?.projectFileIndex
  }

  var projectPath: String? {
    snapshot?.state.projectPath
  }

  var canSubmit: Bool {
    snapshot?.state.acceptsUserInput ?? false
  }

  var availableModels: [String] {
    guard let session = currentSession, let snap = snapshot else { return [] }
    switch snap.state.provider {
      case .claude:
        return ServerClaudeModelOption.defaults.map(\.value)
      case .codex:
        return session.codexModels.map(\.model)
    }
  }

  func fetchEnabledSkills(session: ServerSessionContext) async throws -> [ControlDeckSkill] {
    let response = try await session.api.listSkills()
    let allSkills = response.skills.flatMap(\.skills)
    return allSkills.filter(\.enabled).map(ControlDeckSnapshotMapper.mapSkill)
  }

  func resolveSkillsForSubmit(
    draft: ControlDeckDraft,
    session: ServerSessionContext
  ) async throws -> [ControlDeckSkill] {
    if !skills.isEmpty {
      return skills
    }

    let requiresSkillResolution = draft.text.contains("$") || !draft.selectedSkillPaths.isEmpty
    guard requiresSkillResolution else { return [] }

    let fetched = try await fetchEnabledSkills(session: session)
    skills = fetched
    return fetched
  }

  func applyDetailSnapshotPayload(
    _ payload: ServerSessionDetailSnapshotPayload,
    source: String,
    propagateToBindingOwner: Bool
  ) {
    if let currentRevision = snapshot?.revision, payload.revision < currentRevision {
      return
    }
    currentSession?.transport.recordRevision(payload.revision)
    netLog(
      .info,
      cat: .store,
      "Session interaction snapshot apply start",
      sid: payload.session.id,
      data: snapshotLogData(snapshot: payload, source: source)
    )
    snapshot = ControlDeckSnapshotMapper.map(
      payload,
      codexModels: currentSession?.codexModels ?? [],
      controls: controls
    )
    lastError = nil
    rebuildPresentation()
    logSessionStateIfChanged(source: "applyDetail(\(source))")
    if propagateToBindingOwner {
      detailSnapshotSink?(payload)
    }
  }

  func acceptAuthoritativeDetailSnapshot(
    _ payload: ServerSessionDetailSnapshotPayload,
    source: String
  ) {
    if let detailSnapshotSink {
      detailSnapshotSink(payload)
    } else {
      applyDetailSnapshotPayload(
        payload,
        source: source,
        propagateToBindingOwner: false
      )
    }
  }

  func clearPendingApprovalOptimistically() {
    guard let current = snapshot else { return }
    snapshot = current.replacing(pendingApproval: .some(nil))
    rebuildPresentation()
  }

  func logSessionStateIfChanged(source: String) {
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
    netLog(.debug, cat: .store, "Session interaction state updated", sid: currentSessionId, data: [
      "source": source,
      "lifecycle": lifecycle.rawValue,
      "controlMode": controlMode.rawValue,
      "acceptsUserInput": acceptsUserInput,
      "steerable": steerable,
      "pendingApprovalId": pendingApproval?.requestId ?? "",
      "presentationMode": presentation?.mode.debugLabel ?? "nil",
    ])
  }

  func resetBoundStateForSessionChange() {
    snapshot = nil
    presentation = nil
    skills = []
    controls = nil
    isLoadingSkills = false
    hasAttemptedSkillLoad = false
    isLoading = false
    isResuming = false
    lastError = nil
    lastLoggedSessionSignature = nil
  }

  func requestRefresh() {
    refreshRunner.schedule { [weak self] in
      await self?.performRefresh()
    }
  }

  func performRefresh() async {
    guard let binding = currentBindingContext else { return }

    isLoading = true
    defer {
      if isCurrent(binding) {
        isLoading = false
      }
    }

    let sessionId = binding.sessionId
    let session = binding.session

    netLog(.debug, cat: .store, "Session interaction refresh started", sid: sessionId)
    do {
      let serverSnapshot = try await session.api.fetchSessionDetail()
      guard isCurrent(binding) else { return }
      acceptAuthoritativeDetailSnapshot(
        serverSnapshot,
        source: "refresh"
      )
      if detailSnapshotSink == nil {
        await loadSupportData(for: serverSnapshot.session, binding: binding)
      }
      guard isCurrent(binding) else { return }
      netLog(.debug, cat: .store, "Session interaction refresh finished", sid: sessionId)
    } catch {
      guard isCurrent(binding) else { return }
      lastError = String(describing: error)
      netLog(.error, cat: .store, "Session interaction refresh failed", sid: sessionId, data: [
        "error": String(describing: error),
      ])
    }
  }

  var currentBindingContext: BindingContext? {
    guard let sessionId = currentSessionId, let session = currentSession else { return nil }
    return BindingContext(
      sessionId: sessionId,
      session: session,
      revision: currentBindingRevision
    )
  }

  func isCurrent(_ binding: BindingContext) -> Bool {
    currentSessionId == binding.sessionId
      && currentSession === binding.session
      && currentBindingRevision == binding.revision
  }

  func loadCodexModelsIfNeeded(for provider: ServerProvider, binding: BindingContext) async {
    guard provider == .codex else {
      if isCurrent(binding) {
        rebuildPresentation()
      }
      return
    }

    guard isCurrent(binding) else { return }
    let session = binding.session
    guard session.codexModels.isEmpty else {
      rebuildPresentation()
      return
    }

    if let models = try? await session.api.listCodexModels() {
      guard isCurrent(binding) else { return }
      session.codexModels = models
    }

    guard isCurrent(binding) else { return }
    rebuildPresentation()
  }

  func loadSupportData(
    for session: ServerSessionState,
    binding: BindingContext
  ) async {
    await loadCodexModelsIfNeeded(for: session.provider, binding: binding)
    await loadProjectFileIndexIfNeeded(for: session.projectPath, binding: binding)
    await loadControlsIfNeeded(binding: binding)
    await loadSkillsIfNeeded(for: session.provider, binding: binding)
  }

  func loadControlsIfNeeded(binding: BindingContext) async {
    guard isCurrent(binding) else { return }
    let session = binding.session

    do {
      let fetchedControls = try await session.api.fetchSessionControls()
      guard isCurrent(binding) else { return }
      controls = fetchedControls
      updateSnapshotWithControls(fetchedControls)
    } catch {
      // Controls are optional — don't fail the load if they're unavailable
      netLog(.debug, cat: .store, "Session controls fetch skipped", sid: binding.sessionId, data: [
        "error": String(describing: error)
      ])
    }
  }

  func updateSnapshotWithControls(_ newControls: ServerSessionControlsPayload) {
    guard let current = snapshot else { return }
    snapshot = current.replacing(
      sessionShell: ControlDeckSnapshotMapper.mapSessionShell(newControls),
      turnControls: ControlDeckSnapshotMapper.mapTurnControls(newControls)
    )
    rebuildPresentation()
  }

  func refreshControls() async {
    guard let binding = currentBindingContext else { return }
    await loadControlsIfNeeded(binding: binding)
  }

  func loadSkillsIfNeeded(for provider: ServerProvider, binding: BindingContext) async {
    guard provider == .codex else { return }
    guard isCurrent(binding) else { return }
    await loadSkills()
  }

  func loadProjectFileIndexIfNeeded(for projectPath: String?, binding: BindingContext) async {
    guard let projectPath, !projectPath.isEmpty else { return }
    guard isCurrent(binding) else { return }
    await binding.session.projectFileIndex.loadIfNeeded(projectPath)
  }

  func rebuildPresentation() {
    guard let snapshot else {
      presentation = nil
      return
    }

    presentation = ControlDeckPresentationBuilder.build(
      snapshot: snapshot,
      isLoading: isLoading,
      availableModels: availableModels
    )
  }

  func configUpdateLogData(
    request: SessionsClient.UpdateSessionConfigRequest
  ) -> [String: Any] {
    let changedFields = [
      request.model != nil ? "model" : nil,
      request.effort != nil ? "effort" : nil,
      request.approvalPolicyDetails != nil ? "approval_policy_details" : nil,
      request.sandboxPolicyDetails != nil ? "sandbox_policy_details" : nil,
      request.approvalsReviewer != nil ? "approvals_reviewer" : nil,
      request.permissionMode != nil ? "permission_mode" : nil,
      request.collaborationMode != nil ? "collaboration_mode" : nil,
      request.multiAgent != nil ? "multi_agent" : nil,
      request.personality != nil ? "personality" : nil,
      request.serviceTier != nil ? "service_tier" : nil,
      request.developerInstructions != nil ? "developer_instructions" : nil,
    ].compactMap { $0 }

    return [
      "changedFields": changedFields,
      "model": request.model ?? "",
      "effort": request.effort ?? "",
      "approvalPolicyDetails": request.approvalPolicyDetails?.summaryText ?? "",
      "sandboxPolicyDetails": request.sandboxPolicyDetails?.summaryText ?? "",
      "approvalsReviewer": request.approvalsReviewer?.rawValue ?? "",
      "permissionMode": request.permissionMode ?? "",
      "collaborationMode": request.collaborationMode ?? "",
      "multiAgent": request.multiAgent as Any,
      "personality": request.personality ?? "",
      "serviceTier": request.serviceTier ?? "",
    ]
  }

  func snapshotLogData(
    snapshot: ServerSessionDetailSnapshotPayload,
    source: String
  ) -> [String: Any] {
    [
      "source": source,
      "revision": snapshot.revision,
      "provider": snapshot.session.provider.rawValue,
      "controlMode": snapshot.session.controlMode.rawValue,
      "lifecycleState": snapshot.session.lifecycleState.rawValue,
      "model": snapshot.session.model ?? "",
      "effort": snapshot.session.effort ?? "",
      "approvalPolicy": snapshot.session.approvalPolicy ?? "",
      "sandboxMode": snapshot.session.sandboxMode ?? "",
      "sandboxPolicyDetails": snapshot.session.sandboxPolicyDetails?.summaryText ?? "",
      "permissionMode": snapshot.session.permissionMode ?? "",
      "collaborationMode": snapshot.session.collaborationMode ?? "",
      "approvalsReviewer": snapshot.session.codexConfigOverrides?.approvalsReviewer?.rawValue ?? "",
      "codexConfigMode": snapshot.session.codexConfigMode?.rawValue ?? "",
      "codexConfigProfile": snapshot.session.codexConfigProfile ?? "",
      "codexModelProvider": snapshot.session.codexModelProvider ?? "",
      "pendingApproval": snapshot.session.pendingApproval?.id ?? "",
    ]
  }
}
