import Foundation

extension ControlDeckSessionModel {
  func bind(
    sessionId: String,
    session: ServerSessionContext,
    detailSnapshotSink: ((ServerSessionDetailSnapshotPayload) -> Void)? = nil
  ) {
    let didBindingChange = currentSessionId != sessionId || currentSession !== session
    currentSessionId = sessionId
    currentSession = session
    self.detailSnapshotSink = detailSnapshotSink
    if didBindingChange {
      currentBindingRevision += 1
      refreshRunner.cancel()
      resetBoundStateForSessionChange()
    }
  }

  func bootstrap(detailPayload: ServerSessionDetailSnapshotPayload?) async {
    if let detailPayload {
      await applyExternalDetailSnapshot(detailPayload)
      return
    }
    await refresh()
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
    await loadCodexModelsIfNeeded(for: payload.session.provider, binding: binding)
  }

  func loadSkills() async {
    guard let sessionId = currentSessionId, let session = currentSession else { return }
    guard !isLoadingSkills else { return }
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
