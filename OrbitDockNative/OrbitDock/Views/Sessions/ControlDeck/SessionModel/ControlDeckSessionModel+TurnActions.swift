import Foundation

extension ControlDeckSessionModel {
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
    let result = try await session.api.sendMessage(
      content: request.content,
      model: request.model,
      effort: request.effort,
      skills: request.skills,
      images: request.images,
      mentions: request.mentions
    )
    if let snapshot = result.sessionDetailSnapshot {
      applyDetailSnapshotPayload(
        snapshot,
        source: "send_message_response",
        propagateToBindingOwner: true
      )
    }
  }

  func steerTurn(
    draft: ControlDeckDraft,
    uploadedImageIds: [String: String]
  ) async throws {
    guard currentSessionId != nil, let session = currentSession else { return }
    let result = try await session.api.steerTurn(
      content: draft.trimmedText,
      images: ControlDeckSubmitEncoder.encodeSteerImages(
        draft.attachments,
        uploadedImageIds: uploadedImageIds
      ),
      mentions: ControlDeckSubmitEncoder.encodeSteerMentions(draft.attachments)
    )
    if let snapshot = result.sessionDetailSnapshot {
      applyDetailSnapshotPayload(
        snapshot,
        source: "steer_turn_response",
        propagateToBindingOwner: true
      )
    }
  }

  func interruptSession() async {
    guard currentSessionId != nil, let session = currentSession else { return }
    do {
      if let snapshot = try await session.api.interruptSession() {
        applyDetailSnapshotPayload(
          snapshot,
          source: "interrupt_response",
          propagateToBindingOwner: true
        )
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
      let snapshot = try await session.api.resumeSession()
      guard isCurrent(binding) else { return }
      if let snapshot {
        applyDetailSnapshotPayload(
          snapshot,
          source: "resume_response",
          propagateToBindingOwner: true
        )
      } else {
        await refresh()
      }
      netLog(.info, cat: .store, "ControlDeck resume sync complete", sid: sessionId, data: [
        "lifecycle": lifecycle.rawValue,
        "controlMode": controlMode.rawValue,
        "acceptsUserInput": acceptsUserInput,
        "steerable": steerable,
        "mode": presentation?.mode.debugLabel ?? "nil",
      ])
    } catch {
      lastError = String(describing: error)
      netLog(.error, cat: .store, "ControlDeck resume failed", sid: sessionId, data: [
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
      throw ControlDeckError.notBound
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
