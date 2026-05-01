import Foundation

extension SessionInteractionModel {
  private func steerPayload(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) -> ControlDeckSubmitEncoder.SendPayload {
    ControlDeckSubmitEncoder.SendPayload(
      content: draft.trimmedText,
      model: draft.modelOverride,
      effort: draft.effortOverride,
      skills: [],
      images: ControlDeckSubmitEncoder.encodeSteerImages(
        draft.attachments,
        uploadedImageIds: uploadedImageIds
      ),
      mentions: ControlDeckSubmitEncoder.encodeSteerMentions(draft.attachments)
    )
  }

  private func queuedFollowUpPayload(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String],
    session: ServerSessionContext
  ) async throws -> ControlDeckSubmitEncoder.SendPayload {
    let availableSkills = try await resolveSkillsForSubmit(
      draft: draft,
      session: session
    )
    var payload = steerPayload(
      draft: draft,
      uploadedImageIds: uploadedImageIds
    )
    payload.skills = ControlDeckSkillResolver.resolveSkillRefs(
      content: draft.text,
      selectedSkillPaths: draft.selectedSkillPaths,
      availableSkills: availableSkills
    )
    return payload
  }

  private func submitPreparedTurn(
    _ payload: ControlDeckSubmitEncoder.SendPayload,
    session: ServerSessionContext
  ) async throws {
    let result = try await session.api.sendMessage(
      content: payload.content,
      model: payload.model,
      effort: payload.effort,
      skills: payload.skills,
      images: payload.images,
      mentions: payload.mentions
    )
    conversationRowSink?(result.row)
    if let snapshot = result.sessionDetailSnapshot {
      acceptAuthoritativeDetailSnapshot(
        snapshot,
        source: "send_message_response"
      )
    }
  }

  private func mergedPendingPayload(
    existing: ControlDeckSubmitEncoder.SendPayload,
    next: ControlDeckSubmitEncoder.SendPayload
  ) -> ControlDeckSubmitEncoder.SendPayload {
    let combinedContent = [existing.content, next.content]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    return ControlDeckSubmitEncoder.SendPayload(
      content: combinedContent,
      model: next.model ?? existing.model,
      effort: next.effort ?? existing.effort,
      skills: mergeSkills(existing.skills, next.skills),
      images: existing.images + next.images,
      mentions: existing.mentions + next.mentions
    )
  }

  private func mergeSkills(
    _ existing: [ServerSkillInput],
    _ next: [ServerSkillInput]
  ) -> [ServerSkillInput] {
    var merged = existing
    var seenPaths = Set(existing.map(\.path))
    for skill in next where !seenPaths.contains(skill.path) {
      merged.append(skill)
      seenPaths.insert(skill.path)
    }
    return merged
  }

  private func queuePendingFollowUpTurn(
    payload: ControlDeckSubmitEncoder.SendPayload,
    strategy: PendingFollowUpTurn.Strategy
  ) {
    if let existing = pendingFollowUpTurn {
      pendingFollowUpTurn = PendingFollowUpTurn(
        payload: mergedPendingPayload(existing: existing.payload, next: payload),
        strategy: existing.strategy == .afterInterrupt ? .afterInterrupt : strategy
      )
    } else {
      pendingFollowUpTurn = PendingFollowUpTurn(payload: payload, strategy: strategy)
    }
  }

  func processPendingFollowUpTurnIfPossible() {
    guard pendingFollowUpTask == nil else { return }
    guard !isSendingPendingFollowUp else { return }
    guard let pendingFollowUpTurn, let binding = currentBindingContext else { return }
    guard acceptsUserInput, lifecycle == .open else { return }
    guard pendingApproval == nil else { return }

    let payload = pendingFollowUpTurn.payload
    isSendingPendingFollowUp = true
    pendingFollowUpTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.isCurrent(binding) {
          self.isSendingPendingFollowUp = false
          self.pendingFollowUpTask = nil
        }
      }

      do {
        try await self.submitPreparedTurn(payload, session: binding.session)
        guard self.isCurrent(binding) else { return }
        self.pendingFollowUpTurn = nil
        self.lastError = nil
      } catch {
        guard self.isCurrent(binding) else { return }
        self.lastError = error.localizedDescription
      }
    }
  }

  func submitShellCommand(draft: ControlDeckDraft) async throws {
    guard let session = currentSession else { return }
    if draft.attachments.hasItems {
      throw NSError(
        domain: "OrbitDock.SessionShell",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Session shell commands do not support attachments yet."]
      )
    }

    let command = ControlDeckSubmissionPlanner.normalizedShellCommand(from: draft)
    guard !command.isEmpty else {
      throw NSError(
        domain: "OrbitDock.SessionShell",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Enter a shell command to run in this session."]
      )
    }

    if let snapshot = try await session.api.runSessionShellCommand(command: command) {
      acceptAuthoritativeDetailSnapshot(
        snapshot,
        source: "session_shell_command_response"
      )
    }
  }

  func submitTurn(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) async throws {
    guard let session = currentSession else { return }
    let availableSkills = try await resolveSkillsForSubmit(
      draft: draft,
      session: session
    )

    let request = ControlDeckSubmitEncoder.encode(
      draft: draft,
      uploadedImageIds: uploadedImageIds,
      availableSkills: availableSkills
    )
    try await submitPreparedTurn(request, session: session)
  }

  func steerTurn(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) async throws {
    guard currentSessionId != nil, let session = currentSession else { return }
    let payload = steerPayload(draft: draft, uploadedImageIds: uploadedImageIds)
    do {
      let result = try await session.api.steerTurn(
        content: payload.content,
        images: payload.images,
        mentions: payload.mentions,
        expectedTurnId: currentTurnId
      )
      conversationRowSink?(result.row)
      if let snapshot = result.sessionDetailSnapshot {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "steer_turn_response"
        )
      }
    } catch let error as ServerRequestError {
      if error.apiErrorCode == "not_steerable" || error.apiErrorCode == "active_turn_mismatch" {
        let queuedPayload = try await queuedFollowUpPayload(
          draft: draft,
          uploadedImageIds: uploadedImageIds,
          session: session
        )
        queuePendingFollowUpTurn(payload: queuedPayload, strategy: .whenCurrentTurnEnds)
        lastError = nil
        processPendingFollowUpTurnIfPossible()
        return
      }
      throw error
    }
  }

  func interruptAndSendQueuedDraft(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) async throws {
    guard let session = currentSession else { return }
    let availableSkills = try await resolveSkillsForSubmit(
      draft: draft,
      session: session
    )
    let payload = ControlDeckSubmitEncoder.encode(
      draft: draft,
      uploadedImageIds: uploadedImageIds,
      availableSkills: availableSkills
    )
    queuePendingFollowUpTurn(payload: payload, strategy: .afterInterrupt)
    await interruptSession()
  }

  func interruptSession() async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.interruptSession() {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "interrupt_response"
        )
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func undoLastTurn() async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.undoLastTurn() {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "undo_response"
        )
        await refreshControls()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func compactContext() async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.compactContext() {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "compact_response"
        )
        await refreshControls()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func rollbackTurns(_ count: Int) async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.rollbackTurns(numTurns: UInt32(count)) {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "rollback_response"
        )
        await refreshControls()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func rewindToMessage(_ messageId: String) async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.rewindToMessage(messageId: messageId) {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "rewind_response"
        )
        await refreshControls()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func stopTarget(_ targetId: String) async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.stopTarget(targetId: targetId) {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "stop_target_response"
        )
        await refreshControls()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  func resumeSession() async {
    guard let binding = currentBindingContext else { return }
    let sessionId = binding.sessionId
    let session = binding.session
    guard !isResuming else { return }
    isResuming = true
    netLog(.info, cat: .store, "Session interaction resume started", sid: sessionId, data: [
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
      let snapshot = try await session.api.resumeSession()
      guard isCurrent(binding) else { return }
      if let snapshot {
        acceptAuthoritativeDetailSnapshot(
          snapshot,
          source: "resume_response"
        )
      } else {
        await refresh()
      }
      netLog(.info, cat: .store, "Session interaction resume sync complete", sid: sessionId, data: [
        "lifecycle": lifecycle.rawValue,
        "controlMode": controlMode.rawValue,
        "acceptsUserInput": acceptsUserInput,
        "steerable": steerable,
        "mode": presentation?.mode.debugLabel ?? "nil",
      ])
    } catch {
      lastError = String(describing: error)
      netLog(.error, cat: .store, "Session interaction resume failed", sid: sessionId, data: [
        "error": String(describing: error),
      ])
    }
  }

  func uploadImage(
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int?,
    pixelHeight: Int?
  ) async throws -> String {
    guard let session = currentSession else {
      throw SessionInteractionError.notBound
    }

    let result = try await session.api.uploadImageAttachment(
      data: data,
      mimeType: mimeType,
      displayName: displayName,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    return result.value
  }
}
