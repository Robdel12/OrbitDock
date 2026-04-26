import Foundation

extension SessionInteractionModel {
  func bind(
    sessionId: String,
    session: ServerSessionContext,
    detailSnapshotSink: ((ServerSessionDetailSnapshotPayload) -> Void)? = nil,
    conversationRowSink: ((ServerConversationRowEntry) -> Void)? = nil
  ) {
    let didBindingChange = currentSessionId != sessionId || currentSession !== session
    currentSessionId = sessionId
    currentSession = session
    self.detailSnapshotSink = detailSnapshotSink
    self.conversationRowSink = conversationRowSink
    if didBindingChange {
      currentBindingRevision += 1
      refreshRunner.cancel()
      resetBoundStateForSessionChange()
    }
  }

  func refresh() async {
    requestRefresh()
    await refreshRunner.waitForCurrentRefresh()
  }

  func applyExternalDetailSnapshot(
    _ payload: ServerSessionDetailSnapshotPayload,
    source: String = "session_detail_parent"
  ) async {
    applyDetailSnapshotPayload(
      payload,
      source: source,
      propagateToBindingOwner: false
    )
    guard let binding = currentBindingContext else { return }
    await loadSupportData(for: payload.session, binding: binding)
  }

  func applyOwnerDetailSnapshot(
    _ payload: ServerSessionDetailSnapshotPayload,
    source: String = "session_detail_owner"
  ) {
    applyDetailSnapshotPayload(
      payload,
      source: source,
      propagateToBindingOwner: false
    )
    guard let binding = currentBindingContext else { return }
    Task {
      await loadSupportData(for: payload.session, binding: binding)
    }
  }

  func loadSkills(force: Bool = false) async {
    guard let sessionId = currentSessionId, let session = currentSession else { return }
    guard force || !hasAttemptedSkillLoad else { return }
    guard !isLoadingSkills else { return }
    hasAttemptedSkillLoad = true
    isLoadingSkills = true
    defer { isLoadingSkills = false }

    do {
      skills = try await fetchEnabledSkills(session: session)
    } catch {
      netLog(.debug, cat: .store, "Skills load failed (non-critical)", sid: sessionId, data: [
        "error": String(describing: error),
      ])
    }
  }
}
