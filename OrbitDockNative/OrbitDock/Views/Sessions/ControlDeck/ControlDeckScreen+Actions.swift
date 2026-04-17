import SwiftUI

extension ControlDeckScreen {
  func handleTextChange(_ text: String) {
    let shouldLoadSkills = composer.handleTextChange(text, availableSkills: sessionModel.skills)
    if shouldLoadSkills {
      Task { await sessionModel.loadSkills() }
    }
  }

  func handleKeyCommand(_ command: ControlDeckTextAreaKeyCommand) -> Bool {
    switch composer.handleKeyCommand(command, suggestions: currentSuggestions, canSubmit: canSubmit) {
    case .ignored:
      return false
    case .handled:
      return true
    case .submit:
      submitDraft()
      return true
    case let .accept(suggestion):
      acceptSuggestion(suggestion)
      return true
    }
  }

  func handleFocusEvent(_ event: ControlDeckTextAreaFocusEvent) {
    onFocusStateChange?(composer.handleFocusEvent(event))
  }

  func handleModuleAction(_ module: ControlDeckStatusModule, _ value: String) {
    netLog(.info, cat: .store, "ControlDeck module action tapped", sid: sessionId, data: [
      "module": module.rawValue,
      "value": value,
    ])
    Task {
      switch module {
      case .model:
        await sessionModel.updateModel(value)
      case .effort:
        await sessionModel.updateEffort(value)
      case .autonomy:
        await sessionModel.updatePermissionMode(value)
      case .approvalMode:
        await sessionModel.updateApprovalPolicy(value)
      case .collaborationMode:
        await sessionModel.updateCollaborationMode(value)
      case .autoReview:
        await sessionModel.updateAutoReview(value)
      default:
        break
      }
    }
  }

  func handleApprovalReviewerAction(_ reviewer: ServerCodexApprovalsReviewer) {
    netLog(.info, cat: .store, "ControlDeck approval reviewer action tapped", sid: sessionId, data: [
      "reviewer": reviewer.rawValue
    ])
    Task {
      await sessionModel.updateApprovalsReviewer(reviewer)
    }
  }

  func handleSandboxPolicyAction(_ policy: ServerCodexSandboxPolicy) {
    netLog(.info, cat: .store, "ControlDeck sandbox policy action tapped", sid: sessionId, data: [
      "policy": policy.legacySummary
    ])
    Task {
      await sessionModel.updateSandboxPolicy(policy)
    }
  }

  func acceptSuggestion(_ suggestion: ControlDeckCompletionSuggestion) {
    composer.acceptSuggestion(
      suggestion,
      availableSkills: sessionModel.skills,
      projectPath: sessionModel.projectPath,
      projectFileIndex: sessionModel.projectFileIndex
    )
  }

  func submitDraft() {
    guard composer.draft.hasContent, !composer.isSubmitting else { return }

    let submissionAction = ControlDeckSubmissionPlanner.action(for: currentMode)
    composer.isSubmitting = true
    let currentDraft = composer.draft

    Task {
      defer { composer.isSubmitting = false }

      do {
        var imageIds = composer.uploadedImageIds
        for image in currentDraft.attachments.images where imageIds[image.localId] == nil {
          let attachmentId = try await sessionModel.uploadImage(
            data: image.uploadData,
            mimeType: image.uploadMimeType,
            displayName: image.displayName,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight
          )
          imageIds[image.localId] = attachmentId
        }

        composer.uploadedImageIds = imageIds

        if submissionAction == .steerTurn {
          try await sessionModel.steerTurn(draft: currentDraft, uploadedImageIds: imageIds)
        } else {
          try await sessionModel.submitTurn(draft: currentDraft, uploadedImageIds: imageIds)
        }

        sessionModel.lastError = nil
        composer.clearDraft(for: sessionId)
      } catch {
        sessionModel.lastError = String(describing: error)
        await sessionModel.refresh()
      }
    }
  }

  func resumeSession() {
    guard !composer.isSubmitting else { return }
    netLog(.info, cat: .store, "ControlDeckScreen resume tapped", sid: sessionId, data: [
      "isSubmitting": composer.isSubmitting,
      "isResuming": sessionModel.isResuming,
      "presentationMode": sessionModel.presentation?.mode.debugLabel ?? "nil",
      "canResume": sessionModel.presentation?.canResume ?? false
    ])
    Task { await sessionModel.resumeSession() }
  }

  func handleAttachmentImport(_ result: Result<[URL], Error>) {
    if let error = composer.handleAttachmentImport(result, projectPath: sessionModel.projectPath) {
      sessionModel.lastError = error
    }
  }

  func toggleDictation() {
    Task {
      if let error = await composer.toggleDictation(localDictationEnabled: localDictationEnabled) {
        sessionModel.lastError = error
      }
    }
  }
}
